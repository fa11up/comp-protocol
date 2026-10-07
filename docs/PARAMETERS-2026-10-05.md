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
| Redemption fee divisor | 4 | **2** | `Parameters.redemptionDivisor`, governed 1–8 |
| Stability fee `duty` | 200 bps | **444 bps** | `DUTY_BPS` (governed, 0–1000) |
| Debt ceiling `line` | unlimited | **$1M** | `LINE` (governed) |
| ETH/USD max age | 24 h | **2 h** | `ETH_USD_MAX_AGE`: Chainlink's hourly heartbeat plus one missed round |
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

- The redemption divisor and the stability fee: analysed below. DECIDED 2026-10-05 (`223c66a`): divisor
  **2** (the user's call, overruling the "keep 4" recommendation below — a run on the reserve is slowed
  harder, at the cost of a slightly wider peg band only while a run is under way), stability fee **444 bps**.
- The debt ceiling `line` starts at **$1M** (same commit). The pool absorbs about $290k per profitable
  liquidation. See "Final confirmation" below for why raising it is a safety decision, not just a growth one.

## Treasury exits (decided 2026-10-05)

- **Bad debt first.** `cover(owner, amount)` lets anyone burn the Treasury's imdUSD against a drained
  position's realized bad debt, through the ordinary repayment path.
- **Reserve protected.** The operator's `withdraw` refuses the collateral (sIMD, which pays redemptions
  first) and every listed reserve asset; removing backing requires a delisting behind the timelock.
  imdUSD may be withdrawn (governors run LP directly) but never below outstanding `totalBadDebt`.
- **Capped stream.** `payStream()` pays a governed payee up to `streamPerDay` imdUSD per UTC day, hard
  cap 500 a day; off at launch. It also never dips below outstanding bad debt.

## Analysis: the redemption fee divisor

A redemption's fee is `0.5% + min(base + redeemed ÷ supply ÷ divisor, 4.5%)`, where `base` remembers
recent redemptions and halves every 12 hours. The divisor sets how fast the fee climbs during a run.

| Redeemed at once (calm start) | divisor 2 | divisor 4 (now) |
|---|---|---|
| 1% of supply | 1.00% | 0.75% |
| 5% | 3.00% | 1.75% |
| 10% | 5.00% | 3.00% |

A lower divisor protects the positions being redeemed against and slows a run; a higher one keeps the
peg floor tighter, because redeemers keep arbitraging at a lower fee (imdUSD can sit at about
$1 × (1 − fee) − 1.5% before they step in). Liquity uses 2 because it redeems against every borrower.
Here redemption only reaches the reserve and positions already within `gap` of `mat`, and a
candidate's ratio may not worsen, so borrowers need less protection. Recommendation at the time: keep 4.
**Decided 2026-10-05: 2** (`223c66a`), reconfirmed 2026-10-06.

## Analysis: the stability fee

The research's 10% was sized to pay for clock-driven oracle updates (~$37k a year per feed). On-demand
pricing removed that: the Treasury's own oracle bill is about $2,100 a year (NHI kept alive) plus rare
25%-move asks. Stability fees are also minted as imdUSD, while the oracle is paid in IMD from the
protocol's liquidation share, so the fee was never what paid the oracle.

What the fee is for, then: a risk premium for bad debt (which scales with debt against the pool's
depth), protocol revenue, and the peg lever (raise it if imdUSD trades below $1, lower it above). It is
governed between 0 and 10% behind the 48-hour timelock, so the launch value is a starting point.

| Debt | 2% | 4% | 6% | 10% |
|---|---|---|---|---|
| $250k | $5k | $10k | $15k | $25k |
| $1M | $20k | $40k | $60k | $100k |
| $3M | $60k | $120k | $180k | $300k |

sIMD collateral earns about 1.8% a year (the staking drip's cap over 1.72M IMD staked), so a borrower's
net carry is the fee minus 1.8 points. **Recommendation: launch at 4%**, revisit with real debt and peg
data.

## Final confirmation (2026-10-06)

Every value in the Decisions table above, plus the oracle and Treasury settings in
`src/DeploymentConfig.sol` (`ORACLE_BUDGET_PER_DAY` 15 IMD, `ASK_MAX_PRICE` 1 IMD, fall trigger 5%, no rise
trigger, NHI keep-alive at 75% of its lifetime, `ASK_MIN_INTERVAL` 10 min, `ASK_TIMEOUT` 2 h) and the feed
deviation cap of 2,000 bps (`script/DeployMainnet.s.sol`), was walked through and confirmed by the operator
on 2026-10-06 as the launch set. Minting from work ships OFF (`WAGE_WAD` 0); the founder stream ships off.

### No rolling (per-epoch) deviation bound — decided 2026-10-06

The bound stays per attestation: 20% from the last accepted value, 40% once that value is older than the
feed's lifetime (`SwarmFeed.STALE_DEVIATION_MULTIPLE`). A per-epoch variant — every value accepted within
one lifetime measured against the value the feed held when the hour began — was built and tested
(branch `feat/epoch-bound`) and deliberately NOT shipped.

What it would have closed: six attestations bought over an hour and relayed in one block walk a 20% cap
from 1.0 to 3.48. What that attack costs at launch parameters: the primary feed is the median of 13 samples
across a 2-hour window, so each 20% rung needs the pool (841 ETH + 207,881 IMD, 1% fee, full range) pushed
at 7 sampled blocks and unpushed after each. Round-trip fees alone: about $58k for the 1.4x stale step
(which exists with or without the epoch bound), then $93k, $130k, $174k, $221k and $273k per rung — about
$950k for the full walk — with real ETH held across block boundaries, not a flash loan. The gain only begins
above 1.7x (`mat`) and is capped by `line` at $1M: at most ~$150k at 2.0x, ~$510k at 3.48x. Negative at
every rung. The window-recency rule (`WindowTooOld`, `WindowNotAdvancing`) already makes the chain hard to
assemble; the epoch bound would only have made it slow as well.

**Revisit rule.** The arithmetic flips when the debt ceiling grows relative to the pool: at today's depth a
$5M line makes the 3.48x walk worth ~$2.5M against ~$950k of fees. Any `proposeLine` above roughly HALF the
pool's depth (about $2M today) must re-run this arithmetic first, and ship the epoch bound (a feed redeploy)
if it no longer holds. This is the one safety condition attached to raising `line`.

### The keeper and the oracle — decided 2026-10-06

The Treasury pays for falls only. The keeper buys an update with its own IMD only as the Treasury's fallback:
a fall past the trigger, armed and still present five blocks later, when the asker cannot cover one update
even after `fundOracle`. Never for a rise, never to refresh a quiet stale price. Capped at **2 IMD per UTC
day** (`ASK_PAID_IMD_PER_DAY`, shared with the liquidation loop's buy-a-price step). Once the Treasury carries
the oracle, `KEEPER_ORACLE_FALLBACK = false` makes the keeper liquidation-only.

### Minting from work — deferred without blocking

The vault knows only `IWorkOracle` (rights in imdUSD units). The wage is 0 at launch and
`Parameters.proposeWorkOracle` can replace the oracle wholesale while it stays 0, so the pay-per-job-type
design (a governed tariff per skill with a default for skills that do not exist yet) is a later deployment,
not a launch decision. Its one dependency is evidence that carries the job type: an upstream per-skill leaf
in the daily receipt (the same shape as the agent tally already merged in PR #332).
