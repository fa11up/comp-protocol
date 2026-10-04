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
export function payout(
  comp: bigint,
  fee: bigint,
  price: bigint,
  reserve: bigint,
) {
  if (price <= 0n || fee >= 10000n)
    throw Error("A valid, fresh USD price is required.");
  const scale = (10000n - fee) * 10n ** 14n;
  const out = (comp * scale) / price;
  if (!out) throw Error("This amount rounds to zero IMD. Increase the amount.");
  const reserveOut = out < reserve ? out : reserve;
  return {
    out,
    reserveOut,
    positionOut: out - reserveOut,
    debtCancelled:
      reserveOut === out ? 0n : comp - (reserveOut * price) / scale,
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
    RedemptionWorsensBacking:
      "This redemption would reduce backing for remaining COMP. Try again when backing improves.",
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
