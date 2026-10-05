#!/usr/bin/env node
// Genesis points leaderboard.
//
//   node points/cli.ts --stablecoin 0x.. --vault 0x.. [--chain ethereum] [--exclude 0x..,0x..]
//                      [--start <block>] [--end <block>] [--lp-x 3] [--credit-days 3] [--out points.json]
//
// --start defaults to the stablecoin's first log, --end to the latest log, so a run mid-season is a
// live leaderboard. The vault and the chain's v4 PoolManager are always excluded; pass the Treasury
// (and any other protocol contract that holds imdUSD) with --exclude.
//
// LP credit needs the imdUSD/USDC pool, which does not exist yet: until it does, liquidity earns
// nothing here, and the LP reader is the next piece to build.
import { writeFileSync } from "node:fs";
import { computePoints, display, shareBps, DEFAULTS } from "./engine.ts";
import { decodeLog, fetchLogs } from "./logs.ts";
import { CHAINS } from "./chains.ts";

const args = process.argv.slice(2);
const opt = (name: string, fallback?: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const isAddr = (a?: string) => !!a && /^0x[0-9a-fA-F]{40}$/.test(a);
const stablecoin = opt("stablecoin");
const vault = opt("vault");
const chainName = opt("chain", "ethereum")!;
const chain = CHAINS[chainName];
if (!isAddr(stablecoin) || !isAddr(vault) || !chain) {
  console.error("usage: node points/cli.ts --stablecoin 0x.. --vault 0x.. [--chain ethereum|sepolia] [--exclude 0x..] [--start N] [--end N] [--lp-x 3] [--credit-days 3] [--out file]");
  process.exit(1);
}
const excluded = [vault!, chain.poolManager, ...(opt("exclude", "")!.split(",").filter(isAddr))];

const [tokenLogs, vaultLogs] = await Promise.all([fetchLogs(chain.blockscout, stablecoin!), fetchLogs(chain.blockscout, vault!)]);
const events = [...tokenLogs, ...vaultLogs].map(decodeLog).filter((e) => e !== null);
const blocks = tokenLogs.map((l) => Number(l.block_number));
const startBlock = Number(opt("start", String(Math.min(...blocks))));
const endBlock = Number(opt("end", String(Math.max(...blocks, ...vaultLogs.map((l) => Number(l.block_number))))));
const season = {
  startBlock,
  endBlock,
  blocksPerDay: chain.blocksPerDay,
  lpBps: Math.round(Number(opt("lp-x", String(DEFAULTS.lpBps / 10_000))) * 10_000),
  liquidationCreditDays: Number(opt("credit-days", String(DEFAULTS.liquidationCreditDays))),
  excluded,
};
const r = computePoints(events, season);
const out = {
  chain: chainName,
  stablecoin: stablecoin!.toLowerCase(),
  vault: vault!.toLowerCase(),
  season: { ...season, unit: "1 point = 1 imdUSD held for 1 day (7,200 blocks); liquidity earns lpBps/10000 x" },
  logsRead: tokenLogs.length + vaultLogs.length,
  totalPoints: display(r.total, chain.blocksPerDay),
  accounts: r.accounts.map((a) => ({
    owner: a.owner,
    points: display(a.points, chain.blocksPerDay),
    shareBps: shareBps(a.points, r.total),
    heldNow: a.held.toString(),
    lpNow: a.lp.toString(),
    perDayNow: display(a.ratePerBlock * BigInt(chain.blocksPerDay), chain.blocksPerDay),
  })),
};
const file = opt("out", "points.json")!;
writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
console.error(`${out.logsRead} logs, ${events.length} point events, ${out.accounts.length} accounts, ${out.totalPoints} points (blocks ${startBlock}..${endBlock}) -> ${file}`);
for (const a of out.accounts.slice(0, 10)) console.error(`  ${a.owner}  ${a.points.padStart(16)}  ${(a.shareBps / 100).toFixed(2)}%  +${a.perDayNow}/day`);
