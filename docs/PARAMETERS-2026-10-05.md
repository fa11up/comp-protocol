# Launch parameters — decided 2026-10-05

The liquidation bonus, its split, the collateral-ratio floor and the price lifetimes, decided together
because each one moves the others. Inputs are IMD's own market, read from chain and from the POOL4 docs
(pool4.imd.fun/docs), and the deployment-parameter research (`RESEARCH-PARAMS-2026-10-04.md`).

## Decisions

| Parameter | Was | Now | Where |
|---|---|---|---|
| Liquidation bonus `CHOP_PERCENT` | 10% | **20%** | `CDPVault.sol` |
| Protocol share of the bonus `CUT_BPS` | 3333 | **1000** | `DeploymentConfig.sol` (governed after launch) |
| Marker share `CHIP_BPS` | 1000 | 1000 | unchanged |
| `mat` at NHI ≥ 0.85 | 150% | **170%** | `CDPVault._mat` |
| `mat` at NHI ≤ 0.60 | 200% | 200% | unchanged; linear between |
| Grace `lull` | 0–6 h | 0–6 h | unchanged (user's call: keep 6 h, raise the floor) |
| Primary price max age | 24 h | **1 h** | `PRICE_MAX_AGE` |
| Spot price max age | 1 h | 1 h | `SPOT_MAX_AGE` |
| NHI max age | 24 h | 24 h | `NHI_MAX_AGE` |
| Price updates | clock | **on demand** | `OracleAsker` |

A liquidator who did not mark the position keeps 16% of the debt repaid; the marker gets 2%, the
protocol 2%. The borrower's cost of being liquidated doubles, from 10% to 20% of the debt repaid.
`tail()`, the window after grace in which a mark stays usable, is the shorter of the price and NHI
lifetimes, so it becomes one hour.

## How updates are paid for

The protocol does not keep prices fresh on a clock. At one update per hour per feed, at $4.25 each,
that would cost about $37,000 a year per feed; at a ten-minute lifetime it would be about $298,000.

- **Treasury, on price movement.** `OracleAsker.ask` pays when IMD's pool has drifted more than half a
  feed's deviation bound from it, armed and still present a few blocks later. Cost scales with
  volatility; a crash triggers it.
- **Treasury, to keep NHI alive.** NHI moves slowly and is daily; staleness asks apply to it alone
  (`keepAlive`).
- **Anyone, with their own IMD.** `OracleAsker.askPaid(feed, body, maxPrice)` buys an update for any
  feed at any time, with no need check, because no protocol money is spent. A borrower who finds the
  price stale pays about $4.25 instead of waiting.

Between updates, price-dependent actions (borrowing, withdrawing against debt, marking, liquidating,
redeeming) pause. Positions are never priced off a stale figure.

## Inputs

**The market (read 2026-10-05).** A full-range ETH/IMD Uniswap v4 pool with a 1% fee; the POOL4 hook is
the only LP, and its ownership is renounced (the sIMD vault's `owner()` reads zero, verified on chain).
In range: **841 ETH + 207,881 IMD**, IMD **$10.92**, about **$2.27M per side**.

- A single sell of 42,089 IMD (~$460k) moves the price −30.84%, the worst day observed.
- After a sell, IMD above the pool's inventory cap is trimmed by removing liquidity on both sides. The
  price does not move, but the pool gets thinner, so back-to-back sales meet less depth, not more.
- An ETH-only buy wall sits below the price and softens a fall. It is left out of these numbers, so
  they are conservative.
- sIMD: 1 sIMD = 7.95 IMD; 1.72M IMD staked. Unstaking has a one-block hold.

**One real attestation** (`e2c85027`): 2m10s from payment to signature; the observation window closed
3.5 minutes before signing; the primary is a 2-hour median, so its content is about an hour behind.
Feed age is counted from `issuedAt`, the signing time.

## The arithmetic

**Liquidator.** Repaying debt `D` returns collateral worth `D·(1 + b·(1 − chip − cut))` at the oracle
price, sold into the pool. A single sale of `q` IMD loses `1 − (1 − fee)·Y / (Y + (1 − fee)·q)` against the
pre-sale price.

| Debt repaid | Sale loss | Liquidator's net (20% / 10%) |
|---|---|---|
| $50k | 3.4% | +12.0% |
| $100k | 5.8% | +9.3% |
| $250k | 12.1% | +2.0% |
| $293k | 13.8% | 0 |
| $500k | 21.0% | −8.3% |

One liquidation is profitable up to about $293k of debt. Larger positions are liquidated in parts.

**Floor.** A marked position must still cover debt plus the bonus after the price falls over the
horizon (max age + ~1 h median lag + grace + ~5 min to unstake and sell), and after the liquidator's
sale: `mat ≥ 100·(1 + b) / ((1 − fall)·(1 − sale loss))`. The fall is the worst observed day,
−30.84%, scaled by the square root of time — **an assumption, not a measurement**.

| NHI | Grace | Needed ($293k sale) | Curve now |
|---|---|---|---|
| ≥ 0.85 | 6.0 h | 170% | **170%** |
| 0.80 | 4.8 h | 167% | 176% |
| 0.75 | 3.6 h | 164% | 182% |
| 0.70 | 2.4 h | 161% | 189% |
| 0.60 | 0 h | 153% | 200% |

Grace is longest when the network is healthy, which is exactly where the floor applies, so the floor is
what had to rise. Each extra hour of grace costs about two points of `mat`.

**Lifetime.** With a 20% bonus and 6 hours of grace, the floor needed (before sale loss) is 185% at a
24-hour lifetime, 146% at one hour and 144% at ten minutes. One hour keeps almost all of the safety of
ten minutes at a sixth of the cost of keeping it fresh.

## Not changed, worth a look

- `ETH_USD_MAX_AGE` is still one day. Chainlink's mainnet ETH/USD heartbeat is one hour with a 0.5%
  deviation trigger, so a tighter bound (two hours) would match the one-hour IMD price.
- The research report's redemption divisor (4 → 2) and stability fee (200 → 1000 bps) are still open.
- The terminal has no "buy an update" button for `askPaid` yet.
