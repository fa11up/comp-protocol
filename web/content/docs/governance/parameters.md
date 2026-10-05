---
title: Parameters
section: governance
order: 1
audience: governance
sources:
  - src/Parameters.sol:38-348
  - src/Governed.sol:23-94
  - src/Treasury.sol:115-185
  - src/Treasury.sol:277-323
  - src/CDPVault.sol:103-127
  - src/CDPVault.sol:578-617
  - src/CDPVault.sol:832-849
  - src/CDPVault.sol:1001-1011
  - src/ParameterizedVault.sol:61-199
  - src/SwarmWorkOracle.sol:135-191
---

# Parameters

`Parameters` governs bounded economic values for its creating `ParameterizedVault`. It cannot replace the vault, collateral, primary/NHI/spot feeds, work oracle, dollar-price adapter or revenue destination. All economic values and bounds below are (under consideration); the table describes enforcement, not a selected launch calibration.

A basis point is one hundredth of a percentage point. imdUSD amounts use 18 decimals. The [timelock flow](./timelock-and-proposals.md) applies to every proposal kind in this table.

| Value | Meaning and units | How changed | Enforced bound; value |
|---|---|---|---|
| `line` | Maximum outstanding minted principal, imdUSD raw units; fees and work issuance are separate. | Complete `ParamSet` via `propose`. | Must be positive, with no additional economic upper cap beyond the ABI integer range. May be below outstanding debt; only new borrowing stops. Value and lower bound: (under consideration). |
| `cut` | Treasury fraction of the liquidation bonus, basis points. | Complete `ParamSet`. | Together with `chip`, cannot exceed the whole bonus; no guaranteed executor remainder. Value and combined cap: (under consideration). |
| `duty` | Annual stability fee on principal, basis points per year. | Complete `ParamSet`; `drip()` checkpoints the old rate before application. | Nonnegative and no greater than `MAX_DUTY_BPS`. Value and both endpoints: (under consideration). |
| `skew` | Allowed absolute primary/spot difference divided by primary, basis points. | Complete `ParamSet`. | Between `MIN_DIVERGENCE_BPS` and `MAX_SKEW_BPS`, inclusive. Value and endpoints: (under consideration). |
| `chip` | Marker fraction of the liquidation bonus, basis points. | Complete `ParamSet`. | Nonnegative and bounded jointly with `cut`; value and bounds: (under consideration). |
| `earnMat` | Work ceiling's ratio term, basis points of `backedDebt()`. | `proposeEarnMat(bps)`. | Nonnegative, no greater than `MAX_EARN_MAT_BPS`; value and endpoints: (under consideration). |
| `wage` | imdUSD raw units credited per newly claimed accepted task. | `proposeWage(wad)`. | Nonnegative, no greater than `MAX_WAGE_WAD`; value and endpoints: (under consideration). |
| `gap` | Redemption eligibility spread above `mat`, whole percentage points. | `proposeGap(spread)`. | `MIN_GAP` through `MAX_GAP`, inclusive; value and endpoints: (under consideration). |
| `redemptionDivisor` | How fast the redemption fee climbs: each redemption raises its base by redeemed ÷ supply ÷ divisor. | `proposeRedemptionDivisor(divisor)`. | `MIN_REDEMPTION_DIVISOR` through `MAX_REDEMPTION_DIVISOR`; value and bounds: (under consideration). |
| `streamPayee`, `streamPerDay` | Who the Treasury pays imdUSD to, and at most how much per UTC day. Off until proposed. | `proposeStream(payee, perDay)`. | Zero through `MAX_STREAM_PER_DAY`; a nonzero amount needs a payee. Values: (under consideration). |
| `oracleBudget` | IMD the Treasury may send `OracleAsker` per UTC day to buy price updates ([How updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). Zero stops the stream. | `proposeOracleBudget(imdPerDay)`. | Zero through `MAX_ORACLE_BUDGET_PER_DAY`, inclusive; value and limit: (under consideration). |
| Reserve membership and `priceFeed` | Token listing and USD price source used for reserve valuation: USD per whole token, except the vault's own collateral (sIMD), which is valued per 1e18 raw units like the vault, so it is listed with `collateralPriceFeed()`. | `proposeReserveAsset(asset, priceFeed, haircutBps)`. | Asset must have code and supported decimals, and cannot be the vault's own imdUSD. A listed source must have code and well-formed freshness/value responses. The zero-address sentinel removes an existing listing. |
| Reserve `haircutBps` | Retained fraction of a listed asset's market value, basis points. Lower means less counted backing. | Same reserve proposal. | From no retained value through full retained value; removal requires no retained-value factor. Factor and numeric bounds: (under consideration). |

`ParamSet` field order is `line`, `cut`, `duty`, `skew`, `chip`. All fields travel together, even when only one changes. Parameter bounds are source constants and cannot be widened by governance. Reserve decimals are read from the token at listing, not selected freely; decimals above 77 places are rejected to keep decimal exponentiation representable.

A reserve feed may be stale when listed if its responses are structurally valid. That does not make its balance usable backing: stale or zero-valued sources contribute nothing. Validation cannot prove that the source tells the truth about price or freshness. The operator can also withdraw reserve assets immediately through `Treasury.withdraw`; this authority is outside the proposal timelock.

## Fixed or derived economics

| Identifier | Definition and control |
|---|---|
| `mat` | Minimum collateral ratio. Derived from the NHI curve in `CDPVault`; no governance setter. Curve, breakpoints, endpoint ratios and bounds: (under consideration). |
| `lull` | Liquidation grace duration in seconds, derived from NHI and snapshotted when marked. Curve and bounds: (under consideration). |
| `tail` | Liquidation window after grace, the shorter primary/NHI maximum age. Derived, not a separate proposal. Duration and bounds: (under consideration). |
| `CHOP_PERCENT` | Fixed bonus as percent of debt repaid. Value: (under consideration). `chip` and `cut` divide this bonus; they do not increase it. |
| `REDEMPTION_FEE_FLOOR_BPS`, `REDEMPTION_FEE_CAP_BPS` | Fixed redemption-fee endpoints, in basis points. Values: (under consideration). |
| `REDEMPTION_SECOND_DECAY`, `FRESH_DEBT_WINDOW` | Fixed per-second base-fee decay and fresh-principal exclusion window. Factor, half-life and window duration: (under consideration). The burn-fraction sensitivity is also fixed, with its value (under consideration). |
| `SECURED_COLLATERAL_MULTIPLE` | Fixed per-position principal multiple used to bound counted collateral. Value: (under consideration). |
| Feed `maxAge`, `maxDeviationBps` | Maximum accepted age in seconds and allowed fresh-to-fresh movement in basis points. Constructor-fixed. Age must be positive; deviation ranges from no movement through a full prior-value change. Values and bounds: (under consideration). |
| `ETH_USD_MAX_AGE`, `WORK_ORACLE_MAX_AGE` | Source-pinned ETH/USD and factory-created work-attestation age allowances. Values and bounds: (under consideration). Work claims do not separately expire accepted roots. |
| `earnLine` | Derived ceiling: discounted reserve USD plus eligible debt scaled by `earnMat`. Value: (under consideration). Gates new cumulative work mints; does not burn outstanding tokens when it falls. |
| `chi` | Linear stability-fee index. Calculated from stored checkpoint, elapsed seconds and `duty`; `drip` stores it. Not an independently governed rate. |

`TIMELOCK` is the fixed governance delay, (under consideration), measured in seconds. It cannot be shortened by a proposal. Authorities and contract identities are likewise fixed by source or construction; their addresses are (waiting for mainnet launch).

## What bounds do not guarantee

A valid split can leave no bonus for a liquidator who did not mark. A valid reserve feed can overstate value. A valid rate can still make positions unsafe. These are governance trust assumptions, not failed arithmetic checks. A lower `wage` affects new claims, not already credited rights; a lower `earnMat` affects new mints, not outstanding supply. See [Risks and open questions](../economics/risks-and-open-questions.md).
