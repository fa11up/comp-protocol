import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  fallback,
  http,
  keccak256,
  toBytes,
  type Abi,
  type Address,
  type EIP1193Provider,
} from "viem";
export type Deployment = {
  version: 1;
  launchId: string;
  chainId: number;
  sourceCommit: string;
  attestationHash: string;
  contracts: {
    name: string;
    address: Address;
    abiHash: string;
    abiPath: string;
  }[];
  assets: { path: string; sha256: string }[];
  network: {
    chainId: number;
    name: string;
    rpcUrls: string[];
    explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
  };
  walletAddChain?: object;
};
export type Target = { address: Address; abi: Abi };
function sort(v: unknown): unknown {
  return Array.isArray(v)
    ? v.map(sort)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.entries(v)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([k, x]) => [k, sort(x)]),
        )
      : v;
}
export async function loadConfig() {
  const get = async (path: string) => {
    const r = await fetch(new URL(path, document.baseURI));
    if (!r.ok) throw Error(`Unable to load ${path}. Reload the terminal.`);
    return r;
  };
  const config = (await (
    await get("imd-deployment.json")
  ).json()) as Deployment;
  if (
    config.version !== 1 ||
    !config.network ||
    config.chainId !== config.network.chainId ||
    !config.contracts.length
  )
    throw Error(
      "Deployment configuration is incomplete. Transactions are disabled.",
    );
  const abis: Record<string, Abi> = {};
  const targets: Record<string, Target> = {};
  const loadAbi = async (path: string) => {
    if (!/^abi\/[A-Za-z0-9]+\.json$/.test(path))
      throw Error("Invalid ABI path.");
    const asset = config.assets.find((x) => x.path === path);
    if (!asset) throw Error("ABI is missing from the asset inventory.");
    const bytes = await (await get(path)).arrayBuffer();
    const sha = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    )
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    if (sha !== asset.sha256) throw Error("ABI asset integrity check failed.");
    const a = JSON.parse(new TextDecoder().decode(bytes));
    if (!Array.isArray(a)) throw Error("Invalid ABI array.");
    return a as Abi;
  };
  await Promise.all(
    config.contracts.map(async (c) => {
      const abi = await loadAbi(c.abiPath);
      if (keccak256(toBytes(JSON.stringify(sort(abi)))).slice(2) !== c.abiHash)
        throw Error(`ABI binding failed: ${c.name}`);
      abis[c.name] = abi;
      targets[c.name] = { address: c.address, abi };
    }),
  );
  await Promise.all(
    [
      "CompToken",
      "MockIMD",
      "Parameters",
      "Treasury",
      "UsdPriceFeed",
      "MockWorkOracle",
      "SwarmWorkOracle",
    ].map(async (n) => (abis[n] = await loadAbi(`abi/${n}.json`))),
  );
  const chain = defineChain({
    id: config.chainId,
    name: config.network.name,
    nativeCurrency: config.network.nativeCurrency,
    rpcUrls: { default: { http: config.network.rpcUrls } },
  });
  const client = createPublicClient({
    chain,
    transport: fallback(
      config.network.rpcUrls.map((url) =>
        http(url, { timeout: 8000, retryCount: 0 }),
      ),
    ),
    batch: { multicall: false },
  });
  return { config, abis, targets, chain, client };
}
export type Runtime = Awaited<ReturnType<typeof loadConfig>>;
export function wallet(r: Runtime, p: EIP1193Provider) {
  return createWalletClient({ chain: r.chain, transport: custom(p) });
}
export async function switchChain(r: Runtime, p: EIP1193Provider) {
  const chainId = `0x${r.config.chainId.toString(16)}`;
  try {
    await p.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  } catch (e) {
    const err = e as { code?: number; message?: string };
    if (
      err.code !== 4902 &&
      !/unknown chain|unrecognized chain|not added/i.test(err.message || "")
    )
      throw e;
    if (!r.config.walletAddChain)
      throw Error("This network has no wallet setup configuration.");
    await p.request({
      method: "wallet_addEthereumChain",
      params: [r.config.walletAddChain as never],
    });
    await p.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId }],
    });
  }
}
declare global {
  interface Window {
    ethereum?: EIP1193Provider & {
      on?: (event: string, listener: (arg: unknown) => void) => void;
      removeListener?: (
        event: string,
        listener: (arg: unknown) => void,
      ) => void;
    };
  }
}

// Public history service and bounded browser read policy; no indexer is operated by this app.
export const historyConfig = {
  blockscoutApi: "https://eth-sepolia.blockscout.com/api/v2/",
  chainId: 11155111,
  chunkSize: 2000n,
  maxChunks: 10000,
  maxPages: 2000,
  overlap: 12n,
};
