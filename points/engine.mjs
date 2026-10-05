// Genesis points: principal x seconds per account, plus a flat credit for liquidators.
//
// PURE: no network, no clock. Give it events and a season window, get points back. The same module
// runs in the CLI and, later, in the terminal, so both always agree.
//
//   borrower points   = sum over time of (that account's principal) x (seconds it was held)
//   liquidator points = sum of (debt repaid in each liquidation) x liquidationCreditSeconds
//
// Principal comes from the vault's Principal(owner, debt) event, emitted whenever a position's
// principal changes, by any path (draw, repay, liquidation, redemption). It carries the NEW TOTAL,
// so the engine never has to know how a repayment split between fees and principal. Stability fees
// are not principal and earn nothing: they are a cost of borrowing, not borrowing.
//
// Flat and linear on purpose (user decision 2026-10-05): splitting a position across wallets earns
// exactly the same, a late entrant earns at the same rate as an early one, and a flash borrow at the
// season's end earns one block's worth. Redeemers earn nothing.

/** @typedef {{kind: "principal", owner: string, debt: bigint, timestamp: number, blockNumber: number, logIndex: number}} PrincipalEvent */
/** @typedef {{kind: "bite", owner: string, liquidator: string, debtRepaid: bigint, timestamp: number, blockNumber: number, logIndex: number}} BiteEvent */

export const WAD = 10n ** 18n;
export const DAY = 86_400n;
export const DEFAULT_LIQUIDATION_CREDIT_SECONDS = 7n * DAY;

/** Chain order: block, then position in the block. */
export function byChainOrder(a, b) {
  return a.blockNumber - b.blockNumber || a.logIndex - b.logIndex;
}

/**
 * @param {Array<PrincipalEvent | BiteEvent>} events  any order; sorted here
 * @param {{seasonStart: number, seasonEnd: number, liquidationCreditSeconds?: bigint}} season
 *   unix seconds; time outside [seasonStart, seasonEnd] earns nothing
 */
export function computePoints(events, season) {
  const start = BigInt(season.seasonStart);
  const end = BigInt(season.seasonEnd);
  if (end < start) throw new Error("season ends before it starts");
  const credit = season.liquidationCreditSeconds ?? DEFAULT_LIQUIDATION_CREDIT_SECONDS;
  const clamp = (t) => (t < start ? start : t > end ? end : t);

  const accounts = new Map(); // owner -> {principal, since, debtSeconds, liquidationSeconds}
  const at = (address) => {
    const key = address.toLowerCase();
    if (!accounts.has(key)) accounts.set(key, { principal: 0n, since: start, debtSeconds: 0n, liquidationSeconds: 0n });
    return accounts.get(key);
  };

  for (const e of [...events].sort(byChainOrder)) {
    const t = BigInt(e.timestamp);
    if (e.kind === "principal") {
      const a = at(e.owner);
      a.debtSeconds += a.principal * (clamp(t) - clamp(a.since));
      a.principal = e.debt;
      a.since = t;
    } else if (e.kind === "bite") {
      if (t >= start && t <= end) at(e.liquidator).liquidationSeconds += e.debtRepaid * credit;
    }
  }

  let total = 0n;
  const rows = [];
  for (const [owner, a] of accounts) {
    const debtSeconds = a.debtSeconds + a.principal * (end - clamp(a.since));
    const points = debtSeconds + a.liquidationSeconds;
    if (points === 0n && a.principal === 0n) continue;
    total += points;
    rows.push({ owner, principal: a.principal, debtSeconds, liquidationSeconds: a.liquidationSeconds, points });
  }
  rows.sort((x, y) => (y.points > x.points ? 1 : y.points < x.points ? -1 : x.owner.localeCompare(y.owner)));
  return { seasonStart: season.seasonStart, seasonEnd: season.seasonEnd, liquidationCreditSeconds: credit, total, accounts: rows };
}

/** Points in display units: imdUSD-days (1 imdUSD of principal held for 1 day = 1 point). */
export function toDisplay(raw) {
  const scale = WAD * DAY;
  const whole = raw / scale;
  const frac = ((raw % scale) * 100n) / scale;
  return `${whole}.${frac.toString().padStart(2, "0")}`;
}

/** An account's share of all points, in basis points. */
export function shareBps(points, total) {
  return total === 0n ? 0 : Number((points * 10_000n) / total);
}
