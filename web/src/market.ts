import { useEffect, useState } from "react";
import { createPublicClient, encodeAbiParameters, fallback, http, keccak256, parseAbi } from "viem";
import { mainnet } from "viem/chains";
import rpcUrls from "./ens-rpc.json";

// IMD's live market price, read where the feeds read it: the native-ETH/IMD Uniswap v4 pool on Ethereum
// mainnet (the feeds' data chain on every deployment, testnets included), priced in USD with Chainlink's
// mainnet ETH/USD. It is what the next price update would bring the vault's price towards. It is display
// only: the vault never reads it, and a pool can be pushed within a block, which is why the vault uses
// attested window medians instead.
const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const IMD_POOL_ID = "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3";
const ETH_USD = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419";
const POLL_MS = 30_000;

const client = createPublicClient({
  chain: mainnet,
  transport: fallback(rpcUrls.map((url: string) => http(url, { timeout: 6000, retryCount: 0 }))),
  batch: { multicall: false },
});
const abi = parseAbi([
  "function extsload(bytes32 slot) view returns (bytes32)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);

export type Market = { imdEth: bigint; imdUsd: bigint; ethUsd: bigint; readAt: number };

/** The pool's slot0 lives at keccak256(abi.encode(poolId, 6)); its low 160 bits are sqrtPriceX96. */
const SLOT0 = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [IMD_POOL_ID, 6n]));

export async function readMarket(): Promise<Market> {
  const [word, round] = await Promise.all([
    client.readContract({ address: POOL_MANAGER, abi, functionName: "extsload", args: [SLOT0] }),
    client.readContract({ address: ETH_USD, abi, functionName: "latestRoundData" }),
  ]);
  const sqrt = BigInt(word) & ((1n << 160n) - 1n);
  if (sqrt === 0n) throw Error("IMD's pool is not initialised");
  // currency0 is native ETH and currency1 is IMD, so the raw price is IMD per ETH; invert it.
  const imdEth = (10n ** 18n << 192n) / (sqrt * sqrt);
  const ethUsd = round[1] as bigint; // 8 decimals
  if (ethUsd <= 0n) throw Error("ETH/USD unreadable");
  return { imdEth, ethUsd, imdUsd: (imdEth * ethUsd) / 10n ** 8n, readAt: Date.now() };
}

/** The live market, refreshed every 30 s; undefined until read or while unreadable. */
export function useMarket(): Market | undefined {
  const [m, setM] = useState<Market>();
  useEffect(() => {
    let live = true;
    // A failed read keeps the last good price for two minutes, then shows none rather than an old one.
    const tick = () =>
      readMarket()
        .then((x) => live && setM(x))
        .catch(() => live && setM((old) => (old && Date.now() - old.readAt < 120_000 ? old : undefined)));
    tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      live = false;
      clearInterval(id);
    };
  }, []);
  return m;
}
