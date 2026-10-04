import { readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const run = promisify(execFile);
const config = JSON.parse(
  await readFile(new URL("../deployment-source.json", import.meta.url)),
);
const requests = [
  { jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] },
  ...config.contracts.map((c, i) => ({
    jsonrpc: "2.0",
    id: i + 2,
    method: "eth_getCode",
    params: [c.address, "latest"],
  })),
];
const results = await Promise.all(
  config.network.rpcUrls.map(async (url) => {
    try {
      const { stdout } = await run(
        "curl",
        [
          "-sS",
          "--max-time",
          "15",
          "-H",
          "Content-Type: application/json",
          "--data",
          JSON.stringify(requests),
          url,
        ],
        { maxBuffer: 2 * 1024 * 1024 },
      );
      const data = JSON.parse(stdout);
      if (!Array.isArray(data))
        return {
          url,
          error: "RPC did not return batch results",
          response: data,
        };
      const chain = data.find((x) => x.id === 1);
      return {
        url,
        chainId: chain?.result ? Number(chain.result) : null,
        chainError: chain?.error,
        contracts: config.contracts.map((c, i) => {
          const value = data.find((x) => x.id === i + 2);
          return {
            name: c.name,
            address: c.address,
            codeBytes: value?.result ? (value.result.length - 2) / 2 : 0,
            error: value?.error,
          };
        }),
      };
    } catch (e) {
      return { url, error: e.message.slice(0, 300) };
    }
  }),
);
const evidence = {
  observedAt: new Date().toISOString(),
  sourceCommit: config.sourceCommit,
  method:
    "eth_chainId and eth_getCode(address, latest), curl JSON-RPC batch to each configured public endpoint. Read only; no wallet used.",
  results,
};
await writeFile(
  new URL("../../docs/frontend/live-check.json", import.meta.url),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(JSON.stringify(evidence, null, 2));
