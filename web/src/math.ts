import {
  formatUnits,
  parseUnits,
  isAddress,
  getAddress,
  maxUint256,
} from "viem";
export const WAD = 10n ** 18n;
export const fmt = (v: bigint | undefined, d = 18, places = 4): string => {
  if (v === undefined) return "—";
  const [a, b = ""] = formatUnits(v, d).split(".");
  return (
    Number(a).toLocaleString("en-US", { maximumFractionDigits: 0 }) +
    (b && places
      ? "." + b.slice(0, places).padEnd(Math.min(places, b.length), "0")
      : "")
  );
};
export const exact = (v: bigint, d = 18) => formatUnits(v, d);
export const percent = (v: bigint | undefined) =>
  v === undefined ? "—" : `${formatUnits(v, 2)}%`;
export const ratio = (v: bigint | undefined) =>
  v === maxUint256 ? "Debt-free" : v === undefined ? "—" : `${v}%`;
export function amount(text: string, d = 18, allowZero = false) {
  if (!new RegExp(`^\\d+(?:\\.\\d{1,${d}})?$`).test(text.trim()))
    throw Error(`Enter a positive amount with at most ${d} decimal places.`);
  const n = parseUnits(text.trim(), d);
  if ((allowZero ? n < 0n : n <= 0n) || n > maxUint256)
    throw Error(
      "Enter an amount greater than zero and within the token range.",
    );
  return n;
}
export function address(text: string) {
  const t = text.trim();
  if (!isAddress(t)) throw Error("Enter a valid 0x address.");
  return getAddress(t);
}
export function uint(text: string) {
  if (!/^\d+$/.test(text.trim()))
    throw Error("Enter a whole non-negative number.");
  const n = BigInt(text);
  if (n > maxUint256) throw Error("Number is too large.");
  return n;
}
// Mirrors the vault: payoutScale = mulDiv(backingPerComp, 10000 - fee, 10000), where
// backingPerComp never exceeds par. A deployment without backingPerComp() pays par.
export function payout(
  comp: bigint,
  fee: bigint,
  price: bigint,
  reserve: bigint,
  backing: bigint = WAD,
) {
  if (price <= 0n || fee >= 10000n)
    throw Error("A valid, fresh USD price is required.");
  const paidAt = backing < WAD ? backing : WAD;
  const scale = (paidAt * (10000n - fee)) / 10000n;
  if (scale === 0n)
    throw Error("Backing per COMP is zero. A redemption would pay nothing.");
  const out = (comp * scale) / price;
  if (!out) throw Error("This amount rounds to zero IMD. Increase the amount.");
  const reserveOut = out < reserve ? out : reserve;
  return {
    out,
    reserveOut,
    positionOut: out - reserveOut,
    debtCancelled:
      reserveOut === out ? 0n : comp - (reserveOut * price) / scale,
    paidAt,
    capped: paidAt < WAD,
    source:
      reserveOut === out
        ? "Reserve"
        : reserveOut === 0n
          ? "Position"
          : "Reserve + position",
  };
}
export function age(t: bigint | undefined, now: bigint) {
  if (!t) return "Unpublished";
  const s = now > t ? now - t : 0n;
  return s < 60n
    ? `${s}s ago`
    : s < 3600n
      ? `${s / 60n}m ago`
      : `${s / 3600n}h ${(s % 3600n) / 60n}m ago`;
}
export function message(e: unknown): string {
  const err = e as {
    shortMessage?: string;
    message?: string;
    cause?: unknown;
    data?: { errorName?: string };
    code?: number;
  };
  if (err.code === 4001 || /rejected|denied/i.test(err.message || ""))
    return "Wallet request rejected. Nothing was sent. You can try again.";
  const known: Record<string, string> = {
    StaleFeed:
      "A required price feed is stale. Wait for a fresh attestation, then refresh.",
    PriceDivergence:
      "Primary and spot prices disagree beyond the allowed limit. Try again after the feeds converge.",
    IneligibleRedemptionPosition:
      "This position is debt-free or at/above the eligibility ceiling. Choose another candidate.",
    RedemptionWorsensRatio:
      "The candidate’s collateral ratio would fall. Choose another candidate.",
    MinimumOutNotMet: "The payout fell below your minimum. Refresh the quote.",
    WorkCeilingReached:
      "Work issuance would exceed its backing ceiling. Reduce the amount or wait for more backing.",
    InsufficientRights: "This account has insufficient work rights.",
    InsufficientCollateral: "There is not enough collateral for this action.",
    Unauthorized: "This account does not have permission.",
    ExcessRepayment:
      "The amount exceeds available supply or the candidate’s debt.",
    PositionNotMarked: "Mark the unhealthy position before liquidating.",
    GracePeriodNotElapsed: "The liquidation grace period has not ended.",
    HealthyPosition: "This position is healthy and cannot be liquidated.",
    MarkExpired: "The mark expired. Mark the position again.",
    UnsafeCollateralRatio:
      "This would put the position below the required collateral ratio.",
  };
  let x: unknown = e;
  for (let i = 0; i < 8 && x; i++) {
    const c = x as typeof err;
    const name = c.data?.errorName;
    if (name && known[name]) return known[name];
    x = c.cause;
  }
  if (
    /RPC|HTTP request|fetch failed|network request/i.test(
      err.shortMessage || "",
    )
  )
    return "The public RPC request failed. Refresh state to try again.";
  const s =
    err.shortMessage ||
    err.message ||
    "Request failed. Refresh state and try again.";
  for (const [key, v] of Object.entries(known)) if (s.includes(key)) return v;
  return s.slice(0, 500);
}

// Position arithmetic, mirroring CDPVault._collateralRatio: CR% = collateral * price / (debt * 1e16),
// healthy when CR >= minCR. Price is the 1e18-scaled USD price per IMD the vault reads.
const ceilDiv = (a: bigint, b: bigint) => (a === 0n ? 0n : (a - 1n) / b + 1n);
export const CR_SCALE = 10n ** 16n;
/** Smallest collateral (IMD wei) that keeps `debt` at or above `minCR`. */
export function requiredCollateral(debt: bigint, minCR: bigint, price: bigint) {
  if (price <= 0n) throw Error("A valid USD price is required.");
  return ceilDiv(debt * minCR * CR_SCALE, price);
}
/** Most COMP a position can owe in total at `minCR`, given its collateral. */
export function maxDebt(collateral: bigint, minCR: bigint, price: bigint) {
  if (minCR <= 0n) throw Error("A valid minCR is required.");
  return (collateral * price) / (minCR * CR_SCALE);
}
/** USD price per IMD (1e18-scaled) at which the position reaches minCR. */
export function liquidationPrice(
  collateral: bigint,
  debt: bigint,
  minCR: bigint,
): bigint | undefined {
  if (debt === 0n || collateral === 0n) return undefined;
  return ceilDiv(debt * minCR * CR_SCALE, collateral);
}
/** Signed basis points the price can fall before liquidation; negative means already below. */
export function cushionBps(price: bigint, liquidation: bigint) {
  return price > 0n ? ((price - liquidation) * 10000n) / price : undefined;
}
export function cushion(
  price: bigint | undefined,
  liquidation: bigint | undefined,
) {
  if (price === undefined || liquidation === undefined) return "—";
  const bps = cushionBps(price, liquidation);
  if (bps === undefined) return "—";
  return bps >= 0n
    ? `${formatUnits(bps, 2)}% above it`
    : `${formatUnits(-bps, 2)}% below it`;
}

/** Seconds as the largest two units: "2h 14m", "14m 5s", "5s". */
export function span(seconds: bigint) {
  const s = seconds > 0n ? seconds : 0n;
  if (s >= 3600n) return `${s / 3600n}h ${(s % 3600n) / 60n}m`;
  if (s >= 60n) return `${s / 60n}m ${s % 60n}s`;
  return `${s}s`;
}
/**
 * What a keeper can do next with an inspected position, as the Act button's label.
 * mark = [markedAt, grace, active] from liquidationMarks(owner).
 */
export function nextStep(
  p: { cr: bigint; mark: readonly [bigint, bigint, boolean, ...unknown[]] },
  minCR: bigint,
  now: bigint,
  window: bigint,
  name: string,
) {
  const [markedAt, grace, active] = p.mark;
  const healthy = p.cr >= minCR;
  // A recovered position cannot be liquidated, so its leftover mark is housekeeping, not the next step.
  if (active && healthy) return "View actions →";
  if (active) {
    const graceEnds = markedAt + grace;
    if (now < graceEnds) return `Grace ${span(graceEnds - now)} · View →`;
    if (now > graceEnds + window) return `Mark ${name} again →`;
    return `Liquidate ${name} →`;
  }
  return healthy ? "View actions →" : `Mark ${name} →`;
}
