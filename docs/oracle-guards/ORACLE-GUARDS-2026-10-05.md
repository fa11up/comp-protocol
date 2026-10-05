# Oracle guards — measured on IMD's own history (2026-10-05)

**Question.** Two guards protect the price: the on-chain deviation cap (`maxDeviationBps`, refuses a jump
larger than the cap while the current value is fresh) and the trigger that decides when an update is
bought (`OracleAsker`, today half the cap, symmetric; the keeper drives it). Chainlink's 0.5% / 1h
cadence is out of reach at ~0.5 IMD an attestation. What should ours be, for a token that is very
volatile and mostly moving up?

**Data.** GeckoTerminal 1-minute candles for the IMD/ETH v4 pool (`fetch_gt.py`, no key), 17 Aug –
5 Oct 2026: 49.7 days, forward-filled to 71,532 minutes. IMD went from 0.000387 to 0.004666 ETH,
**12x**. Seven weeks of one regime — a strong uptrend — so the falls below are a small sample.

**Model** (`simulate.py`, re-runnable): updates are bought as a pair (PRICE = 2h median of 13 samples,
SPOT = pool at request), 2 attestations x 0.5 IMD; landing 4 minutes after the trigger (5-block arm +
signing); ≥10 minutes between Treasury asks; a fresh value refuses a move beyond the cap; the vault is
usable only while both are fresh and within 5% of each other. "Over" = the feed values collateral ABOVE
the pool — the dangerous side (over-borrowing, late liquidation). "Under" costs only borrowing room.

## Volatility

| horizon | median move | p95 | p99 | max up | max down | share of windows moving >10% | falls >10% |
|---|---|---|---|---|---|---|---|
| 10 min | 0.6% | 3.6% | 7.0% | +52% | −18.5% | 0.3% | 0.1% |
| 1 h | 2.1% | 8.5% | 14.1% | +54% | −24.5% | 3.1% | 0.8% |
| 2 h | 2.9% | 11.3% | 20.9% | +66% | −19.7% | 7.2% | 2.3% |
| 24 h | 11.3% | 49.7% | 80.3% | +132% | −43% | 55% | 22% |

Up-moves are about three times as large and as frequent as down-moves at every horizon.

## Results (full grids in `sim-out.txt`, `sim-asym.txt`, `sim-daily.txt`)

| setting | IMD/day (median / p95 / max) | usable | refused / 50 d | over, max | over, p99 |
|---|---|---|---|---|---|
| **current:** cap 20%, trigger 10% both ways, 1h, no clock | 3.0 / 11 / 12 | 5% | 5 | **21.0%** | 9.7% |
| cap 20%, trigger 5% on falls / 20% on rises, 1h, no clock | 2.0 / 11 / 15 | 5% | 17 | 11.3% | 8.3% |
| **BUILT:** cap 20%, trigger **5% on falls, never on rises**, 1h, no clock | **2.2 mean** | 3% | **6** | **9.0%** | 8.1% |
| symmetric 5% both ways, 1h | 11.1 mean | 18% | 5 | 18.7% | 9.7% |
| recommended + clock keep-alive, 4h maxAge | 10 / 32 / 33 | 75% | 160 | 15.6% | 8.6% |
| recommended + clock keep-alive, 1h maxAge | ~33 mean | 86% | 24 | 12.8% | 7.5% |

What the table says:

1. **The clock, not the trigger, is the cost.** Keeping prices fresh around the clock costs 10–33
   IMD/day (~$115–380); buying on movement alone costs a median 2–3. The protocol is on-demand by
   design: between updates price actions pause (a user or the keeper buys a fresh pair, ~$12, with
   "Buy update" / `askPaid`), they are never mispriced. Keep it that way at launch.
2. **An asymmetric trigger is strictly better, not a trade-off.** Tight on falls (5%), loose on rises
   (20%) halves the worst over-valuation (21% → 11.3%) at a LOWER median cost than today's symmetric
   10%. A rally under-values collateral, which only limits borrowing; a fall over-values it, which is
   the risk. Paying for falls and not for rises is the right shape for a token going mostly up.
3. **The cap is not the binding guard.** At 20–25% only 5–17 updates in 50 days were refused, and
   nearly all landing values arrive after a stale period, where the cap does not apply. Keep **2000**:
   lower caps multiply refusals (10% → 36–222) without improving the dangerous side.
4. **The 2h median protects falls by itself.** After a sharp fall the PRICE median lags SPOT by more than
   the 5% skew bound, and the vault pauses rather than lend against the stale median. That interplay is
   why worst over-valuation stays near the trigger even in an 18% ten-minute drop.
5. **Margin.** 11.3% worst over-valuation against a 70% buffer (mat 170) and a 20% bonus: a position
   exactly at mat is really at ~151% in the worst case observed — under-incentivised liquidation at
   worst, not bad debt. Bad debt needs a ~41% over-valuation.

## Recommendation

| knob | value | change |
|---|---|---|
| `maxDeviationBps` (deploy script) | **2000** | none |
| Treasury trigger on a FALL (pool below feed) | **5%** (¼ of cap) | **OracleAsker: split `_triggerBps` into down/up** |
| Treasury trigger on a RISE | **none** — a rise past the cap on a fresh feed is refused anyway, so paying for rises bought only refusals (17 vs 6 in 50 days) and a worse worst case (11.3% vs 9.0%) | same change |
| PRICE/SPOT `maxAge` | **1 h**, no clock keep-alive | none |
| NHI | daily, kept alive by the Treasury (≈1 IMD/day) | none |
| `ORACLE_BUDGET_PER_DAY` | **15 IMD** (worst simulated day; exceeding it only defers asks) | 10 → 15 |
| Keeper `ASK_PAID_IMD_PER_DAY` | **5 IMD** once there is debt (2–3 pairs to unlock a liquidation) | config only |

The asker change is small (two trigger constants instead of `maxDeviationBps / 2`) but it is a contract
change, so it belongs in the scoped pre-deploy review. Revisit after a month of mainnet data: one
uptrend regime is not a distribution, and a sustained drawdown would move every number here.

**Decided and built (2026-10-05):** `DRIFT_FALL_TRIGGER_OF_CAP_BPS = 2500`, `DRIFT_RISE_TRIGGER_OF_CAP_BPS = 0`
(never), `ORACLE_BUDGET_PER_DAY = 15 IMD`; `OracleAsker.triggerBps(feed)` exposes both, and the keeper reads it.

## Can the change be used to drain the Treasury? (reviewed 2026-10-05)

Every path by which Treasury IMD can leave for oracle updates, and what the asymmetric trigger does to it:

| # | guard (where) | what it bounds | effect of the change |
|---|---|---|---|
| 1 | Daily budget — `Treasury.fundOracle` caps what it sends per UTC day at `Parameters.oracleBudget` (`oracleSpent`) | **the hard ceiling on Treasury loss, whatever anyone does** | raised 10 → 15 IMD/day (~$134 → ~$201 at today's price) |
| 2 | Top-up, never pile-up — `fundOracle` sends at most `budget − asker balance` | the asker never holds more than one day's budget | none |
| 3 | Fixed destination — `fundOracle` pays only `ORACLE_ASKER`, a source constant; the asker has no withdraw function and approves the Intake for exactly one request's price, then resets to zero | IMD can only leave the asker as a payment for one of our three questions | none |
| 4 | Pinned bodies — `ask` takes only the body whose keccak the asker pins per feed (`WrongBody`) | Treasury money buys only our feeds' questions | none |
| 5 | Need check — `ask` pays only for (a) NHI near stale (keep-alive) or (b) an IMD/ETH feed whose drift was armed ≥5 and ≤100 blocks earlier and is still present | nobody can make the Treasury pay for a feed that does not need it | **(b) narrowed to falls only.** Rises can no longer trigger Treasury spend at all; a fall must exceed 5% instead of 10%. |
| 6 | Arming delay — the drift must persist ≥5 blocks, so a push-and-restore inside one transaction cannot trigger | flash-loan manipulation | none (still accepted: two pushes 5 blocks apart can, audit D4) |
| 7 | One request in flight per feed (2h timeout) and ≥10 minutes between Treasury asks per feed, backing off to 2h after a refused delivery | rate per feed | none |
| 8 | Price ceiling — `ASK_MAX_PRICE` 1 IMD per request (the Intake's price is the dev's) | a mispriced Intake cannot take more per request | none |
| 9 | `askPaid` pulls the caller's own IMD first, has no need check and is not budgeted | no Treasury money at all | none |
| 10 | NHI keep-alive needs a value 75% of the way to its 1-day `maxAge` | nobody can age a feed faster | none |

**What an attacker can do now.** Force Treasury-paid price+spot updates by pushing IMD's pool down 5% and
holding it (or pushing twice) across ≥5 blocks. At today's pool (~207,881 IMD side, 1% fee) that is
~5,400 IMD (~$72k) per push and ~$2,900 in fees for one forced pair, against 1 IMD (~$13) of Treasury
spend: **~216:1 against the attacker**, down from ~450:1 under the old 10% symmetric trigger, because a
smaller push suffices. The attack earns nothing — the attestations are honest — so it is pure griefing,
and it cannot exceed guard 1: at most 15 IMD a day, however much the attacker spends. A pushed SPOT value
can pause the vault (it then disagrees with the 2h PRICE median past the 5% skew bound); it cannot
misprice collateral, which is valued from PRICE.

**Net.** The ceiling is unchanged in kind (guard 1) and higher in size (15 vs 10 IMD/day, a deliberate
choice from the history). Per-update griefing got cheaper by half but stays two orders of magnitude
uneconomic, and the whole upward direction stopped being a trigger.
