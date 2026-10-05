#!/usr/bin/env python3
"""Oracle guard simulation over IMD's real price history (GeckoTerminal 1-minute candles, IMD/ETH).

Model (per OracleAsker + SwarmFeed + vault, DeploymentConfig as of 2026-10-05):
  - PRICE feed = median of 13 samples over the 2h before the request; SPOT = pool at the request.
  - An update is bought as a PAIR (price + spot), 2 attestations, 0.5 IMD each.
  - Drift trigger: pool vs the SPOT feed value beyond `trig` (fraction of cap) -> arm, land LAG min later.
    Asymmetric variant: separate trigger for falls (pool below feed) and rises.
  - At most one pair in flight; >= 10 min between Treasury asks.
  - Landing: if the current value is still fresh (age < maxAge) and the new value moves more than
    `cap`, it is REFUSED (paid, value unchanged). If stale, accepted at any level.
  - Optional keep-alive: re-buy when age > 75% of maxAge.
  - Vault usable for price actions iff price and spot fresh and |price-spot| <= 5% of price.
Metrics: attestations/day, share of time usable, refusals, and MISPRICING while usable:
  over = feed price above pool (collateral over-valued: over-borrowing, late liquidation) — the dangerous side
  under = feed price below pool (collateral under-valued: borrowers constrained) — costs only UX
"""
import json, statistics, sys
from itertools import product

d = json.load(open(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].endswith(".json") else "gt_minute.json"))
d.sort(key=lambda r: r[0])
t0, t1 = d[0][0] // 60, d[-1][0] // 60
close = {r[0] // 60: r[4] for r in d}
P, last = [], d[0][4]
for m in range(t0, t1 + 1):  # forward-fill minutes with no trade
    last = close.get(m, last)
    P.append(last)
N = len(P)
DAYS = N / 1440
LAG = 4  # 1 min arming (5 blocks) + ~3 min request -> signature
SKEW = 0.05


def median2h(i):
    lo = max(0, i - 120)
    xs = [P[lo + k * (i - lo) // 12] for k in range(13)]
    return statistics.median(xs)


def run(cap, trig_down, trig_up, max_age, keep_alive):
    price = spot = None
    upd = -10**9
    inflight = None  # landing minute
    last_ask = -10**9
    asks = refused = usable = 0
    over = []
    under = []
    for i in range(N):
        p = P[i]
        if inflight is not None and i >= inflight:
            inflight = None
            new_price, new_spot = median2h(i - LAG), P[i - LAG]
            fresh = i - upd < max_age
            if price is not None and fresh and (abs(new_price - price) > cap * price or abs(new_spot - spot) > cap * spot):
                refused += 1
            else:
                price, spot, upd = new_price, new_spot, i - LAG
        need = False
        if price is None:
            need = True
        else:
            gap = (p - spot) / spot
            if gap < -trig_down or gap > trig_up:
                need = True
            if keep_alive and i - upd > 0.75 * max_age:
                need = True
        if need and inflight is None and i - last_ask >= 10:
            inflight, last_ask = i + LAG, i
            asks += 2
        fresh = price is not None and i - upd < max_age
        if fresh and abs(price - spot) <= SKEW * price:
            usable += 1
            over.append(price / p - 1) if price > p else under.append(1 - price / p)
    pct = lambda xs, q: sorted(xs)[int(q * (len(xs) - 1))] if xs else 0
    return dict(
        att_day=asks / DAYS, imd_day=asks * 0.5 / DAYS, usable=usable / N, refused=refused,
        over_max=max(over, default=0), over_p99=pct(over, 0.99), under_max=max(under, default=0),
    )


def vol():
    out = {}
    for name, h in [("10m", 10), ("1h", 60), ("2h", 120), ("6h", 360), ("24h", 1440)]:
        mv = [P[i + h] / P[i] - 1 for i in range(0, N - h, 5)]
        a = sorted(abs(x) for x in mv)
        out[name] = dict(
            p50=a[len(a) // 2], p95=a[int(.95 * len(a))], p99=a[int(.99 * len(a))],
            max_up=max(mv), max_down=min(mv),
            gt10=sum(x > .10 for x in a) / len(a), gt20=sum(x > .20 for x in a) / len(a),
            falls_gt10=sum(x < -.10 for x in mv) / len(mv),
        )
    return out


if __name__ == "__main__":
    print(f"history: {N} minutes = {DAYS:.1f} days, price {P[0]:.6f} -> {P[-1]:.6f} ETH/IMD ({P[-1]/P[0]:.1f}x)")
    for k, v in vol().items():
        print(f"  {k:>4}: |move| p50 {v['p50']:.2%} p95 {v['p95']:.2%} p99 {v['p99']:.2%}  max up {v['max_up']:+.1%} max down {v['max_down']:+.1%}"
              f"  >10% {v['gt10']:.1%}  >20% {v['gt20']:.1%}  falls>10% {v['falls_gt10']:.1%}")
    rows = []
    for cap, tf, age, ka in product([0.10, 0.15, 0.20, 0.25, 0.30, 0.50], [0.25, 0.5, 0.75], [60, 120, 240], [False, True]):
        r = run(cap, cap * tf, cap * tf, age, ka)
        rows.append(((cap, tf, tf, age, ka), r))
    for cap, td, tu, age in product([0.20, 0.30], [0.25, 0.5], [0.5, 1.0, 1.5], [60]):
        if td == tu:
            continue
        rows.append(((cap, td, tu, age, False), run(cap, cap * td, cap * tu, age, False)))
    print("\ncap  trig(dn/up)  maxAge keepAlive | att/day  IMD/day  usable  refused | over max  over p99  under max")
    for (cap, td, tu, age, ka), r in rows:
        print(f"{cap:4.0%}  {td:.2f}/{tu:.2f}  {age:4d}m  {str(ka):5} | {r['att_day']:7.1f} {r['imd_day']:7.1f}  {r['usable']:6.1%} {r['refused']:7d} |"
              f" {r['over_max']:8.1%} {r['over_p99']:8.2%} {r['under_max']:9.1%}")
