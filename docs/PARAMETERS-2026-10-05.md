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

- **Treasury, on a fall.** `OracleAsker.ask` pays when IMD's pool has FALLEN more than a quarter of a
  feed's deviation cap (5% at a 20% cap) below the feed, armed and still present five blocks later.
  Never for a rise (decided 2026-10-06). Cost scales with volatility; a crash triggers it.
- **Treasury, to keep NHI alive.** NHI moves slowly and is daily; staleness asks apply to it alone
  (`keepAlive`).
- **Treasury, when a feed's allowance has widened.** A feed's allowance grows the longer it is stale
  (below). Once it reaches `WIDE_ALLOWANCE_BPS` (60%), the Treasury refreshes the feed whatever its
  policy, once, while it has been silent a whole lifetime: the honest value lands first and closes the
  epoch behind it, so a single purchase cannot then re-anchor the price far from the market. Only a
  price feed silent for ten hours (NHI: 33) triggers it.
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

### The per-epoch deviation bound SHIPS, widening with staleness — decided 2026-10-07

On 2026-10-06 the per-epoch bound was built and parked (branch `feat/epoch-bound`): the chained walk it
closes looked uneconomic at launch parameters. The final pre-launch review
(`docs/AUDIT-FINAL-2026-10-07.md`) corrected both halves of that call, and the bound now ships.

**What the review showed.** (1) The never-widening stale bound from `ce39fc6` could not follow a
single-step market move larger than itself: the pinned recipes read the pool and a step has no
intermediate medians, so after one gap over 40% every honest attestation was refused for ever and every
vault pinned to the feed halted for good (high). (2) The walk's cost model counted seven round trips per
rung; one ramp-and-hold does it in a single round trip — push the pool 20% a block for six blocks, hold
3.48x for 150 blocks (about 30 minutes), and six windows ending one block apart have their CENTRE sample,
which is the median, at each rung. About $39k of pool fees against $300k–$500k of gain at the $1M line,
with only the attacker's exposure to holders selling into a 3.5x pump standing in the way (medium). The
per-epoch bound slows that walk to one step an hour. (3) The second-half review
(`docs/AUDIT-FINAL-2-2026-10-07.md`, medium) then showed the step was 40%, not 20%: with the stale base
applying one second past the lifetime, a buyer relaying each step an hour and a second after the last
opened every epoch on a stale anchor and compounded at 1.4 an hour, 3.84x in three hours. The stale base is
now earned by a whole hour of silence past the lifetime (`_allowanceNow`), so a feed anyone keeps alive
moves at most the cap, 20%, per hour.

**What ships (`SwarmFeed`).** Every value accepted within one lifetime of an epoch's start must lie
within the epoch's allowance of the ANCHOR, the value the feed held when the epoch opened. The allowance
is the cap (20%) when that value was fresh and through the first hour it is stale; after a whole hour
of staleness, twice the cap, widening by an eighth of the cap for every further HOUR of silence
(`STALE_GROWTH_PERIOD`, whatever the feed's lifetime): for the one-hour price feeds 20% through the
second hour of silence, 40% after two hours, 45% after four, 50% after six, 60% after ten, 100% after
twenty-six, capped at 100x; for the one-day NHI feed the same steps a day later (40% at 25 hours, 50% at
29, 60% at 33). A genuine gap is therefore a delay of a few hours, not a halt; a far re-anchor costs an
attacker those same hours of silence. An epoch opened that wide closes behind its first value: every
later value in it must also sit within the cap of that first one (`_epochFirst`), so whoever lands first
after a silence gets the stale allowance and nobody after them does.

**The walk, at the committed constants.** A run of steps compounds at the cap per hour after the first
step, whose size is whatever the silence before it bought: from a fresh feed 1.2 an epoch (2x in four
steps, three hours; 3.58x in seven, six hours, 3.48x falling between the sixth and seventh); from a feed
two hours silent 1.4 then 1.2 an hour (3.48x in six steps, five hours); from a feed ten hours silent the first step is 60%, racing the Treasury's
refresh, and then 1.2 an hour. Each hour of it is a pool held at the rung for the whole hour (one
ramp-and-hold round trip, about $40k in fees to 3.48x) with the attacker's position exposed to every
holder selling into it. `test_relayingAnHourApartNeverEarnsTheStaleBase` pins the rate. Silence is
measured from the later of a value's signature and its relay: measured from the signature, an attestation
held back 55 minutes before relaying arrived an hour old and the next step 65 minutes later earned the
stale base, 1.4 per ~65 minutes (final panel audit, oracle, medium);
`test_aHeldAttestationDoesNotEarnTheStaleBase` pins that.

What the delay costs (review of cc4103f, 2026-10-07; one hour longer since the second-half review, the
price of the rate above). While a feed cannot follow, it goes stale and the vault refuses price actions,
liquidations included. Hours from the feed's last accepted value until a value at the new level is
accepted:

| Move the market makes in one step | Price/spot feeds (1-hour life) | NHI (1-day life) |
|---|---|---|
| up to 20% | at once (fresh cap) | at once |
| 40% | 2 | 25 |
| 45% fall | 4 | 27 |
| 50% | 6 | 29 |
| 70% fall | 14 | 37 |
| 100% rise | 26 | 49 |

During a crash larger than 40% that is hours with no liquidation, so the positions it reaches are
liquidated late and some bad debt is the price of not accepting a single far value at once. That is the
trade this bound makes on purpose: a halt for good was the alternative, an instant re-anchor the attack.

**And the refresh that closes the silence (`OracleAsker`).** Once a feed silent for a whole lifetime
has an allowance of `WIDE_ALLOWANCE_BPS` (60%, ten silent hours for a price feed, 33 for NHI), the
Treasury refreshes it whatever its trigger policy, so no accepted value can sit more than 60% from the
anchor — below the 1.7x (`mat`) at which a single-shot re-anchor would pay — and once the honest value
lands, the rest of that epoch is held to the cap around it. `wideOpen` requires the value to be stale
AND no epoch to be live, so the refresh is bought once per silence: reading the epoch's stored allowance
alone kept it true for the hour after the refresh and let anyone make the Treasury pay every ten minutes,
about 14 of the 15 IMD a day in a quiet market (review of cc4103f); staleness alone, which runs from the
signed issue time rather than the relay, reopened it for the gap between the two, one more purchase per
silence (second-half review, low). In a dead market that is at most about two refreshes per price feed
per day; in a moving one the fall trigger refreshes first and it never fires. The keeper does the same for the primary
with its own IMD while the Treasury cannot pay.

**Revisit rule, restated.** Raising `line` no longer changes the walk's speed, only its prize; the hold
model above is the one to re-run before any `proposeLine`, and the epoch bound is what keeps the answer
"five hours in the open".

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

### At the freeze — 2026-10-10

Every value above ships unchanged in the deploy commit (`release/mainnet` `9e37405`, tag
`mainnet-freeze-2026-10-10c`). Two things this record predates:

- **The redemption fee base.** The analysis above divides by supply; the shipped fee divides by the *fee
  base*, the supply as paced (following the live supply by at most 10% an hour) and never less than
  100,000 imdUSD (`CDPVault._feeBase`), so a small supply right after launch cannot set everyone's fee at the cap.
- **Requests that end without an answer.** `OracleAsker` buys through Intake v2
  (`0xa43e6F75ee006411F79Ac1C84120606C2330DE82`) with `requestWithFailure`. A request the plane refuses
  (status 1) or that ends without a result (status 2) calls `onOracleFailure` at once: the feed's in-flight
  slot clears then rather than at `ASK_TIMEOUT`, `AskFailed` is emitted, and, because a failed request is
  not refunded, the Treasury's own purchase of that feed backs off for `ASK_TIMEOUT` as after a refused relay.
  Record: `docs/AUDIT-INTERNAL-2026-10-10-INTAKE-V2.md`.
