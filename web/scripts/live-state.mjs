import { readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { encodeFunctionData, decodeFunctionResult } from "viem";
const run = promisify(execFile);
const config = JSON.parse(
  await readFile(new URL("../deployment-source.json", import.meta.url)),
);
const rpc = config.network.rpcUrls[0];
const abis = {};
for (const n of [
  "ParameterizedVault",
  "UsdPriceFeed",
  "MockWorkOracle",
  "Parameters",
])
  abis[n] = JSON.parse(
    await readFile(new URL(`../public/abi/${n}.json`, import.meta.url)),
  );
async function batch(requests) {
  const { stdout } = await run(
    "curl",
    [
      "-sS",
      "--max-time",
      "15",
      "-H",
      "Content-Type: application/json",
      "--data",
      JSON.stringify(requests.map((r, i) => ({ jsonrpc: "2.0", id: i, ...r }))),
      rpc,
    ],
    { maxBuffer: 2 * 1024 * 1024 },
  );
  return JSON.parse(stdout);
}
const vault = config.contracts.find(
  (c) => c.name === "ParameterizedVault",
).address;
const first = await batch([{ method: "eth_blockNumber", params: [] }]);
const block = process.argv[2]
  ? `0x${BigInt(process.argv[2]).toString(16)}`
  : first[0].result;
const call = (name, target, fn, args = []) => ({
  method: "eth_call",
  params: [
    {
      to: target,
      data: encodeFunctionData({ abi: abis[name], functionName: fn, args }),
    },
    block,
  ],
});
const names = [
  "oracle",
  "usdPriceFeed",
  "parameters",
  "redemptionReserve",
  "minCR",
  "redemptionCeilingCR",
  "redemptionFeeBps",
  "REDEMPTION_FEE_FLOOR_BPS",
  "REDEMPTION_FEE_CAP_BPS",
];
const raw = await batch(
  names.map((fn) =>
    call(
      "ParameterizedVault",
      vault,
      fn,
      fn === "redemptionFeeBps" ? [0n] : [],
    ),
  ),
);
const data = {};
for (let i = 0; i < names.length; i++) {
  const res = raw.find((r) => r.id === i);
  data[names[i]] =
    res.error ||
    decodeFunctionResult({
      abi: abis.ParameterizedVault,
      functionName: names[i],
      data: res.result,
    });
}
const further = [
  ["MockWorkOracle", data.oracle, "deployer"],
  ["UsdPriceFeed", data.usdPriceFeed, "latestValue"],
  ["UsdPriceFeed", data.usdPriceFeed, "isStale"],
  ["Parameters", data.parameters, "compPerTaskWad"],
];
const raw2 = await batch(further.map(([name, t, fn]) => call(name, t, fn)));
for (let i = 0; i < further.length; i++) {
  const [name, , fn] = further[i];
  const res = raw2.find((r) => r.id === i);
  data[`${name}.${fn}`] =
    res.error ||
    decodeFunctionResult({
      abi: abis[name],
      functionName: fn,
      data: res.result,
    });
}
const evidence = {
  observedAt: new Date().toISOString(),
  rpc,
  blockNumber: BigInt(block),
  method:
    "Read-only eth_call at one explicit block; encoding and decoding with exported implementation ABIs. Run node web/scripts/live-state.mjs to observe a new block.",
  data,
};
await writeFile(
  new URL("../../docs/frontend/live-state.json", import.meta.url),
  JSON.stringify(
    evidence,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ) + "\n",
);
console.log(
  JSON.stringify(
    evidence,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ),
);
