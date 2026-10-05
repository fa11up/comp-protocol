// The collateral as the vault holds it, read once per snapshot from the vault's own gem():
//   mainnet — sIMD, a 24-decimal share of IMD's staking vault, priced per 1e18 RAW units;
//   legacy  — plain 18-decimal test IMD.
// The vault never reads decimals: every collateral price is per 1e18 raw units, so amounts are
// formatted with the token's own decimals and prices are converted back to "per IMD" through the
// staking vault's exchange rate wherever a person reads them.
import { parseAbi } from "viem";
import { fmt, exact, amount, WAD } from "./math.ts";

export const shareAbi = parseAbi([
  "function asset() view returns (address)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
]);
export const vaultShareAbi = parseAbi([
  "function collateralPriceFeed() view returns (address)",
  "function lockIMD(uint256 assets)",
]);

export type Collateral = {
  symbol: string;
  decimals: number;
  /** True when the collateral is a staking-vault share (sIMD) over IMD. */
  share: boolean;
  /** Underlying (IMD) raw units per 1e18 raw collateral units; 1e18 for plain IMD. */
  rate: bigint;
  underlyingSymbol: string;
  underlyingDecimals: number;
};
const PLAIN: Collateral = {
  symbol: "IMD",
  decimals: 18,
  share: false,
  rate: WAD,
  underlyingSymbol: "IMD",
  underlyingDecimals: 18,
};
let current: Collateral = PLAIN;
export const collateral = () => current;
export function setCollateral(c: Partial<Collateral>) {
  const symbol =
    typeof c.symbol === "string" && /^[A-Za-z0-9._-]{1,16}$/.test(c.symbol)
      ? c.symbol
      : PLAIN.symbol;
  current = { ...PLAIN, ...c, symbol };
}
export const gemUnit = () => current.symbol;
/** A raw collateral amount in its own decimals. */
export const fmtGem = (v: bigint | undefined, places = 4) =>
  fmt(v, current.decimals, places);
export const exactGem = (v: bigint) => exact(v, current.decimals);
export const parseGem = (text: string) => amount(text, current.decimals);
/** A raw collateral amount as the IMD it is worth (itself, for plain IMD). */
export const asImd = (v: bigint | undefined) =>
  v === undefined || current.rate <= 0n ? undefined : (v * current.rate) / WAD;
/**
 * A USD price per 1e18 raw collateral units (what the vault reads) as a USD price per IMD.
 * For sIMD: P_imd = P_share * 1e18 / rate.
 */
export const perImd = (p: bigint | undefined) =>
  p === undefined || current.rate <= 0n ? undefined : (p * WAD) / current.rate;
