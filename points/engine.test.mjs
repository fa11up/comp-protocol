// node --test points/
import { test } from "node:test";
import assert from "node:assert/strict";
import { computePoints, toDisplay, WAD, DAY } from "./engine.mjs";
import { decodeLog, TOPICS, fetchVaultLogs } from "./logs.mjs";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const L = "0x00000000000000000000000000000000000000c3";
let n = 0;
const p = (owner, debtWhole, timestamp) => ({ kind: "principal", owner, debt: BigInt(debtWhole) * WAD, timestamp, blockNumber: timestamp, logIndex: n++ });
const bite = (owner, liquidator, repaidWhole, timestamp) => ({ kind: "bite", owner, liquidator, debtRepaid: BigInt(repaidWhole) * WAD, timestamp, blockNumber: timestamp, logIndex: n++ });
const D = Number(DAY);
const pts = (r, who) => r.accounts.find((a) => a.owner === who)?.points ?? 0n;

test("principal held over time is principal x seconds", () => {
  const r = computePoints([p(A, 100, 0), p(A, 50, 2 * D)], { seasonStart: 0, seasonEnd: 4 * D });
  // 100 for 2 days + 50 for 2 days = 300 imdUSD-days
  assert.equal(toDisplay(pts(r, A)), "300.00");
});

test("splitting a position across wallets earns exactly the same (sybil-neutral)", () => {
  const one = computePoints([p(A, 100, 0)], { seasonStart: 0, seasonEnd: 10 * D });
  const split = computePoints([p(A, 50, 0), p(B, 50, 0)], { seasonStart: 0, seasonEnd: 10 * D });
  assert.equal(one.total, split.total);
});

test("a late entrant earns at the same rate", () => {
  const r = computePoints([p(A, 100, 0), p(B, 100, 5 * D)], { seasonStart: 0, seasonEnd: 10 * D });
  assert.equal(toDisplay(pts(r, A)), "1000.00");
  assert.equal(toDisplay(pts(r, B)), "500.00");
});

test("a flash borrow at the season's end earns one block", () => {
  const r = computePoints([p(A, 1_000_000, 10 * D - 12), p(A, 0, 10 * D)], { seasonStart: 0, seasonEnd: 10 * D });
  assert.equal(pts(r, A), 1_000_000n * WAD * 12n);
});

test("time before the season and after it earns nothing", () => {
  const r = computePoints([p(A, 100, 0)], { seasonStart: 2 * D, seasonEnd: 3 * D });
  assert.equal(toDisplay(pts(r, A)), "100.00");
});

test("liquidators earn debt repaid x the credit; only inside the season", () => {
  const r = computePoints(
    [p(A, 100, 0), bite(A, L, 40, D), p(A, 60, D), bite(A, L, 10, 20 * D)],
    { seasonStart: 0, seasonEnd: 10 * D, liquidationCreditSeconds: 7n * DAY },
  );
  assert.equal(toDisplay(pts(r, L)), "280.00"); // 40 x 7 days; the second bite is after the season
});

test("events are applied in chain order whatever order they arrive in", () => {
  const evs = [p(A, 100, 0), p(A, 0, D)];
  const r1 = computePoints(evs, { seasonStart: 0, seasonEnd: 2 * D });
  const r2 = computePoints([...evs].reverse(), { seasonStart: 0, seasonEnd: 2 * D });
  assert.equal(r1.total, r2.total);
});

test("decodes a Blockscout v2 log item", () => {
  const item = {
    topics: [TOPICS.principal, "0x" + "0".repeat(24) + A.slice(2), null, null],
    data: "0x" + (123n * WAD).toString(16).padStart(64, "0"),
    block_timestamp: "2026-10-05T00:00:00.000000Z",
    block_number: 7,
    index: 3,
    transaction_hash: "0xabc",
  };
  const e = decodeLog(item);
  assert.deepEqual([e.kind, e.owner, e.debt, e.blockNumber, e.logIndex], ["principal", A, 123n * WAD, 7, 3]);
  const b = decodeLog({ ...item, topics: [TOPICS.bite, item.topics[1], "0x" + "0".repeat(24) + L.slice(2), null], data: "0x" + (5n * WAD).toString(16).padStart(64, "0") + "0".repeat(64) });
  assert.deepEqual([b.kind, b.liquidator, b.debtRepaid], ["bite", L, 5n * WAD]);
  assert.equal(decodeLog({ ...item, topics: ["0x" + "1".repeat(64)] }), null);
});

test("zero logs is an error, never an empty leaderboard", async () => {
  const empty = async () => ({ ok: true, json: async () => ({ items: [], next_page_params: null }) });
  await assert.rejects(fetchVaultLogs({ chain: "sepolia", vault: A, fetchImpl: empty }), /refusing to report "no positions"/);
});
