import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeAbiParameters, parseAbiParameters, zeroAddress } from "viem";
import { describePending, utc, countdown } from "../src/governance.ts";
const W = 10n ** 18n;
const set = { line: 1_000_000n * W, cut: 1000n, duty: 200n, skew: 2000n, chip: 1000n };

test("an economics change lists only what changes, current → proposed", () => {
  const payload = encodeAbiParameters(parseAbiParameters("uint8, (uint256, uint256, uint256, uint256, uint256)"), [
    0,
    [2_000_000n * W, 1000n, 444n, 2000n, 1000n],
  ]);
  const p = describePending(payload, { set }, "imdUSD");
  assert.equal(p.title, "Economics");
  const changed = p.lines.filter((l) => l.changed);
  assert.deepEqual(
    changed.map((l) => [l.label, l.from, l.to]),
    [
      ["Debt ceiling", "1,000,000 imdUSD", "2,000,000 imdUSD"],
      ["Stability fee / year", "2%", "4.44%"],
    ],
  );
});

test("the older deployment's field names read the same", () => {
  const legacy = { debtCeiling: set.line, protocolBonusShareBps: 1000n, stabilityFeeBps: 200n, maxDivergenceBps: 2000n, markerShareBps: 1000n };
  const payload = encodeAbiParameters(parseAbiParameters("uint8, (uint256, uint256, uint256, uint256, uint256)"), [
    0,
    [set.line, 1000n, 300n, 2000n, 1000n],
  ]);
  const p = describePending(payload, { set: legacy }, "COMP");
  assert.deepEqual(p.lines.filter((l) => l.changed).map((l) => l.to), ["3%"]);
});

test("single-value changes", () => {
  const one = (kind, v) => encodeAbiParameters(parseAbiParameters("uint8, uint256"), [kind, v]);
  assert.deepEqual(describePending(one(4, 60n), { gap: 50n }, "imdUSD").lines[0], {
    label: "Redemption spread", from: "50 ratio points", to: "60 ratio points", changed: true,
  });
  assert.equal(describePending(one(5, 20n * W), { oracleBudget: 15n * W }, "imdUSD").lines[0].to, "20 IMD / day");
  assert.equal(describePending(one(6, 3n), { redemptionDivisor: 2n }, "imdUSD").lines[0].from, "2");
  assert.equal(describePending(one(1, 2000n), { earnMat: 2500n }, "imdUSD").title, "Work ratio");
});

test("reserve listing and delisting, stream, work oracle", () => {
  const asset = "0x9Efa934D9fAd4AE28c998a40195646b965a97247";
  const list = encodeAbiParameters(parseAbiParameters("uint8, address, address, uint256"), [2, asset, asset, 8000n]);
  assert.equal(describePending(list, {}, "imdUSD").title, "List or reprice a reserve asset");
  const delist = encodeAbiParameters(parseAbiParameters("uint8, address, address, uint256"), [2, asset, zeroAddress, 0n]);
  const d = describePending(delist, {}, "imdUSD");
  assert.equal(d.title, "Delist a reserve asset");
  assert.equal(d.lines.length, 2);
  const stream = encodeAbiParameters(parseAbiParameters("uint8, address, uint256"), [7, asset, 100n * W]);
  assert.equal(describePending(stream, { streamPayee: zeroAddress, streamPerDay: 0n }, "imdUSD").lines[0].from, "none");
  const oracle = encodeAbiParameters(parseAbiParameters("uint8, address"), [8, asset]);
  assert.equal(describePending(oracle, {}, "imdUSD").lines[0].to, "0x9Efa…7247");
});

test("nothing pending, unknown kinds, and time formats", () => {
  assert.equal(describePending("0x", {}, "imdUSD"), undefined);
  assert.equal(describePending(encodeAbiParameters(parseAbiParameters("uint8"), [42]), {}, "x").title, "Unknown change (kind 42)");
  assert.equal(utc(1_791_400_980n), "Oct 7, 19:23 UTC");
  assert.equal(countdown(25_192n), "6h 59m");
  assert.equal(countdown(200_000n), "2d 7h");
});
