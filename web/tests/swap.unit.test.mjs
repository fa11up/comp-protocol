import { test } from "node:test";
import assert from "node:assert/strict";
import {
  priceFromSlot0,
  encodeSwap,
  minimumOut,
  NATIVE,
} from "../src/infer/swap.ts";
import { parseAmount } from "../src/infer/amount.ts";

// The IMD/ETH launch pool's slot0 word, read from the PoolManager on 2026-10-06: sqrtPriceX96
// 1214268767572137080795828515032, i.e. 234.89 IMD per ETH, so 0.004257 ETH per IMD.
const WORD =
  "0x0000000027103e83e800d53d000000000000000f529ef6a8a1f57b191dfc9d7d";
const IMD = "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7";

test("the pool price reads the right way round for either currency ordering", () => {
  const imdPerEth = priceFromSlot0(WORD, false); // currency1 (IMD) per currency0 (ETH)
  assert.ok(
    imdPerEth > 234_000_000_000_000_000_000n &&
      imdPerEth < 235_000_000_000_000_000_000n,
    `${imdPerEth}`,
  );
  const ethPerImd = priceFromSlot0(WORD, true); // the pair (ETH) per INFER when INFER is currency1
  assert.ok(
    ethPerImd > 4_250_000_000_000_000n && ethPerImd < 4_260_000_000_000_000n,
    `${ethPerImd}`,
  );
});

test("amounts: plain decimals only, thousands separators forgiven, nothing negative or exotic", () => {
  assert.equal(parseAmount("1.5", 18), 1_500_000_000_000_000_000n);
  assert.equal(parseAmount(" 1,000 ", 18), 1_000_000_000_000_000_000_000n);
  assert.equal(parseAmount("007", 18), 7_000_000_000_000_000_000n);
  for (const bad of ["-5", "1e5", "1.2.3", "abc", "", ".", "٣", "1 2"])
    assert.equal(parseAmount(bad, 18), 0n, bad);
  assert.equal(
    parseAmount("1.1234567890123456789012345", 24),
    1_123_456_789_012_345_678_901_235n,
  );
});

test("minimum out and the native leg", () => {
  assert.equal(minimumOut(10_000n, 100), 9_900n);
  const key = {
    currency0: NATIVE,
    currency1: IMD,
    fee: 10_000,
    tickSpacing: 200,
    hooks: NATIVE,
  };
  assert.equal(
    encodeSwap({ key, tokenIn: NATIVE, amountIn: 5n, minOut: 1n }).value,
    5n,
  );
  assert.equal(
    encodeSwap({ key, tokenIn: IMD, amountIn: 5n, minOut: 1n }).value,
    0n,
  );
  assert.throws(() =>
    encodeSwap({
      key,
      tokenIn: "0x0000000000000000000000000000000000000001",
      amountIn: 5n,
      minOut: 1n,
    }),
  );
});
