import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import {
  fixture,
  fixtureLogs,
  addresses,
  abi,
  account,
  candidate,
  closedOwner,
  extraOwner,
} from "./fixture.mjs";
// Node's TS stripping cannot resolve extensionless browser imports. This scratch copy
// only resolves module paths; the delivered source's behavior is exercised unchanged.
const scratch = new URL(
  "../../test/scratch/history-module.ts",
  import.meta.url,
);
await mkdir(new URL(".", scratch), { recursive: true });
let source = await readFile(
  new URL("../src/history.ts", import.meta.url),
  "utf8",
);
for (const name of ["config", "state"])
  source = source.replaceAll(
    `"./${name}"`,
    JSON.stringify(new URL(`../src/${name}.ts`, import.meta.url).pathname),
  );
source = source.replace(
  '"viem"',
  JSON.stringify(
    new URL("../node_modules/viem/_esm/index.js", import.meta.url).pathname,
  ),
);
await writeFile(scratch, source);
const { rangeLogs, explorerLogs, loanBook, acceptedPoints, positionName } =
  await import(scratch.href);
const t = {
  address: addresses.ParameterizedVault,
  abi: abi.ParameterizedVault,
};
const feed = { address: addresses.PriceFeed, abi: abi.PriceFeed };
const originalFetch = global.fetch;
const state = fixture();
const depositLogs = fixtureLogs(state, t.address);
const normalized = (logs) =>
  logs.map((l) => ({
    ...l,
    blockNumber: BigInt(l.blockNumber),
    logIndex: Number(BigInt(l.logIndex)),
  }));
const runtime = (client) => ({ config: { chainId: 11155111 }, client });

test("historical ranges are contiguous, inclusive, and at most 2,000 blocks", async () => {
  const ranges = [];
  const r = runtime({
    getLogs: async (params) => {
      ranges.push(params);
      return [{ ...depositLogs[0], blockNumber: params.fromBlock }];
    },
  });
  const result = await rangeLogs(r, t, 16n, 5020n);
  assert.equal(result.source, "RPC");
  assert.deepEqual(
    ranges.map((p) => [p.fromBlock, p.toBlock]),
    [
      [16n, 2015n],
      [2016n, 4015n],
      [4016n, 5020n],
    ],
  );
});
test("silent empty RPC falls back to every Blockscout page, and both empty is unknown", async () => {
  let urls = [];
  global.fetch = async (url) => {
    urls.push(String(url));
    const second = String(url).includes("block_number=100");
    const selected = second ? depositLogs.slice(0, 2) : depositLogs.slice(2);
    return {
      ok: true,
      json: async () => ({
        items: selected,
        next_page_params: second
          ? null
          : { block_number: 100, index: 2, items_count: 3 },
      }),
    };
  };
  try {
    const result = await rangeLogs(
      runtime({ getLogs: async () => [] }),
      t,
      16n,
      256n,
    );
    assert.equal(result.source, "Blockscout");
    assert.equal(result.logs.length, 5);
    assert.equal(urls.length, 2);
    global.fetch = async () => ({
      ok: true,
      json: async () => ({ items: [], next_page_params: null }),
    });
    await assert.rejects(
      rangeLogs(runtime({ getLogs: async () => [] }), t, 16n, 256n),
      /Could not read history/,
    );
  } finally {
    global.fetch = originalFetch;
  }
});
test("pagination loops, missing cursor schema and wrong-address logs cannot certify coverage", async () => {
  try {
    global.fetch = async () => ({
      ok: true,
      json: async () => ({
        items: depositLogs,
        next_page_params: { index: 1 },
      }),
    });
    await assert.rejects(
      explorerLogs(runtime({}), t, 16n, 256n),
      /did not advance/,
    );
    global.fetch = async () => ({
      ok: true,
      json: async () => ({ items: depositLogs }),
    });
    await assert.rejects(explorerLogs(runtime({}), t, 16n, 256n), /Incomplete/);
    global.fetch = async () => ({
      ok: true,
      json: async () => ({
        items: [{ ...depositLogs[0], address: feed.address }],
        next_page_params: null,
      }),
    });
    await assert.rejects(
      explorerLogs(runtime({}), t, 16n, 256n),
      /address mismatch/,
    );
  } finally {
    global.fetch = originalFetch;
  }
});
test("book discovers distinct deposit owners, reads the same block, drops zero debt, fails on partial reads", async () => {
  const calls = [];
  const r = runtime({
    getCode: async ({ blockNumber }) => (blockNumber >= 16n ? "0x01" : "0x"),
    getLogs: async () => depositLogs,
    readContract: async ({ functionName, args, blockNumber }) => {
      calls.push({ functionName, args, blockNumber });
      if (functionName === "collateralRatio") return 180n;
      return [
        100n,
        args[0].toLowerCase() === closedOwner.toLowerCase() ? 0n : 50n,
      ];
    },
  });
  const s = { targets: { ParameterizedVault: t }, block: 256n };
  const book = await loanBook(r, s);
  assert.equal(book.history.from, 16n);
  assert.equal(book.positions.length, 3);
  assert.equal(calls.filter((c) => c.functionName === "positions").length, 4);
  assert.ok(calls.every((c) => c.blockNumber === 256n));
  r.client.readContract = async () => {
    throw Error("owner unavailable");
  };
  await assert.rejects(loanBook(r, s), /owner unavailable/);
});
test("accepted points pair the preceding value within the same transaction; reporter values excluded", () => {
  const logs = normalized(fixtureLogs(state, feed.address));
  const points = acceptedPoints(feed, logs);
  assert.equal(points.length, 4);
  assert.deepEqual(
    points.map((p) => Number(state.now) - p.time),
    [7200, 7000, 2400, 120],
  );
  assert.equal(points[0].value, 10n ** 15n);
  assert.equal(
    acceptedPoints(
      feed,
      logs.filter((l) => l.logIndex === 0),
    ).length,
    0,
  );
  assert.throws(() => acceptedPoints(feed, [logs[1]]), /missing its value/);
});
test("address names use the complete address and stable case-independent vocabulary", () => {
  assert.equal(positionName(account), positionName(account.toUpperCase()));
  assert.equal(positionName(account), "Copper Penny");
  assert.notEqual(positionName(account), positionName(candidate));
  assert.match(positionName(extraOwner), /^\w+ \w+$/);
});
