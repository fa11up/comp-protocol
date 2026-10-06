import { decodeAbiParameters, formatUnits, zeroAddress, type Hex } from "viem";

// A pending governance change, decoded from Parameters' public `pending` payload into what it would change:
// each value as current → proposed. Pure, so it is unit-tested apart from the page.
//
// The payload's first word is the change kind. The kinds' order is the same on every deployment (the older
// launch-688 contract has the first five, the current one adds four after them), so one table serves both.

export const CHANGE_KINDS = [
  "Economics",
  "Work ratio",
  "Reserve asset",
  "Pay per task",
  "Redemption spread",
  "Oracle budget",
  "Redemption divisor",
  "Operator stream",
  "Work oracle",
] as const;

export type Current = {
  /** Parameters.current(): line, cut, duty, skew, chip (named either way). */
  set?: Record<string, bigint>;
  earnMat?: bigint;
  wage?: bigint;
  gap?: bigint;
  oracleBudget?: bigint;
  redemptionDivisor?: bigint;
  streamPayee?: string;
  streamPerDay?: bigint;
  workOracle?: string;
};

export type Line = { label: string; from: string; to: string; changed: boolean };
export type Pending = { title: string; lines: Line[] };

const bps = (v?: bigint) => (v === undefined ? "—" : `${formatUnits(v, 2)}%`);
const amount = (v: bigint | undefined, unit: string) =>
  v === undefined ? "—" : `${Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: 4 })} ${unit}`;
const short = (a?: string) =>
  !a ? "—" : a.toLowerCase() === zeroAddress ? "none" : `${a.slice(0, 6)}…${a.slice(-4)}`;
const line = (label: string, from: string, to: string): Line => ({ label, from, to, changed: from !== to });

/** The five-value set in a fixed order, whichever field names the deployment uses. */
function five(s?: Record<string, bigint>): (bigint | undefined)[] {
  if (!s) return [undefined, undefined, undefined, undefined, undefined];
  return [
    s.line ?? s.debtCeiling,
    s.cut ?? s.protocolBonusShareBps,
    s.duty ?? s.stabilityFeeBps,
    s.skew ?? s.maxDivergenceBps,
    s.chip ?? s.markerShareBps,
  ];
}

export function describePending(payload: Hex | undefined, current: Current, unit: string): Pending | undefined {
  if (!payload || payload === "0x" || payload.length < 66) return undefined;
  const kind = Number(BigInt(payload.slice(0, 66)));
  const title = CHANGE_KINDS[kind];
  if (!title) return { title: `Unknown change (kind ${kind})`, lines: [] };
  const word = (types: { type: string }[]) => decodeAbiParameters([{ type: "uint8" }, ...types], payload);
  try {
    switch (kind) {
      case 0: {
        const [, next] = decodeAbiParameters(
          [
            { type: "uint8" },
            {
              type: "tuple",
              components: ["a", "b", "c", "d", "e"].map((name) => ({ name, type: "uint256" })),
            },
          ],
          payload,
        ) as [number, { a: bigint; b: bigint; c: bigint; d: bigint; e: bigint }];
        const [line0, cut, duty, skew, chip] = five(current.set);
        return {
          title,
          lines: [
            line("Debt ceiling", amount(line0, unit), amount(next.a, unit)),
            line("Protocol share of liquidation bonus", bps(cut), bps(next.b)),
            line("Stability fee / year", bps(duty), bps(next.c)),
            line("Max divergence", bps(skew), bps(next.d)),
            line("Marker share of liquidation bonus", bps(chip), bps(next.e)),
          ],
        };
      }
      case 1: {
        const [, v] = word([{ type: "uint256" }]) as [number, bigint];
        return { title, lines: [line("Work ratio", bps(current.earnMat), bps(v))] };
      }
      case 2: {
        const [, asset, feed, keep] = word([{ type: "address" }, { type: "address" }, { type: "uint256" }]) as [
          number,
          string,
          string,
          bigint,
        ];
        const delist = feed.toLowerCase() === zeroAddress;
        return {
          title: delist ? "Delist a reserve asset" : "List or reprice a reserve asset",
          lines: [
            line("Asset", "", short(asset)),
            line("USD price feed", "", delist ? "none (delist)" : short(feed)),
            ...(delist ? [] : [line("Value counted", "", bps(keep))]),
          ],
        };
      }
      case 3: {
        const [, v] = word([{ type: "uint256" }]) as [number, bigint];
        return { title, lines: [line("Pay per task", amount(current.wage, unit), amount(v, unit))] };
      }
      case 4: {
        const [, v] = word([{ type: "uint256" }]) as [number, bigint];
        const pts = (x?: bigint) => (x === undefined ? "—" : `${x} ratio points`);
        return { title, lines: [line("Redemption spread", pts(current.gap), pts(v))] };
      }
      case 5: {
        const [, v] = word([{ type: "uint256" }]) as [number, bigint];
        return {
          title,
          lines: [line("Oracle budget", amount(current.oracleBudget, "IMD / day"), amount(v, "IMD / day"))],
        };
      }
      case 6: {
        const [, v] = word([{ type: "uint256" }]) as [number, bigint];
        const d = (x?: bigint) => (x === undefined ? "—" : String(x));
        return { title, lines: [line("Redemption divisor", d(current.redemptionDivisor), d(v))] };
      }
      case 7: {
        const [, payee, perDay] = word([{ type: "address" }, { type: "uint256" }]) as [number, string, bigint];
        return {
          title,
          lines: [
            line("Paid to", short(current.streamPayee), short(payee)),
            line("Per day", amount(current.streamPerDay, `${unit} / day`), amount(perDay, `${unit} / day`)),
          ],
        };
      }
      case 8: {
        const [, next] = word([{ type: "address" }]) as [number, string];
        return { title, lines: [line("Work oracle", short(current.workOracle), short(next))] };
      }
    }
  } catch {
    return { title, lines: [] };
  }
  return { title, lines: [] };
}

/** "Oct 8, 14:03 UTC" */
export function utc(seconds: bigint) {
  const d = new Date(Number(seconds) * 1000);
  const month = d.toLocaleString("en-US", { month: "short", timeZone: "UTC" });
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${month} ${d.getUTCDate()}, ${hh}:${mm} UTC`;
}

/** "6h 59m", "2d 3h" */
export function countdown(seconds: bigint) {
  const m = seconds / 60n;
  if (m < 60n) return `${m}m`;
  const h = m / 60n;
  if (h < 48n) return `${h}h ${m % 60n}m`;
  return `${h / 24n}d ${h % 24n}h`;
}
