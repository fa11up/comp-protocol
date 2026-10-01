#!/usr/bin/env node
/**
 * Relay a signed IdentityMD oracle attestation into our live PriceFeed.
 *
 *   node relay-attestation.js <oracleRequestId> [--dry]
 *
 * The feed pins the attester and builds its EIP-712 domain from block.chainid + address(this),
 * so the oracle request MUST have carried consumer {chainId: 11155111, verifyingContract: <feed>}
 * (lowercase — a checksummed address is rejected with a bare 400 at /requests/quote).
 *
 * Every precondition SwarmFeed.submitAttestation enforces is checked locally first, so a doomed
 * relay costs no gas and says exactly which guard would have failed.
 */
const https = require('https');
const ethers = require('ethers');
// Reporter/relayer key. Never commit a filled-in copy.
const cfg = require('./relayer.config.js');

const FEED = '0x5bEc0f48C7e054d84be5A96e9E7aA5530c2369F0';
const RPC = 'https://ethereum-sepolia-public.nodies.app';
const ANSWER_TYPE = { bool: 0, address: 1, bytes32: 2, uint256: 3 }; // recovered empirically

const FEED_ABI = [
  'function attester() view returns (address)',
  'function relayer() view returns (address)',
  'function attestationChainId() view returns (uint256)',
  'function attestationAnswerType() view returns (uint8)',
  'function maxAge() view returns (uint256)',
  'function maxDeviationBps() view returns (uint256)',
  'function isStale() view returns (bool)',
  'function latestValue() view returns (uint256,uint64)',
  'function usedRequests(bytes32) view returns (bool)',
  'function DOMAIN_SEPARATOR() view returns (bytes32)',
  'function ATTESTATION_TYPEHASH() view returns (bytes32)',
  'function submitAttestation((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint64,uint64),bytes)',
];

const get = p => new Promise((res, rej) =>
  https.get('https://api.imd.fun' + p, r => {
    let b = ''; r.on('data', c => b += c);
    r.on('end', () => { try { res({ status: r.statusCode, body: JSON.parse(b) }); } catch (e) { rej(e); } });
  }).on('error', rej));

(async () => {
  const id = process.argv[2];
  const dry = process.argv.includes('--dry');
  if (!id) { console.error('usage: node relay-attestation.js <oracleRequestId> [--dry]'); process.exit(1); }

  const a = await get(`/oracle/requests/${id}/attestation`);
  if (a.status !== 200) {
    const st = await get(`/oracle/requests/${id}`);
    console.error(`not attested (HTTP ${a.status}); request status: ${st.body && st.body.status}`);
    if (st.body && st.body.failure) console.error('failure:', st.body.failure);
    process.exit(1);
  }
  const { domain, message: m, signature, signer } = a.body;

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const wallet = ethers.Wallet.fromMnemonic(cfg.MNEMONIC, "m/44'/60'/0'/0/0").connect(provider);
  const feed = new ethers.Contract(FEED, FEED_ABI, wallet);

  const answerType = typeof m.answerType === 'string' ? ANSWER_TYPE[m.answerType] : Number(m.answerType);
  const tuple = [m.requestId, ethers.BigNumber.from(m.chainId), m.questionHash, answerType, m.answer,
    ethers.BigNumber.from(m.figure), m.fromBlock, m.toBlock, m.blockHash, m.panelJobId, m.issuedAt, m.expiresAt];

  // --- local preflight: every guard submitAttestation applies, checked before spending gas ---
  const [attester, relayer, chainId, wantType, maxAge, devBps, used, sep] = await Promise.all([
    feed.attester(), feed.relayer(), feed.attestationChainId(), feed.attestationAnswerType(),
    feed.maxAge(), feed.maxDeviationBps(), feed.usedRequests(m.requestId), feed.DOMAIN_SEPARATOR(),
  ]);
  const [curVal, curAt] = await feed.latestValue();
  const now = Math.floor(Date.now() / 1000);
  const fail = [];

  if (signer.toLowerCase() !== attester.toLowerCase()) fail.push(`signer ${signer} != attester ${attester}`);
  if (wallet.address.toLowerCase() !== relayer.toLowerCase()) fail.push(`we are not the relayer (${relayer})`);
  if (!ethers.BigNumber.from(m.chainId).eq(chainId)) fail.push(`payload chainId ${m.chainId} != ${chainId}`);
  if (answerType !== wantType) fail.push(`answerType ${answerType} (${m.answerType}) != ${wantType}`);
  if (used) fail.push('requestId already consumed');
  if (now > Number(m.expiresAt)) fail.push(`expired ${now - Number(m.expiresAt)}s ago`);
  if (now - Number(m.issuedAt) > Number(maxAge)) fail.push('issuedAt older than maxAge');
  if (curAt && Number(m.issuedAt) < Number(curAt)) fail.push('older than the stored value');
  if (ethers.BigNumber.from(m.figure).isZero()) fail.push('figure is zero');
  if (!curVal.isZero()) {
    const f = ethers.BigNumber.from(m.figure);
    const change = f.gt(curVal) ? f.sub(curVal) : curVal.sub(f);
    const allowed = curVal.mul(devBps).div(10000);
    if (change.gt(allowed)) fail.push(`deviation ${change} > allowed ${allowed} (needs successive updates)`);
  }
  // The domain the service signed must equal the one the feed will rebuild.
  const expected = ethers.utils._TypedDataEncoder.hashDomain(domain);
  if (expected !== sep) fail.push(`domain mismatch: signed ${expected} vs feed ${sep} — was consumer set?`);

  console.log(`request ${id}`);
  console.log(`  figure       ${m.figure}`);
  console.log(`  questionHash ${m.questionHash}`);
  console.log(`  window       ${m.fromBlock}..${m.toBlock}`);
  console.log(`  ttl left     ${Number(m.expiresAt) - now}s`);
  console.log(`  domain ok    ${expected === sep}`);
  if (fail.length) { console.error('\nWOULD REVERT:\n  - ' + fail.join('\n  - ')); process.exit(1); }
  console.log('\nall guards pass');
  if (dry) return console.log('(dry run, nothing sent)');

  const tx = await feed.submitAttestation(tuple, signature);
  console.log('submitted', tx.hash);
  const rc = await tx.wait();
  console.log('mined in block', rc.blockNumber, '| gas', rc.gasUsed.toString());
  const [v, at] = await feed.latestValue();
  console.log(`feed now: value ${v.toString()} updatedAt ${at} stale ${await feed.isStale()}`);
})();
