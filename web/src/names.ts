// The terminal speaks the protocol's own names (docs/NAMING.md): lock, draw, bark, bite, mat, lull…
// A deployment made before that rename exposes the same functions under their old names, so every
// call, read, event and error crosses this table on its way to or from the chain. Users see neither:
// the interface labels actions in plain words.
//
//   "maker"  — every deployment from protocol commit 892a055 on, and mainnet.
//   "legacy" — anything deployed earlier, including Sepolia launch 688.
//
// The deployment file names its interface; the terminal never guesses.

export type Interface = "maker" | "legacy";

/** Maker name → the name a legacy deployment uses. Anything absent is spelled the same in both. */
export const LEGACY_NAMES: Readonly<Record<string, string>> = {
  // actions
  lock: "depositCollateral",
  free: "withdrawCollateral",
  draw: "mintCOMP",
  wipe: "repayCOMP",
  bark: "markUnderwater",
  barkFor: "markUnderwaterFor",
  bite: "liquidate",
  heel: "clearRecoveredMark",
  cash: "redeem",
  earn: "mintFromWork",
  drip: "pokeIndex",
  // parameters and reads
  mat: "minCR",
  lull: "gracePeriod",
  tail: "liquidationWindow",
  gap: "redemptionSpread",
  line: "debtCeiling",
  duty: "stabilityFeeBps",
  skew: "maxDivergenceBps",
  chip: "markerShareBps",
  cut: "protocolBonusShareBps",
  chi: "debtIndex",
  chiOf: "debtIndexOf",
  earnLine: "workCeiling",
  earnMat: "workRatioBps",
  totalEarned: "totalWorkMinted",
  wage: "compPerTaskWad",
  stablecoin: "compToken",
  backingPerUnit: "backingPerComp",
  gem: "imdToken",
  // governance
  pendingGap: "pendingRedemptionSpread",
  pendingEarnMat: "pendingWorkRatio",
  proposeGap: "proposeRedemptionSpread",
  proposeEarnMat: "proposeWorkRatio",
  proposeWage: "proposeCompPerTask",
  // events
  Lock: "CollateralDeposited",
  Free: "CollateralWithdrawn",
  Draw: "COMPMinted",
  Wipe: "COMPRepaid",
  Bark: "UnderwaterMarked",
  Bite: "Liquidated",
  Cash: "Redeemed",
  Heel: "UnderwaterMarkCleared",
  Earn: "WorkMinted",
  // errors that took a parameter's name
  WageTooHigh: "CompPerTaskTooHigh",
  EarnMatTooHigh: "WorkRatioTooHigh",
  GapOutOfRange: "RedemptionSpreadOutOfRange",
  StablecoinIsNotReserve: "CompIsNotReserve",
  // ABI files
  ImdUSD: "CompToken",
};
const MAKER_NAMES: Readonly<Record<string, string>> = Object.fromEntries(
  Object.entries(LEGACY_NAMES).map(([maker, legacy]) => [legacy, maker]),
);

let active: Interface = "maker";
export function setInterface(i: unknown) {
  if (i === undefined) active = "maker";
  else if (i === "maker" || i === "legacy") active = i;
  else
    throw Error(
      `Unknown contract interface "${String(i)}" in the deployment file.`,
    );
}
export const activeInterface = () => active;

/** The name the deployed contract uses for a protocol name. */
export const onChain = (name: string) =>
  active === "legacy" ? (LEGACY_NAMES[name] ?? name) : name;

/** The protocol name for whatever the deployed contract reported (an event or error name). */
export const ours = (name: string) =>
  active === "legacy" ? (MAKER_NAMES[name] ?? name) : name;

/** Struct arguments carry field names too (a governance proposal is a tuple of parameters). */
export function onChainArgs(args: readonly unknown[]): readonly unknown[] {
  if (active !== "legacy") return args;
  return args.map((a) =>
    a && typeof a === "object" && !Array.isArray(a)
      ? Object.fromEntries(Object.entries(a).map(([k, v]) => [onChain(k), v]))
      : a,
  );
}

/**
 * Members of contracts that were replaced before mainnet: the reporter fallback (deleted as a mainnet
 * hole) and the single-agent work oracle (superseded by the swarm-wide one). The terminal calls them
 * only on a legacy deployment, and a test holds this list to exactly the names it may still use.
 */
export const LEGACY_ONLY: readonly string[] = [
  "report",
  "isReporter",
  "round",
  "AGENT_ID",
  "CLAIMANT",
  "attestedTasks",
  "earnedRights",
];
