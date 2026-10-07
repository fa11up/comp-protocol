import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";

const dir = new URL("../src/infer/", import.meta.url);
const example = JSON.parse(
  await readFile(new URL("launch.example.json", dir), "utf8"),
);
const names = await readdir(dir);
const launch = names.includes("launch.json")
  ? JSON.parse(await readFile(new URL("launch.json", dir), "utf8"))
  : null;

const shape = (o) =>
  o && typeof o === "object" && !Array.isArray(o)
    ? Object.fromEntries(
        Object.keys(o)
          .sort()
          .map((k) => [k, shape(o[k])]),
      )
    : Array.isArray(o)
      ? o.map(shape)
      : "value";

test("the example file has every figure unset and names only mainnet", () => {
  assert.equal(example.chainId, 1);
  assert.equal(example.supply, null);
  for (const a of example.allocation) assert.equal(a.bps, null, a.key);
  for (const r of example.redemptions) assert.equal(r.rate, null, r.key);
  assert.equal(
    example.contracts.infer,
    null,
    "the example never carries a token address",
  );
});

test(
  "the private launch file, when present, matches the example's shape and its figures reconcile",
  { skip: !launch && "no launch.json" },
  () => {
    // Same keys at every level; the example is what the public page is built from, so a key added to one
    // without the other would render as "undefined" somewhere.
    const strip = (o) => {
      const { $comment, ...rest } = o;
      return rest;
    };
    const same = (a, b, path = "") => {
      const ka = Object.keys(shape(a)),
        kb = Object.keys(shape(b));
      assert.deepEqual(ka, kb, `keys differ at ${path || "root"}`);
      for (const k of ka)
        if (typeof a[k] === "object" && a[k] && !Array.isArray(a[k]))
          same(a[k], b[k], `${path}.${k}`);
    };
    same(strip(launch), strip(example));

    const bps = launch.allocation.reduce((s, a) => s + a.bps, 0);
    assert.equal(bps, 10_000, "the allocation sums to 100%");
    const supply = BigInt(launch.supply);
    const bucket = (key) =>
      (supply * BigInt(launch.allocation.find((a) => a.key === key).bps)) /
      10_000n;
    const seasons = launch.seasons.amounts.reduce((s, a) => s + BigInt(a), 0n);
    assert.equal(
      seasons,
      bucket("seasons"),
      "the five seasons add up to the seasons bucket",
    );
    assert.equal(launch.seasons.amounts.length, launch.seasons.count);
    for (let i = 1; i < launch.seasons.amounts.length - 1; i++) {
      // Each season is `decay` times the one before (to within rounding to 500 INFER); the last season is
      // whatever makes the bucket exact, so it is checked by the sum above rather than by the ratio.
      const expected =
        (BigInt(launch.seasons.amounts[i - 1]) *
          BigInt(Math.round(Number(launch.seasons.decay) * 1000))) /
        1000n;
      const diff = expected - BigInt(launch.seasons.amounts[i]);
      assert.ok(
        diff < 500n && diff > -500n,
        `season ${i + 1} decays by ${launch.seasons.decay}`,
      );
    }
    for (const r of launch.redemptions)
      assert.equal(
        BigInt(r.allocation),
        bucket(r.key),
        `${r.symbol} allocation is its bucket`,
      );
    assert.equal(BigInt(launch.founder.amount), bucket("founder"));
    // A rate never over-promises its allocation: allocation / rate is the redeemable legacy supply it covers.
    for (const r of launch.redemptions)
      assert.ok(Number(r.allocation) / Number(r.rate) > 0);
    for (const url of [...launch.rpc, ...launch.claims.origins])
      assert.ok(url.startsWith("https://"), url);
  },
);
