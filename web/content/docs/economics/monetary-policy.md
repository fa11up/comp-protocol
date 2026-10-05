---
title: Monetary policy
section: economics
order: 1
audience: everyone
sources:
  - src/CDPVault.sol:362-428
  - src/CDPVault.sol:434-640
  - src/CDPVault.sol:778-803
  - src/CDPVault.sol:887-951
  - src/ParameterizedVault.sol:86-199
  - src/Treasury.sol:115-185
  - src/Treasury.sol:257-323
  - src/SwarmWorkOracle.sol:135-191
---

# Monetary policy

`draw` and `earn` are the two issuance channels for imdUSD. `cash` is redemption, and `wipe` retires a borrower's debt. These mechanisms target a dollar denomination; they do not guarantee a dollar market price. The [overview](../overview/how-it-holds-a-dollar.md) explains the peg mechanism in plain terms.

## `draw`: issuance against collateral

`draw(amount)` mints imdUSD against the caller's locked sIMD. Accrued debt after the draw must be covered at `mat`, the health-derived minimum ratio, and total minted principal must remain within `line`, the governed debt ceiling. Both values are (under consideration). Fresh, agreeing prices are required.

The debt is denominated in USD because `ParameterizedVault` prices collateral through `UsdPriceFeed`. Raw IMD/ETH is multiplied by Chainlink ETH/USD before computing collateral ratios and payouts. Borrowed tokens are fungible with tokens from work issuance.

## `earn`: issuance against attested work and backing headroom

`earn(amount)` consumes work rights and mints imdUSD without adding collateral or debt to a position. Whether earn is open at launch is (under consideration).

`wage`, imdUSD per accepted task, is (under consideration). `SwarmWorkOracle.claim` prices each newly claimed cumulative task increment at the rate in force at claim time. Changing `wage` does not reprice already credited rights. Rights alone are insufficient to mint: the vault also checks the cumulative ceiling:

> `earnLine` = discounted reserve USD value + `backedDebt` × the basis-point fraction `earnMat`.

`earnMat` and `earnLine` values and bounds are (under consideration). `backedDebt` caps total principal at its transaction-start level, then subtracts recorded bad debt with a floor at zero. This prevents a borrow-and-repay within one transaction from temporarily enlarging work capacity. It is conservative because recorded bad debt can include fees while total debt here is principal.

The limit gates new issuance only. Repayment across transactions, reserve withdrawals, falling prices or a parameter change can leave `totalEarned` above `earnLine`. Existing tokens are not burned. Work history and consumed rights are not restored by repayment or redemption. This is a point-in-time issuance limit, not a continuing collateral lock for every earned token.

## `duty` and `chi`: the stability fee

`duty`, the annual fee on outstanding principal, is (under consideration). `chi` is the additive fee index, scaled by 1e18. It advances linearly from `indexCheckpointAt` using elapsed seconds and the annual-rate basis-point fraction; the implementation uses a 365-day year.

A position's fee is its stored unpaid fee plus principal multiplied by the increase since `chiOf(owner)`. Unpaid fees do not earn interest. `drip()` checkpoints the global index without collecting money. Governance checkpoints before changing `duty`, so a new rate applies only to subsequent time.

`wipe` and `bite` retire fees before principal. The payer's full imdUSD amount is burned, then the fee portion is reminted to Treasury. `cash` instead cancels candidate fees without reminting them. Supply therefore satisfies:

> supply = `totalDebt` + `totalEarned` − `totalNonPrincipalRedeemed`.

Unpaid fees are obligations but are not issued tokens. `totalFeesMinted` is a cumulative revenue counter and must not be added to that supply identity.

## `cash`: payout and fee shape

`cash(amount, minImdOut, candidate)` pays:

> sIMD out = imdUSD burned × `backingPerUnit` × (one minus the fee fraction) ÷ USD price per sIMD.

`backingPerUnit` is already capped at $1 per imdUSD. The payout rounds down to sIMD raw units and must be nonzero and at least `minImdOut`. The fee is charged on this redemption, not just the next one.

`REDEMPTION_FEE_FLOOR_BPS` and `REDEMPTION_FEE_CAP_BPS` are fixed bounds, both (under consideration). The base rate decays per second, then rises with the burn's fraction of supply before the transaction's new principal mints. Burn sensitivity, decay factor and half-life are (under consideration). The stored base is capped at the space between fee floor and cap; conversion to whole basis points rounds against the redeemer.

Recently minted candidate principal is charged the full fee when redeemed, but its cancellation is excluded from the base-rate increase left for subsequent redeemers. `FRESH_DEBT_WINDOW` is (under consideration). Weighted principal age and youngest-first retirement prevent small mint/repay cycles from cheaply refreshing an entire debt balance. They do not prove that seasoned self-redemption cannot influence the fee.

The Treasury's idle collateral funds the payout first, regardless of reserve listing. Any shortfall comes from one candidate's collateral while matching accrued debt is cancelled. The candidate must have debt and be strictly below `mat + gap`; the exact collateral/debt fraction cannot worsen. There is no mark or grace requirement and no partial fill. Other registered reserve tokens are counted for backing but are not sold or paid out by `cash`.

A backing shortfall lowers redemption pricing rather than introducing a backing-ratio halt. Redemption can still fail for stale or divergent prices, insufficient feasible candidate capacity, minimum output, balances or other guards. See [Redeem](../guides/redeem.md).

## Backing per unit and the par cap

The numerator has two parts. Treasury collateral is valued at the same vault price used for payout, including unlisted collateral; other registered assets contribute their discounted USD values. Secured collateral comes from per-position tracked amounts bounded by principal at the last position change, excludes additions in the same transaction, and is capped in aggregate by `mat` times prior principal net of recorded losses.

This is a conservative accounting measure, not the total market value of all collateral in custody. Debt-free deposits contribute nothing. It can fall when redemption retires principal and thereby reduces the amount of collateral eligible to count, even when balance-based economic backing improves. It must not be treated as a monotone invariant under redemption.

Divide that numerator by imdUSD supply and cap at par. With no supply, the view returns par by convention. The cap preserves surplus for borrower collateral and issuance headroom rather than granting a redeemer a premium. Below par, holders share the measured shortfall through reduced payout.

## Revenue and spending

`cut`, the protocol's share of the liquidation bonus, is (under consideration) and arrives in sIMD at the vault-created Treasury. Paid stability fees arrive there as imdUSD. `chip`, the marker's share, is (under consideration) and goes to the recorded beneficiary. The remaining bonus goes to the liquidator. `CHOP_PERCENT`, the total bonus, is (under consideration).

The redemption fee is retained collateral value, not a separate transfer to a fee recipient. Its reserve-funded part remains in Treasury; its position-funded part remains with the candidate. `Treasury.sync` records receipts but is not needed for balance-based reserve valuation. Own-issued imdUSD cannot be listed as reserve backing.

Two things leave the Treasury: operator-authorized withdrawals, and a capped daily stream of IMD that pays for the protocol's own price updates ([How updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). There is no automatic revenue distribution or buyback. The oracle stream is an expense of the reserve, not revenue: it lowers the reserve, and with it backing per imdUSD, by at most the daily budget.
