#!/usr/bin/env node
// The CDP position watcher and liquidator.
//
// Reports by default. `--execute` marks and liquidates, and requires KEEPER_MNEMONIC in the
// environment; every transaction is simulated with callStatic first, so a doomed one costs nothing.
//
// BEING THE MARKER IS WORTH MONEY. `liquidate` pays the caller `seized - protocolCut` when the caller
// is also the marker, and `seized - protocolCut - markerCut` otherwise. So marking a position
// ourselves and liquidating it ourselves earns the marker share on top; letting someone else mark it
// hands them that share even if we do the liquidating. `markUnderwaterFor(owner, beneficiary)` exists
// for exactly this, and naming ourselves is the whole competitive edge available to us on chain.
import { providers, Contract, BigNumber, utils, Wallet } from "ethers";
import { VAULT_ABI, discoverOwners, maxRepayable, payout, markWindow } from "./lib/vault.mjs";
import cfg from "./config.js";

const FEED_ABI = ["function latestValue() view returns (uint256,uint64)", "function isStale() view returns (bool)"];
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)"];
const execute = process.argv.includes("--execute");
const wad = (x) => utils.formatUnits(x, 18);
const secs = (s) => (s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)}m` : `${(s / 3600).toFixed(1)}h`);

async function main() {
  const provider = new providers.JsonRpcProvider(cfg.VAULT_RPC_URL);
  const vault = new Contract(cfg.VAULT, VAULT_ABI, provider);
  const now = Math.floor(Date.now() / 1000);

  const [minCR, grace, window, markerBps, protocolBps, imdAddr, compAddr, feedAddr] = await Promise.all([
    vault.minCR(), vault.gracePeriod(), vault.liquidationWindow(),
    vault.markerShareBps(), vault.protocolBonusShareBps(),
    vault.imdToken(), vault.compToken(), vault.priceFeed(),
  ]);
  const feed = new Contract(feedAddr, FEED_ABI, provider);
  const [[price], stale] = await Promise.all([feed.latestValue(), feed.isStale()]);

  console.log(`vault   ${cfg.VAULT}`);
  console.log(`risk    minCR ${minCR}%  grace ${secs(Number(grace))}  window ${secs(Number(window))}`);
  console.log(`split   marker ${markerBps}bps  protocol ${protocolBps}bps of the bonus`);
  console.log(`price   ${price.toString()}${stale ? "  *** STALE ***" : ""}`);

  // THE PRECONDITION THAT GATES EVERYTHING. `liquidate` calls _requireFreshFeeds and
  // _requirePriceAgreement before anything else, so a stale feed means no position can be liquidated
  // at all, however underwater it is. A keeper that does not say this out loud looks idle when it is
  // actually blind.
  if (stale || price.isZero()) {
    console.log(`\nBLOCKED: the price feed is stale, so liquidate() reverts StaleFeed for every position.`);
    console.log(`         Nothing can be marked or liquidated until a fresh attestation lands.`);
    console.log(`         Run \`node keeper/watch.mjs\` — it reports what the feed needs.`);
    if (execute) process.exitCode = 3;
    return;
  }

  let signer = null;
  if (execute) {
    if (!process.env.KEEPER_MNEMONIC) throw new Error("--execute needs KEEPER_MNEMONIC in the environment");
    signer = Wallet.fromMnemonic(process.env.KEEPER_MNEMONIC).connect(provider);
    const comp = new Contract(compAddr, ERC20, provider);
    const [bal, eth] = await Promise.all([comp.balanceOf(signer.address), provider.getBalance(signer.address)]);
    console.log(`keeper  ${signer.address}  ${wad(eth)} ETH  ${wad(bal)} stablecoin inventory`);
    // liquidate burns the CALLER's stablecoin. Inventory is working capital, not an expense.
    if (bal.isZero()) console.log(`        WARNING: no stablecoin. liquidate() burns the caller's, so nothing can be liquidated.`);
  }

  // From an indexer, not eth_getLogs — see lib/vault.mjs for the measurement that forced this.
  // It throws rather than returning empty if the source answered with nothing at all, because for a
  // liquidator "no positions" and "the source is broken" must never look the same.
  const { owners, logsSeen } = await discoverOwners(cfg.INDEXER, cfg.VAULT);
  console.log(`\nowners  ${owners.length} from ${logsSeen} indexed logs`);

  const rows = [];
  for (const owner of owners) {
    const [pos, mark, cr] = await Promise.all([
      vault.positions(owner), vault.liquidationMarks(owner), vault.collateralRatio(owner),
    ]);
    if (pos.debt.isZero()) continue;
    const win = markWindow(mark, window, now);
    const healthy = cr.gte(minCR);
    rows.push({ owner, pos, mark, cr, win, healthy });
  }

  rows.sort((a, b) => (a.cr.lt(b.cr) ? -1 : 1));
  console.log(`        ${rows.length} with debt outstanding\n`);

  for (const r of rows) {
    const crText = r.cr.gt(BigNumber.from(10).pow(9)) ? "inf" : `${r.cr}%`;
    console.log(`${r.owner}  CR ${crText}  collateral ${wad(r.pos.collateral)}  debt ${wad(r.pos.debt)}`);

    if (r.healthy && r.win.state === "unmarked") { console.log(`   healthy, unmarked — nothing to do\n`); continue; }
    if (r.healthy) { console.log(`   healthy but ${r.win.state} — a deposit or repayment would clear the mark\n`); continue; }

    const repay = maxRepayable(r.pos, price);
    const asMarker = r.mark.marked && signer && r.mark.marker.toLowerCase() === signer.address.toLowerCase();
    const p = payout(r.pos, price, repay, { markerBps, protocolBps, weAreMarker: !!asMarker });
    console.log(`   UNDERWATER (CR ${crText} < ${minCR}%)  max repay ${wad(repay)}`);
    if (p) {
      console.log(`   payout  seized ${wad(p.seized)}  bonus ${wad(p.bonus)}  ours ${wad(p.toUs)}`);
      if (!p.swept.isZero()) console.log(`   sweep   ${wad(p.swept)} of unreachable dust folded into the seizure`);
      if (!asMarker) console.log(`   note    marking it ourselves would add ${wad(p.markerCut)} — mark first`);
    }

    if (r.win.state === "unmarked") {
      console.log(`   ACT     markUnderwaterFor(${r.owner}, <us>)  then wait ${secs(Number(grace))}`);
    } else if (r.win.state === "grace") {
      console.log(`   WAIT    grace ends in ${secs(r.win.secondsToOpen)}, marker ${r.mark.marker}`);
    } else if (r.win.state === "actionable") {
      console.log(`   ACT     liquidate(${r.owner}, ${repay.toString()})  — ${secs(r.win.secondsLeft)} left in the window`);
    } else {
      console.log(`   ACT     mark EXPIRED — it must be retaken before liquidation is possible again`);
    }

    if (execute && signer) {
      const live = vault.connect(signer);
      try {
        if (r.win.state === "unmarked") {
          await live.callStatic.markUnderwaterFor(r.owner, signer.address);
          const tx = await live.markUnderwaterFor(r.owner, signer.address);
          console.log(`   sent    mark ${tx.hash}`);
        } else if (r.win.state === "actionable") {
          await live.callStatic.liquidate(r.owner, repay);
          const tx = await live.liquidate(r.owner, repay);
          console.log(`   sent    liquidate ${tx.hash}`);
        }
      } catch (e) {
        // Simulated first precisely so this costs nothing: a revert here is information, not a loss.
        console.log(`   refused ${e.errorName || e.reason || (e.shortMessage ?? e.message).slice(0, 120)}`);
      }
    }
    console.log();
  }

  if (!execute) console.log("report only. Add --execute (with KEEPER_MNEMONIC) to mark and liquidate.");
}

main().catch((e) => { console.error("positions failed:", e.message); process.exitCode = 1; });
