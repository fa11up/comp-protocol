// infer.imdusd.com/rpc: the INFER pages' own Ethereum RPC. The browser calls this instead of a public RPC; the
// Worker answers from Cloudflare's cache or forwards to a keyed provider, so:
//
// * reads every visitor shares (prices, pool state, supply, staking totals) cost one upstream call per block
//   however many people have the page open: each answer is cached for one 12-second block;
// * the provider keys stay Worker secrets (RPC_UPSTREAMS), never in the page;
// * it is not a free RPC for anyone else: only the methods the pages use, and every eth_call and gas estimate
//   must target a contract the pages read (rpc-allow.json, written by the build from the launch config and the
//   page source), including each call inside a Multicall3 bundle.
//
// Per visitor (Cloudflare's rate limiting bindings, keyed by the connecting IP; see wrangler.infer.jsonc):
// RPC_REQUESTS caps requests to /rpc, and RPC_UPSTREAM caps the calls that miss the cache and reach a provider,
// so a flood of distinct calls cannot drain the keyed providers' quotas. Cache hits never count against
// RPC_UPSTREAM, so any number of visitors behind one address can share the cached reads. A visitor over a limit
// is told so (HTTP 429, or JSON-RPC -32005 for the one call) and nothing goes upstream. Without the bindings
// (tests, local dev) nothing is limited.
//
// Upstreams are tried in order: RPC_UPSTREAMS (comma- or newline-separated full URLs, e.g. Chainstack then
// Blockscout PRO), then the public RPCs below. A revert is an answer and is returned as is; only a provider
// failure (network, HTTP error, rate limit) moves on to the next upstream.
import { decodeFunctionData, parseAbi } from "viem";

export const MULTICALL3 = "0xca11bde05977b3631167028862be2a173976ca11";
const PUBLIC = [
  "https://ethereum-rpc.publicnode.com",
  "https://eth.drpc.org",
  "https://rpc.mevblocker.io",
  "https://eth-mainnet.public.blastapi.io",
];
const ALLOWED = new Set([
  "eth_chainId",
  "eth_blockNumber",
  "eth_call",
  "eth_estimateGas",
  "eth_getBalance",
  "eth_getBlockByNumber",
  "eth_getCode",
  "eth_getTransactionReceipt",
  "eth_getTransactionByHash",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
]);
const BLOCK_MS = 12_000;
const MAX_BODY = 64 * 1024;
const MAX_BATCH = 20;
const MAX_INNER = 64;
const AGGREGATE3 = parseAbi([
  "function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)",
]);

// The build's rpc-allow.json as a Set of lowercase addresses, read once per isolate; false when the build has
// none (the whitepaper runs this same Worker), which turns /rpc into a 404.
let allow = null;
async function allowlist(env) {
  if (allow !== null) return allow;
  const r = await env.ASSETS.fetch(new Request("https://infer.imdusd.com/rpc-allow.json"));
  allow = r.ok ? new Set((await r.json()).map((a) => a.toLowerCase())) : false;
  return allow;
}
/** Tests reset the cached allowlist between cases. */
export const resetAllowlist = () => (allow = null);

const fail = (id, code, message) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

/** Why a call is refused, or null when it may go upstream. */
function refusal(call, allowed) {
  if (!call || call.jsonrpc !== "2.0" || typeof call.method !== "string") return "not a JSON-RPC request";
  if (!ALLOWED.has(call.method)) return `method ${call.method} is not served here`;
  if (call.method !== "eth_call" && call.method !== "eth_estimateGas") return null;
  const [tx, , overrides] = call.params ?? [];
  if (overrides !== undefined) return "state overrides are not served here";
  const to = typeof tx?.to === "string" ? tx.to.toLowerCase() : null;
  if (!to) return "a call must name its target contract";
  if (to === MULTICALL3) {
    if (call.method !== "eth_call") return "gas estimates through Multicall3 are not served here";
    let inner;
    try {
      inner = decodeFunctionData({ abi: AGGREGATE3, data: tx.data ?? tx.input }).args[0];
    } catch {
      return "only Multicall3 aggregate3 is served here";
    }
    if (inner.length > MAX_INNER) return `at most ${MAX_INNER} calls per bundle`;
    for (const c of inner) if (!allowed.has(c.target.toLowerCase())) return `contract ${c.target} is not one the INFER pages read`;
    return null;
  }
  return allowed.has(to) ? null : `contract ${tx.to} is not one the INFER pages read`;
}

/**
 * How long an answer may be shared, in ms, or 0 for never: reads that do not depend on who asks, at the
 * latest block (one block) or at a fixed block (an hour; history does not change).
 */
function shareable(call) {
  const p = call.params ?? [];
  const at = (tag) => (tag === undefined || tag === "latest" ? BLOCK_MS : /^0x[0-9a-f]+$/i.test(tag) ? 3_600_000 : 0);
  switch (call.method) {
    case "eth_chainId":
      return 86_400_000;
    case "eth_blockNumber":
      return BLOCK_MS;
    case "eth_call": {
      const from = p[0]?.from?.toLowerCase();
      // A simulation names its sender; its answer is that sender's, so it is never shared.
      return from && from !== "0x0000000000000000000000000000000000000000" ? 0 : at(p[1]);
    }
    case "eth_getBalance":
    case "eth_getCode":
      return at(p[1]);
    case "eth_getBlockByNumber":
      return p[1] === false ? at(p[0]) : 0;
    default:
      return 0;
  }
}

async function cacheKey(call, ttl) {
  const bytes = new TextEncoder().encode(JSON.stringify([call.method, call.params ?? []]));
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  // One key per block window, so an answer is never served past its window even if a cache keeps it longer.
  return new Request(`https://infer.imdusd.com/__rpc/${hash}/${Math.floor(Date.now() / ttl)}`);
}

const providerTrouble = (e) =>
  e && (e.code === -32005 || e.code === 429 || /rate|limit|capacity|unavailable|timeout|too many|exceeded|unauthor|forbidden/i.test(e.message ?? ""));

/** One call upstream: the first provider that answers, revert included. */
async function forward(call, upstreams, fetcher) {
  let last = "no upstream answered";
  for (const url of upstreams) {
    try {
      const r = await fetcher(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: call.method, params: call.params ?? [] }),
        signal: AbortSignal.timeout(6000),
      });
      if (!r.ok) {
        last = `HTTP ${r.status}`;
        continue;
      }
      const d = await r.json();
      if (d.error && providerTrouble(d.error)) {
        last = d.error.message;
        continue;
      }
      if (!("result" in d) && !d.error) {
        last = "empty answer";
        continue;
      }
      return { result: d.result, error: d.error };
    } catch (e) {
      last = e instanceof Error ? e.message : String(e);
    }
  }
  return { error: { code: -32603, message: `upstream unavailable: ${last}` } };
}

/** Whether `binding` lets `key` through; a missing binding, or one that fails, never blocks. */
async function under(binding, key) {
  if (!binding) return true;
  try {
    return (await binding.limit({ key })).success;
  } catch {
    return true;
  }
}

async function answer(call, env, allowed, upstreams, fetcher, cache, who) {
  const no = refusal(call, allowed);
  if (no) return { body: fail(call?.id, -32601, no), source: "refused" };
  const ttl = shareable(call);
  const key = ttl && cache ? await cacheKey(call, ttl) : null;
  if (key) {
    const hit = await cache.match(key);
    if (hit) return { body: { jsonrpc: "2.0", id: call.id, ...(await hit.json()) }, source: "cache" };
  }
  if (!(await under(env.RPC_UPSTREAM, who)))
    return { body: fail(call.id, -32005, "rate limited: too many uncached calls from this address, retry in a minute"), source: "limited" };
  const got = await forward(call, upstreams, fetcher);
  if (key && !got.error && got.result !== null && got.result !== undefined)
    await cache.put(key, new Response(JSON.stringify({ result: got.result }), { headers: { "cache-control": `max-age=${Math.ceil(ttl / 1000)}` } }));
  return { body: { jsonrpc: "2.0", id: call.id, ...got }, source: "upstream" };
}

/** POST /rpc. `deps` lets tests pass a fetch and a cache. */
export async function handleRpc(request, env, deps = {}) {
  const fetcher = deps.fetch ?? fetch;
  const cache = deps.cache === undefined ? (typeof caches !== "undefined" ? caches.default : null) : deps.cache;
  const json = (body, status = 200, source = "") =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store", ...(source ? { "x-rpc": source } : {}) },
    });
  const allowed = await allowlist(env);
  if (!allowed) return new Response("Not found", { status: 404 });
  if (request.method !== "POST") return json(fail(null, -32600, "POST a JSON-RPC request"), 405);
  const who = request.headers.get("cf-connecting-ip") ?? "unknown";
  if (!(await under(env.RPC_REQUESTS, who)))
    return new Response(JSON.stringify(fail(null, -32005, "rate limited: too many requests from this address, retry in a minute")), {
      status: 429,
      headers: { "content-type": "application/json", "cache-control": "no-store", "retry-after": "60" },
    });
  const text = await request.text();
  if (text.length > MAX_BODY) return json(fail(null, -32600, "request too large"), 413);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return json(fail(null, -32700, "not JSON"), 400);
  }
  const upstreams = [
    ...String(env.RPC_UPSTREAMS ?? "")
      .split(/[\s,]+/)
      .filter((u) => u.startsWith("https://")),
    ...PUBLIC,
  ];
  if (Array.isArray(body)) {
    if (body.length === 0 || body.length > MAX_BATCH) return json(fail(null, -32600, `send 1 to ${MAX_BATCH} calls`), 400);
    const out = await Promise.all(body.map((c) => answer(c, env, allowed, upstreams, fetcher, cache, who)));
    return json(out.map((o) => o.body), 200, out.map((o) => o.source).join(","));
  }
  const o = await answer(body, env, allowed, upstreams, fetcher, cache, who);
  return json(o.body, 200, o.source);
}
