import type { Runtime } from "./config";
import { type Snapshot, feedsReady } from "./state";
import { Info, Row, type Actions } from "./actions";
import { BuyUpdate } from "./BuyUpdate";
import { collateral } from "./collateral";
import { age, maxDebt } from "./math";
import { unit } from "./unit";
import { useMarket } from "./market";
import { adviseUpdate, dollars, pct } from "./priceUpdate";

/** Time left on a fresh price: "42m more", "23h 57m more". */
function remaining(seconds: bigint) {
  const m = seconds / 60n;
  return m >= 60n ? `${m / 60n}h ${m % 60n}m more` : `${m}m more`;
}

const LABELS: Record<string, string> = {
  PriceFeed: "Update price",
  SpotFeed: "Update spot check",
  NhiFeed: "Update network health",
};

/**
 * The price the vault is using, when it was last updated, what IMD trades at right now, and what buying
 * an update would do for this viewer, in plain words, with the buttons to buy it.
 */
export function PriceStatus({
  r,
  s,
  now,
  actions,
  where,
  slim = false,
}: {
  r: Runtime;
  s?: Snapshot;
  now: bigint;
  actions: Actions;
  /** Ids stay unique when the panel is shown in more than one pane. */
  where: string;
  /** Update buttons only while price actions are paused (the position desk, where the oracle pane's own
   * buttons sit beside it on a desktop). */
  slim?: boolean;
}) {
  const market = useMarket();
  const f = s?.feeds ?? {};
  const v = s?.v ?? {};
  const price = f.PriceFeed;
  const usd = f.USD;
  const held = v.positions?.[0] as bigint | undefined;
  const debt = v.debtOf as bigint | undefined;
  const collateralPrice = f.Collateral?.value;
  const position =
    held !== undefined && debt !== undefined && v.collateralRatio !== undefined && v.mat && collateralPrice
      ? { cr: v.collateralRatio as bigint, debt, maxDebt: maxDebt(held, v.mat, collateralPrice) }
      : undefined;
  const asker = s?.asker === "unreadable" ? undefined : s?.asker;
  const advice = adviseUpdate({
    now,
    price,
    spot: f.SpotFeed,
    nhi: f.NhiFeed,
    usd,
    market: market && { imdEth: market.imdEth, imdUsd: market.imdUsd },
    capBps: v.priceCapBps,
    staleMultiple: v.staleMultiple,
    position,
    mat: v.mat,
    cost: asker?.price,
    unit: unit(),
  });
  const open = feedsReady(s);
  const left = price && !price.stale ? price.updated + price.maxAge - now : undefined;
  const diff =
    advice.ratio === undefined
      ? undefined
      : advice.ratio >= 10n ** 18n
        ? `${pct(((advice.ratio - 10n ** 18n) * 10000n) / 10n ** 18n)} above`
        : `${pct(((10n ** 18n - advice.ratio) * 10000n) / 10n ** 18n)} below`;
  const g = collateral();
  // One sentence on the page, chosen for what matters most to this viewer; every sentence is in the info
  // window. A warning first, then "actions are paused", then what it does to their own position.
  const headline =
    (advice.warning && advice.lines.find((l) => /minimum/.test(l))) ||
    advice.lines.find((l) => /paused/.test(l)) ||
    advice.lines.find((l) => /^Your collateral ratio/.test(l)) ||
    advice.lines[0];
  const all = [...advice.lines, ...(g.share ? [`Collateral is ${g.symbol}, valued through ${g.underlyingSymbol}'s price, so it moves with it.`] : [])];
  const freshness = price?.updated ? (
    open ? (
      <span className="healthy-text">fresh{left !== undefined && left > 0n ? ` ${remaining(left)}` : ""}</span>
    ) : (
      <span className="danger-text">out of date</span>
    )
  ) : null;
  const showButtons = advice.needed.length > 0 && (!slim || !open);
  return (
    <section className="price-status" aria-label="IMD price">
      <Row label="IMD price">
        {usd?.value ? dollars(usd.value) : "—"}
        {price?.updated ? ` · ${age(price.updated, now)} · ` : " · never updated"}
        {freshness}
        {market ? ` · market ${dollars(market.imdUsd)}${diff ? `, ${diff}` : ""}` : " · market unreadable"}
      </Row>
      {headline && (
        <p className={`price-status-line${advice.warning ? " danger-text" : ""}`}>
          {headline}
          {all.length > 1 && <Info label="What an update does" text={all.join(" ")} />}
        </p>
      )}
      {showButtons && (
        <div className="price-status-actions">
          {advice.needed.map((feed) => (
            <BuyUpdate
              key={feed}
              r={r}
              s={s}
              feed={feed}
              actions={actions}
              label={LABELS[feed]}
              idPrefix={`price-status-${where}`}
            />
          ))}
        </div>
      )}
    </section>
  );
}
