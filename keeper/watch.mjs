#!/usr/bin/env node
// The price-movement watcher: decides WHEN a feed needs a new attestation, and never buys one.
//
// WHY MOVEMENT AND NOT A CLOCK. A SwarmFeed accepts at most `maxDeviationBps` of change per update
// while its current value is fresh. So the cap and the update cadence are one knob, not two: a cap is
// only safe if the market cannot move further than the cap between updates. Updating on a schedule
// gets this wrong in both directions — it pays for requests in a flat market and still misses a fast
// one. IMD moved 44.6% in a day while we watched, and a request bought with guards pinned to the old
// level was refused by the panel, costing 0.5 IMD for nothing.
//
// So: watch the pool continuously, and fire when spot leaves a band NARROWER than the cap.
//
// IT DOES NOT SPEND. Buying an oracle request costs 0.5 IMD and cannot be undone, and a submitted
// request cannot be cancelled by us. This prints the exact commands instead. Automating the spend is
// a deliberate later decision, not an oversight — see README.
import { providers, Contract, BigNumber, utils } from "ethers";
import { readSpot } from "./lib/pool.mjs";
import cfg from "./config.js";

const FEED_ABI = [
  "function latestValue() view returns (uint256 value, uint64 updatedAt)",
  "function isStale() view returns (bool)",
  "function maxAge() view returns (uint256)",
  "function maxDeviationBps() view returns (uint256)",
  "function lastToBlock() view returns (uint64)",
];

const BPS = 10_000;
const bps = (a, b) => (b.isZero() ? null : a.sub(b).abs().mul(BPS).div(b).toNumber());
const ago = (s) => (s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)}m` : `${(s / 3600).toFixed(1)}h`);

/** How many successive capped updates it takes to walk `from` to `to`. */
function stepsNeeded(from, to, capBps) {
  if (from.isZero()) return 1;
  const ratio = Number(utils.formatUnits(to.mul(1e9).div(from), 9));
  const step = 1 + capBps / BPS;
  return Math.max(1, Math.ceil(Math.abs(Math.log(ratio)) / Math.log(step)));
}

async function main() {
  const mainnet = new providers.JsonRpcProvider(cfg.MAINNET_RPC_URL);
  const vaultChain = new providers.JsonRpcProvider(cfg.VAULT_RPC_URL);

  const { sqrtPriceX96, spot } = await readSpot(mainnet, cfg.POOL);
  const net = await vaultChain.getNetwork();
  const now = Math.floor(Date.now() / 1000);

  console.log(`pool    ${cfg.POOL.poolId.slice(0, 18)}… on PoolManager ${cfg.POOL.poolManager.slice(0, 10)}…`);
  console.log(`spot    ${spot.toString()} wei ETH per 1e18 IMD   (sqrtPriceX96 ${sqrtPriceX96.toString()})`);
  // The direction check that has bitten us: inverting gives a number ~1e20, which reads as a market
  // move rather than a misreading. A correct answer is many orders of magnitude below 1e18.
  if (spot.gte(utils.parseEther("1"))) {
    console.log("REFUSING: spot is at or above 1e18, which means the direction is inverted, not that IMD is worth an ETH.");
    process.exitCode = 2;
    return;
  }
  console.log(`feeds   on chain ${net.chainId}\n`);

  let anyAction = false;
  for (const f of cfg.FEEDS) {
    const feed = new Contract(f.address, FEED_ABI, vaultChain);
    let value, updatedAt, stale, cap, maxAge;
    try {
      [[value, updatedAt], stale, cap, maxAge] = await Promise.all([
        feed.latestValue(), feed.isStale(), feed.maxDeviationBps(), feed.maxAge(),
      ]);
    } catch (e) {
      console.log(`${f.role.padEnd(6)} ${f.address}  UNREADABLE: ${e.shortMessage || e.message}`);
      continue;
    }

    const capBps = cap.toNumber();
    const triggerBps = Math.floor(capBps * cfg.TRIGGER_FRACTION_OF_CAP);
    const age = updatedAt === 0 ? null : now - Number(updatedAt);
    const drift = value.isZero() ? null : bps(spot, value);
    const nearStale = age !== null && Number(maxAge) - age <= cfg.STALENESS_MARGIN_SECONDS;

    console.log(`${f.role.padEnd(6)} ${f.address}`);
    console.log(`       value ${value.toString()}${age === null ? "  (never set)" : `  set ${ago(age)} ago of ${ago(Number(maxAge))} allowed`}`);
    if (drift === null) {
      console.log(`       drift  n/a — the feed holds no value, so there is no band to leave`);
    } else {
      console.log(`       drift  ${(drift / 100).toFixed(2)}%  vs trigger ${(triggerBps / 100).toFixed(2)}%  vs cap ${(capBps / 100).toFixed(2)}%`);
    }

    const reasons = [];
    if (stale) reasons.push("STALE — the vault is halted and the next accepted value re-anchors with no deviation bound");
    else if (nearStale) reasons.push(`within ${ago(cfg.STALENESS_MARGIN_SECONDS)} of going stale`);
    if (drift !== null && drift >= triggerBps) reasons.push(`spot has left the trigger band (${(drift / 100).toFixed(2)}% >= ${(triggerBps / 100).toFixed(2)}%)`);

    if (drift !== null && drift > capBps) {
      const n = stepsNeeded(value, spot, capBps);
      reasons.push(
        `GAP EXCEEDS THE CAP: ${(drift / 100).toFixed(2)}% > ${(capBps / 100).toFixed(2)}%, so ONE attestation cannot close it. ` +
        `Needs ${n} successive updates (${(n * 0.5).toFixed(1)} IMD), each landing inside the band at the time. ` +
        `This is the state the watcher exists to prevent.`,
      );
    }

    if (reasons.length === 0) {
      console.log(`       hold   inside the band and fresh\n`);
      continue;
    }
    anyAction = true;
    for (const r of reasons) console.log(`       ACT    ${r}`);
    console.log(`       run    node oracle/preflight-oracle.mjs ${f.payload} ${f.address} --rpc ${cfg.VAULT_RPC_URL} --fix-guards`);
    console.log(`       then   node whitepaper/submit.js ${f.payload}            # 0.5 IMD, no undo`);
    console.log(`       order  walk the feed to market FIRST, then pin guards, then pay — in that order, same sitting\n`);
  }

  if (!anyAction) console.log("nothing to do.");
  else console.log("This watcher does not spend. Review each command before running it.");
}

main().catch((e) => {
  console.error("watcher failed:", e.message);
  process.exitCode = 1;
});
