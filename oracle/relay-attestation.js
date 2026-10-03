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
// Relayer key: a local file this repository does not carry. See RUNBOOK.
const cfg = require('./relayer.config.js');

// The feed this attestation was asked FOR. The request's consumer.verifyingContract must equal it,
// or the service signed under a different domain and the relay cannot work. Override for the NHI or
// spot feed: FEED=0x... node relay-attestation.js <id>
const FEED = process.env.FEED || '0xC677A113e06d70a313FfB459B291ec4bEcF5AB18';
const RPC = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const ANSWER_TYPE = { bool: 0, address: 1, bytes32: 2, uint256: 3 }; // recovered empirically

const RELAY_ABI = [
  'function relay(address feed,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64) a,bytes sig)',
];
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
  'function MIN_PANEL_SIZE() view returns (uint16)',
  'function MIN_AGREED() view returns (uint16)',
  // Attestation v2: panelSize, quorum and agreed are signed, and sit between panelJobId and issuedAt.
  'function submitAttestation((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)',
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
  if (m.panelSize == null || m.agreed == null) {
    console.error('attestation carries no panelSize/agreed — this is a v1 payload and the feed verifies v2');
    process.exit(1);
  }
  const tuple = [m.requestId, ethers.BigNumber.from(m.chainId), m.questionHash, answerType, m.answer,
    ethers.BigNumber.from(m.figure), m.fromBlock, m.toBlock, m.blockHash, m.panelJobId,
    m.panelSize, m.quorum, m.agreed, m.issuedAt, m.expiresAt];

  // --- local preflight: every guard submitAttestation applies, checked before spending gas ---
  const [attester, relayer, chainId, wantType, maxAge, devBps, used, sep, minPanel, minAgreed] = await Promise.all([
    feed.attester(), feed.relayer(), feed.attestationChainId(), feed.attestationAnswerType(),
    feed.maxAge(), feed.maxDeviationBps(), feed.usedRequests(m.requestId), feed.DOMAIN_SEPARATOR(),
    feed.MIN_PANEL_SIZE(), feed.MIN_AGREED(),
  ]);
  const [curVal, curAt] = await feed.latestValue();
  const now = Math.floor(Date.now() / 1000);
  const fail = [];

  if (signer.toLowerCase() !== attester.toLowerCase()) fail.push(`signer ${signer} != attester ${attester}`);
  // The relayer may be an EOA or SwarmRelay. If it is a contract, we cannot call the feed directly —
  // we go through it, and anyone may. The feeds live today still pin an EOA; a redeployment moves to
  // the relay, and this handles both without being told which.
  const relayerCode = await provider.getCode(relayer);
  const viaRelay = relayerCode !== '0x';
  if (!viaRelay && wallet.address.toLowerCase() !== relayer.toLowerCase()) {
    fail.push(`we are not the relayer (${relayer}) and it is not a contract we can route through`);
  }
  if (!ethers.BigNumber.from(m.chainId).eq(chainId)) fail.push(`payload chainId ${m.chainId} != ${chainId}`);
  if (answerType !== wantType) fail.push(`answerType ${answerType} (${m.answerType}) != ${wantType}`);
  if (used) fail.push('requestId already consumed');
  if (now > Number(m.expiresAt)) fail.push(`expired ${now - Number(m.expiresAt)}s ago`);
  if (now - Number(m.issuedAt) > Number(maxAge)) fail.push('issuedAt older than maxAge');
  if (curAt && Number(m.issuedAt) < Number(curAt)) fail.push('older than the stored value');
  if (ethers.BigNumber.from(m.figure).isZero()) fail.push('figure is zero');
  // The floors that made a perfect 14-of-14 attestation unrelayable once: the feed checks the SIGNED
  // panel, not what the request asked for.
  if (Number(m.panelSize) < Number(minPanel)) fail.push(`panelSize ${m.panelSize} < feed floor ${minPanel}`);
  if (Number(m.agreed) < Number(minAgreed)) fail.push(`agreed ${m.agreed} < feed floor ${minAgreed}`);
  if (Number(m.agreed) > Number(m.panelSize)) fail.push(`agreed ${m.agreed} > panelSize ${m.panelSize}`);
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
  console.log(`  panel        ${m.panelSize} members, ${m.agreed} agreed (feed needs ${minPanel}/${minAgreed})`);
  console.log(`  feed         ${FEED}`);
  console.log(`  route        ${viaRelay ? 'through SwarmRelay ' + relayer + ' (permissionless)' : 'direct, as the pinned EOA'}`);
  console.log(`  ttl left     ${Number(m.expiresAt) - now}s`);
  console.log(`  domain ok    ${expected === sep}`);
  if (fail.length) { console.error('\nWOULD REVERT:\n  - ' + fail.join('\n  - ')); process.exit(1); }
  console.log('\nall guards pass');
  if (dry) return console.log('(dry run, nothing sent)');

  const tx = viaRelay
    ? await new ethers.Contract(relayer, RELAY_ABI, wallet).relay(FEED, tuple, signature)
    : await feed.submitAttestation(tuple, signature);
  console.log('submitted', tx.hash);
  const rc = await tx.wait();
  console.log('mined in block', rc.blockNumber, '| gas', rc.gasUsed.toString());
  const [v, at] = await feed.latestValue();
  console.log(`feed now: value ${v.toString()} updatedAt ${at} stale ${await feed.isStale()}`);
})();
