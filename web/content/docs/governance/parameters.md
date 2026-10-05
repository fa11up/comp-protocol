---
title: Parameters
section: governance
order: 1
audience: governance
pending: true
sources:
  - src/Parameters.sol:38-348
  - src/Governed.sol:23-94
  - src/Treasury.sol:115-185
  - src/Treasury.sol:277-323
  - src/Treasury.sol:330-350
  - src/CDPVault.sol:103-127
  - src/CDPVault.sol:578-617
  - src/CDPVault.sol:832-849
  - src/CDPVault.sol:1001-1011
  - src/ParameterizedVault.sol:61-199
  - src/SwarmWorkOracle.sol:135-191
---

# Parameters

`Parameters` holds the economic settings governance may change for its vault, each inside a hard limit written into the contract. It cannot replace the vault, the collateral, the price and health feeds, the work oracle, the dollar-price adapter or the Treasury.

Every change goes through the same [proposal and delay](./timelock-and-proposals.md). A basis point is one hundredth of a percent; imdUSD amounts use 18 decimals.

## Governed values

| Value | What it is | How it changes | Limit |
|---|---|---|---|
| `line` | Debt ceiling: the most principal that can be outstanding, in imdUSD. Fees and work issuance are not counted. | `propose(ParamSet)` | Above zero. Setting it below current debt only stops new borrowing. |
| `cut` | Treasury's share of the liquidation bonus, in basis points. | `propose(ParamSet)` | `cut` plus `chip` cannot exceed the whole bonus. |
| `duty` | Annual stability fee on principal, in basis points. | `propose(ParamSet)`; the old rate is checkpointed first. | Zero up to `MAX_DUTY_BPS`. |
| `skew` | How far the primary and spot prices may differ, in basis points of the primary. | `propose(ParamSet)` | Between `MIN_DIVERGENCE_BPS` and `MAX_SKEW_BPS`. |
| `chip` | Marker's share of the liquidation bonus, in basis points. | `propose(ParamSet)` | Shares the bound with `cut`. |
| `earnMat` | How much of the backed debt counts toward the work ceiling, in basis points. | `proposeEarnMat(bps)` | Zero up to `MAX_EARN_MAT_BPS`. |
| `wage` | imdUSD credited per newly claimed accepted task. | `proposeWage(wad)` | Zero up to `MAX_WAGE_WAD`. |
| `gap` | Redemption eligibility spread above `mat`, in whole percent. | `proposeGap(spread)` | `MIN_GAP` to `MAX_GAP`. |
| `redemptionDivisor` | How fast the redemption fee climbs: each redemption raises the base by redeemed ÷ supply ÷ divisor. | `proposeRedemptionDivisor(divisor)` | `MIN_REDEMPTION_DIVISOR` to `MAX_REDEMPTION_DIVISOR`. |
| `streamPayee`, `streamPerDay` | Who the Treasury pays imdUSD to, and at most how much per UTC day. Off until proposed. | `proposeStream(payee, perDay)` | Zero up to `MAX_STREAM_PER_DAY`; a nonzero amount needs a payee. |
| `oracleBudget` | IMD the Treasury may send `OracleAsker` per UTC day to buy price updates ([how updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). Zero stops it. | `proposeOracleBudget(imdPerDay)` | Zero up to `MAX_ORACLE_BUDGET_PER_DAY`. |
| Reserve asset and its `priceFeed` | A token the Treasury counts as backing, and the dollar price source used to value it. sIMD is listed with the vault's own `collateralPriceFeed()`, so it counts at the vault's price. | `proposeReserveAsset(asset, priceFeed, haircutBps)` | The asset and feed must be contracts that answer sensibly; imdUSD itself cannot be listed. Proposing the zero address as the feed removes a listing. |
| Reserve `haircutBps` | The share of a listed asset's market value that counts. Lower counts less. | Same proposal | From none of its value to all of it. |

The five `ParamSet` values travel together in the order `line`, `cut`, `duty`, `skew`, `chip`, so a proposal restates all five even to change one. No proposal can widen a limit.

A listed reserve feed that goes stale or reads zero counts for nothing. Listing checks that the feed answers sensibly, not that it tells the truth.

**Taking backing out is never immediate.** The operator can withdraw from the Treasury with `Treasury.withdraw`, but never sIMD and never a listed reserve asset, and imdUSD only above what outstanding bad debt needs. Removing an asset from the reserve takes a delisting proposal, visible for the whole delay.

## Fixed or derived values

These are written into the contracts or calculated, not proposed.

| Identifier | What it is | Value |
|---|---|---|
| `mat` | Minimum collateral ratio, from the [network health](./network-health.md) curve. | — |
| `lull` | Grace between a mark and liquidation, from the same curve, fixed at the moment of marking. | — |
| `tail` | Liquidation window after grace: the shorter of the price and health feeds' maximum ages. | — |
| `CHOP_PERCENT` | Liquidation bonus as a percent of debt repaid. `chip` and `cut` divide it; they never add to it. | — |
| `REDEMPTION_FEE_FLOOR_BPS`, `REDEMPTION_FEE_CAP_BPS` | Lowest and highest redemption fee. | — |
| `REDEMPTION_SECOND_DECAY`, `FRESH_DEBT_WINDOW` | How fast the redemption fee decays, and how long new debt is treated as fresh. | — |
| `SECURED_COLLATERAL_MULTIPLE` | How much collateral per unit of debt can count as backing. | — |
| Feed `maxAge`, `maxDeviationBps` | How old a feed may get, and how far one update may move it. Set when each feed is deployed. | — |
| `ETH_USD_MAX_AGE`, `WORK_ORACLE_MAX_AGE` | Maximum age of the Chainlink ETH/USD reading and of a work attestation. | — |
| `earnLine` | Work ceiling: discounted reserve value plus backed debt scaled by `earnMat`. Gates new work mints; it never burns tokens already issued. | Calculated |
| `chi` | Stability-fee index, from the last checkpoint, elapsed time and `duty`. | Calculated |

`TIMELOCK`, the governance delay, is fixed too and cannot be shortened by a proposal.

## What the limits do not guarantee

A split inside the limits can leave nothing for a liquidator who did not mark. A reserve feed inside the limits can overstate value. A rate inside the limits can still make positions unsafe. A lower `wage` affects only new claims, and a lower `earnMat` only new mints. See [Risks and open questions](../economics/risks-and-open-questions.md).
