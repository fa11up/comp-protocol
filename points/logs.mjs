// Reads a vault's Principal and Bite events from Blockscout and turns them into engine events.
//
// Blockscout, never a public RPC's eth_getLogs: public nodes silently return an EMPTY array for
// ranges they decline, and a reader that takes "no logs" at face value reports "nobody borrowed".
// A deployed vault always has at least its constructor's logs, so zero logs is treated as an error.

export const HOSTS = { ethereum: "eth.blockscout.com", sepolia: "eth-sepolia.blockscout.com" };

// keccak256 topics, precomputed (no dependency): cast keccak "Principal(address,uint256)" etc.
export const TOPICS = {
  principal: "0xaa854fc43b5dade4dc7aa24a0d5e427d718c5d3aa5db80265f2d300880fb2867",
  bite: "0xc55e1bb84cb7e132c40564eb13e09fd474d063a3c1142615fe6a309d21c1c5aa",
};

const word = (hex, i) => BigInt("0x" + hex.slice(2 + i * 64, 2 + (i + 1) * 64));
const topicAddress = (topic) => "0x" + topic.slice(-40).toLowerCase();

/** Decode one Blockscout v2 log item into an engine event, or null if it is neither event. */
export function decodeLog(item) {
  const [t0, t1, t2] = item.topics ?? [];
  const base = {
    timestamp: Math.floor(Date.parse(item.block_timestamp) / 1000),
    blockNumber: Number(item.block_number),
    logIndex: Number(item.index),
  };
  if (!Number.isFinite(base.timestamp)) throw new Error(`log ${item.transaction_hash}:${item.index} has no block_timestamp`);
  if (t0 === TOPICS.principal) return { kind: "principal", owner: topicAddress(t1), debt: word(item.data, 0), ...base };
  if (t0 === TOPICS.bite) return { kind: "bite", owner: topicAddress(t1), liquidator: topicAddress(t2), debtRepaid: word(item.data, 0), ...base };
  return null;
}

/** Every log the vault emitted, all pages. Throws on zero: see the header. */
export async function fetchVaultLogs({ chain, vault, apiKey = process.env.BLOCKSCOUT_API_KEY, fetchImpl = fetch }) {
  const host = HOSTS[chain];
  if (!host) throw new Error(`unknown chain ${chain}; one of ${Object.keys(HOSTS).join(", ")}`);
  const headers = { Accept: "application/json", "User-Agent": "infer-points/1.0" };
  if (apiKey) headers["x-api-key"] = apiKey;
  const items = [];
  let params = null;
  for (let page = 0; page < 10_000; ++page) {
    const qs = params ? "?" + new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])) : "";
    const res = await fetchImpl(`https://${host}/api/v2/addresses/${vault}/logs${qs}`, { headers });
    if (!res.ok) throw new Error(`blockscout ${res.status} on page ${page}`);
    const body = await res.json();
    items.push(...(body.items ?? []));
    params = body.next_page_params;
    if (!params) break;
  }
  if (items.length === 0) throw new Error(`no logs at all for ${vault} on ${chain}: wrong address or chain, or the explorer declined; refusing to report "no positions"`);
  return items;
}

/** Fetch and decode; returns the engine's events plus how many raw logs were read. */
export async function loadEvents(opts) {
  const items = await fetchVaultLogs(opts);
  const events = items.map(decodeLog).filter(Boolean);
  return { events, logsRead: items.length };
}
