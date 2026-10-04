import { test } from "node:test";
import assert from "node:assert/strict";
import { amount, payout, address, message, WAD, ratio } from "../src/math.ts";
import { maxUint256 } from "viem";
test("amount input rejects lossy, signed, exponent, zero and out of range values", () => {
  for (const input of [
    "0",
    "-1",
    "1e2",
    "NaN",
    "1.0000000000000000001",
    (maxUint256 + 1n).toString(),
  ])
    assert.throws(() => amount(input));
  assert.equal(amount(" 12.345 "), 12345n * 10n ** 15n);
  assert.equal(amount("0", 18, true), 0n);
});
test("reserve first, position only, mixed payout and debt rounding", () => {
  const reserve = payout(100n * WAD, 50n, 2n * WAD, 100n * WAD);
  assert.equal(reserve.out, 4975n * 10n ** 16n);
  assert.equal(reserve.source, "Reserve");
  assert.equal(reserve.debtCancelled, 0n);
  const mixed = payout(100n * WAD, 50n, 2n * WAD, 10n * WAD);
  assert.equal(mixed.source, "Reserve + position");
  assert.equal(mixed.reserveOut, 10n * WAD);
  assert.equal(mixed.positionOut, 3975n * 10n ** 16n);
  assert.equal(
    mixed.debtCancelled,
    100n * WAD - (10n * WAD * 2n * WAD) / (9950n * 10n ** 14n),
  );
  assert.equal(payout(100n * WAD, 500n, 2n * WAD, 0n).source, "Position");
});
test("fee increase lowers output, supply-independent quote conservation over varied sizes", () => {
  for (let i = 1n; i <= 200n; i++) {
    const n = i * WAD + 17n,
      price = ((i % 13n) + 1n) * WAD + 7n,
      reserve = (i % 7n) * WAD;
    const low = payout(n, 50n, price, reserve),
      high = payout(n, 500n, price, reserve);
    assert.ok(low.out >= high.out);
    assert.equal(low.out, low.reserveOut + low.positionOut);
    assert.ok(low.reserveOut <= reserve);
    assert.ok(low.out * price <= n * 9950n * 10n ** 14n);
    assert.ok(low.debtCancelled >= 0n && low.debtCancelled <= n);
  }
  assert.throws(() => payout(1n, 500n, 100n * WAD, 0n));
  assert.throws(() => payout(WAD, 50n, 0n, 0n));
});
test("address normalization, debt-free label and actionable custom errors", () => {
  assert.throws(() => address("alice.eth"));
  assert.equal(
    address(" 0x0000000000000000000000000000000000000001 "),
    "0x0000000000000000000000000000000000000001",
  );
  assert.equal(ratio(maxUint256), "Debt-free");
  assert.match(message({ code: 4001 }), /rejected/);
  assert.match(
    message({ cause: { data: { errorName: "RedemptionWorsensBacking" } } }),
    /reduce backing/,
  );
});
