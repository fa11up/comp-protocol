// Points the terminal at a mainnet deployment: turns the record `launch.sh` leaves behind
// (deploy/mainnet/out/deployment.json + out/bodies/) into web/deployment-source.json, and copies the
// ABIs the terminal loads from the FROZEN commit's docs/abi into web/public/abi, byte for byte, so
// manifest.mjs's pin check (`git show sourceCommit:docs/abi/X.json`) holds.
//
//   node web/scripts/mainnet-deployment.mjs --record <deployment.json> --commit <frozen sha>
//        [--bodies <dir>]   default: <record's dir>/bodies
//        [--rpc <url>]      replaces the public RPC list (fork tests only; refuses a non-local URL)
//
// Everything else the terminal needs (gem, imdUSD, Parameters, Treasury, the work oracle, the collateral
// price feed) it reads from the vault on chain, so the record's four contracts are all this writes.
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toBytes, getAddress, toHex } from "viem";

// manifest.mjs's canonical form (sorted keys), so the hashes here are the ones it checks.
const canonical = (v) => JSON.stringify(sort(v));
function sort(v) {
  return Array.isArray(v)
    ? v.map(sort)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, sort(v[k])]),
        )
      : v;
}

const web = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(web, "..");
const arg = (k) => {
  const i = process.argv.indexOf(k);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const recordPath = arg("--record");
const commit = arg("--commit");
if (!recordPath || !commit) {
  console.error(
    "usage: mainnet-deployment.mjs --record <deployment.json> --commit <sha> [--bodies <dir>] [--rpc <url>]",
  );
  process.exit(2);
}
const sha = execFileSync(
  "git",
  ["rev-parse", "--verify", `${commit}^{commit}`],
  { cwd: root },
)
  .toString()
  .trim();
const recordRaw = await readFile(recordPath);
const rec = JSON.parse(recordRaw);
const bodiesDir = arg("--bodies") ?? resolve(dirname(recordPath), "bodies");

const need = ["vault", "priceFeed", "nhiFeed", "spotFeed", "oracleAsker"];
const missing = need.filter((k) => !rec[k]);
if (missing.length)
  throw Error(
    `the record has no ${missing.join(", ")}: run it after stage two (the vault)`,
  );
if (rec.interface !== "maker")
  throw Error(
    `the record names interface "${rec.interface}"; mainnet is "maker"`,
  );

const rpcOverride = arg("--rpc");
if (
  rpcOverride &&
  !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(rpcOverride)
)
  throw Error("--rpc is for fork tests and takes a local URL only");
if (Number(rec.chainId) !== 1 && !rpcOverride)
  throw Error(`the record is for chain ${rec.chainId}, not mainnet`);

// The ABI each deployed contract answers to, and the extra ones config.ts loads by name.
const contracts = [
  ["PriceFeed", rec.priceFeed],
  ["NhiFeed", rec.nhiFeed],
  ["SpotFeed", rec.spotFeed],
  ["ParameterizedVault", rec.vault],
];
const extra = [
  "ImdUSD",
  "MockIMD",
  "Parameters",
  "Treasury",
  "UsdPriceFeed",
  "MockWorkOracle",
  "SwarmWorkOracle",
];
const pinned = (name) =>
  execFileSync("git", ["show", `${sha}:docs/abi/${name}.json`], { cwd: root });

await mkdir(`${web}/public/abi`, { recursive: true });
for (const name of [...contracts.map(([n]) => n), ...extra])
  await writeFile(`${web}/public/abi/${name}.json`, pinned(name));

// The bodies the asker pins, as the deploy wrote them; each must hash to what its feed is registered with.
const bodies = {};
for (const [name, file] of [
  ["PriceFeed", "price"],
  ["NhiFeed", "nhi"],
  ["SpotFeed", "spot"],
]) {
  const raw = await readFile(`${bodiesDir}/${file}.json`);
  bodies[name] = toHex(raw);
}

const rpcUrls = rpcOverride
  ? [rpcOverride]
  : [
      "https://ethereum-rpc.publicnode.com",
      "https://eth.drpc.org",
      "https://rpc.mevblocker.io",
      "https://eth-mainnet.public.blastapi.io",
    ];
const chainId = Number(rec.chainId);
const network = {
  chainId,
  name: "Ethereum",
  testnet: false,
  rpcUrls,
  explorer: "https://etherscan.io",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
};
const source = {
  version: 1,
  // Our own deployment, not a swarm launch: the id names the deploy block, and the hash binds this file
  // to the exact record it was made from.
  launchId: `imdusd-mainnet-${rec.block}`,
  chainId,
  sourceCommit: sha,
  attestationHash: createHash("sha256").update(recordRaw).digest("hex"),
  contracts: contracts.map(([name, address]) => ({
    name,
    address: getAddress(address).toLowerCase(),
    abiHash: keccak256(toBytes(canonical(JSON.parse(pinned(name))))).slice(2),
    abiPath: `abi/${name}.json`,
  })),
  network,
  walletAddChain: {
    chainId: `0x${chainId.toString(16)}`,
    chainName: network.name,
    rpcUrls,
    nativeCurrency: network.nativeCurrency,
    blockExplorerUrls: [network.explorer],
  },
  interface: "maker",
  oracleAsker: {
    address: getAddress(rec.oracleAsker).toLowerCase(),
    requests: bodies,
  },
};
await writeFile(
  `${web}/deployment-source.json`,
  JSON.stringify(source, null, 2) + "\n",
);
console.log(
  `deployment-source.json -> chain ${chainId}, vault ${source.contracts[3].address}, asker ${source.oracleAsker.address}; ` +
    `${contracts.length + extra.length} ABIs from ${sha.slice(0, 7)}`,
);
