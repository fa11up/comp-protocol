#!/usr/bin/env node
// Compute genesis points for a vault and write them to a JSON file.
//
//   node points/cli.mjs --vault 0x.. --chain ethereum [--start <unix|ISO>] [--end <unix|ISO>]
//                       [--credit-days 7] [--out points.json]
//
// --start defaults to the vault's first log (its deployment); --end defaults to now, so a run
// mid-season is a live leaderboard. Set BLOCKSCOUT_API_KEY to raise the explorer's rate limit.
import { writeFileSync } from "node:fs";
import { computePoints, toDisplay, shareBps, DAY } from "./engine.mjs";
import { fetchVaultLogs, decodeLog } from "./logs.mjs";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const toUnix = (v) => (/^\d+$/.test(v) ? Number(v) : Math.floor(Date.parse(v) / 1000));

const vault = opt("vault");
const chain = opt("chain", "ethereum");
if (!vault || !/^0x[0-9a-fA-F]{40}$/.test(vault)) {
  console.error("usage: node points/cli.mjs --vault 0x.. --chain ethereum|sepolia [--start] [--end] [--credit-days 7] [--out file]");
  process.exit(1);
}

const items = await fetchVaultLogs({ chain, vault });
const events = items.map(decodeLog).filter(Boolean);
const firstLog = Math.min(...items.map((i) => Math.floor(Date.parse(i.block_timestamp) / 1000)));
const seasonStart = opt("start") ? toUnix(opt("start")) : firstLog;
const seasonEnd = opt("end") ? toUnix(opt("end")) : Math.floor(Date.now() / 1000);
const liquidationCreditSeconds = BigInt(opt("credit-days", "7")) * DAY;

const result = computePoints(events, { seasonStart, seasonEnd, liquidationCreditSeconds });
const out = {
  vault: vault.toLowerCase(),
  chain,
  seasonStart,
  seasonEnd,
  liquidationCreditDays: Number(liquidationCreditSeconds / DAY),
  logsRead: items.length,
  eventsUsed: events.length,
  unit: "imdUSD-days (1 imdUSD of principal held for 1 day = 1 point); raw values are wei-seconds",
  totalPoints: toDisplay(result.total),
  totalRaw: result.total.toString(),
  accounts: result.accounts.map((a) => ({
    owner: a.owner,
    points: toDisplay(a.points),
    shareBps: shareBps(a.points, result.total),
    principalNow: a.principal.toString(),
    borrowRaw: a.debtSeconds.toString(),
    liquidationRaw: a.liquidationSeconds.toString(),
  })),
};
const file = opt("out", "points.json");
writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
console.error(`${items.length} logs, ${events.length} point events, ${out.accounts.length} accounts, ${out.totalPoints} points -> ${file}`);
for (const a of out.accounts.slice(0, 10)) console.error(`  ${a.owner}  ${a.points.padStart(16)}  ${(a.shareBps / 100).toFixed(2)}%`);
