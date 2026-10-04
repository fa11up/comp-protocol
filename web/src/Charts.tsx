import { useEffect, useRef, useState } from "react";
import { formatUnits, maxUint256 } from "viem";
import type { Runtime } from "./config";
import type { Snapshot } from "./state";
import {
  loanBook,
  cadence,
  positionName,
  type Book,
  type Cadence,
  type Result,
} from "./history";
import { fmt, ratio, WAD, message, liquidationPrice, cushion } from "./math";
import { Ticker } from "./motion";
import { Info } from "./actions";

type Loaded<T> = Result<T> & { snapshot?: Snapshot; loading?: boolean };
export function useCharts(r: Runtime, s?: Snapshot) {
  const [book, setBook] = useState<Loaded<Book>>({ loading: true });
  const [feeds, setFeeds] = useState<Record<string, Loaded<Cadence>>>({});
  const [attempt, retry] = useState(0);
  const running = useRef(false);
  const pending = useRef(false);
  const mounted = useRef(true);
  useEffect(
    () => () => {
      mounted.current = false;
    },
    [],
  );
  useEffect(() => {
    if (!s) return;
    if (running.current) {
      pending.current = true;
      return;
    }
    running.current = true;
    setBook((old) => ({ ...old, loading: true }));
    const load = async <T,>(fn: () => Promise<T>): Promise<Loaded<T>> => {
      try {
        return { data: await fn(), snapshot: s };
      } catch (e) {
        return { error: message(e) };
      }
    };
    void Promise.all([
      load(() => loanBook(r, s)).then((result) => {
        if (mounted.current) setBook(result);
      }),
      ...[
        "PriceFeed",
        "NhiFeed",
        "SpotFeed",
        ...(s.work.mode === "attested" ? ["oracle"] : []),
      ].map(async (name) => {
        if (mounted.current)
          setFeeds((old) => ({
            ...old,
            [name]: { ...old[name], loading: true },
          }));
        const result = await load(() => cadence(r, s.targets[name], s.block));
        if (mounted.current) setFeeds((old) => ({ ...old, [name]: result }));
      }),
    ]).finally(() => {
      running.current = false;
      if (pending.current && mounted.current) {
        pending.current = false;
        retry((n) => n + 1);
      }
    });
  }, [r, s, attempt]);
  return { book, feeds, retry: () => retry((n) => n + 1) };
}
export type ChartData = ReturnType<typeof useCharts>;
const number = (v: bigint) => Number(formatUnits(v, 18));
const liquidation = (p: { collateral: bigint; debt: bigint }, s?: Snapshot) => {
  const at = s?.v.minCR && liquidationPrice(p.collateral, p.debt, s.v.minCR);
  return at
    ? `liquidates at $${fmt(at, 18, 2)}, ${cushion(s!.feeds.USD?.value, at)}`
    : "liquidation price unavailable";
};
const stateOf = (cr: bigint, min: bigint, ceiling: bigint) =>
  cr < min ? "Liquidatable" : cr < ceiling ? "Redeemable" : "Safe";

export function LoanBook({
  charts,
  available,
}: {
  charts: ChartData;
  available: boolean;
}) {
  const { book } = charts;
  const host = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const [selected, setSelected] = useState<string>();
  const axisCeiling = useRef(300);
  useEffect(() => {
    if (!host.current) return;
    const observer = new ResizeObserver(([entry]) =>
      setWidth(entry.contentRect.width),
    );
    observer.observe(host.current);
    return () => observer.disconnect();
  }, [book.data, available]);
  const s = book.snapshot;
  const positions = book.data?.positions ?? [];
  const min = s?.v.minCR as bigint | undefined;
  const ceiling = s?.v.redemptionCeilingCR as bigint | undefined;
  const valid =
    available && !!book.data && min !== undefined && ceiling !== undefined;
  // Saturated uint256 ratios remain identifiable in the ledger; the arrow marks the overflow.
  const finite = positions
    .filter((p) => p.cr !== maxUint256)
    .map((p) => Number(p.cr));
  axisCeiling.current = Math.max(
    axisCeiling.current,
    Math.ceil(
      Math.max(
        Number(ceiling ?? 0n) * 1.05,
        ...finite.map((x) => x * 1.05),
        300,
      ) / 100,
    ) * 100,
  );
  const maximum = axisCeiling.current;
  const at = (value: bigint) => Math.min(100, (Number(value) / maximum) * 100);
  const maxDebt = positions.reduce((m, p) => (p.debt > m ? p.debt : m), 1n);
  // Pack labels in separate lanes without changing the ratio coordinate.
  const lanes: number[] = [];
  const marks = [...positions]
    .sort((a, b) =>
      a.cr < b.cr ? -1 : a.cr > b.cr ? 1 : a.owner.localeCompare(b.owner),
    )
    .map((p) => {
      const x = at(p.cr),
        px = (x / 100) * width;
      let lane = lanes.findIndex((end) => end + 12 < px - 64);
      if (lane < 0) lane = lanes.length;
      lanes[lane] = px + 64;
      return {
        ...p,
        x,
        lane,
        radius: 12 * Math.sqrt(Number(p.debt) / Number(maxDebt)),
      };
    });
  const height = Math.max(64, lanes.length * 48 + 14);
  return (
    <>
      <div className="book-heading">
        <p>
          Collateral ratio{" "}
          <span className="muted">/ circle area = accrued COMP debt</span>
        </p>
        <span className="muted">
          {valid
            ? `${positions.length} open · block ${s!.block}`
            : "Coverage unverified"}
          {book.loading && " · Reading…"}
        </span>
      </div>
      <div className="book-legend">
        <span className="danger-text">Below minCR · liquidatable</span>
        <span>minCR → ceiling · redeemable</span>
        <span className="healthy-text">Above ceiling · safe</span>
      </div>
      {!valid ? (
        <div className="chart-unavailable" role="status">
          <p>
            {book.error
              ? `Could not read loan book. ${book.error} Refresh state or retry history; position count is unknown.`
              : !available
                ? "Waiting for live contract state. Position count is unknown."
                : book.loading
                  ? "Reading deposit logs and every owner’s position…"
                  : "Could not read loan book thresholds. Refresh state."}
          </p>
          <button disabled={book.loading || !available} onClick={charts.retry}>
            Retry history
          </button>
        </div>
      ) : (
        <>
          <div className="strip-wrap">
            <div className="strip-labels">
              <span>0%</span>
              <span className="min-label" style={{ left: `${at(min!)}%` }}>
                minCR <Ticker text={`${min}%`} />
              </span>
              <span
                className="ceiling-label"
                style={{ left: `${at(ceiling!)}%` }}
              >
                Ceiling <Ticker text={`${ceiling}%`} />
              </span>
              <span>{maximum}%</span>
            </div>
            <div
              className="strip-plot"
              ref={host}
              style={{ height }}
              role="group"
              aria-label="Open positions by collateral ratio"
            >
              <div
                className="ratio-band liquidatable-band"
                style={{ width: `${at(min!)}%` }}
              />
              <div
                className="ratio-band redeemable-band"
                style={{
                  left: `${at(min!)}%`,
                  width: `${at(ceiling!) - at(min!)}%`,
                }}
              />
              <div
                className="ratio-band safe-band"
                style={{
                  left: `${at(ceiling!)}%`,
                  width: `${100 - at(ceiling!)}%`,
                }}
              />
              <div className="band-boundary" style={{ left: `${at(min!)}%` }} />
              <div
                className="band-boundary ceiling-boundary"
                style={{ left: `${at(ceiling!)}%` }}
              />
              {marks.map((p) => (
                <button
                  key={p.owner}
                  type="button"
                  className={`loan-mark ${p.cr < min! ? "is-danger" : "is-healthy"}`}
                  style={{ left: `${p.x}%`, top: p.lane * 48 + 4 }}
                  title={`${positionName(p.owner)} · ${p.owner}\n${p.cr}% · ${fmt(p.debt)} COMP · ${stateOf(p.cr, min!, ceiling!)}\n${liquidation(p, s)}`}
                  aria-label={`${positionName(p.owner)}, ${p.owner}, ${p.cr}% collateral ratio, ${fmt(p.debt)} COMP, ${stateOf(p.cr, min!, ceiling!)}, ${liquidation(p, s)}`}
                  aria-pressed={selected === p.owner}
                  onClick={() =>
                    setSelected(selected === p.owner ? undefined : p.owner)
                  }
                >
                  <span
                    className="loan-dot"
                    style={{ width: p.radius * 2, height: p.radius * 2 }}
                  />
                  <span className="loan-label">
                    {p.cr === maxUint256 && "→ "}
                    {positionName(p.owner)}
                  </span>
                </button>
              ))}
            </div>
          </div>
          {positions.length === 0 && (
            <p className="micro">
              All discovered owners have zero debt at block{" "}
              {s!.block.toString()}. Deposit history was read successfully.
            </p>
          )}
          {positions
            .filter((p) => p.owner === selected)
            .map((p) => (
              <p className="selected-loan" key={p.owner}>
                {positionName(p.owner)} · <span>{p.owner}</span> · {ratio(p.cr)}{" "}
                · {fmt(p.debt)} COMP · {stateOf(p.cr, min!, ceiling!)} ·{" "}
                {liquidation(p, s)}
              </p>
            ))}
          <details className="loan-ledger">
            <summary>
              Position ledger & read coverage ({positions.length})
            </summary>
            <p className="micro">
              {book.data!.history.source} deposit history from deployment block{" "}
              {book.data!.history.from.toString()} through{" "}
              {book.data!.history.through.toString()}. Every discovered owner
              was read at the displayed block. Names are deterministic address
              labels and may repeat; addresses remain public. Select a mark to
              read its address on touch.
            </p>
            <div className="table-scroll">
              <table>
                <caption>Open positions · accrued debt</caption>
                <thead>
                  <tr>
                    <th scope="col">Position / public address</th>
                    <th scope="col">Ratio</th>
                    <th scope="col">COMP</th>
                    <th scope="col">Zone</th>
                    <th scope="col">Liquidates at</th>
                  </tr>
                </thead>
                <tbody>
                  {positions.map((p) => (
                    <tr key={p.owner}>
                      <td>
                        {positionName(p.owner)}
                        <br />
                        <span>{p.owner}</span>
                      </td>
                      <td>{ratio(p.cr)}</td>
                      <td>{fmt(p.debt)}</td>
                      <td>{stateOf(p.cr, min!, ceiling!)}</td>
                      <td>
                        {(() => {
                          const at = liquidationPrice(
                            p.collateral,
                            p.debt,
                            min!,
                          );
                          return at ? (
                            <>
                              ${fmt(at, 18, 2)}
                              <br />
                              <span>{cushion(s!.feeds.USD?.value, at)}</span>
                            </>
                          ) : (
                            "—"
                          );
                        })()}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </details>
        </>
      )}
    </>
  );
}

function Unavailable({ children }: { children: string }) {
  return <p className="micro chart-unavailable">{children}</p>;
}
export function Sparkline({
  feed,
  live,
  now,
  label,
}: {
  feed?: Loaded<Cadence>;
  live?: Snapshot["feeds"][string];
  now: bigint;
  label: string;
}) {
  if (!feed?.data || !live)
    return (
      <Unavailable>
        {feed?.error
          ? `Could not read ${label} cadence. Retry history in the loan book.`
          : "Reading accepted updates…"}
      </Unavailable>
    );
  const points = feed.data.points;
  const start = Math.min(...points.map((p) => p.time));
  const latest = points.reduce((a, b) => (a.time > b.time ? a : b));
  const expiry = latest.time + Number(live.maxAge);
  const end = Math.max(Number(now), latest.time, start + 1);
  const values = points.map((p) => number(p.value));
  const low = Math.min(...values),
    high = Math.max(...values);
  const x = (t: number) => 6 + ((t - start) / (end - start)) * 288;
  const expiryX = Math.min(294, x(expiry));
  const y = (v: number) =>
    high === low ? 34 : 56 - ((v - low) / (high - low)) * 40;
  const d = points
    .map((p, i) => `${i ? "L" : "M"}${x(p.time)},${y(number(p.value))}`)
    .join(" ");
  return (
    <figure className="mini-chart cadence-chart">
      <svg
        viewBox="0 0 300 78"
        role="img"
        aria-label={`${label}: ${points.length} accepted updates, irregular signed timestamps. Last accepted value expires ${new Date(expiry * 1000).toISOString()}.`}
      >
        <path d={d} className="spark-path" pathLength="1" />
        <line
          className="limit-line"
          x1={expiryX}
          x2={expiryX}
          y1="10"
          y2="64"
        />
        <text
          className="chart-text"
          x={expiryX > 180 ? expiryX - 3 : expiryX + 3}
          y="9"
          textAnchor={expiryX > 180 ? "end" : "start"}
        >
          {expiry > end ? "stale after →" : "stale after"}
        </text>
        {points.map((p) => (
          <circle
            key={p.id}
            className="spark-point"
            cx={x(p.time)}
            cy={y(number(p.value))}
            r="3"
          >
            <title>{`${new Date(p.time * 1000).toISOString()} · ${fmt(p.value, 18, 8)} · block ${p.block}`}</title>
          </circle>
        ))}
        <text className="chart-text" x="6" y="77">
          {new Date(start * 1000).toISOString().slice(5, 16).replace("T", " ")}
        </text>
        <text className="chart-text" x="294" y="77" textAnchor="end">
          {new Date(end * 1000).toISOString().slice(5, 16).replace("T", " ")}
        </text>
      </svg>
      <figcaption className="figure-head">
        {points.length} accepted · expiry{" "}
        {new Date(expiry * 1000).toISOString().slice(5, 16).replace("T", " ")}
        {feed.loading && " · Updating…"}
        <Info
          label={`${label} history`}
          text={`Every accepted attestation, plotted at its signed time (UTC). Gaps are real: updates are bought on demand, not pushed on a clock. Stale after ${live.maxAge}s.`}
        />
      </figcaption>
      <details>
        <summary>Accepted update values</summary>
        <ul className="point-list">
          {points.map((p) => (
            <li key={p.id}>
              {new Date(p.time * 1000).toISOString()} · {fmt(p.value, 18, 8)}
            </li>
          ))}
        </ul>
      </details>
    </figure>
  );
}

export function DivergenceChart({ s }: { s?: Snapshot }) {
  const primary = s?.feeds.PriceFeed,
    spot = s?.feeds.SpotFeed;
  const bps = s?.v.maxDivergenceBps as bigint | undefined;
  if (!primary?.value || !spot || bps === undefined)
    return <Unavailable>Could not read the divergence band.</Unavailable>;
  const divergence = (number(spot.value) / number(primary.value) - 1) * 100;
  const limit = Number(bps) / 100;
  const span = Math.max(limit * 1.4, Math.abs(divergence) * 1.15, 1);
  const at = (v: number) => 150 + (v / span) * 140;
  const breached = Math.abs(divergence) > limit;
  return (
    <figure className="mini-chart divergence-chart">
      <figcaption className="figure-head">
        Primary / spot · ±{limit}%
        <Info
          label="Divergence band"
          text="◆ primary at the centre, ● spot. The band is the allowed divergence; outside it, price actions pause."
        />
      </figcaption>
      <svg
        viewBox="0 0 300 72"
        role="img"
        aria-label={`Primary ${fmt(primary.value, 18, 8)} ETH per IMD; spot ${fmt(spot.value, 18, 8)}; divergence ${divergence.toFixed(2)} percent; limit ${limit} percent${breached ? ", outside band" : ", inside band"}`}
      >
        <rect
          className="chart-band"
          x={at(-limit)}
          y="18"
          width={at(limit) - at(-limit)}
          height="28"
        />
        <line
          className="limit-line"
          x1={at(-limit)}
          x2={at(-limit)}
          y1="14"
          y2="50"
        />
        <line
          className="limit-line"
          x1={at(limit)}
          x2={at(limit)}
          y1="14"
          y2="50"
        />
        <path className="primary-price" d="M150 20 L156 26 L150 32 L144 26 Z" />
        <circle
          className={breached ? "spot-price breached" : "spot-price"}
          cx={at(divergence)}
          cy="39"
          r="4"
        />
        <text className="chart-text" x="150" y="11" textAnchor="middle">
          ◆ primary
        </text>
        <text
          className="chart-text"
          x={Math.max(40, Math.min(260, at(divergence)))}
          y="65"
          textAnchor="middle"
        >
          ● spot {divergence > 0 ? "+" : ""}
          {divergence.toFixed(2)}%
        </text>
      </svg>
      <div className="row">
        <span>Headroom</span>
        <strong>
          {primary.stale || spot.stale ? (
            <span className="danger-text">Stale</span>
          ) : breached ? (
            <span className="danger-text">Breached</span>
          ) : (
            `${Math.max(0, limit - Math.abs(divergence)).toFixed(2)} pts`
          )}
        </strong>
      </div>
    </figure>
  );
}

export function WorkChart({ s }: { s?: Snapshot }) {
  const minted = s?.v.totalWorkMinted as bigint | undefined,
    ceiling = s?.v.workCeiling as bigint | undefined;
  if (minted === undefined || ceiling === undefined)
    return <Unavailable>Could not read work ceiling headroom.</Unavailable>;
  const max = minted > ceiling ? minted : ceiling;
  const fraction = (value: bigint) =>
    max ? (Number(value) / Number(max)) * 100 : 0;
  return (
    <figure className="mini-chart work-chart">
      <figcaption>Work ceiling headroom</figcaption>
      <div
        className="bar"
        role="img"
        aria-label={`${fmt(minted)} COMP minted against ${fmt(ceiling)} COMP ceiling`}
      >
        <span
          className={`bar-fill ${minted > ceiling ? "over-limit" : ""}`}
          style={{ width: `${fraction(minted)}%` }}
        />
        <i className="bar-marker" style={{ left: `${fraction(ceiling)}%` }} />
      </div>
      <p className={minted > ceiling ? "micro danger-text" : "micro"}>
        <Ticker
          text={
            minted > ceiling
              ? `${fmt(minted - ceiling)} COMP over ceiling`
              : `${fmt(ceiling - minted)} COMP available`
          }
        />
      </p>
    </figure>
  );
}

export function SupplyChart({ s }: { s?: Snapshot }) {
  const v = s?.v;
  const usd = s?.feeds.USD;
  if (
    !v ||
    [
      v.supply,
      v.totalDebt,
      v.totalWorkMinted,
      v.totalNonPrincipalRedeemed,
      v.reserveValue,
      v.securedCollateral,
      v.minCR,
      v.totalBadDebt,
    ].some((x) => x === undefined) ||
    !usd?.value
  )
    return (
      <Unavailable>Could not read supply composition and backing.</Unavailable>
    );
  const supply = v.supply as bigint;
  const debt = v.totalDebt as bigint,
    minted = v.totalWorkMinted as bigint,
    burns = v.totalNonPrincipalRedeemed as bigint;
  const collateral = v.securedCollateral as bigint,
    badDebt = v.totalBadDebt as bigint,
    minCR = v.minCR as bigint;
  const reserveValue = v.reserveValue as bigint;
  if (debt + minted - burns !== supply)
    return (
      <Unavailable>
        Supply accounting did not reconcile. Refresh state to retry.
      </Unavailable>
    );
  const principal = debt < supply ? debt : supply;
  const work = supply - principal;
  const secured = (collateral * usd.value) / WAD;
  const backedPrincipal = debt > badDebt ? debt - badDebt : 0n;
  const cap = (backedPrincipal * minCR) / 100n;
  const backing = reserveValue + (secured < cap ? secured : cap);
  const ratio = supply ? Number(backing) / Number(supply) : 0;
  const domain = Math.max(1.25, ratio * 1.1);
  return (
    <figure className="mini-chart supply-chart">
      <figcaption className="figure-head">
        Supply · <Ticker text={`${fmt(supply)} COMP`} />
        <Info
          label="Supply composition"
          text="■ collateral-backed principal (capped at supply) and ▨ net work-issued COMP. Solid marker = backing ratio, dashed = par."
        />
      </figcaption>
      <div
        className="bar composition"
        role="img"
        aria-label={`${fmt(principal)} COMP collateral principal, ${fmt(work)} COMP net work. Backing ${supply ? (ratio * 100).toFixed(1) + "%" : "undefined: zero supply"}`}
      >
        <span
          className="collateral-fill"
          style={{
            width: `${supply ? (Number(principal) / Number(supply)) * 100 : 0}%`,
          }}
        />
        <span
          className="work-fill"
          style={{
            width: `${supply ? (Number(work) / Number(supply)) * 100 : 0}%`,
          }}
        />
        <i
          className="par-marker"
          style={{ left: `${100 / domain}%` }}
          title="Par: 100% backing"
        />
        {supply > 0n && (
          <i
            className="backing-marker"
            style={{ left: `${(ratio / domain) * 100}%` }}
            title={`${(ratio * 100).toFixed(1)}% backing`}
          />
        )}
      </div>
      <p className="composition-legend">
        <span>■ Collateral {fmt(principal)}</span>
        <span>▨ Net work {fmt(work)}</span>
      </p>
      <div className="row">
        <span>
          Backing ratio
          <Info
            label="Backing ratio"
            text={`Reserve value + secured collateral at the live USD price, capped at (principal − bad debt) × minCR, over supply. Bar scale 0–${(domain * 100).toFixed(0)}%. A point-in-time ratio, not a promise of redeemability.`}
          />
        </span>
        <strong>
          <Ticker text={supply ? `${(ratio * 100).toFixed(1)}%` : "—"} />
          {usd.stale && <span className="danger-text"> · USD stale</span>}
        </strong>
      </div>
    </figure>
  );
}
