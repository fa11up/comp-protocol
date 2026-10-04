# Risk parameters for the sIMD-backed USD stablecoin

Research date: 2026-10-04. Figures describing IMD, its vault, its market and the present system are supplied by the assignment, not independently verified. Recommendations below are engineering judgments, not measurements of this pool's capacity. Sources are linked individually; on-chain observations are attached as JSON.

**The most dangerous current value is the 24-hour collateral-price staleness allowance, especially combined with six hours of liquidation grace.** It permits borrowing and collateral withdrawal against a price that can be materially above realizable value, then delays recovery. A 20% update rejection cap and a 5% spot disagreement halt can also trap the system outside its operating band. Raising the bonus or stability fee cannot repair either failure.

| Question | Recommended starting figure | Direction from present values |
|---|---|---|
| 1. Liquidation bonus | **20% gross of debt repaid**, initially **18% to executor**, **2% to flagger**, **0% to protocol** | Increase gross bonus and executor compensation; conditional on executable sale sizes |
| 2. Minimum collateral ratio | **300%** liquidation MCR; **350%** minimum for new borrowing; **0-hour grace** | Increase substantially; do not relax to 150% in good health |
| 3. Protocol cut | **0% initially**; at most **10% of the bonus** after demonstrated competition | Reduce from 33.33%; measure participation before introducing a cut |
| 4. Oracle | **5-minute maximum age** for collateral attestations used in value-sensitive actions; **20% normal-path anomaly threshold**, not an absolute recovery ceiling; keep **5% disagreement** as an investigation trigger | Cut 24h/1h age allowances; add funded refresh and authenticated recovery; **no automatic stale-age widening** |
| 5. Fees | **1,000 bps/year** provisional stability fee; redemption **50 bps floor, 500 bps cap, divisor 2, 12h half-life** | Raise annual fee; double redemption sensitivity; retain floor, peg-friendly cap and decay provisionally |

**Deployment condition:** no additional debt until fresh-price recovery, immediate liquidation and sale-capacity checks work. A provisional 300% ratio and 20% bonus do not make an unmeasured pool safe. Start with a zero new-debt ceiling during that work, then set a small ceiling from measured stressed exit capacity, rather than from the vault's $14.9M marked value.

## Comparable protocols: published settings versus observations

A borrowing LTV and a liquidation threshold are different. The equivalent collateral ratios are `1 / borrowing LTV` and `1 / liquidation threshold`. Bonuses below are percentages of debt repaid unless stated otherwise. A borrower penalty, an auction discount and an executor reward are not interchangeable.

| Protocol / collateral | Borrowing and liquidation collateral ratios | Liquidation economics | Status and source |
|---|---|---|---|
| **Aave V3 Ethereum SNX** | Current borrowing LTV **0%**: no new borrowing capacity. LT **65%**, equivalent liquidation CR **153.85%** | **8.5%** gross bonus; protocol takes **10% of bonus**, leaving **7.65%** executor bonus | Direct contract observation, Ethereum block recorded in attached Aave snapshot. Reserve frozen. [A1–A3] |
| **Aave V3 Ethereum CRV** | Current LTV **0%**; LT **41%**, equivalent liquidation CR **243.90%** | **8.3%** gross bonus; **10% of bonus** to protocol, leaving **7.47%** | Same observation; frozen. These are liquidation settings for outstanding exposure, not an endorsement of new loans. [A1–A3] |
| **Venus BSC isolated DeFi, BSW / ANKR; GameFi, RACA** | Published deployment configuration: borrowing CF **25%**, LT **30%** → **400%** borrowing CR / **333.33%** liquidation CR | Pool incentive **1.1**, or **10%** gross; default protocol seize parameter **5% of repaid principal**, leaving **5%** executor bonus | Mainnet configuration, not current eligibility. Direct BSW check now returns CF and LT **0**, so these are historical/configured comparisons. [V1–V3] |
| **Venus BSC BabyDoge, Meme pool** | Published configuration: CF **30%**, LT **40%** → **333.33% / 250%** | **10%** gross; same **5 percentage points of principal** protocol allocation | Current observation also returns CF/LT **0**, while incentive remains 1.1 and seize parameter 0.05. Do not describe the old ratios as currently borrowable. [V1–V3] |
| **Liquity V1, ETH** | **110% MCR**, recovery boundary **150%** | Stability Pool absorbs debt and receives collateral; approximately **10%** surplus near MCR, reduced by collateral gas compensation. Initiator gets **200 LUSD + 0.5% of collateral** | Live protocol's immutable design. Deep ETH liquidity and prefunded Stability Pool make this a poor long-tail benchmark. [L1, L2] |
| **Liquity V2, wstETH / rETH** | **120% MCR**; ETH **110%** | Normal Stability Pool penalty **5%** of debt; redistribution penalties **20%** for LSTs and **10%** for ETH. Initiator: **0.0375 WETH + min(0.5% collateral, 2 collateral units)** | Documentation and constants. The 20% redistribution penalty is not a 20% cash bounty paid to an external token seller. [L5, L6] |
| **Morpho Blue, isolated markets** | LLTV is market-specific; **86%** in the documentation's example means CR **116.28%**, not a recommended long-tail limit | `LIF = min(1.15, 1/(0.3 × LLTV + 0.7))`; **15% maximum bonus**; **0% protocol liquidation fee** | Actual protocol rule, not evidence that a particular thin-token market is active at an illustrative LLTV. At LLTV 50%, bonus reaches the 15% ceiling. [M1] |

These examples show two common practices: lower LTVs and exposure caps for riskier assets, and explicit separation of borrower penalties from executor compensation. **There is no universal “long-tail bonus” or universal MCR.** In particular, neither Liquity's low ETH MCR nor Aave's SNX threshold establishes safety for a single-pool collateral with an on-demand oracle.

## 1. Is the liquidation bonus sufficient?

**Recommend 20% gross, with 18% reaching the executor, and zero grace. The current 10% headline is misleading: the executor receives only 5.667%.** On $100 repaid, the flagger receives $1, the protocol $3.333, and the executor $5.667. A person performing both roles gets $6.667, but competition should not depend on that person winning the flag race.

Let `s` be the combined loss from execution, price movement while holding collateral, unwrap cost, pool fees and MEV. Let `c` be stablecoin funding, gas, oracle expense and required profit, expressed per dollar repaid. With executor bonus `b`, participation requires:

`(1 + b) × (1 − s) ≥ 1 + c`.

Ignoring all costs and profit, the current executor bonus tolerates only **5.36%** loss (`1 − 1/1.05667`). With a **3%** funding/cost/profit allowance, it tolerates only **2.52%**. An **18%** executor bonus tolerates **15.25%** before costs, or **12.71%** with the same 3% allowance. The proposed 20% gross bonus is therefore a starting budget for roughly **10–12%** adverse execution, not insurance against a 44% crash while waiting a day.

At an assumed 10% execution loss and 3% other allowance, required executor bonus is **14.44%** (`1.03/0.90 − 1`). Retaining the flagger's 10% share of bonus requires **16.05% gross**; round upward to **20%** for uncertain execution. If stress quotes exceed the resulting loss budget, reduce debt and liquidation batch sizes; do not keep increasing bonuses against insufficient collateral.

Comparators actually range from Aave's **8.3–8.5%** gross long-tail bonuses to Morpho's **15% ceiling**, with Venus's **10%** gross substantially reduced by its protocol allocation. Liquity V2's **20%** LST redistribution penalty is the highest number here but serves a different mechanism. [A1–A3, V1–V3, M1, L5–L6] Our proposed 20% is deliberately above these ordinary executor incentives because our liquidity and oracle architecture are worse, not because 20% is industry standard.

Stablecoin inventory costs depend on its market price: buying $100 nominal debt tokens above par adds cost, while buying them below par reduces it. Flash liquidity or a prefunded stability pool could reduce inventory requirements, but availability must be demonstrated. The executor must also redeem sIMD to IMD before accessing the only pool; immediate ERC-4626 redemption, limits and fees remain unverified.

## 2. Is 150% MCR defensible?

**No. Recommend 300% liquidation MCR and 350% for opening/increasing debt, subject to the depth gate.** A protocol should choose a liquidation horizon, stress downward returns over that horizon, stress aggregate sales and disappearing LP liquidity, incorporate oracle error, and require the residual value to cover principal plus incentives.

A transparent provisional solvency calculation is:

`required CR = (1 + gross bonus) / [(1 − price fall) × (1 − sale impact) × (1 − oracle overvaluation)]`.

Use **44.6% downward stress**, **15% aggregate sale impact**, **5% oracle overvaluation**, and **20% gross incentive**:

`1.20 / (0.554 × 0.85 × 0.95) = 2.6824`, or **268.24%**.

Round to **300%**; require **350%** on new borrowing to create a buffer before liquidation. At 300%, the stressed effective collateral is **134.21% of debt**, versus 120% allocated to principal and incentives. At 150%, it is only **67.10%**. Even 200% produces **89.47%**, below principal. Conversely, a bare 150% position can lose only **33.33%** before principal is unbacked, before any liquidation incentive or sale impact.

**Assumptions, not facts:** the observed move was **up** 44.6%, not down. Reversing that exact increase is a **30.84%** fall (`1 − 1/1.446`). I use a 44.6% downward scenario as a conservative stress hypothesis, not as an observed drawdown or a statistically estimated quantile. The 15% impact and 5% error allowances are also hypotheses. A 5% agreement check does not prove prices are within 5% of true value when both readings depend on one manipulable pool.

The pool's active ticks, quote-asset reserves, fee tier, hooks, LP concentration and withdrawal behavior were not supplied. **No depth-derived optimal MCR can honestly be calculated from this brief.** A 300% recommendation is conditional, not a claim to have measured depth. Simulate simultaneous liquidation of the largest accounts and concentrated-liquidity tick crossings, including LP withdrawals, rather than using a constant-product approximation or total vault holdings as liquidity.

Set the debt ceiling so stressed proceeds from aggregate forced sales cover outstanding debt and rewards. For a quote-tested maximum liquidation notional `Q` whose impact remains within budget, an individual repaid-debt batch must be at most approximately `Q / 1.20`. Also enforce an aggregate horizon cap; splitting one enormous liquidation into transactions does not create market depth. Until this is measured, use **zero new debt**. A health index may raise ratios or freeze new debt, but should not lower this base floor when the single collateral rallies.

The wrapper's monotone **0.027% daily yield** does not protect against underlying price loss: it is approximately **0.00675% over six hours**, negligible here. Price one whole sIMD via the vault's actual asset conversion, respecting **24 share decimals / 18 asset decimals**, then multiply IMD/ETH by synchronized, validated ETH/USD. Do not equate one share with one IMD or assume the same decimal scale.

## 3. Does the protocol's cut reduce participation?

**It measurably reduces available profitability; a measured causal reduction in the number of liquidators has not been established by these sources. Recommend 0% initially, with a later ceiling of 10% of bonus.** The current cut removes **3.333 percentage points of repaid debt**, and reduces executor reward from 9% after flagger payment to 5.667%—a **37.03% reduction**. Any executor whose cost lies between those two rewards becomes unprofitable. That is an arithmetic participation margin, not an empirical estimate of bidder loss.

Two protocols demonstrably take cuts:

- **Aave V3:** observed SNX and CRV fee setting **1,000 bps = 10% of the bonus**, not 10% of total seized collateral. SNX: protocol **0.85% of debt**, executor **7.65%**. Its liquidation code computes the bonus collateral separately before taking the percentage. [A1–A3]
- **Venus isolated pools:** observed `protocolSeizeShareMantissa = 0.05`, incentive **1.10**. The implementation divides the seized-token share by the incentive. Thus the protocol receives **5% of repaid principal**, the executor the other **5% bonus**: **50% of the gross bonus**, or **4.545% of all seized collateral**. This is not a 5% cut of bonus and not evidence that large cuts are harmless. [V2, V3]

Morpho explicitly gives the entire incentive to the liquidator and charges **no liquidation fee**. [M1] These divergent choices preclude calling 33.33% standard practice.

Track distinct funded executors, liquidation inclusion latency, failed attempts, quote impact and realized margins by size. Introduce a cut only after competitive execution is demonstrated; remove it automatically during stressed liquidity. Fund reserves primarily from ongoing fees instead of taking scarce recovery margin. The proposed flagger reward is also provisional: paying 2% of debt for flagging can invite races and unnecessary early flags. Require valid fresh-price flags, prevent duplicate payouts, and examine a capped dollar bounty after observing actual costs.

## 4. Oracle cap, cadence and recovery

**The current architecture needs a recovery path, not merely a different percentage. Keep 20% as a normal-path anomaly threshold; require prices at most five minutes old for borrowing, collateral withdrawal, liquidation and redemption; do not automatically widen the cap with age.** Five minutes is a provisional latency budget, not an existing capability of the swarm. If panel response times cannot meet it reliably, pause affected value-sensitive operations and improve the oracle before issuing more debt.

### What comparable oracle integrations actually do

| Integration | Published bound / timing | Meaning |
|---|---|---|
| **Liquity V1 Chainlink + Tellor** | **4h timeout**, **50% consecutive-price deviation threshold**, **5% inter-oracle agreement threshold** | A state machine can corroborate a large move and accept the current price or switch feeds. Deviation is calculated relative to the **larger** of consecutive prices, so 50% means more than doubling/halving, not an ordinary ±50% band about the old price. [L4] |
| **Pyth pull updates** | Caller chooses `age` in **seconds** via `getPriceNoOlderThan`; **no old-price percentage rejection cap** in the update path | Users pay for authenticated newer updates; stale reads revert. Best-practice guidance explicitly warns about adversarial selection and recommends strict age limits. Signature/source authentication and confidence information carry the security burden. No universal application age is specified. [P1, P2] |
| **RedStone pull connector defaults** | Maximum timestamp delay **3 minutes**; future allowance **1 minute** | Defaults validate signed payload time rather than requiring the new value to remain inside an old-price band. Integrators can override defaults; this is not a measured setting of every consuming protocol. [R1] |

There is **no sourced industry rule that expensive or pull oracles should use 20%, or widen their bound as they age**. These examples instead use freshness, authenticated updates and, in Liquity, corroboration and fallback. A publication deviation trigger tells a feed when to publish; our rejection cap tells a feed what it cannot publish. Confusing them reverses the intended behavior.

For a stationary endpoint **44.6% above** the old price, idealized 20% bridges require **three** updates: `1.2² = 1.44 < 1.446`; minimum payment **$12.75**, before failures and gas. But a truthful panel cannot simply attest fictitious intermediate prices because the contract needs them. Bridges require legitimate observation times and an explicit historical-update design. With a 5% spot agreement rule, a primary value allowed up to 1.20 times the old price cannot agree with a spot value at 1.446: even the permissive lower bound is `1.446 × 0.95 = 1.3737`. There is no overlap. Halting here must not permanently eliminate the ability to ingest a recovery price.

A moving market need not be mathematically impossible to catch merely because one move exceeded the cap: it can slow or reverse, or authenticated historical rounds may exist. It can nevertheless become **operationally uncatchable** if every truthful current value is outside the band, requests expire, or bridges are rejected. The already refused panel request demonstrates this liveness risk.

Recommended behavior:

1. Bundle a paid fresh update with each value-sensitive action, or enforce the five-minute bound against an already accepted update. Validate observation time, expiry, round ordering, replay protection, signer threshold and both components of the USD price. Staleness should use observation time, not payment or delivery time.
2. When live debt exists, fund watchers and refresh/recovery execution. A service promise of on-demand availability is insufficient if nobody is paid to notice and liquidate. Allow debt repayment and collateral additions during price uncertainty.
3. Above 20%, freeze new borrowing and withdrawals, then accept a **direct current-price recovery** only through a separately specified stronger authentication/corroboration path. A second reading of the same pool is not independent economic evidence. Multiple panel signers, independent observation infrastructure, sufficiently long TWAPs and manipulation-cost checks help, but do not create a second market.
4. If corroboration is unavailable, keep unsafe actions paused; use a predeclared settlement/shutdown process after oracle review. Do not fabricate bridge answers, silently clamp the price, or reopen lending at the stale value. Liquidations need a validated recovery price, rather than an indefinite blanket halt or an arbitrary stale-price seizure.
5. **No automatic age-based widening.** An attacker could wait for inactivity to obtain a weaker attestation bound. Increasing uncertainty with time should tighten exposure/freshness permissions, not expand authority to change the price. Legitimate large moves should use the recovery path.

Retain the **5%** discrepancy check as an alarm and borrowing/withdrawal circuit breaker only with defined recovery semantics. Reduce the spot's **1h** freshness to **5min or less**, align observation windows and investigate whether a spot-vs-TWAP comparison creates ordinary false alarms. Do not treat the single-pool spot as a trusted backup.

**Loss evidence:** Venus's May 2022 LUNA post-mortem states: “Chainlink’s price feed for LUNA hit a price floor threshold and was suspended by Chainlink with a price of $0.107.” It then reports spot near **$0.01** four hours later and an initial shortfall of approximately **$14.2M**. It records LUNA/UST feeds being set to **zero** for offboarding, and proposes fallback feeds and individual-market fail-safes. [V4] This is a concrete warning that a bound which freezes a collapsing price can enable borrowing against obsolete collateral. The proposed monitoring changes are described as plans, not independently proven implemented by that post.

## 5. Stability and redemption fees

### Stability fee

**200 bps is not a defensible default given these operating costs and risks; recommend 1,000 bps/year provisionally, reviewed against actual costs and peg demand.** It is not possible to derive an actuarially correct rate from one daily return.

Liquity V1 charges **no ongoing interest**, instead charging a **0.5–5% one-off borrowing fee** in normal operation; these are not APRs. [L1] Liquity V2 uses borrower-set annual rates; code permits **0.5% to 250%**, and the upfront charge is **seven days of average branch interest**. The documentation's **5%** example is an illustration, not the current market rate. [L5, L6] Thus neither design substantiates a flat 2% fee for sIMD. Venus's cited long-tail configuration has a **2% base borrowing rate** plus a **20% annual multiplier slope parameter** below its kink and a **300% jump multiplier**; the base alone is not the charged APR and this is lending-pool utilization pricing, not a CDP stability fee. [V1]

A reproducible provisional budget: **24 updates/day × $4.25 × 365 = $37,230/year**, or **3.723% of $1M debt**, plus an assumed **3% annual reserve contribution** and **1% operations/liquidator support** gives **7.723%**. Round to **10%** for variability and failures. At 2%, $1M debt earns only **$20,000/year**, less than that update budget alone. At $250,000 debt, update expense alone is **14.892%**; 10% would also be insufficient. Charge oracle costs to transacting users where feasible, or subsidize them explicitly.

The 24/day budget is illustrative, **not** a recommended hourly freshness rule. Continuous five-minute refresh would cost **$446,760/year**; five-minute age checks need not cause payments when nobody transacts, but outstanding debt still needs monitored protection. Actual usage, watcher requirements and panel latency determine the expense. A 10% fee without a funded refresh plan is not a safety solution. Do not multiply the vault's yield into stablecoin fee revenue unless the contracts actually capture it.

### Redemption fee

| Design | Floor | Maximum redemption fee | Increase per redemption, fraction `f` of pre-redemption supply | Decay half-life |
|---|---:|---:|---:|---:|
| **Our current** | **0.5%** | **5%** | **f / 4** | **12h** |
| **Liquity V1** | **0.5%** | Formula capped at **100%**; fee consuming all collateral is rejected | **f / 2** | **12h** |
| **Liquity V2** | **0.5%** | **100%** formula cap | **f / 1** | **6h** |
| **Recommendation** | **0.5%** | **5%** explicit peg-oriented choice | **f / 2** | **12h** initially |

V1's **5% cap is a borrowing-fee cap, not its redemption-fee cap**. This common confusion would misattribute our setting. V1 documentation explicitly gives `baseRateNew = baseRateOld + redeemedLUSD / (2 * totalLUSD)` and a **12-hour** half-life; its contract distinguishes `MAX_BORROWING_FEE` from the 100% redemption formula. V2 constants give `REDEMPTION_BETA = 1` and a **six-hour** decay, and its registry caps the redemption formula at 100%. [L3, L6, L7, L8]

From a zero base, redeeming **10% of supply** raises the raw fee to **3%** under our divisor 4, **5.5%** under V1's divisor 2, and **10.5%** under V2's divisor 1. Our 5% cap truncates the recommended divisor-2 result to **5%**. With a 0.5% floor, saturation begins at **18%** of supply under divisor 4 versus **9%** under divisor 2. This is substantial sensitivity, not a cosmetic difference.

**Divisor 4 is mathematically defensible but unsupported as a safe calibration here.** It halves the immediate response relative to V1 and could improve redemption arbitrage during a depeg; it also gives weaker discouragement of concentrated redemption-driven collateral sales. For comparable protection over time, doubling half-life to 24h roughly restores integrated response (`half-life / divisor`), but lengthens peg friction. Do not adopt that combination without flow simulation. Recommend the documented **divisor 2 / 12h** starting pair, retain the **50bps floor**, and retain **500bps cap** deliberately to keep the redemption route usable rather than copying a 100% cap.

Even a 50bps floor plus token-sale friction means redemption does not guarantee a $1 floor. At a 5% fee, a redeemer receives only **$0.95 nominal collateral per $1 debt token** before execution losses. A higher cap can greatly weaken the peg under stress; a lower divisor can accelerate sale pressure. Model both effects using executable pool quotes. No fee curve substitutes for a debt ceiling.

Specify `fee = min(cap, floor + decayedBase + f/divisor)` on the current redemption, using pre-redemption supply; clamp base state deliberately, preserve decay during inactivity, and prevent tiny operations from repeatedly resetting the decay clock. If base state can exceed the fee cap, the cap may remain binding long after activity stops. The current brief does not specify that state behavior; it must be checked.

## Changes after losses, and limits of attribution

Aave's November 2022 CRV review states: “The user has been fully liquidated, but despite this, Aave has accrued a much smaller (~$1.6M USD) bad debt position as of today’s CRV price.” It identifies approximately **92M CRV** short exposure and distinguishes the borrower's roughly **$10M** liquidation loss from the protocol's **$1.6M** bad debt. [A4]

The subsequent risk-update discussion proposed disabling borrowing across CRV and other volatile assets, contrasting this with **AIP-121's reserve freeze**. [A5] These are evidenced post-loss proposals; this report does not infer their execution solely from forum wording. Separately, the August 2026 governance payload's diff records SNX/CRV freezes and CRV's supply cap moving **11M → 1 token**. [A6] The current on-chain observations confirm those reserves are frozen and borrowing LTV is zero. Do **not** attribute the 2026 settings solely to the 2022 loss, or claim the 8.3/8.5% bonuses were increased in response to that loss: that causal claim was not established.

Venus's LUNA loss and the explicit feed-to-zero response are detailed above. Neither case establishes that a particular bonus percentage would have prevented the loss. Both support limiting exposure and halting obsolete-price borrowing, rather than assuming a solvent-looking ratio or nominal bonus guarantees recovery.

**Unanswered before production:** active v4 liquidity and hooks; stress executable depth; wrapper redemption limits; account concentration; stablecoin funding markets; panel signer compromise model and response latency; oracle normalization and timestamps; exact halt scope; current fee-state decay implementation; and independently measured liquidation competition. Statistical tail estimates, live Liquity V2 borrower rates, and causal participation elasticities were not measured. The recommendations should be revised when those inputs exist.

## Sources and verification notes

At least ten distinct primary pages were read; the entries below state the specific figures they support. Repository source is used as evidence of contract rules, not as instructions. Main/develop URLs can change. Dynamic Aave/Venus values are separately preserved in the attached snapshots, with chain, block hash and timestamp. Explorer read-contract pages provide the public parameter interface; a snapshot is stronger temporal evidence than an unpinned UI.

- **[A1] [Aave V3 Ethereum parameter provider, verified contract/read interface](https://etherscan.io/address/0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD#readContract)** — `getReserveConfigurationData` and `getLiquidationProtocolFee`. Attached [snapshot](aave-parameter-snapshot.json) records SNX LT 6500, bonus 10850, fee 1000; CRV LT 4100, bonus 10830, fee 1000; both LTV 0 and frozen. LT/LTV/fee are bps; bonus 10850 means 1.085 times repayment, not an 108.5% surplus.
- **[A2] [Aave LiquidationLogic contract](https://github.com/aave/aave-v3-origin/blob/main/src/contracts/protocol/libraries/logic/LiquidationLogic.sol)** — separates `bonusCollateral` and computes `liquidationProtocolFee` from that bonus; establishes the cut denominator.
- **[A3] [Aave address book, Ethereum deployment](https://github.com/aave-dao/aave-address-book/blob/main/src/ts/AaveV3Ethereum.ts)** — identifies provider address `0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD`, used for the observed calls. This page supports deployment identity, not the risk percentages by itself.
- **[A4] [Aave CRV excess-debt review, 2022-11-23](https://governance.aave.com/t/arc-repay-excess-debt-in-crv-market-for-aave-v2-eth/10779)** — explicitly reports ~$1.6M protocol bad debt, ~92M CRV short and ~$10M borrower loss; exact loss sentence quoted above.
- **[A5] [Aave post-event risk update, 2022-11-25](https://governance.aave.com/t/risk-parameter-updates-for-aave-v2-ethereum-liquidity-pool-2022-11-25/10824)** — says the alternative disables borrowing while retaining deposits, versus the AIP-121 freeze; proposal status distinguished from enactment.
- **[A6] [Aave August 2026 low-adoption deprecation parameter diff](https://github.com/bgd-labs/aave-proposals-v3/blob/main/diffs/AaveV3Ethereum_LowAdoptionAssetDeprecationOnAaveV3_20260826_before_AaveV3Ethereum_LowAdoptionAssetDeprecationOnAaveV3_20260826_after.md)** — SNX/CRV `isFrozen` false→true; CRV `supplyCap` 11,000,000→1. Payload simulation evidence, cross-checked against live frozen flags.
- **[V1] [Venus isolated-pool mainnet deployment configuration](https://github.com/VenusProtocol/isolated-pools/blob/develop/helpers/deploymentConfig.ts)** — BSC DeFi/GameFi incentive 1.1; BSW/ANKR/RACA CF 0.25 and LT 0.30; BabyDoge CF 0.30/LT 0.40; cited long-tail interest-model inputs. These are configuration figures, superseded where chain reads show zero thresholds.
- **[V2] [Venus isolated-pool VToken implementation](https://github.com/VenusProtocol/isolated-pools/blob/develop/contracts/VToken.sol)** — `DEFAULT_PROTOCOL_SEIZE_SHARE_MANTISSA = 5e16`; seized protocol tokens equal seize tokens times share divided by liquidation incentive. This establishes 5% of principal under a 1.1 incentive.
- **[V3] [Venus BSC Meme Comptroller, public contract interface](https://bscscan.com/address/0x33B6fa34cd23e5aeeD1B112d5988B026b8A5567d#readProxyContract)** and [BabyDoge vToken](https://bscscan.com/address/0x52eD99Cd0a56d60451dD4314058854bc0845bbB5#readProxyContract) — calls preserved in [Meme snapshot](venus-meme-parameter-snapshot.json): incentive 1.1, seize parameter 0.05, CF/LT zero. [BSW snapshot](venus-parameter-snapshot.json) independently has the same incentive/share and zero thresholds. Token and Comptroller addresses came from the repository's mainnet deployment JSON files, not guessed names.
- **[V4] [Venus LUNA incident update 2, May 2022](https://community.venus.io/t/venus-protocol-luna-incident-update-2/2654)** — frozen $0.107 feed, ~$0.01 spot, ~$14.2M initial shortfall; exact frozen-feed sentence quoted above. “UST and LUNA price feeds have been set to ‘0’” states the implemented feed response.
- **[L1] [Liquity V1 borrowing FAQ](https://docs.liquity.org/liquity-v1/faq/borrowing)** — 110% MCR, 150% recovery boundary; no recurring interest; one-off borrowing fee 0.5–5%. “This is a protocol parameter that is set to 110%.”
- **[L2] [Liquity V1 Stability Pool and liquidations FAQ](https://docs.liquity.org/liquity-v1/faq/stability-pool-and-liquidations)** — approximately 10% liquidation surplus near 110% CR; initiator reward 200 LUSD + 0.5% collateral, not the whole surplus.
- **[L3] [Liquity V1 redemption FAQ](https://docs.liquity.org/liquity-v1/faq/lusd-redemptions)** — 0.5% floor, divisor 2, 12h half-life. “The baseRate increases with each redemption, and decays to 0 over time with a 12 hour half life.”
- **[L4] [Liquity V1 PriceFeed contract](https://github.com/liquity/dev/blob/main/packages/contracts/contracts/PriceFeed.sol)** — timeout 14400 seconds, consecutive-round threshold 5e17, inter-oracle bound 5e16; comparison uses larger consecutive price and fallback/corroboration state machine.
- **[L5] [Liquity V2 borrowing and liquidation FAQ](https://docs.liquity.org/v2-faq/borrowing-and-liquidations)** — 5% normal liquidation penalty, 10% ETH / 20% LST redistribution penalties, 0.0375 WETH and variable compensation; user-set interest and seven-day upfront fee. The example 5% annual rate is illustrative.
- **[L6] [Liquity V2 Constants.sol](https://github.com/liquity/bold/blob/main/contracts/src/Dependencies/Constants.sol)** — MCR ETH 110% / LST 120%; annual interest bounds 0.5–250%; redemption floor 0.5%, beta 1, six-hour half-life and seven-day upfront period.
- **[L7] [Liquity V1 TroveManager contract](https://github.com/liquity/dev/blob/main/packages/contracts/contracts/TroveManager.sol)** — beta 2, redemption floor 0.5%, separate 5% maximum borrowing fee, redemption formula capped at DECIMAL_PRECISION (100%) and rejection if fee consumes all collateral.
- **[L8] [Liquity V2 CollateralRegistry contract](https://github.com/liquity/bold/blob/main/contracts/src/CollateralRegistry.sol)** — redemption fraction divided by REDEMPTION_BETA; fee and base rate capped at 100%; fee calculated for the redemption being performed.
- **[M1] [Morpho liquidation documentation](https://docs.morpho.org/learn/concepts/liquidation/)** — beta 0.3, maximum LIF 1.15, illustrative 86% LLTV, and explicit statement: “The entire LIF goes to the liquidator; Morpho protocol doesn't take a fee”.
- **[P1] [Pyth best practices](https://docs.pyth.network/price-feeds/best-practices)** — caller-configured staleness checks, pull-update adversarial selection and confidence-based safeguards; no universal numerical age requirement claimed.
- **[P2] [Pyth EVM implementation](https://github.com/pyth-network/pyth-crosschain/blob/main/target_chains/ethereum/contracts/contracts/pyth/Pyth.sol)** — paid authenticated update processing and publish-time ordering, without an old-price deviation percentage filter. [IPyth interface](https://github.com/pyth-network/pyth-crosschain/blob/main/target_chains/ethereum/sdk/solidity/IPyth.sol) documents `getPriceNoOlderThan(id, age)` in seconds.
- **[R1] [RedStone defaults library](https://github.com/redstone-finance/redstone-oracles-monorepo/blob/main/packages/evm-connector/contracts/core/RedstoneDefaultsLib.sol)** — `DEFAULT_MAX_DATA_TIMESTAMP_DELAY_SECONDS = 3 minutes`, future tolerance `1 minutes`. These defaults are numerical freshness limits, not per-update price limits.

**Local checks:** independently recomputed incentive splits, reciprocal LTVs, stress CR, oracle bridge count, update budgets and redemption examples; parsed all attached RPC snapshots; checked required report sections and source links. This checks arithmetic and output integrity, not independent truth certification or production readiness.
