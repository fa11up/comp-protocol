// Position discovery and the liquidation economics, computed the way CDPVault computes them.
//
// The arithmetic below is a transcription of `liquidate`, not an estimate. A liquidator that rounds
// differently either leaves money behind or sends a reverting transaction, and both are worse than
// not bidding. Every `mulDiv` here floors, as Solidity's does.
import { BigNumber, Contract } from "ethers";

export const VAULT_ABI = [
  "function positions(address) view returns (uint256 collateral, uint256 debt)",
  "function collateralRatio(address) view returns (uint256)",
  "function liquidationMarks(address) view returns (uint256 markedAt, uint256 grace, bool marked, address marker)",
  "function minCR() view returns (uint256)",
  "function gracePeriod() view returns (uint256)",
  "function liquidationWindow() view returns (uint256)",
  "function markerShareBps() view returns (uint256)",
  "function protocolBonusShareBps() view returns (uint256)",
  "function totalDebt() view returns (uint256)",
  "function imdToken() view returns (address)",
  "function compToken() view returns (address)",
  "function priceFeed() view returns (address)",
  "function markUnderwaterFor(address owner, address beneficiary)",
  "function liquidate(address owner, uint256 debtToRepay)",
  "event CollateralDeposited(address indexed account, uint256 amount)",
  "event COMPMinted(address indexed account, uint256 amount)",
  "event WorkMinted(address indexed account, uint256 amount)",
];

const WAD = BigNumber.from(10).pow(18);
// (100 + LIQUIDATION_BONUS_PERCENT) * 1e16 — the 110% payout scale, as the contract spells it.
export const PAYOUT_SCALE = BigNumber.from(110).mul(BigNumber.from(10).pow(16));

/**
 * The three events that can create an obligation. Read by topic0 rather than by decoded name,
 * because an indexer may label the indexed parameter differently from our own ABI; topic1 is the
 * account either way.
 */
export const OWNER_TOPICS = {
  "0xd7243f6f8212d5188fd054141cf6ea89cfc0d91facb8c3afe2f88a1358480142": "CollateralDeposited",
  "0x83d67b403d80f1ed499e87cfdc3240e20adf1a22dbf41cb2eb6db63008418bc3": "COMPMinted",
  "0x5bd621cd81288032e6cb6b93933f05c6e77d014f8c7aa7843d6c5c0ed5ff60c7": "WorkMinted",
};

/**
 * Owners who have ever held a position, from an indexer rather than from eth_getLogs.
 *
 * WHY NOT THE RPC. Positions live in a mapping with no on-chain enumeration, so events are the only
 * index there is — and public RPCs are an unsound source for them. Measured against this vault on
 * 2026-10-04: a 50,000-block span returned the one real depositor while a 40,669-block span *inside
 * the same range* returned nothing, with no error either time. The node also caps ranges at 50,000
 * (-32701) and is not an archive node, so eth_getCode on a historical block fails outright. An empty
 * array from such a node is indistinguishable from "there are no positions", which for a liquidator
 * means silently doing nothing while a position rots.
 *
 * Blockscout returns the whole decoded history, paginated and deterministic, and is what this
 * repository already mandates for any historical log work.
 */
export async function discoverOwners(indexerBase, address, { fetchImpl = fetch, maxPages = 20 } = {}) {
  const owners = new Map(); // owner -> the events that named it, for the log
  let params = null;
  let pages = 0;
  let total = 0;

  while (pages < maxPages) {
    const url = new URL(`${indexerBase.replace(/\/$/, "")}/api/v2/addresses/${address}/logs`);
    if (params) for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
    const res = await fetchImpl(url, {
      headers: { accept: "application/json", "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" },
    });
    if (!res.ok) throw new Error(`indexer returned ${res.status} for ${url.pathname}`);
    const body = await res.json();
    const items = body.items ?? [];
    total += items.length;
    for (const it of items) {
      const [t0, t1] = it.topics ?? [];
      const name = OWNER_TOPICS[(t0 ?? "").toLowerCase()];
      if (!name || !t1) continue;
      const owner = `0x${t1.slice(-40)}`;
      owners.set(owner, (owners.get(owner) ?? new Set()).add(name));
    }
    params = body.next_page_params;
    pages += 1;
    if (!params) break;
  }

  // An empty history is a real answer only if the indexer answered at all. Zero logs from a contract
  // that must at least have emitted OracleSet in its constructor means the source is wrong.
  if (total === 0) throw new Error("indexer returned no logs at all for this address, which cannot be right: treat as a source failure, not an empty vault");
  return { owners: [...owners.keys()], evidence: owners, logsSeen: total, pages };
}

/** The largest `debtToRepay` the contract will accept: bounded by the debt and by the collateral. */
export function maxRepayable({ collateral, debt }, price) {
  if (price.isZero()) return BigNumber.from(0);
  // collateralSeized = debtToRepay * PAYOUT_SCALE / price must be <= collateral.
  const byCollateral = collateral.mul(price).div(PAYOUT_SCALE);
  return byCollateral.lt(debt) ? byCollateral : debt;
}

/**
 * What a liquidation of `debtToRepay` pays, split exactly as `liquidate` splits it.
 * `weAreMarker` is worth `markerCut` and is the reason to mark a position oneself.
 */
export function payout({ collateral, debt }, price, debtToRepay, { markerBps, protocolBps, weAreMarker }) {
  const seizedBase = debtToRepay.mul(PAYOUT_SCALE).div(price);
  if (seizedBase.gt(collateral)) return null; // InsufficientCollateral
  const principalValue = debtToRepay.mul(WAD).div(price);
  const bonus = seizedBase.sub(principalValue);
  const protocolCut = bonus.mul(protocolBps).div(10_000);
  const markerCut = bonus.mul(markerBps).div(10_000);

  // The dust sweep, folded in AFTER the split so it enlarges neither share. Only when debt survives.
  const remainder = collateral.sub(seizedBase);
  const oneWeiSeizure = PAYOUT_SCALE.div(price);
  const sweeps = !remainder.isZero() && debtToRepay.lt(debt) && remainder.lt(oneWeiSeizure);
  const seized = sweeps ? seizedBase.add(remainder) : seizedBase;

  const toUs = weAreMarker ? seized.sub(protocolCut) : seized.sub(protocolCut).sub(markerCut);
  return { seized, bonus, protocolCut, markerCut, swept: sweeps ? remainder : BigNumber.from(0), toUs, principalValue };
}

/** Where a marked position sits relative to its actionable window. */
export function markWindow(mark, liquidationWindowSeconds, now) {
  if (!mark.marked) return { state: "unmarked" };
  const opens = mark.markedAt.add(mark.grace).toNumber();
  const closes = opens + Number(liquidationWindowSeconds);
  if (now < opens) return { state: "grace", opens, closes, secondsToOpen: opens - now };
  if (now > closes) return { state: "expired", opens, closes };
  return { state: "actionable", opens, closes, secondsLeft: closes - now };
}
