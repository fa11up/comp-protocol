import { Ticker } from "./motion";
import { useEffect, useRef, useState } from "react";
import { zeroAddress, type Address } from "viem";
import { type Runtime } from "./config";
import { type Snapshot, read, feedsReady } from "./state";
import { Action, Row, type Actions } from "./actions";
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
} from "./math";
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
      <div className="hero-stat">
        <span>Current fee</span>
        <strong>
          <Ticker text={percent(v.fee)} />
        </strong>
        <small>before your amount</small>
      </div>
      <div className="two-col">
        <Row label="Floor">{percent(v.REDEMPTION_FEE_FLOOR_BPS)}</Row>
        <Row label="Cap">{percent(v.REDEMPTION_FEE_CAP_BPS)}</Row>
      </div>
      <Row label="Reserve on hand">{fmt(v.redemptionReserve)} IMD</Row>
      <Row label="Eligibility ceiling">{ratio(v.redemptionCeilingCR)}</Row>
      <p className="micro">
        minCR {ratio(v.minCR)} + {v.redemptionSpread?.toString() ?? "—"} ratio
        points. A candidate must have debt and be strictly below the ceiling.
      </p>
      <div className="size-table">
        <div className="section-label">Size / fee at this block</div>
        {curve.length ? (
          curve.map((p) => (
            <div className="curve-row" key={p.pct}>
              <span title={`${exact(p.size)} COMP`}>{p.pct}% of supply</span>
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
          <p className="micro">
            A nonzero supply is needed for size comparisons.
          </p>
        )}
      </div>
      <p className="micro">
        Larger redemptions raise the fee, up to the cap. The base decays with an
        approximately 12-hour half-life. The fee stays as backing.
      </p>
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
                throw Error("The amount exceeds your COMP balance.");
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
            await r.client.simulateContract({
              ...s.targets.ParameterizedVault,
              functionName: "redeem",
              args: [n, minimum, c],
              account: actions.account,
              blockNumber: s.block,
            });
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
          Redeem COMP
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
              aria-invalid={invalidField === "redemption-slippage" || undefined}
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
            No COMP approval
          </div>
        </div>
        <label>
          Candidate position{" "}
          <span className="muted">/ if reserve is short</span>
          <input
            name="redemption-candidate"
            aria-invalid={invalidField === "redemption-candidate" || undefined}
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
          {!actions.ready
            ? actions.reason
            : !ready
              ? "Fresh, agreeing primary, spot, NHI and USD feeds are required."
              : "Burn COMP for IMD at the USD feed price, less the fee."}
        </p>
      </form>
      <div id="redemption-feedback" role="status" aria-live="polite">
        {error && <p className="notice">{error}</p>}
      </div>
      {q && (
        <div className="quote" aria-live="polite">
          <div className="section-label">
            Quote / block {q.block.toString()}
          </div>
          <Row label="You receive">{exact(q.out)} IMD</Row>
          <Row label="Your fee">{percent(q.fee)}</Row>
          <Row label="Served by">{q.source}</Row>
          <Row label="From reserve">{fmt(q.reserveOut)} IMD</Row>
          <Row label="From position">{fmt(q.positionOut)} IMD</Row>
          {q.cr !== undefined && (
            <Row label="Candidate ratio">{ratio(q.cr)}</Row>
          )}
          <Row label="Debt cancelled">{fmt(q.debtCancelled)} COMP</Row>
          <Row label="Minimum received">{exact(q.minimum)} IMD</Row>
          <p className="micro">
            An estimate from this block. Feed, fee and reserve changes can alter
            execution. A new snapshot or input change clears this quote.
          </p>
          <Action
            id="redeem"
            label="Review redemption"
            actions={actions}
            request={() => ({
              target: s!.targets.ParameterizedVault,
              fn: "redeem",
              args: [q.amount, q.minimum, q.candidate],
              summary: `Burn ${exact(q.amount)} COMP. Receive at least ${exact(q.minimum)} IMD; quoted ${exact(q.out)} IMD from ${q.source.toLowerCase()} at ${percent(q.fee)}. Candidate: ${q.candidate}. The fee is retained as backing.`,
            })}
          />
        </div>
      )}
    </>
  );
}
