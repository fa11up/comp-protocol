import { useState } from "react";
import {
  WorkChart,
  SupplyChart,
  DivergenceChart,
  Sparkline,
  type ChartData,
} from "./Charts";
import { Ticker } from "./motion";
import { type Runtime } from "./config";
import { type Snapshot, read, feedsReady } from "./state";
import { Action, ActionForm, Row, AddressLink, type Actions } from "./actions";
import {
  amount,
  address,
  age,
  fmt,
  percent,
  ratio,
  message,
  exact,
} from "./math";
const amt = (name: string) => ({ name, kind: "amount" as const });
const addr = (name: string) => ({ name, kind: "address" as const });
const num = (name: string) => ({ name, kind: "uint" as const });
export function Position({
  r,
  s,
  actions,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
}) {
  const [input, setInput] = useState("");
  const v = s?.v || {};
  let n = 0n;
  try {
    n = amount(input);
  } catch {
    /* Validation on action. */
  }
  const needsApproval =
    n > 0n && (v.allowance === undefined || v.allowance < n);
  const t = s?.targets;
  const fresh = feedsReady(s);
  return (
    <>
      <div className="hero-stat">
        <span>Collateral ratio</span>
        <strong>
          <Ticker text={ratio(v.collateralRatio)} />
        </strong>
        <small>
          minCR <Ticker text={ratio(v.minCR)} />
        </small>
      </div>
      <Row label="Collateral">{fmt(v.positions?.[0])} IMD</Row>
      <Row label="Accrued debt">{fmt(v.debtOf)} COMP</Row>
      <Row label="Unpaid stability fee">{fmt(v.stabilityFeeOf)} COMP</Row>
      <Row label="Wallet">
        {fmt(v.imdBalance)} IMD / {fmt(v.compBalance)} COMP
      </Row>
      <div className="section-label">Add collateral</div>
      <label>
        Deposit IMD
        <input
          name="deposit-amount"
          inputMode="decimal"
          value={input}
          onChange={(e) => setInput(e.target.value)}
        />
      </label>
      <Action
        id={needsApproval ? "approve" : "deposit"}
        label={needsApproval ? "Approve IMD" : "Review deposit"}
        actions={actions}
        request={() => {
          const n = amount(input);
          if (n > v.imdBalance) throw Error("Deposit exceeds the IMD balance.");
          if (!t) throw Error("Wait for contract verification.");
          return needsApproval
            ? {
                target: t.imdToken,
                fn: "approve",
                args: [t.ParameterizedVault.address, n],
                summary: `Approve exactly ${exact(n)} IMD for the vault. Deposit is a separate transaction.`,
              }
            : {
                target: t.ParameterizedVault,
                fn: "depositCollateral",
                args: [n],
                summary: `Deposit ${exact(n)} IMD as collateral.`,
              };
        }}
      />
      <details>
        <summary>Borrow, repay & withdraw</summary>
        <ActionForm
          id="borrow"
          label="Review borrow"
          actions={actions}
          target={t?.ParameterizedVault}
          fn="mintCOMP"
          fields={[amt("Borrow COMP")]}
          summary="Add COMP debt to your position."
          disabled={!fresh}
          reason="Fresh, agreeing price feeds are required."
        />
        <ActionForm
          id="repay"
          label="Review repayment"
          actions={actions}
          target={t?.ParameterizedVault}
          fn="repayCOMP"
          fields={[amt("Repay COMP")]}
          summary="Burn COMP to repay fees first, then principal. No approval required."
        />
        <ActionForm
          id="withdraw"
          label="Review withdrawal"
          actions={actions}
          target={t?.ParameterizedVault}
          fn="withdrawCollateral"
          fields={[amt("Withdraw IMD")]}
          summary="Remove collateral if the remaining position meets minCR."
          disabled={!fresh && v.debtOf !== 0n}
          reason="An indebted position needs fresh feeds to withdraw."
        />
      </details>
      <details>
        <summary>Testnet collateral faucet</summary>
        <ActionForm
          id="faucet"
          label="Review mint IMD"
          actions={actions}
          target={t?.imdToken}
          fn="mint"
          fields={[amt("Test IMD")]}
          mapArgs={(a) => [actions.account, ...a]}
          summary="Mint test IMD to this wallet. This deployment uses MockIMD."
          disabled={
            actions.account?.toLowerCase() !== v.imdDeployer?.toLowerCase()
          }
          reason="Only the collateral faucet operator can mint test IMD."
        />
      </details>
      <p className="micro">
        COMP debt is denominated in USD. IMD / USD:{" "}
        {s?.feeds.USD && !s.feeds.USD.stale
          ? `$${fmt(s.feeds.USD.value)}`
          : "unavailable"}
        . No market price for COMP is supplied.
      </p>
      <AddressLink
        value={t?.compToken.address}
        explorer={r.config.network.explorer}
        label="COMP"
      />
    </>
  );
}
export function Work({
  r,
  s,
  actions,
  now,
  charts,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
  now: bigint;
  charts: ChartData;
}) {
  const w = s?.work;
  const v = s?.v || {};
  const attested = w?.mode === "attested";
  const faucet = w?.mode === "faucet";
  const remaining = attested
    ? w.earnedRights > w.consumedRights
      ? BigInt(w.earnedRights) - BigInt(w.consumedRights)
      : 0n
    : undefined;
  return (
    <>
      <WorkChart s={s} />
      <div className="hero-stat">
        <span>Attested cumulative tasks</span>
        <strong>
          <Ticker
            text={attested ? w.attestedTasks.toLocaleString("en-US") : "—"}
          />
        </strong>
        <small>
          {attested
            ? `${w.isStale ? "Stale" : "Fresh"} · ${age(w.latestValue?.[1], now)}`
            : faucet
              ? "Faucet mode"
              : "Awaiting linked oracle"}
        </small>
      </div>
      {attested && (
        <Sparkline
          feed={charts.feeds.oracle}
          live={
            w
              ? {
                  value: w.latestValue[0],
                  updated: w.latestValue[1],
                  stale: w.isStale,
                  maxAge: w.maxAge,
                }
              : undefined
          }
          now={now}
          label="Work tally"
        />
      )}
      {faucet && (
        <p className="notice">
          This vault uses MockWorkOracle. No attested task count or publication
          age is available; credits are granted by the testnet operator.
        </p>
      )}
      {attested && (
        <>
          <Row label="Published tally">
            {w.latestValue[0].toLocaleString("en-US")} tasks
          </Row>
          <Row label="Credited high-water mark">
            {w.creditedTasks.toLocaleString("en-US")} tasks
          </Row>
          <Row label="Publication age">{age(w.latestValue[1], now)}</Row>
          <Row label="Freshness limit">{w.maxAge.toString()}s</Row>
        </>
      )}
      <Row label="COMP per task">
        {fmt(attested ? w.compPerTaskWad : v.compPerTaskWad)}
      </Row>
      <Row label="Rights earned">
        {fmt(attested ? w.earnedRights : undefined)} COMP
      </Row>
      <Row label="Rights consumed">
        {fmt(attested ? w.consumedRights : undefined)} COMP
      </Row>
      <Row label="Rights remaining">{fmt(remaining)} COMP</Row>
      <Row label="This wallet can claim">{fmt(v.rights)} COMP</Row>
      <p className="micro">
        The count is the swarm’s published tally, attested by a panel. It is not
        an on-chain proof that the work happened. The Sepolia reporter fallback
        also exists.
      </p>
      {attested && (
        <>
          <p className="micro">
            Agent {w.AGENT_ID.toString()}. Rights belong only to the claimant. A
            stale tally adds no new tasks; credited tasks are retained. Lowering
            COMP per task can reduce unconsumed rights.
          </p>
          <AddressLink
            value={w.CLAIMANT}
            explorer={r.config.network.explorer}
            label="Claimant"
          />
        </>
      )}
      <Row label="Work minted / ceiling">
        {fmt(v.totalWorkMinted)} / {fmt(v.workCeiling)} COMP
      </Row>
      <ActionForm
        id="mint-work"
        label="Review work mint"
        actions={actions}
        target={s?.targets.ParameterizedVault}
        fn="mintFromWork"
        fields={[amt("Mint earned COMP")]}
        summary="Consume work rights permanently. Redemption does not restore them."
        disabled={!feedsReady(s) || !v.rights || w?.mode === "unknown"}
        reason="Fresh feeds, available rights and backing headroom are required."
      />
      {faucet && (
        <details>
          <summary>Operator / grant test rights</summary>
          <ActionForm
            id="grant-rights"
            label="Review grant rights"
            actions={actions}
            target={s?.targets.oracle}
            fn="grantRights"
            fields={[addr("Recipient"), amt("Rights in COMP")]}
            summary="Grant test credits; this does not attest work."
            disabled={
              actions.account?.toLowerCase() !== w.deployer?.toLowerCase()
            }
            reason="Only the faucet operator can grant rights."
          />
        </details>
      )}
      <AddressLink
        value={s?.targets.oracle.address}
        explorer={r.config.network.explorer}
        label="Work oracle"
      />
    </>
  );
}
export function Oracle({
  r,
  s,
  actions,
  now,
  charts,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
  now: bigint;
  charts: ChartData;
}) {
  const [selected, setSelected] = useState("PriceFeed");
  const [reporter, setReporter] = useState(false);
  const [error, setError] = useState("");
  const f = s?.feeds || {};
  const primary = f.PriceFeed?.value,
    spot = f.SpotFeed?.value;
  const divergence =
    primary && spot !== undefined
      ? ((primary > spot ? primary - spot : spot - primary) * 10000n) / primary
      : undefined;
  return (
    <>
      <DivergenceChart s={s} />
      <p className="micro">
        Primary and spot quote IMD in ETH. USD price combines the primary feed
        with Chainlink ETH / USD.
      </p>
      {["PriceFeed", "NhiFeed", "SpotFeed", "USD"].map((n) => (
        <div className="feed" key={n}>
          <Row
            label={
              n === "USD"
                ? "IMD / USD"
                : n === "NhiFeed"
                  ? "Network health"
                  : n === "PriceFeed"
                    ? "IMD / ETH primary"
                    : "IMD / ETH spot"
            }
          >
            {fmt(f[n]?.value, 18, 8)}
          </Row>
          <p className="micro">
            {!f[n]
              ? "Unavailable"
              : `${f[n].stale ? "Stale" : "Fresh"} · ${age(f[n].updated, now)} · limit ${f[n].maxAge}s`}
          </p>
          {n !== "USD" && (
            <Sparkline feed={charts.feeds[n]} live={f[n]} now={now} label={n} />
          )}
          {n === "USD" && (
            <p className="micro">
              Derived on chain; no AttestationAccepted events.
            </p>
          )}
        </div>
      ))}
      <Row label="Divergence / allowed">
        {percent(divergence)} / {percent(s?.v.maxDivergenceBps)}
      </Row>
      <p className="notice">
        {feedsReady(s)
          ? "Price-dependent actions are available."
          : "Price-dependent actions are paused until every required feed is fresh and primary agrees with spot."}
      </p>
      <details>
        <summary>Reporter fallback</summary>
        <label>
          Feed
          <select
            value={selected}
            onChange={(e) => {
              setSelected(e.target.value);
              setReporter(false);
            }}
          >
            {["PriceFeed", "NhiFeed", "SpotFeed"].map((n) => (
              <option key={n}>{n}</option>
            ))}
          </select>
        </label>
        <button
          type="button"
          disabled={!actions.account || !s}
          onClick={async () => {
            setError("");
            try {
              setReporter(
                await read(r, s!.targets[selected], "isReporter", [
                  actions.account,
                ]),
              );
            } catch (e) {
              setError(message(e));
            }
          }}
        >
          Check reporter permission
        </button>
        <p className="micro" role="status">
          {error ||
            (reporter
              ? "Reporter permission confirmed."
              : "Reporter permission has not been confirmed.")}
        </p>
        <ActionForm
          id="report"
          label="Review feed report"
          actions={actions}
          target={s?.targets[selected]}
          fn="report"
          fields={[amt("Value (18-decimal units)")]}
          summary="Publish through the configured testnet reporter fallback."
          disabled={!reporter}
          reason="Only a configured reporter can report. Simulation rechecks permission."
        />
      </details>
      <details>
        <summary>Feed contracts</summary>
        {r.config.contracts
          .filter((c) => c.name.includes("Feed"))
          .map((c) => (
            <AddressLink
              key={c.name}
              value={c.address}
              explorer={r.config.network.explorer}
              label={c.name}
            />
          ))}
      </details>
    </>
  );
}
export function Keeper({
  r,
  s,
  actions,
  now,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
  now: bigint;
}) {
  const [owner, setOwner] = useState("");
  const [position, setPosition] = useState<any>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  return (
    <>
      <p className="micro">
        Inspect a borrower, record an unhealthy position, then liquidate inside
        its grace and execution window.
      </p>
      <form
        onSubmit={async (e) => {
          e.preventDefault();
          setLoading(true);
          setError("");
          setPosition(undefined);
          try {
            if (!s) throw Error("Wait for state to load.");
            const a = address(owner);
            const [cr, debt, mark, badDebt] = await Promise.all(
              [
                "collateralRatio",
                "debtOf",
                "liquidationMarks",
                "badDebtOf",
              ].map((fn) => read(r, s.targets.ParameterizedVault, fn, [a])),
            );
            setPosition({ cr, debt, mark, badDebt, owner: a });
          } catch (e) {
            setError(message(e));
          } finally {
            setLoading(false);
          }
        }}
      >
        <label>
          Borrower address
          <input
            required
            value={owner}
            onChange={(e) => {
              setOwner(e.target.value);
              setPosition(undefined);
            }}
            spellCheck={false}
            placeholder="0x…"
          />
        </label>
        <button type="submit" disabled={!s || loading}>
          {loading ? "Inspecting…" : "Inspect position"}
        </button>
      </form>
      <p role="status" className="micro">
        {error}
      </p>
      {position && (
        <>
          <p className="micro keeper-owner">
            Acting on borrower: {position.owner}
          </p>
          <Row label="Collateral ratio">{ratio(position.cr)}</Row>
          <Row label="Accrued debt">{fmt(position.debt)} COMP</Row>
          <Row label="Bad debt estimate">{fmt(position.badDebt)} COMP</Row>
          <Row label="Mark">{position.mark[2] ? "Active" : "None"}</Row>
          {position.mark[2] && (
            <>
              <Row label="Grace remaining">
                {(position.mark[0] + position.mark[1] > now
                  ? position.mark[0] + position.mark[1] - now
                  : 0n
                ).toString()}
                s
              </Row>
              <Row label="Mark expires">
                {new Date(
                  Number(
                    position.mark[0] +
                      position.mark[1] +
                      (s?.v.liquidationWindow || 0n),
                  ) * 1000,
                ).toISOString()}
              </Row>
            </>
          )}
        </>
      )}
      <div className="button-row">
        <Action
          id="mark"
          label="Review mark"
          actions={actions}
          disabled={!feedsReady(s) || !position || position.cr >= s?.v.minCR}
          reason="Inspect an unhealthy borrower with fresh feeds."
          request={() => ({
            target: s!.targets.ParameterizedVault,
            fn: "markUnderwater",
            args: [address(owner)],
            summary: `Mark ${address(owner)} as underwater. The on-chain grace snapshot governs liquidation.`,
          })}
        />
        <Action
          id="clear-mark"
          label="Review clear mark"
          actions={actions}
          disabled={!position?.mark[2]}
          reason="Inspect a marked position."
          request={() => ({
            target: s!.targets.ParameterizedVault,
            fn: "clearRecoveredMark",
            args: [address(owner)],
            summary: `Clear the mark only if ${address(owner)} has recovered.`,
          })}
        />
      </div>
      <ActionForm
        id="liquidate"
        label="Review liquidation"
        actions={actions}
        target={s?.targets.ParameterizedVault}
        fn="liquidate"
        fields={[amt("Repay borrower COMP")]}
        mapArgs={(a) => [address(owner), ...a]}
        summary="Burn your COMP to cancel borrower debt and receive IMD, including the liquidation bonus after protocol and marker shares."
        disabled={
          !feedsReady(s) ||
          !position?.mark[2] ||
          now < position.mark[0] + position.mark[1] ||
          now >
            position.mark[0] + position.mark[1] + (s?.v.liquidationWindow ?? 0n)
        }
        reason="An active mark, elapsed grace, open execution window and fresh feeds are required."
      />
      <details>
        <summary>Mark for another beneficiary</summary>
        <ActionForm
          id="mark-for"
          label="Review beneficiary mark"
          actions={actions}
          target={s?.targets.ParameterizedVault}
          fn="markUnderwaterFor"
          fields={[addr("Marker beneficiary")]}
          mapArgs={(a) => [address(owner), ...a]}
          summary="Record the marker reward beneficiary for this borrower."
          disabled={!feedsReady(s) || !position}
          reason="Inspect a borrower and wait for fresh feeds."
        />
      </details>
    </>
  );
}
export function Backing({
  r,
  s,
  actions,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
}) {
  const v = s?.v || {};
  return (
    <>
      <SupplyChart s={s} />
      <Row label="Reserve value">${fmt(v.reserveValue)}</Row>
      <Row label="Collateral-backed debt">{fmt(v.backedDebt)} COMP</Row>
      <Row label="Secured collateral">{fmt(v.securedCollateral)} IMD</Row>
      <Row label="Total principal debt">{fmt(v.totalDebt)} COMP</Row>
      <Row label="Recorded bad debt">{fmt(v.totalBadDebt)} COMP</Row>
      <Row label="Work ratio">{percent(v.workRatioBps)}</Row>
      <Row label="Work ceiling">{fmt(v.workCeiling)} COMP</Row>
      <p className="micro">
        Work ceiling = reserve value + backed debt × work ratio. A repayment or
        redemption can lower it and pause new work issuance.
      </p>
      <Row label="Registered reserve assets">
        {v.reserveAssets?.length ?? "—"}
      </Row>
      {v.reserveAssets?.map((a: any) => (
        <AddressLink
          key={a}
          value={a}
          explorer={r.config.network.explorer}
          label="Reserve asset"
        />
      ))}
      <details>
        <summary>Treasury actions</summary>
        <ActionForm
          id="sync"
          label="Review reserve sync"
          actions={actions}
          target={s?.targets.treasury}
          fn="sync"
          fields={[addr("Token to sync")]}
          summary="Record a token arrival in Treasury accounting."
        />
        <ActionForm
          id="treasury-withdraw"
          label="Review reserve withdrawal"
          actions={actions}
          target={s?.targets.treasury}
          fn="withdraw"
          fields={[
            addr("Token"),
            addr("Destination"),
            num("Amount in token base units"),
          ]}
          summary="Withdraw reserve tokens to the specified destination. This reduces backing."
          disabled={
            actions.account?.toLowerCase() !== v.withdrawer?.toLowerCase()
          }
          reason="Only the Treasury withdrawer can withdraw."
        />
      </details>
      <AddressLink
        value={s?.targets.treasury.address}
        explorer={r.config.network.explorer}
        label="Treasury"
      />
    </>
  );
}
export function Governance({
  r,
  s,
  actions,
  now,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
  now: bigint;
}) {
  const v = s?.v || {};
  const t = s?.targets.parameters;
  const isGov =
    !!actions.account &&
    actions.account.toLowerCase() === v.governor?.toLowerCase();
  const pending = v.pendingChange;
  const eta = pending?.[1] as bigint | undefined;
  const common = {
    actions,
    target: t,
    disabled: !isGov,
    reason: "Only the governor can propose or cancel changes.",
  };
  return (
    <>
      <Row label="Stability fee / year">{percent(v.stabilityFeeBps)}</Row>
      <Row label="Debt ceiling">{fmt(v.debtCeiling)} COMP</Row>
      <Row label="Governance delay">
        {v.TIMELOCK === undefined ? "—" : `${v.TIMELOCK / 3600n} hours`}
      </Row>
      <Row label="Pending change">
        {pending
          ? ([
              "None",
              "Economics",
              "Work ratio",
              "Reserve asset",
              "COMP per task",
              "Redemption spread",
            ][Number(pending[0])] ?? String(pending[0]))
          : "—"}
      </Row>
      <Row label="Execution">
        {eta
          ? now >= eta
            ? "Ready to apply"
            : `${eta - now}s remaining`
          : "No pending change"}
      </Row>
      {eta && eta > 0n ? (
        <details>
          <summary>Pending payload</summary>
          <pre>
            {JSON.stringify(
              {
                economics: v.pendingSet,
                workRatio: v.pendingWorkRatio,
                reserveAsset: v.pendingReserveAsset,
                redemptionSpread: v.pendingRedemptionSpread,
                raw: v.pending,
              },
              (_, x) => (typeof x === "bigint" ? x.toString() : x),
              2,
            )}
          </pre>
        </details>
      ) : null}
      <ActionForm
        id="apply"
        label="Review apply pending"
        actions={actions}
        target={t}
        fn="applyPending"
        summary="Apply the visible pending change after the timelock. Anyone may execute."
        disabled={!eta || now < eta}
        reason="A pending proposal must finish its timelock."
      />
      <details>
        <summary>Governor / propose a change</summary>
        <ActionForm
          {...common}
          id="spread"
          label="Review spread proposal"
          fn="proposeRedemptionSpread"
          fields={[num("Spread (25–100 ratio points)")]}
          summary="Set the spread above minCR after the governance delay."
        />
        <ActionForm
          {...common}
          id="work-ratio"
          label="Review work ratio proposal"
          fn="proposeWorkRatio"
          fields={[num("Work ratio (0–2500 bps)")]}
          summary="Change the backing fraction available to work issuance."
        />
        <ActionForm
          {...common}
          id="per-task"
          label="Review COMP per task"
          fn="proposeCompPerTask"
          fields={[{ name: "COMP per task (max 1)", kind: "amount0" }]}
          summary="Change the COMP earned per task after the delay."
        />
        <ActionForm
          {...common}
          id="economics"
          label="Review economics proposal"
          fn="propose"
          fields={[
            { name: "Debt ceiling COMP", kind: "amount0" },
            num("Protocol bonus share bps"),
            num("Annual stability fee bps"),
            num("Max divergence bps"),
            num("Marker share bps"),
          ]}
          mapArgs={(a) => [
            {
              debtCeiling: a[0],
              protocolBonusShareBps: a[1],
              stabilityFeeBps: a[2],
              maxDivergenceBps: a[3],
              markerShareBps: a[4],
            },
          ]}
          summary="Replace all five economic parameters. Simulation enforces their bounds."
        />
        <ActionForm
          {...common}
          id="reserve-proposal"
          label="Review reserve proposal"
          fn="proposeReserveAsset"
          fields={[
            addr("Reserve token"),
            addr("USD price feed (zero to delist)"),
            num("Retained value (0–10000 bps)"),
          ]}
          summary="List, reprice or delist a reserve asset after the delay. COMP cannot be a reserve."
        />
        <ActionForm
          {...common}
          id="cancel"
          label="Review cancel proposal"
          fn="cancel"
          summary="Cancel the currently pending proposal."
        />
      </details>
      <details>
        <summary>Index checkpoint</summary>
        <ActionForm
          id="checkpoint"
          label="Review checkpoint"
          actions={actions}
          target={s?.targets.ParameterizedVault}
          fn="pokeIndex"
          summary="Checkpoint the accrued stability fee index."
        />
      </details>
      <AddressLink
        value={v.governor}
        explorer={r.config.network.explorer}
        label="Governor"
      />
      <AddressLink
        value={t?.address}
        explorer={r.config.network.explorer}
        label="Parameters"
      />
    </>
  );
}
