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

test("the Worker lets X frame /buy/ and nothing else", async () => {
  const worker = (await import("../worker/infer.js")).default;
  const CSP =
    "default-src 'none'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'";
  const env = {
    ASSETS: {
      fetch: async (req) =>
        new URL(req.url).pathname === "/missing/"
          ? new Response("", { status: 404 })
          : new Response("<html>", {
              headers: {
                "Content-Security-Policy": CSP,
                "X-Frame-Options": "DENY",
              },
            }),
    },
  };
  const get = (path) =>
    worker.fetch(new Request(`https://infer.imdusd.com${path}`), env);
  for (const path of ["/buy/", "/buy/index.html"]) {
    const r = await get(path);
    const csp = r.headers.get("Content-Security-Policy");
    assert.equal(r.headers.get("X-Frame-Options"), null, path);
    assert.match(csp, /frame-ancestors https:\/\/x\.com https:\/\/\*\.x\.com https:\/\/twitter\.com https:\/\/\*\.twitter\.com/);
    assert.doesNotMatch(csp, /'none'; base/);
    // Everything else in the policy is the site's own, untouched.
    assert.match(csp, /^default-src 'none'; connect-src 'self'; frame-ancestors .*; base-uri 'self'$/);
  }
  for (const path of ["/", "/claim/", "/buy/card.png", "/buyx/", "/missing/"]) {
    const r = await get(path);
    if (r.status === 404) continue;
    assert.equal(r.headers.get("X-Frame-Options"), "DENY", path);
    assert.equal(r.headers.get("Content-Security-Policy"), CSP, path);
  }
  const http = await worker.fetch(new Request("http://infer.imdusd.com/buy/"), env);
  assert.equal(http.status, 301);
});

// ------------------------------------------------------------------ /rpc (worker/rpc.js)

test("/rpc serves only the pages' methods and contracts, caches shared reads, and falls back on provider trouble", async () => {
  const { handleRpc, resetAllowlist, MULTICALL3 } = await import("../worker/rpc.js");
  const { encodeFunctionData, parseAbi } = await import("viem");
  const OURS = "0x1111111111111111111111111111111111111111";
  const OTHER = "0x2222222222222222222222222222222222222222";
  const AGG = parseAbi(["function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)"]);
  const bundle = (...targets) => encodeFunctionData({ abi: AGG, functionName: "aggregate3", args: [targets.map((t) => ({ target: t, allowFailure: true, callData: "0x18160ddd" }))] });
  const env = (allow = [OURS, MULTICALL3]) => ({
    RPC_UPSTREAMS: "https://keyed.example/a, https://keyed.example/b",
    ASSETS: { fetch: async () => (allow ? new Response(JSON.stringify(allow)) : new Response("", { status: 404 })) },
  });
  const store = new Map();
  const cache = { match: async (k) => store.get(k.url)?.clone(), put: async (k, r) => void store.set(k.url, r) };
  let calls = [];
  let reply = () => ({ jsonrpc: "2.0", id: 1, result: "0x01" });
  const fetchStub = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    const r = reply(url);
    return r instanceof Response ? r : new Response(JSON.stringify(r));
  };
  const rpc = async (body, e = env()) => {
    const r = await handleRpc(new Request("https://infer.imdusd.com/rpc", { method: "POST", body: JSON.stringify(body) }), e, { fetch: fetchStub, cache });
    return { status: r.status, source: r.headers.get("x-rpc"), body: r.status === 200 ? await r.json() : null };
  };
  const call = (to, extra = {}, id = 7) => ({ jsonrpc: "2.0", id, method: "eth_call", params: [{ to, data: "0x18160ddd", ...extra }, "latest"] });

  resetAllowlist();
  // Methods the pages never use are refused before any upstream call.
  for (const method of ["eth_sendRawTransaction", "eth_getLogs", "debug_traceCall", "eth_accounts"]) {
    const r = await rpc({ jsonrpc: "2.0", id: 1, method, params: [] });
    assert.equal(r.body.error.code, -32601, method);
  }
  // Calls must target our contracts, directly or inside a Multicall3 bundle.
  assert.match((await rpc(call(OTHER))).body.error.message, /not one the INFER pages read/);
  assert.match((await rpc({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ data: "0x00" }, "latest"] })).body.error.message, /target/);
  assert.match((await rpc({ ...call(OURS), params: [{ to: OURS, data: "0x18160ddd" }, "latest", { [OURS]: { balance: "0x1" } }] })).body.error.message, /overrides/);
  assert.match((await rpc(call(MULTICALL3, { data: bundle(OURS, OTHER) }))).body.error.message, /not one the INFER pages read/);
  assert.match((await rpc(call(MULTICALL3, { data: "0x252dba42" }))).body.error.message, /aggregate3/);
  assert.equal(calls.length, 0, "nothing refused reached an upstream");

  // An allowed shared read goes to the first keyed upstream once, then comes from the cache with the caller's id.
  let r = await rpc(call(MULTICALL3, { data: bundle(OURS, OURS) }, 1));
  assert.equal(r.source, "upstream");
  assert.deepEqual(r.body, { jsonrpc: "2.0", id: 1, result: "0x01" });
  assert.equal(calls[0].url, "https://keyed.example/a");
  r = await rpc(call(MULTICALL3, { data: bundle(OURS, OURS) }, 99));
  assert.equal(r.source, "cache");
  assert.deepEqual(r.body, { jsonrpc: "2.0", id: 99, result: "0x01" });
  assert.equal(calls.length, 1, "a shared read costs one upstream call per block");

  // A simulation names its sender, so it is never shared.
  calls = [];
  await rpc(call(OURS, { from: OTHER }));
  await rpc(call(OURS, { from: OTHER }));
  assert.equal(calls.length, 2);

  // A revert is an answer: returned as is, the next upstream is not asked.
  calls = [];
  reply = () => ({ jsonrpc: "2.0", id: 1, error: { code: 3, message: "execution reverted", data: "0x08c379a0" } });
  r = await rpc(call(OURS, { from: OTHER }));
  assert.equal(r.body.error.message, "execution reverted");
  assert.equal(calls.length, 1);

  // Provider trouble (HTTP 429, a rate-limit error) moves on to the next upstream, then the public RPCs.
  calls = [];
  reply = (url) =>
    url === "https://keyed.example/a"
      ? new Response("", { status: 429 })
      : url === "https://keyed.example/b"
        ? { jsonrpc: "2.0", id: 1, error: { code: -32005, message: "rate limit exceeded" } }
        : { jsonrpc: "2.0", id: 1, result: "0x02" };
  r = await rpc(call(OURS, { from: OTHER }));
  assert.equal(r.body.result, "0x02");
  assert.deepEqual(calls.map((c) => c.url), ["https://keyed.example/a", "https://keyed.example/b", "https://ethereum-rpc.publicnode.com"]);

  // Batches are answered call by call; GET and junk are refused.
  reply = () => ({ jsonrpc: "2.0", id: 1, result: "0x03" });
  r = await rpc([call(OURS, { from: OTHER }, 1), call(OTHER, {}, 2)]);
  assert.equal(r.body[0].result, "0x03");
  assert.equal(r.body[1].error.code, -32601);
  assert.equal((await handleRpc(new Request("https://infer.imdusd.com/rpc"), env(), { fetch: fetchStub, cache })).status, 405);
  assert.equal((await rpc(Array.from({ length: 21 }, (_, i) => call(OURS, {}, i)))).status, 400);

  // A build without rpc-allow.json (the whitepaper) has no /rpc.
  resetAllowlist();
  assert.equal((await rpc(call(OURS), env(null))).status, 404);
  resetAllowlist();
});
