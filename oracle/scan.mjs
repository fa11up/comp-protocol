#!/usr/bin/env node
/**
 * Scans a pinned block window over JSON-RPC and prints totals, never logs.
 *
 * A member's job is a number, a list or a bool, computed over exactly the pinned blocks. The
 * expensive part is not the arithmetic but the transcript: a member that fetches logs and reads
 * them has thousands of them in its context for every turn that follows. This script keeps the
 * logs in the process and prints only what the answer needs — the count, the sum, the ranking —
 * with the chain id and the closing block hash it saw, so the pin is confirmed in the same read.
 *
 * Node 22, no dependencies. Run it from the workspace:
 *
 *   node .imd/reads/skills/oracle-assess/scripts/scan.mjs --rpc URL --from N --to N --pin 0xHASH \
 *     --address 0xTOKEN --event "Transfer(address,address,uint256)" --sum data:0
 *
 *   --event SIG          topic0 is keccak256 of this signature; or give --topic0 yourself
 *   --topic1/2/3 V[,V]   filter an indexed argument (comma-separated values are an OR)
 *   --address A[,A]      filter by emitting contract(s); omit for every contract
 *   --sum FIELD          add this field over every log: data:N (the Nth 32-byte data word) or topic:N
 *   --rank FIELD         group by this field and sum --by (defaults to --sum's field); --top N rows
 *   --signed             read the summed field as int256; --abs adds magnitudes
 *   --chunk N            blocks per eth_getLogs call to start with (default 2000); halves on refusal
 *   --concurrency N      chunks in flight at once (default 3); a public endpoint rarely likes more
 *   --call 0xTO --data 0xCALLDATA --block N   one eth_call, printed as hex, decimal and address
 *   --keccak "SIG"       print keccak256 of a string and exit
 *
 * A Uniswap v4 volume ranking is one command, computed the way the deployer reruns it:
 *
 *   node .../scan.mjs --rpc URL --from N --to N --pin 0xHASH --v4 --pool-manager 0xPM --token 0xTOKEN \
 *     --since N [--top 5] [--yield pool|token] [--exclude 0xA,0xB] [--position-manager 0xPOSM]
 *
 *   Swaps over the window, grouped by pool; each traded pool's currencies from PositionManager
 *   .poolKeys at the closing block when --position-manager is given, else from the Initialize log
 *   scanned from --since with a topic filter on the traded ids, --init-chunk blocks at a time
 *   (default 10000, what public endpoints serve; raise it on an archive endpoint); pools holding
 *   the token ranked by the absolute swapped amount of the token's side. The output carries the
 *   recipe to paste.
 *
 * When a filtered scan matches nothing, the tail of the window is read again without the event
 * filter and the signatures the address did emit are printed: a zero over a busy window is nearly
 * always the wrong signature or address, and this shows which.
 *
 * Exit 0 with a JSON object on stdout; exit 2 when the pin does not match or a chunk cannot be
 * read even one block at a time. Progress goes to stderr, so stdout is only the result.
 */
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

/** The command line, read only when this file is the program; imported for `keccak256`, it reads nothing. */
let args = { quiet: true };
const readArgs = () => parseArgs({ options: {
  rpc: { type: "string" }, from: { type: "string" }, to: { type: "string" }, pin: { type: "string" },
  address: { type: "string" }, event: { type: "string" },
  topic0: { type: "string" }, topic1: { type: "string" }, topic2: { type: "string" }, topic3: { type: "string" },
  sum: { type: "string" }, rank: { type: "string" }, by: { type: "string" }, top: { type: "string", default: "5" },
  signed: { type: "boolean", default: false }, abs: { type: "boolean", default: false },
  chunk: { type: "string", default: "2000" }, concurrency: { type: "string", default: "3" },
  call: { type: "string" }, data: { type: "string" }, block: { type: "string" },
  keccak: { type: "string" }, quiet: { type: "boolean", default: false },
  v4: { type: "boolean", default: false }, "pool-manager": { type: "string" }, token: { type: "string" }, since: { type: "string" },
  yield: { type: "string", default: "pool" }, exclude: { type: "string" }, "position-manager": { type: "string" },
  "init-chunk": { type: "string", default: "10000" },
} }).values;

// ── keccak-256, so a signature becomes a topic without another tool ─────────────────────────────

const MASK64 = (1n << 64n) - 1n;
const RC = [0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n,
  0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n,
  0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n,
  0x8000000000008080n, 0x80000001n, 0x8000000080008008n];
const ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]];
const rotl = (v, n) => (n === 0 ? v : (((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK64));

function keccakF(A) {
  for (let round = 0; round < 24; round += 1) {
    const C = [0, 1, 2, 3, 4].map((x) => A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20]);
    const D = [0, 1, 2, 3, 4].map((x) => C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1));
    for (let i = 0; i < 25; i += 1) A[i] ^= D[i % 5];
    const B = new Array(25);
    for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(A[x + 5 * y], ROT[x][y]);
    for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) A[x + 5 * y] = B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & MASK64 & B[((x + 2) % 5) + 5 * y]);
    A[0] ^= RC[round];
  }
}

export function keccak256(input) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const rate = 136;
  const A = new Array(25).fill(0n);
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  for (let offset = 0; offset < padded.length; offset += rate) {
    for (let i = 0; i < rate / 8; i += 1) {
      let lane = 0n;
      for (let b = 7; b >= 0; b -= 1) lane = (lane << 8n) | BigInt(padded[offset + i * 8 + b]);
      A[i] ^= lane;
    }
    keccakF(A);
  }
  let out = "0x";
  for (let i = 0; i < 4; i += 1) {
    let lane = A[i];
    for (let b = 0; b < 8; b += 1) { out += Number(lane & 0xffn).toString(16).padStart(2, "0"); lane >>= 8n; }
  }
  return out;
}

// ── JSON-RPC with the patience a public endpoint needs ──────────────────────────────────────────

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const note = (text) => { if (!args.quiet) process.stderr.write(`${text}\n`); };
let calls = 0;

async function rpc(method, params, attempt = 0) {
  calls += 1;
  const response = await fetch(args.rpc, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: calls, method, params }), signal: AbortSignal.timeout(60_000) })
    .catch((error) => ({ ok: false, status: 0, statusText: String(error?.message ?? error), text: async () => "" }));
  if (response.status === 429 || response.status === 503) {
    if (attempt >= 3) throw new Error(`${method}: ${response.status} after ${attempt + 1} tries`);
    const wait = 1000 * 2 ** attempt;
    note(`  ${response.status} from endpoint; waiting ${wait} ms`);
    await sleep(wait);
    return rpc(method, params, attempt + 1);
  }
  if (!response.ok) throw new Error(`${method}: HTTP ${response.status} ${response.statusText} ${(await response.text()).slice(0, 200)}`);
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error).slice(0, 300)}`);
  return body.result;
}

const hex = (n) => `0x${BigInt(n).toString(16)}`;
const word = (data, index) => {
  const body = data.startsWith("0x") ? data.slice(2) : data;
  const slice = body.slice(index * 64, index * 64 + 64);
  if (slice.length !== 64) throw new Error(`data word ${index} is missing: the log has ${body.length / 64} words`);
  return BigInt(`0x${slice}`);
};
const signed = (value) => (value >= 1n << 255n ? value - (1n << 256n) : value);
const asKey = (value) => (value < 1n << 160n ? `0x${value.toString(16).padStart(40, "0")}` : `0x${value.toString(16).padStart(64, "0")}`);

/** `data:N` or `topic:N` → a function of a log. */
function fieldReader(spec) {
  const match = /^(data|topic):(\d+)$/.exec(spec ?? "");
  if (!match) throw new Error(`a field is data:N or topic:N, not ${spec}`);
  const index = Number(match[2]);
  if (match[1] === "topic") return (log) => { if (!log.topics[index]) throw new Error(`the log has no topic ${index}`); return BigInt(log.topics[index]); };
  return (log) => word(log.data, index);
}

const topicValue = (text) => text?.split(",").map((value) => value.trim()).filter(Boolean)
  .map((value) => (value.length === 66 ? value.toLowerCase() : `0x${value.replace(/^0x/, "").toLowerCase().padStart(64, "0")}`));

async function scanLogs(filter, fromBlock, toBlock, chunkBlocks, concurrency) {
  const logs = [];
  const chunks = [];
  let chunk = Math.min(chunkBlocks, toBlock - fromBlock + 1);
  let next = fromBlock;
  let done = 0;
  // A few chunks in flight, sharing one chunk size: when any of them is refused the size halves
  // for everyone and the refused range is retried at the new size. Progress is a line every
  // twenty chunks and on every halving, not a line per chunk — a six-hour window on a fast chain
  // is hundreds of chunks, and each line would sit in the reader's transcript for good.
  const pending = [];
  const worker = async () => {
    while (true) {
      let from, to;
      if (pending.length > 0) [from, to] = pending.shift();
      else if (next <= toBlock) { from = next; to = Math.min(next + chunk - 1, toBlock); next = to + 1; }
      else return;
      try {
        const got = await rpc("eth_getLogs", [{ ...filter, fromBlock: hex(from), toBlock: hex(to) }]);
        chunks.push([from, to, got.length]);
        for (const log of got) if (!log.removed) logs.push(log);
        done += 1;
        if (done % 20 === 0) note(`  ${done} chunks read, through block ${to}`);
      } catch (error) {
        if (chunk <= 1 && to - from + 1 <= 1) throw error;
        const size = Math.max(1, Math.min(chunk, Math.floor((to - from + 1) / 2)));
        chunk = Math.min(chunk, size);
        note(`  blocks ${from}-${to} refused (${String(error.message).slice(0, 100)}); now ${chunk} at a time`);
        for (let start = from; start <= to; start += size) pending.push([start, Math.min(start + size - 1, to)]);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, concurrency) }, worker));
  // The same log twice is a provider's mistake, not two transfers.
  const seen = new Set();
  return { logs: logs.filter((log) => { const id = `${log.blockNumber}:${log.logIndex}`; if (seen.has(id)) return false; seen.add(id); return true; }), chunks };
}

/**
 * Signatures worth recognising when a scan finds nothing, so the diagnostic names them.
 *
 * PancakeSwap v3 is here because its Swap carries two protocol-fee fields that Uniswap v3's does
 * not, which changes the hash; every model that guessed the Uniswap signature scanned zero logs.
 */
const KNOWN_SIGNATURES = [
  "Transfer(address,address,uint256)",
  "Approval(address,address,uint256)",
  "TransferSingle(address,address,address,uint256,uint256)",
  "TransferBatch(address,address,address,uint256[],uint256[])",
  "Swap(address,address,int256,int256,uint160,uint128,int24)",
  "Swap(address,address,int256,int256,uint160,uint128,int24,uint128,uint128)",
  "Swap(address,uint256,uint256,uint256,uint256,address)",
  "Sync(uint112,uint112)",
  "Mint(address,address,int24,int24,uint128,uint256,uint256)",
  "Burn(address,int24,int24,uint128,uint256,uint256)",
  "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)",
  "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)",
  "ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)",
  "OrderFulfilled(bytes32,address,address,address,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256,address)[])",
  "Deposit(address,uint256)",
  "Withdrawal(address,uint256)",
];
const SIGNATURE_LABELS = {
  "Swap(address,address,int256,int256,uint160,uint128,int24)": "Uniswap v3 Swap",
  "Swap(address,address,int256,int256,uint160,uint128,int24,uint128,uint128)": "PancakeSwap v3 Swap (protocolFeesToken0/1 after tick)",
  "Swap(address,uint256,uint256,uint256,uint256,address)": "Uniswap v2 / PancakeSwap v2 Swap",
  "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)": "Uniswap v4 PoolManager Swap",
  "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)": "Uniswap v4 PoolManager Initialize",
  "OrderFulfilled(bytes32,address,address,address,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256,address)[])": "Seaport OrderFulfilled",
};
let knownTopics = null;
const nameOfTopic = (topic0) => {
  knownTopics ??= new Map(KNOWN_SIGNATURES.map((sig) => [keccak256(sig), SIGNATURE_LABELS[sig] ? `${sig} — ${SIGNATURE_LABELS[sig]}` : sig]));
  return knownTopics.get(topic0.toLowerCase()) ?? null;
};

/** The tail of the window, unfiltered by event, as the signatures the address actually emitted. */
const SAMPLE_BLOCKS = 2000;
async function seenEvents(address, fromBlock, toBlock, chunkBlocks, concurrency) {
  const from = Math.max(fromBlock, toBlock - SAMPLE_BLOCKS + 1);
  const { logs } = await scanLogs({ address }, from, toBlock, chunkBlocks, concurrency);
  const counts = new Map();
  for (const log of logs) { const t = (log.topics[0] ?? "").toLowerCase(); if (t) counts.set(t, (counts.get(t) ?? 0) + 1); }
  return { sampledFrom: from, sampledTo: toBlock, events: [...counts].sort((a, b) => b[1] - a[1]).slice(0, 8)
    .map(([topic0, count]) => ({ topic0, count, ...(nameOfTopic(topic0) ? { signature: nameOfTopic(topic0) } : {}) })) };
}

const V4_SWAP = "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)";
const V4_INITIALIZE = "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)";
const POOL_KEYS_SELECTOR = "0x86b6be7d"; // poolKeys(bytes25)
const V4_ID_BATCH = 100;
const int128 = (v) => { const x = v & ((1n << 128n) - 1n); return x >= 1n << 127n ? x - (1n << 128n) : x; };
const abs = (v) => (v < 0n ? -v : v);
const addressOf = (topic) => `0x${topic.slice(-40).toLowerCase()}`;

/** The deployer's ranking: descending by sum, ties by key ascending. */
function rankSums(sums, topN) {
  const ranked = [...sums.entries()].sort(([keyA, sumA], [keyB, sumB]) => (sumA !== sumB ? (sumA > sumB ? -1 : 1) : keyA < keyB ? -1 : keyA > keyB ? 1 : 0));
  return { ranked: ranked.slice(0, topN), leader: ranked[0]?.[1] ?? 0n };
}

/**
 * A Uniswap v4 volume ranking, computed as the deployer computes the `v4-volume-rank` recipe.
 *
 * Swaps first, over the window only, grouped by pool id with |amount0| and |amount1| summed as
 * signed int128s. Then which side of each traded pool the token sits on: from the PositionManager's
 * `poolKeys` at the closing block when one is given, which is one call per pool, and otherwise from
 * the pool's Initialize log. The deployer asks for that whole history in one call on its archive
 * endpoint; a public endpoint serves ten thousand blocks at a time, and a manager's history is
 * tens of millions, so here only the pools that could reach the top N are looked up, newest
 * blocks first, stopping when they are found — `--init-chunk` blocks per call, halved if refused.
 * Pools whose other side is excluded are dropped before ranking, exactly as the deployer drops them.
 */
async function v4Rank(fromBlock, toBlock, chunkBlocks, concurrency) {
  const poolManager = (args["pool-manager"] ?? "").toLowerCase();
  const token = (args.token ?? "").toLowerCase();
  const since = Number(args.since);
  if (!/^0x[0-9a-f]{40}$/.test(poolManager) || !/^0x[0-9a-f]{40}$/.test(token)) throw new Error("--v4 needs --pool-manager and --token, each an address");
  if (!Number.isInteger(since) || since < 0 || since > toBlock) throw new Error("--v4 needs --since, the block the pool manager's history starts at, at or before --to");
  const topN = Math.max(1, Number(args.top) || 5);
  const yieldToken = args.yield === "token";
  const excluded = new Set((args.exclude ?? "").split(",").map((a) => a.trim().toLowerCase()).filter(Boolean));

  const { logs: swaps, chunks } = await scanLogs({ address: [poolManager], topics: [keccak256(V4_SWAP)] }, fromBlock, toBlock, chunkBlocks, concurrency);
  const traded = new Map();
  for (const swap of swaps) {
    const id = (swap.topics[1] ?? "").toLowerCase();
    if (!id) throw new Error("a Swap log without a pool id");
    const sums = traded.get(id) ?? { amount0: 0n, amount1: 0n };
    sums.amount0 += abs(int128(word(swap.data, 0)));
    sums.amount1 += abs(int128(word(swap.data, 1)));
    traded.set(id, sums);
  }
  const ids = [...traded.keys()].sort();
  const currencies = new Map();

  const positionManager = args["position-manager"]?.toLowerCase();
  if (positionManager) {
    note(`  reading ${ids.length} pool keys from ${positionManager} at block ${toBlock}`);
    let index = 0;
    const reader = async () => {
      while (index < ids.length) {
        const id = ids[index++];
        const result = await rpc("eth_call", [{ to: positionManager, data: `${POOL_KEYS_SELECTOR}${id.slice(2, 52).padEnd(64, "0")}` }, hex(toBlock)]);
        const body = (result ?? "0x").slice(2);
        if (body.length < 128) continue;
        const currency0 = `0x${body.slice(24, 64)}`, currency1 = `0x${body.slice(88, 128)}`;
        if (currency0 === `0x${"0".repeat(40)}` && currency1 === `0x${"0".repeat(40)}`) continue;
        currencies.set(id, [currency0, currency1]);
      }
    };
    await Promise.all(Array.from({ length: 4 }, reader));
  }

  // Only a pool that could reach the top N needs its currencies. A pool the manager does not know
  // has both sides' volumes in hand already; if neither could pass the N-th pool that is known to
  // hold the token, its currencies change nothing the answer states, and the history scan below
  // is the expensive part of this whole computation.
  const knownVolumes = [...traded].flatMap(([id, amounts]) => {
    const pair = currencies.get(id);
    if (!pair) return [];
    const which = pair[0] === token ? "amount0" : pair[1] === token ? "amount1" : null;
    if (!which || excluded.has(which === "amount0" ? pair[1] : pair[0])) return [];
    return [amounts[which]];
  }).sort((a, b) => (a === b ? 0 : a > b ? -1 : 1));
  const floor = knownVolumes.length >= topN ? knownVolumes[topN - 1] : -1n;
  const missing = ids.filter((id) => !currencies.has(id));
  const contenders = missing.filter((id) => { const a = traded.get(id); return a.amount0 > floor || a.amount1 > floor; });
  if (contenders.length > 0) {
    // Backwards from the closing block, a window at a time, stopping once every contender has its
    // Initialize log: a pool that traded this hour is far likelier to be young than to date from the
    // manager's first week, and a full sweep of the history is the price of the rare old one only.
    const initChunk = Math.max(1, Number(args["init-chunk"]) || 10_000);
    const window = initChunk * 50;
    const wanted = new Set(contenders);
    note(`  resolving ${contenders.length} of ${missing.length} unknown pool${missing.length === 1 ? "" : "s"} from Initialize logs, newest blocks first`);
    for (let to = toBlock; to >= since && wanted.size > 0; to -= window) {
      const from = Math.max(since, to - window + 1);
      const batchIds = [...wanted];
      for (let i = 0; i < batchIds.length; i += V4_ID_BATCH) {
        const { logs } = await scanLogs({ address: [poolManager], topics: [keccak256(V4_INITIALIZE), batchIds.slice(i, i + V4_ID_BATCH)] }, from, to, initChunk, Math.max(concurrency, 8));
        for (const log of logs) {
          const id = (log.topics[1] ?? "").toLowerCase();
          if (id && log.topics[2] && log.topics[3]) { currencies.set(id, [addressOf(log.topics[2]), addressOf(log.topics[3])]); wanted.delete(id); }
        }
      }
      if (wanted.size > 0) note(`  ${wanted.size} still unknown below block ${from}`);
    }
  }

  const sums = new Map();
  const other = new Map();
  for (const [id, amounts] of traded) {
    const pair = currencies.get(id);
    if (!pair) continue;
    const which = pair[0] === token ? "amount0" : pair[1] === token ? "amount1" : null;
    if (!which) continue;
    const otherSide = which === "amount0" ? pair[1] : pair[0];
    if (excluded.has(otherSide)) continue;
    other.set(id, otherSide);
    sums.set(id, amounts[which]);
  }
  const { ranked, leader } = rankSums(sums, topN);
  const unresolved = ids.filter((id) => !currencies.has(id));
  const recipe = { kind: "v4-volume-rank", poolManager, token, initializedSince: since, topN,
    ...(yieldToken ? { yield: "token" } : {}), ...(excluded.size > 0 ? { exclude: [...excluded] } : {}) };
  return {
    poolManager, token, initializedSince: since, swaps: swaps.length, chunks: chunks.length, calls,
    poolsTraded: traded.size, poolsResolved: currencies.size, poolsWithToken: sums.size,
    /** Pools never resolved. Those that could not have reached the top N are left unresolved on purpose. */
    unresolved: unresolved.length, contendersUnresolved: contenders.filter((id) => !currencies.has(id)).length,
    ...(unresolved.length > 0 ? { unresolvedIds: unresolved.slice(0, 10) } : {}),
    ranked: ranked.map(([id, volume]) => ({ pool: id, other: other.get(id), volume: volume.toString() })),
    answerType: yieldToken ? "address[]" : "bytes32[]",
    answer: ranked.map(([id]) => (yieldToken ? other.get(id) : id)),
    figure: leader.toString(),
    recipe,
  };
}

async function main() {
  args = readArgs();
  if (args.keccak !== undefined) { console.log(keccak256(args.keccak)); return; }
  if (!args.rpc) throw new Error("--rpc is required");

  const chainId = Number(await rpc("eth_chainId", []));
  if (args.call) {
    if (!args.data || !args.block) throw new Error("--call needs --data and --block");
    const result = await rpc("eth_call", [{ to: args.call, data: args.data }, hex(args.block)]);
    const value = result && result !== "0x" ? BigInt(result) : null;
    console.log(JSON.stringify({ rpc: args.rpc, chainId, block: Number(args.block), to: args.call, result,
      decimal: value === null ? null : value.toString(), signed: value === null ? null : signed(value).toString(),
      address: value === null ? null : asKey(value & ((1n << 160n) - 1n)) }, null, 2));
    return;
  }

  const fromBlock = Number(args.from), toBlock = Number(args.to);
  if (!Number.isInteger(fromBlock) || !Number.isInteger(toBlock) || fromBlock > toBlock) throw new Error("--from and --to are block numbers, from <= to");
  const closing = await rpc("eth_getBlockByNumber", [hex(toBlock), false]);
  const toBlockHash = closing?.hash ?? null;
  const pinned = args.pin ? toBlockHash?.toLowerCase() === args.pin.toLowerCase() : null;
  if (pinned === false) {
    console.log(JSON.stringify({ rpc: args.rpc, chainId, toBlock, toBlockHash, pin: args.pin, pinned }, null, 2));
    process.exit(2);
  }

  const chunkBlocks = Math.max(1, Number(args.chunk) || 2000);
  const concurrency = Math.min(8, Math.max(1, Number(args.concurrency) || 3));
  if (args.v4) {
    const ranking = await v4Rank(fromBlock, toBlock, chunkBlocks, concurrency);
    console.log(JSON.stringify({ rpc: args.rpc, chainId, fromBlock, toBlock, toBlockHash, pinned, ...ranking }, null, 2));
    return;
  }

  const topics = [args.topic0 ? topicValue(args.topic0) : args.event ? [keccak256(args.event)] : null,
    topicValue(args.topic1) ?? null, topicValue(args.topic2) ?? null, topicValue(args.topic3) ?? null];
  while (topics.length > 0 && topics[topics.length - 1] === null) topics.pop();
  const filter = {
    ...(args.address ? { address: args.address.split(",").map((a) => a.trim().toLowerCase()).filter(Boolean) } : {}),
    ...(topics.length > 0 ? { topics: topics.map((t) => (t && t.length === 1 ? t[0] : t)) } : {}),
  };
  const { logs, chunks } = await scanLogs(filter, fromBlock, toBlock, chunkBlocks, concurrency);

  const result = { rpc: args.rpc, chainId, fromBlock, toBlock, toBlockHash, pinned, filter, logs: logs.length,
    chunks: chunks.length, calls, blocksWithLogs: new Set(logs.map((log) => log.blockNumber)).size };
  // Nothing matched at a named contract with an event filter: say what it does emit, because the
  // likeliest reason is a signature that is nearly right, and a zero written down as the answer
  // is the one mistake every model made on a busy pool.
  if (logs.length === 0 && filter.address && filter.topics) {
    const seen = await seenEvents(filter.address, fromBlock, toBlock, chunkBlocks, concurrency);
    result.seenEvents = seen;
    note(seen.events.length > 0
      ? `  no log matched the requested event; over blocks ${seen.sampledFrom}-${seen.sampledTo} this address emitted: ${seen.events.map((e) => `${e.signature ?? e.topic0} ×${e.count}`).join(", ")}`
      : `  no log matched the requested event, and the address emitted nothing over blocks ${seen.sampledFrom}-${seen.sampledTo}`);
  }
  const read = (spec) => { const reader = fieldReader(spec); return (log) => { const raw = reader(log); const v = args.signed ? signed(raw) : raw; return args.abs && v < 0n ? -v : v; }; };
  if (args.sum) {
    const value = read(args.sum);
    result.sum = logs.reduce((total, log) => total + value(log), 0n).toString();
  }
  if (args.rank) {
    const key = fieldReader(args.rank);
    const value = read(args.by ?? args.sum ?? (() => { throw new Error("--rank needs --by or --sum"); })());
    const totals = new Map();
    for (const log of logs) { const k = asKey(key(log)); totals.set(k, (totals.get(k) ?? 0n) + value(log)); }
    const ranked = [...totals].sort((a, b) => (a[1] === b[1] ? (a[0] < b[0] ? -1 : 1) : a[1] > b[1] ? -1 : 1));
    result.keys = totals.size;
    result.top = ranked.slice(0, Math.max(1, Number(args.top) || 5)).map(([k, total]) => ({ key: k, sum: total.toString() }));
  }
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => { console.error(String(error?.message ?? error)); process.exit(2); });
}
