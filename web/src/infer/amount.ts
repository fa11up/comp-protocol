import { parseUnits } from "viem";

/**
 * A typed amount as wei, or zero for anything that is not a plain positive decimal: letters, signs,
 * exponents, a second point. Thousands separators and surrounding spaces are forgiven.
 */
export function parseAmount(text: string, decimals: number): bigint {
  const t = text.trim().replace(/,/g, "");
  if (!/^\d*\.?\d*$/.test(t) || t === "" || t === ".") return 0n;
  try {
    return parseUnits(t, decimals);
  } catch {
    return 0n;
  }
}
