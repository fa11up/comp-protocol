import { useEffect, useRef, useState } from "react";
import { isAddress } from "viem";
import { WorkChart, SupplyChart, Sparkline, type ChartData } from "./Charts";
import { Ticker } from "./motion";
import { type Runtime } from "./config";
import { type Snapshot, type Question, read, feedsReady } from "./state";
import {
  Action,
  ActionForm,
  Row,
  AddressLink,
  Choice,
  Col,
  Info,
  Select,
  type Actions,
} from "./actions";
import type { Failure } from "./explain";
import {
  amount,
  address,
  age,
  fmt,
  percent,
  ratio,
  message,
  exact,
  WAD,
  liquidationPrice,
  cushion,
  maxDebt,
  requiredCollateral,
  nextStep,
} from "./math";
import { useEns, ensName, displayName } from "./ens";
const amt = (name: string) => ({ name, kind: "amount" as const });
const addr = (name: string) => ({ name, kind: "address" as const });
const num = (name: string) => ({ name, kind: "uint" as const });
// A debt ceiling set to the uint256 range is "none", not a 78-digit number.
const ceilingText = (v?: bigint) =>
  v === undefined ? "—" : v >= 10n ** 36n ? "No ceiling" : `${fmt(v)} COMP`;

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
  const [act, setAct] = useState("deposit");
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
  const price = s?.feeds.USD?.value;
  const collateral = v.positions?.[0] as bigint | undefined;
  const debt = v.debtOf as bigint | undefined;
  const sized =
    collateral !== undefined && debt !== undefined && !!v.minCR && !!price;
  const liq = sized ? liquidationPrice(collateral, debt, v.minCR) : undefined;
  const most = sized ? maxDebt(collateral, v.minCR, price) : undefined;
  const keep = sized ? requiredCollateral(debt, v.minCR, price) : undefined;
  return (
    <>
      <Col label="Your position">
        <div className="hero-stat">
          <span>Collateral ratio</span>
          <strong>
            <Ticker text={ratio(v.collateralRatio)} />
          </strong>
          <small>
            minCR <Ticker text={ratio(v.minCR)} />
          </small>
        </div>
        <Row label="Collateral">{fmt(collateral)} IMD</Row>
        <Row label="Accrued debt">{fmt(debt)} COMP</Row>
        <Row label="Unpaid stability fee">{fmt(v.stabilityFeeOf)} COMP</Row>
        <Row label="Liquidation price">
          {!sized ? "—" : liq === undefined ? "No debt" : `$${fmt(liq)} / IMD`}
        </Row>
        {liq !== undefined && (
          <p className="micro">
            IMD is ${fmt(price)} now, {cushion(price, liq)}.
          </p>
        )}
        <Row label="Can still borrow">
          {most === undefined || debt === undefined
            ? "—"
            : `${fmt(most > debt ? most - debt : 0n)} COMP`}
        </Row>
        <Row label="Can withdraw">
          {keep === undefined || collateral === undefined
            ? "—"
            : `${fmt(collateral > keep ? collateral - keep : 0n)} IMD`}
        </Row>
        <Row label="Wallet">
          {fmt(v.imdBalance)} IMD / {fmt(v.compBalance)} COMP
        </Row>
        <p className="micro">
          COMP debt is USD-denominated. IMD / USD:{" "}
          {s?.feeds.USD && !s.feeds.USD.stale
            ? `$${fmt(s.feeds.USD.value)}`
            : "unavailable"}
          .
        </p>
      </Col>
      <Col label="Act">
        <Choice
          label="Position action"
          value={act}
          onChange={setAct}
          options={[
            ["deposit", "Deposit"],
            ["borrow", "Borrow"],
            ["repay", "Repay"],
            ["withdraw", "Withdraw"],
            ["faucet", "Test IMD"],
          ]}
        />
        {act === "deposit" && (
          <>
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
                if (n > v.imdBalance)
                  throw Error("Deposit exceeds the IMD balance.");
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
            <p className="micro">
              Approval and deposit are two transactions. The approval is for
              exactly this amount.
            </p>
          </>
        )}
        {act === "borrow" && (
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
        )}
        {act === "repay" && (
          <ActionForm
            id="repay"
            label="Review repayment"
            actions={actions}
            target={t?.ParameterizedVault}
            fn="repayCOMP"
            fields={[amt("Repay COMP")]}
            summary="Burn COMP to repay fees first, then principal. No approval required."
          />
        )}
        {act === "withdraw" && (
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
        )}
        {act === "faucet" && (
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
        )}
        <AddressLink
          value={t?.compToken.address}
          explorer={r.config.network.explorer}
          label="COMP"
        />
      </Col>
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
  const [act, setAct] = useState("mint");
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
      <Col label="Swarm tally">
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
            This vault uses MockWorkOracle. Credits are granted by the testnet
            operator; no task count is attested.
          </p>
        )}
        {attested && (
          <>
            <Row label="Credited high-water mark">
              {w.creditedTasks.toLocaleString("en-US")} tasks
            </Row>
            <Row label="Freshness limit">{w.maxAge.toString()}s</Row>
            <Row label="Agent">{w.AGENT_ID.toString()}</Row>
            <AddressLink
              value={w.CLAIMANT}
              explorer={r.config.network.explorer}
              label="Claimant"
            />
          </>
        )}
        <p className="micro">
          The count is the swarm’s published tally, attested by a panel. It is
          not an on-chain proof that the work happened.
        </p>
      </Col>
      <Col label="Rights">
        <WorkChart s={s} />
        <Row label="COMP per task">
          {fmt(attested ? w.compPerTaskWad : v.compPerTaskWad)}
        </Row>
        <Row label="Rights earned / consumed">
          {fmt(attested ? w.earnedRights : undefined)} /{" "}
          {fmt(attested ? w.consumedRights : undefined)}
        </Row>
        <Row label="Rights remaining">{fmt(remaining)} COMP</Row>
        <Row label="This wallet can claim">{fmt(v.rights)} COMP</Row>
        {faucet && (
          <Choice
            label="Work action"
            value={act}
            onChange={setAct}
            options={[
              ["mint", "Mint"],
              ["grant", "Grant rights"],
            ]}
          />
        )}
        {(!faucet || act === "mint") && (
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
        )}
        {faucet && act === "grant" && (
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
        )}
      </Col>
    </>
  );
}
const feedNames: Record<string, [string, string]> = {
  PriceFeed: [
    "IMD / ETH primary",
    "Median IMD price in ETH over the attested window. Liquidation, borrowing and redemption read it, through the USD feed.",
  ],
  NhiFeed: [
    "Network health",
    "Swarm health index, 0 to 1. It sets minCR (200% at or below 0.60, 150% at or above 0.85) and the liquidation grace period.",
  ],
  SpotFeed: [
    "IMD / ETH spot",
    "Price at the last block of its window. It only guards the primary: price actions pause when the two disagree beyond the allowed divergence.",
  ],
  USD: [
    "IMD / USD",
    "Primary feed × Chainlink ETH / USD, computed on chain. It emits no attestations of its own and is stale when either leg is.",
  ],
};
export function Oracle({
  r,
  s,
  now,
  charts,
}: {
  r: Runtime;
  s?: Snapshot;
  now: bigint;
  charts: ChartData;
}) {
  const [open, setOpen] = useState<string>();
  const f = s?.feeds || {};
  const primary = f.PriceFeed?.value,
    spot = f.SpotFeed?.value;
  const divergence =
    primary && spot !== undefined
      ? ((primary > spot ? primary - spot : spot - primary) * 10000n) / primary
      : undefined;
  const allowed = s?.v.maxDivergenceBps as bigint | undefined;
  const stale = !!(f.PriceFeed?.stale || f.SpotFeed?.stale);
  const contract = (n: string) =>
    r.config.contracts.find((c) => c.name === n)?.address ??
    (n === "USD" ? s?.targets.usdPriceFeed.address : undefined);
  return (
    <>
      <Row
        label="Divergence / allowed"
        info="Distance between the primary and spot IMD / ETH feeds, against the vault's maxDivergenceBps. Beyond it, borrowing, marking, liquidation and redemption pause."
      >
        {percent(divergence)} / {percent(allowed)}
      </Row>
      <Row label="Headroom">
        {divergence === undefined || allowed === undefined ? (
          "—"
        ) : stale ? (
          <span className="danger-text">Stale</span>
        ) : divergence > allowed ? (
          <span className="danger-text">Breached</span>
        ) : (
          percent(allowed - divergence)
        )}
      </Row>
      <Row
        label="Price actions"
        info="Open only while the primary, spot, network health and USD feeds are all fresh and primary agrees with spot."
      >
        {!s ? (
          "—"
        ) : feedsReady(s) ? (
          <span className="healthy-text">Open</span>
        ) : (
          <span className="danger-text">Paused</span>
        )}
      </Row>
      <div className="section-label">Feeds</div>
      <ul className="feed-list">
        {["NhiFeed", "PriceFeed", "SpotFeed", "USD"].map((n) => {
          const expanded = open === n;
          return (
            <li key={n} className={expanded ? "is-open" : undefined}>
              <button
                type="button"
                className="feed-toggle"
                aria-expanded={expanded}
                aria-controls={`feed-${n}`}
                onClick={() => setOpen(expanded ? undefined : n)}
              >
                <span className="feed-name">
                  <span
                    className={`feed-state ${!f[n] ? "" : f[n].stale ? "is-stale" : "is-fresh"}`}
                    aria-hidden="true"
                  />
                  {feedNames[n][0]}
                </span>
                <b>{fmt(f[n]?.value, 18, 8)}</b>
                <span className="feed-caret" aria-hidden="true">
                  {expanded ? "−" : "+"}
                </span>
              </button>
              {expanded && (
                <div className="feed-detail" id={`feed-${n}`}>
                  <div>
                    <Row label="About" info={feedNames[n][1]}>
                      {n === "USD" ? "Derived" : "Attested"}
                    </Row>
                    <Row label="Updated">
                      {!f[n] ? (
                        "—"
                      ) : (
                        <span
                          className={f[n].stale ? "danger-text" : undefined}
                        >
                          {f[n].stale ? "Stale · " : ""}
                          {age(f[n].updated, now)}
                        </span>
                      )}
                    </Row>
                    <Row label="Max age">{f[n] ? `${f[n].maxAge}s` : "—"}</Row>
                    {n !== "USD" && <QuestionState q={s?.questions[n]} />}
                    <AddressLink
                      value={contract(n)}
                      explorer={r.config.network.explorer}
                      label={n === "USD" ? "UsdPriceFeed" : n}
                    />
                  </div>
                  {n !== "USD" && (
                    <Sparkline
                      feed={charts.feeds[n]}
                      live={f[n]}
                      now={now}
                      label={n}
                    />
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </>
  );
}
export function Keeper({
  r,
  s,
  actions,
  now,
  target,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
  now: bigint;
  /** A borrower opened from the loan book; seq changes on every open, even of the same owner. */
  target?: { owner: string; seq: number };
}) {
  const [owner, setOwner] = useState("");
  const [position, setPosition] = useState<any>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState("inspect");
  useEns([position?.owner]);
  const requested = useRef("");
  const inspect = async (who: string) => {
    requested.current = who.trim().toLowerCase();
    setLoading(true);
    setError("");
    setPosition(undefined);
    try {
      if (!s) throw Error("Wait for state to load.");
      const a = address(who);
      const [cr, debt, mark, badDebt, held] = await Promise.all(
        [
          "collateralRatio",
          "debtOf",
          "liquidationMarks",
          "badDebtOf",
          "positions",
        ].map((fn) => read(r, s.targets.ParameterizedVault, fn, [a])),
      );
      if (requested.current !== a.toLowerCase()) return;
      setPosition({ cr, debt, mark, badDebt, owner: a, collateral: held[0] });
    } catch (e) {
      setError(message(e));
    } finally {
      setLoading(false);
    }
  };
  // A pasted or typed address is inspected as soon as it is complete, as a loan-book click is.
  useEffect(() => {
    const a = owner.trim();
    if (!isAddress(a) || requested.current === a.toLowerCase()) return;
    const t = setTimeout(() => void inspect(a), 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [owner]);
  const inspected =
    !!position && position.owner.toLowerCase() === owner.trim().toLowerCase();
  useEffect(() => {
    if (!target) return;
    setOwner(target.owner);
    setMode("inspect");
    void inspect(target.owner);
    // Only a new open re-inspects; a snapshot refresh must not reset what the keeper typed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target?.seq]);
  const borrower = (f: Failure) => {
    if (!position || !s) return undefined;
    const graceEnds = position.mark[0] + position.mark[1];
    if (f.name === "HealthyPosition")
      return `${position.owner} sits at ${ratio(position.cr)}, at or above minCR ${ratio(s.v.minCR)}. It cannot be marked or liquidated until it falls below.`;
    if (f.name === "GracePeriodNotElapsed")
      return `The grace period ends in ${graceEnds > now ? graceEnds - now : 0n}s, at ${new Date(Number(graceEnds) * 1000).toISOString()}.`;
    if (f.name === "MarkExpired")
      return `The mark's execution window closed at ${new Date(Number(graceEnds + (s.v.liquidationWindow ?? 0n)) * 1000).toISOString()}. Mark the position again.`;
    if (f.name === "ExcessRepayment")
      return `${position.owner} owes ${fmt(position.debt)} COMP including fees; repay no more than that.`;
    return undefined;
  };
  const liq =
    position && s?.v.minCR
      ? liquidationPrice(position.collateral, position.debt, s.v.minCR)
      : undefined;
  const summary = position && (
    <>
      <p className="keeper-owner">
        <b className={ensName(position.owner) ? "ens-name" : undefined}>
          {displayName(position.owner)}
        </b>{" "}
        · {position.owner}
      </p>
      <div className="row-grid">
        <Row label="Collateral ratio">{ratio(position.cr)}</Row>
        <Row label="Collateral">{fmt(position.collateral)} IMD</Row>
        <Row label="Accrued debt">{fmt(position.debt)} COMP</Row>
        <Row label="Bad debt estimate">{fmt(position.badDebt)} COMP</Row>
        <Row label="Liquidation price">{liq ? `$${fmt(liq)} / IMD` : "—"}</Row>
        <Row label="Cushion">
          {liq ? cushion(s?.feeds.USD?.value, liq) : "—"}
        </Row>
        <Row
          label="Mark"
          info="A mark clears itself when the borrower next deposits, repays, borrows or withdraws. A recovery caused only by the price leaves it in place until anyone clears it; it cannot be used to liquidate a healthy position."
        >
          {position.mark[2] && position.cr >= (s?.v.minCR ?? 0n)
            ? "Recovered · clearable"
            : position.mark[2]
              ? now < position.mark[0] + position.mark[1]
                ? `Grace ${(position.mark[0] + position.mark[1] - now).toString()}s`
                : "Active · liquidatable"
              : "None"}
        </Row>
      </div>
    </>
  );
  // Inspect and Act each take the whole desk; the mode switch is the only thing they share.
  return (
    <div className="desk-span keeper">
      <Choice
        label="Keeper mode"
        value={mode}
        onChange={setMode}
        options={[
          ["inspect", "Inspect"],
          ["act", "Act"],
        ]}
      />
      {mode === "inspect" ? (
        <>
          <form
            className="keeper-search"
            onSubmit={(e) => {
              e.preventDefault();
              // Once the position is on screen, the same button carries it to Act.
              if (inspected) setMode("act");
              else void inspect(owner);
            }}
          >
            <label htmlFor="keeper-borrower">Borrower address</label>
            <div className="inline-field">
              <input
                id="keeper-borrower"
                required
                value={owner}
                onChange={(e) => {
                  setOwner(e.target.value);
                  setPosition(undefined);
                  requested.current = "";
                }}
                spellCheck={false}
                placeholder="0x… or pick one in the loan book"
              />
              <button
                type="submit"
                className={inspected ? "primary" : undefined}
                disabled={!s || loading}
              >
                {loading
                  ? "Inspecting…"
                  : inspected
                    ? nextStep(
                        position,
                        s?.v.minCR ?? 0n,
                        now,
                        s?.v.liquidationWindow ?? 0n,
                        displayName(position.owner),
                      )
                    : "Inspect position"}
              </button>
            </div>
          </form>
          <p role="status" className="micro">
            {error || (
              // QA-05: success is announced, not shown twice; the summary below already shows it.
              <span className="sr-only">
                {inspected && position && !loading
                  ? `Inspected ${displayName(position.owner)}: ${ratio(position.cr)} collateral ratio. ${nextStep(position, s?.v.minCR ?? 0n, now, s?.v.liquidationWindow ?? 0n, displayName(position.owner)).replace(" →", "")} is next.`
                  : ""}
              </span>
            )}
          </p>
          {summary}
        </>
      ) : (
        <>
          {summary || <p className="micro">Inspect a borrower first.</p>}
          <div className="keeper-actions">
            <div>
              <ActionForm
                id="liquidate"
                label="Review liquidation"
                actions={actions}
                target={s?.targets.ParameterizedVault}
                fn="liquidate"
                fields={[amt("Repay borrower COMP")]}
                mapArgs={(a) => [address(owner), ...a]}
                summary="Burn your COMP to cancel borrower debt and receive IMD, including the liquidation bonus after protocol and marker shares."
                explain={borrower}
                disabled={
                  !feedsReady(s) ||
                  !position?.mark[2] ||
                  now < position.mark[0] + position.mark[1] ||
                  now >
                    position.mark[0] +
                      position.mark[1] +
                      (s?.v.liquidationWindow ?? 0n)
                }
                reason="An active mark, elapsed grace, open execution window and fresh feeds are required."
              />
            </div>
            <div>
              <div className="button-row">
                <Action
                  id="mark"
                  label="Review mark"
                  actions={actions}
                  disabled={
                    !feedsReady(s) || !position || position.cr >= s?.v.minCR
                  }
                  reason="Inspect an unhealthy borrower with fresh feeds."
                  request={() => ({
                    target: s!.targets.ParameterizedVault,
                    fn: "markUnderwater",
                    args: [address(owner)],
                    summary: `Mark ${address(owner)} as underwater. The on-chain grace snapshot governs liquidation.`,
                    explain: borrower,
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
                    explain: (f) =>
                      f.name === "UnderwaterPosition" && position
                        ? `${position.owner} is still at ${ratio(position.cr)}, below minCR ${ratio(s?.v.minCR)}. A mark clears only once the position recovers.`
                        : undefined,
                  })}
                />
              </div>
              <ActionForm
                id="mark-for"
                label="Review beneficiary mark"
                actions={actions}
                target={s?.targets.ParameterizedVault}
                fn="markUnderwaterFor"
                fields={[addr("Marker beneficiary")]}
                mapArgs={(a) => [address(owner), ...a]}
                summary="Mark for another beneficiary of the marker reward."
                explain={borrower}
                disabled={!feedsReady(s) || !position}
                reason="Inspect a borrower and wait for fresh feeds."
              />
            </div>
          </div>
        </>
      )}
    </div>
  );
}

export function Backing({ r, s }: { r: Runtime; s?: Snapshot }) {
  const v = s?.v || {};
  return (
    <>
      <div className="desk-col">
        <div className="hero-stat">
          <span>
            Backing per COMP
            <Info
              label="Backing per COMP"
              text="Reserve plus secured collateral, over COMP supply, never above $1. A redemption pays the lesser of $1 and this figure, less the fee."
            />
          </span>
          <strong>
            <Ticker
              text={
                v.backingPerComp === undefined
                  ? "Not reported"
                  : `$${fmt(v.backingPerComp)}`
              }
            />
          </strong>
          <small>
            {v.backingPerComp === undefined
              ? "—"
              : v.backingPerComp < WAD
                ? "Cap binds"
                : "At par"}
          </small>
        </div>
        <SupplyChart s={s} />
        <AddressLink
          value={s?.targets.treasury.address}
          explorer={r.config.network.explorer}
          label="Treasury"
        />
      </div>
      <div className="desk-col">
        <Row
          label="Reserve value"
          info="Treasury reserve assets valued in USD through their listed price feeds."
        >
          ${fmt(v.reserveValue)}
        </Row>
        <Row
          label="Collateral-backed debt"
          info="Principal debt still standing behind collateral, net of recorded bad debt."
        >
          {fmt(v.backedDebt)} COMP
        </Row>
        <Row
          label="Secured collateral"
          info="Collateral that stood behind debt, counted up to that debt at minCR. Surplus and debt-free deposits are excluded."
        >
          {fmt(v.securedCollateral)} IMD
        </Row>
        <Row label="Total principal debt">{fmt(v.totalDebt)} COMP</Row>
        <Row
          label="Recorded bad debt"
          info="Debt left after a liquidation exhausted a position's collateral."
        >
          {fmt(v.totalBadDebt)} COMP
        </Row>
        <Row label="Work minted">{fmt(v.totalWorkMinted)} COMP</Row>
        <Row
          label="Non-principal burns"
          info="Redemptions that retired COMP without cancelling borrower principal."
        >
          {fmt(v.totalNonPrincipalRedeemed)} COMP
        </Row>
        <Row label="Work ratio">{percent(v.workRatioBps)}</Row>
        <Row
          label="Work ceiling"
          info="Reserve value + backed debt × work ratio. A repayment or redemption can lower it and pause new work issuance."
        >
          {fmt(v.workCeiling)} COMP
        </Row>
        <Row label="Reserve assets">{v.reserveAssets?.length ?? "—"}</Row>
        {v.reserveAssets?.map((a: any) => (
          <AddressLink
            key={a}
            value={a}
            explorer={r.config.network.explorer}
            label="Reserve asset"
          />
        ))}
      </div>
    </>
  );
}
const operations = [
  ["spread", "Propose redemption spread"],
  ["work-ratio", "Propose work ratio"],
  ["per-task", "Propose COMP per task"],
  ["economics", "Propose economics"],
  ["reserve-proposal", "Propose reserve asset"],
  ["cancel", "Cancel the pending proposal"],
  ["checkpoint", "Checkpoint the fee index"],
  ["sync", "Sync a reserve token"],
  ["treasury-withdraw", "Withdraw from Treasury"],
  ["report", "Reporter fallback"],
] as const;
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
  const [op, setOp] = useState<string>("spread");
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
  const kind = pending
    ? ([
        "None",
        "Economics",
        "Work ratio",
        "Reserve asset",
        "COMP per task",
        "Redemption spread",
      ][Number(pending[0])] ?? String(pending[0]))
    : "—";
  const pendingBlock = (
    <>
      <Row label="Pending change">{kind}</Row>
      <Row label="Execution">
        {eta
          ? now >= eta
            ? "Ready to apply"
            : `${eta - now}s remaining`
          : "No pending change"}
      </Row>
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
    </>
  );
  return (
    <>
      <Col label="Parameters">
        <Row label="Stability fee / year">{percent(v.stabilityFeeBps)}</Row>
        <Row label="Debt ceiling">{ceilingText(v.debtCeiling)}</Row>
        <Row label="Governance delay">
          {v.TIMELOCK === undefined ? "—" : `${v.TIMELOCK / 3600n} hours`}
        </Row>
        <Row label="Max divergence">{percent(v.maxDivergenceBps)}</Row>
        <Row label="Redemption spread">
          {v.redemptionSpread === undefined
            ? "—"
            : `${v.redemptionSpread} ratio points`}
        </Row>
        {isGov && pendingBlock}
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
      </Col>
      {/* Operator controls render only for the connected governor; everyone else sees what is
          pending and may apply it once the timelock ends. */}
      {!isGov && <Col label="Pending">{pendingBlock}</Col>}
      {isGov && (
        <Col label="Operator">
          <Select
            id="gov-operation"
            label="Operation"
            value={op}
            onChange={setOp}
            options={operations}
          />
          {op === "spread" && (
            <ActionForm
              {...common}
              id="spread"
              label="Review spread proposal"
              fn="proposeRedemptionSpread"
              fields={[num("Spread (25–100 ratio points)")]}
              summary="Set the spread above minCR after the governance delay."
            />
          )}
          {op === "work-ratio" && (
            <ActionForm
              {...common}
              id="work-ratio"
              label="Review work ratio proposal"
              fn="proposeWorkRatio"
              fields={[num("Work ratio (0–2500 bps)")]}
              summary="Change the backing fraction available to work issuance."
            />
          )}
          {op === "per-task" && (
            <ActionForm
              {...common}
              id="per-task"
              label="Review COMP per task"
              fn="proposeCompPerTask"
              fields={[{ name: "COMP per task (max 1)", kind: "amount0" }]}
              summary="Change the COMP earned per task after the delay."
            />
          )}
          {op === "economics" && (
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
          )}
          {op === "reserve-proposal" && (
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
          )}
          {op === "cancel" && (
            <ActionForm
              {...common}
              id="cancel"
              label="Review cancel proposal"
              fn="cancel"
              summary="Cancel the currently pending proposal."
            />
          )}
          {op === "checkpoint" && (
            <ActionForm
              id="checkpoint"
              label="Review checkpoint"
              actions={actions}
              target={s?.targets.ParameterizedVault}
              fn="pokeIndex"
              summary="Checkpoint the accrued stability fee index. Anyone may call it."
            />
          )}
          {op === "sync" && (
            <ActionForm
              id="sync"
              label="Review reserve sync"
              actions={actions}
              target={s?.targets.treasury}
              fn="sync"
              fields={[addr("Token to sync")]}
              summary="Record a token arrival in Treasury accounting. Anyone may call it."
            />
          )}
          {op === "treasury-withdraw" && (
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
          )}
          {op === "report" && <Reporter r={r} s={s} actions={actions} />}
        </Col>
      )}
    </>
  );
}
function Reporter({
  r,
  s,
  actions,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
}) {
  const [selected, setSelected] = useState("PriceFeed");
  const [reporter, setReporter] = useState(false);
  const [error, setError] = useState("");
  return (
    <>
      <Select
        id="reporter-feed"
        label="Feed"
        value={selected}
        onChange={(v) => {
          setSelected(v);
          setReporter(false);
        }}
        options={[
          ["PriceFeed", "PriceFeed"],
          ["NhiFeed", "NhiFeed"],
          ["SpotFeed", "SpotFeed"],
        ]}
      />
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
        summary="Publish through the testnet reporter fallback."
        disabled={!reporter}
        reason="Only a configured reporter can report. Simulation rechecks permission."
      />
    </>
  );
}

function QuestionState({ q }: { q?: Question }) {
  const info =
    "The feed recomputes the question hash from the attested window and refuses an answer to any other question. Fingerprint = expectedQuestionHash(0, 0).";
  if (!q || q.kind === "unavailable")
    return (
      <Row
        label="Question"
        info="This feed predates question binding and cannot report which question it accepts."
      >
        {q ? "Not reported" : "—"}
      </Row>
    );
  if (q.kind === "unpinned")
    return (
      <Row
        label="Question"
        info="Any attestation from the attester is accepted, whatever question it answers."
      >
        <span className="danger-text">None pinned</span>
      </Row>
    );
  return (
    <>
      <Row label="Question" info={info}>
        <span className="healthy-text" title={q.fingerprint}>
          Pinned · {q.fingerprint.slice(0, 10)}…
        </span>
      </Row>
      <Row
        label="Last window"
        info="Closing block of the last accepted attestation window, on the chain the question reads (Ethereum mainnet). It only moves forward."
      >
        {q.lastToBlock ? q.lastToBlock.toLocaleString("en-US") : "—"}
      </Row>
    </>
  );
}
