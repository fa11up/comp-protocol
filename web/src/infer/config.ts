// The INFER page's one source of figures and addresses: src/infer/launch.json when it exists (private
// until the launch request is submitted, so gitignored), else launch.example.json, whose every figure
// is null and renders as a dash. Both files have the same shape; tests/infer.test.mjs checks them.
import type { Address } from "viem";
import type { PoolKey } from "./swap";

export type Allocation = {
  key: string;
  label: string;
  bps: number | null;
  note: string;
};
export type Redemption = {
  key: string;
  symbol: string;
  token: Address | null;
  decimals: number;
  /** INFER per one whole legacy token, as a decimal string. */
  rate: string | null;
  /** Whole INFER set aside for this redemption. */
  allocation: string | null;
  window: string;
};
export type Launch = {
  chainId: number;
  rpc: string[];
  supply: string | null;
  openingMarketCapImd: string | null;
  pair: string;
  allocation: Allocation[];
  /** No season figures: each season's pot is set when it is opened, and the plan is not published. */
  seasons: {
    count: number;
    weeks: number;
    vestWeeks: number;
    pointsRule: string;
  };
  redemptions: Redemption[];
  founder: {
    amount: string | null;
    months: number | null;
    cliffDays: number | null;
  };
  fees: { treasuryBps: number | null };
  contracts: {
    infer: Address | null;
    seasonVault: Address | null;
    legacyRedeemer: Address | null;
    stakedInfer: Address | null;
    founderStream: Address | null;
    dripper: Address | null;
    /** The token INFER is paired with in the launch pool; address(0) means native ETH. */
    pair: Address;
    poolManager: Address;
  };
  /** The launch pool's full Uniswap v4 key, null until the pool exists. */
  poolKey: PoolKey | null;
  /** Uniswap's mainnet contracts the trade pane uses. */
  router: { universalRouter: Address; quoter: Address; permit2: Address };
  slippageBps: number;
  /** One leaf file per season (`files[s]`), and the origins the page may fetch them from. */
  claims: { files: (string | null)[]; origins: string[] };
  links: { swap: string | null; pool: string | null; launch: string | null };
};

const files = import.meta.glob("./launch*.json", {
  eager: true,
  import: "default",
}) as Record<string, Launch>;
export const LAUNCH: Launch =
  files["./launch.json"] ?? files["./launch.example.json"];
if (!LAUNCH) throw Error("src/infer/launch.example.json is missing");
/** True once the token exists: the claim, swap and stake flows then read and write the chain. */
export const LIVE = LAUNCH.contracts.infer !== null;

/** A figure for display: "1,000,000,000", at most `places` decimals, or null when pending. */
export function whole(v: string | null, places = 4): string | null {
  if (v === null) return null;
  const [int, frac = ""] = v.split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const f = frac.slice(0, places).replace(/0+$/, "");
  return f ? `${grouped}.${f}` : grouped;
}

/** A large figure in words: "1 Billion", "80.6 Million", "14.44 Thousand"; null when pending. */
export function compact(v: string | null): string | null {
  if (v === null) return null;
  const n = Number(v);
  const scales: [number, string][] = [
    [1e12, "Trillion"],
    [1e9, "Billion"],
    [1e6, "Million"],
    [1e3, "Thousand"],
  ];
  for (const [size, word] of scales) {
    if (n >= size) {
      const x = n / size;
      // Two decimals at most, trailing zeros dropped: 34.0535 Million reads as 34.05 Million.
      return `${Number(x.toFixed(2)).toString()} ${word}`;
    }
  }
  return Number(n.toFixed(2)).toString();
}

export const pct = (bps: number | null) =>
  bps === null ? null : `${(bps / 100).toString()}%`;

/** The INFER each allocation bucket holds, from the supply and its share. */
export function bucketAmount(bps: number | null): string | null {
  if (bps === null || LAUNCH.supply === null) return null;
  return ((BigInt(LAUNCH.supply) * BigInt(bps)) / 10_000n).toString();
}
