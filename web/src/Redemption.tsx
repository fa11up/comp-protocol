import { unit } from "./unit";
import { Ticker } from "./motion";
import { useEffect, useRef, useState } from "react";
import { zeroAddress, type Address } from "viem";
import { type Runtime } from "./config";
import { type Snapshot, read, feedsReady } from "./state";
import { Action, Row, Col, Info, type Actions } from "./actions";
import {
  amount,
  address,
  uint,
  fmt,
  exact,
  percent,
  payout,
  message,
  ratio,
  WAD,
} from "./math";
import { explained } from "./explain";
import { onChain } from "./names";
type Quote = ReturnType<typeof payout> & {
  amount: bigint;
  fee: bigint;
  minimum: bigint;
  candidate: Address;
  cr?: bigint;
  block: bigint;
};
export function Redemption({
  r,
  s,
  actions,
}: {
  r: Runtime;
  s?: Snapshot;
  actions: Actions;
}) {
  const [input, setInput] = useState("");
  const [candidate, setCandidate] = useState("");
  const [slippage, setSlippage] = useState("50");
  const version = useRef(0);
  const [q, setQ] = useState<Quote>();
  const [error, setError] = useState("");
  const [invalidField, setInvalidField] = useState("");
  const [loading, setLoading] = useState(false);
  const [curve, setCurve] = useState<
    { size: bigint; fee: bigint; pct: number }[]
  >([]);
  useEffect(() => {
    version.current++;
    setQ(undefined);
  }, [input, candidate, slippage, s, actions.account]);
  useEffect(() => {
    let active = true;
    setCurve([]);
    if (s && s.v.supply > 0n) {
      Promise.all(
        [1, 5, 10].map(async (pct) => {
          const size = (s.v.supply * BigInt(pct)) / 100n;
          return {
            pct,
            size,
            fee: (await read(
              r,
              s.targets.ParameterizedVault,
              "redemptionFeeBps",
              [size],
              s.block,
            )) as bigint,
          };
        }),
      )
        .then((v) => {
          if (active) setCurve(v);
        })
        .catch(() => {});
    }
    return () => {
      active = false;
    };
  }, [s, r]);
  const ready = feedsReady(s);
  const v = s?.v || {};
  return (
    <>
      <Col label="Fee and floor">
        <div className="hero-stat">
          <span>
            Current fee
            <Info
              label="Current fee"
              text="The fee before your amount is added. Larger redemptions raise it, up to the cap, and the base decays with a half-life of about 12 hours. The fee stays in the protocol as backing."
            />
          </span>
          <strong>
            <Ticker text={percent(v.fee)} />
          </strong>
        </div>
        <Row label="Floor / cap">
          {percent(v.REDEMPTION_FEE_FLOOR_BPS)} /{" "}
          {percent(v.REDEMPTION_FEE_CAP_BPS)}
        </Row>
        <Row
          label={`Paid at, per ${unit()}`}
          info={`A redemption pays the lesser of $1 and backing per ${unit()}, less the fee.`}
        >
          {v.backingPerUnit === undefined
            ? "Par (backing unavailable)"
            : v.backingPerUnit < WAD
              ? `$${fmt(v.backingPerUnit)} · cap binds`
              : "$1 · par"}
        </Row>
        <Row
          label="Reserve on hand"
          info="Redemptions are paid from the reserve first; a candidate position covers any shortfall."
        >
          {fmt(v.redemptionReserve)} IMD
        </Row>
        <Row
          label="Eligibility ceiling"
          info={`minCR ${ratio(v.mat)} + ${v.gap?.toString() ?? "—"} ratio points. A candidate must have debt and sit strictly below the ceiling.`}
        >
          {ratio(v.redemptionCeilingCR)}
        </Row>
        <div className="size-table">
          <div className="section-label">Size / fee at this block</div>
          {curve.length ? (
            curve.map((p) => (
              <div className="curve-row" key={p.pct}>
                <span title={`${exact(p.size)} ${unit()}`}>
                  {p.pct}% of supply
                </span>
                <meter
                  min={0}
                  max={Number(v.REDEMPTION_FEE_CAP_BPS)}
                  value={Number(p.fee)}
                  aria-label={`Fee for ${p.pct}% of supply`}
                />
                <strong>{percent(p.fee)}</strong>
              </div>
            ))
          ) : (
            <Row label="Supply">—</Row>
          )}
        </div>
      </Col>
      <Col label="Redeem">
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            const generation = version.current;
            const form = e.currentTarget;
            setInvalidField("");
            const validate = <T,>(field: string, check: () => T): T => {
              try {
                return check();
              } catch (error) {
                setInvalidField(field);
                (form.elements.namedItem(field) as HTMLInputElement)?.focus();
                throw error;
              }
            };
            setLoading(true);
            setError("");
            setQ(undefined);
            try {
              if (!s || !actions.account || !ready)
                throw Error(
                  "Connect on the correct chain and wait for fresh, agreeing feeds.",
                );
              const n = validate("redeem-amount", () => {
                const n = amount(input);
                if (n > s.v.compBalance)
                  throw Error(`The amount exceeds your ${unit()} balance.`);
                return n;
              });
              const tolerance = validate("redemption-slippage", () => {
                const n = uint(slippage);
                if (n > 500n)
                  throw Error("Use slippage between 0 and 500 bps (5%).");
                return n;
              });
              const fee = (await read(
                r,
                s.targets.ParameterizedVault,
                "redemptionFeeBps",
                [n],
                s.block,
              )) as bigint;
              const result = payout(
                n,
                fee,
                s.feeds.USD.value,
                s.v.redemptionReserve,
                s.v.backingPerUnit,
              );
              const c = validate("redemption-candidate", () =>
                candidate.trim() ? address(candidate) : zeroAddress,
              );
              let cr: bigint | undefined;
              if (result.positionOut > 0n) {
                if (c === zeroAddress)
                  throw Error(
                    "The reserve cannot cover this amount. Enter a candidate position.",
                  );
                const [debt, collateralRatio] = await Promise.all([
                  read(r, s.targets.ParameterizedVault, "debtOf", [c], s.block),
                  read(
                    r,
                    s.targets.ParameterizedVault,
                    "collateralRatio",
                    [c],
                    s.block,
                  ),
                ]);
                cr = collateralRatio;
                if (!debt || collateralRatio >= s.v.redemptionCeilingCR)
                  throw Error(
                    "Candidate is debt-free or at/above the eligibility ceiling.",
                  );
                if (result.debtCancelled > debt)
                  throw Error(
                    "The reserve shortfall exceeds the candidate’s debt. Reduce the amount.",
                  );
              }
              const minimum = (result.out * (10000n - tolerance)) / 10000n;
              if (minimum === 0n)
                throw Error(
                  "Minimum output rounds to zero. Increase the amount.",
                );
              await r.client
                .simulateContract({
                  ...s.targets.ParameterizedVault,
                  functionName: onChain("cash"),
                  args: [n, minimum, c],
                  account: actions.account,
                  blockNumber: s.block,
                })
                .catch((e) =>
                  explained(
                    e,
                    {
                      fn: "cash",
                      args: [n, minimum, c],
                      s,
                      account: actions.account,
                    },
                    (f) =>
                      f.name === "MinimumOutNotMet"
                        ? `The payout at block ${s.block} is below your minimum of ${exact(minimum)} IMD. Refresh the quote or widen slippage.`
                        : f.name === "IneligibleRedemptionPosition" &&
                            cr !== undefined
                          ? `The candidate sits at ${ratio(cr)}; only positions with debt below ${ratio(s.v.redemptionCeilingCR)} can be redeemed against.`
                          : undefined,
                  ),
                );
              if (generation === version.current)
                setQ({
                  ...result,
                  amount: n,
                  fee,
                  minimum,
                  candidate: c,
                  cr,
                  block: s.block,
                });
            } catch (e) {
              setError(message(e));
            } finally {
              setLoading(false);
            }
          }}
        >
          <label>
            Redeem {unit()}
            <input
              name="redeem-amount"
              aria-invalid={invalidField === "redeem-amount" || undefined}
              aria-describedby="redemption-feedback"
              inputMode="decimal"
              autoComplete="off"
              required
              value={input}
              onChange={(e) => setInput(e.target.value)}
            />
          </label>
          <div className="two-col fields">
            <label>
              Slippage (bps)
              <input
                name="redemption-slippage"
                aria-invalid={
                  invalidField === "redemption-slippage" || undefined
                }
                aria-describedby="redemption-feedback"
                inputMode="numeric"
                required
                value={slippage}
                onChange={(e) => setSlippage(e.target.value)}
              />
            </label>
            <div className="field-info">
              50 bps = 0.5%
              <br />
              No {unit()} approval
            </div>
          </div>
          <label>
            Candidate position{" "}
            <span className="muted">/ if reserve is short</span>
            <input
              name="redemption-candidate"
              aria-invalid={
                invalidField === "redemption-candidate" || undefined
              }
              aria-describedby="redemption-feedback"
              autoComplete="off"
              spellCheck={false}
              placeholder="0x…"
              value={candidate}
              onChange={(e) => setCandidate(e.target.value)}
            />
          </label>
          <button
            type="submit"
            disabled={!actions.ready || !ready || loading || !!actions.busy}
          >
            {loading ? "Quoting…" : "Quote redemption"}
          </button>
          <p className="action-note">
            {q
              ? ""
              : !actions.ready
                ? actions.reason
                : !ready
                  ? "Fresh, agreeing primary, spot, NHI and USD feeds are required."
                  : `Burn ${unit()} for IMD at the lesser of par and backing per ${unit()}, less the fee.`}
          </p>
        </form>
        <div id="redemption-feedback" role="status" aria-live="polite">
          {error && <p className="notice">{error}</p>}
        </div>
        {q && (
          <div className="quote" aria-live="polite">
            <div className="section-label">
              Quote / block {q.block.toString()} · clears on any change
            </div>
            <Row label="You receive">{exact(q.out)} IMD</Row>
            <Row label="Your fee">
              {percent(q.fee)} ·{" "}
              {q.capped ? `$${fmt(q.paidAt)} (backing cap)` : "$1 (par)"}
            </Row>
            <Row label="Served by">{q.source}</Row>
            {q.reserveOut > 0n && q.positionOut > 0n && (
              <Row label="Reserve / position">
                {fmt(q.reserveOut)} / {fmt(q.positionOut)} IMD
              </Row>
            )}
            {q.cr !== undefined && (
              <Row label="Candidate ratio">{ratio(q.cr)}</Row>
            )}
            {q.debtCancelled > 0n && (
              <Row label="Debt cancelled">
                {fmt(q.debtCancelled)} {unit()}
              </Row>
            )}
            <Row label="Minimum received">{exact(q.minimum)} IMD</Row>
            <Action
              id="cash"
              label="Review redemption"
              actions={actions}
              request={() => ({
                target: s!.targets.ParameterizedVault,
                fn: "cash",
                args: [q.amount, q.minimum, q.candidate],
                summary: `Burn ${exact(q.amount)} ${unit()}. Receive at least ${exact(q.minimum)} IMD; quoted ${exact(q.out)} IMD from ${q.source.toLowerCase()} at ${percent(q.fee)}${q.capped ? `, paid at $${fmt(q.paidAt)} per ${unit()} because backing is below par` : ""}. Candidate: ${q.candidate}. The fee is retained as backing.`,
              })}
            />
          </div>
        )}
      </Col>
    </>
  );
}
