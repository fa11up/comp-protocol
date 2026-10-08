---
title: Monetary policy
section: economics
order: 1
audience: everyone
sources:
  - src/CDPVault.sol:280-300
  - src/CDPVault.sol:362-428
  - src/CDPVault.sol:434-640
  - src/CDPVault.sol:639-700
  - src/CDPVault.sol:778-803
  - src/CDPVault.sol:887-1110
  - src/ParameterizedVault.sol:86-199
  - src/ParameterizedVault.sol:235-250
  - src/Treasury.sol:115-185
  - src/Treasury.sol:257-323
  - src/Treasury.sol:330-480
  - src/SwarmWorkOracle.sol:135-191
---

# Monetary policy

imdUSD is created two ways, by borrowing (`draw`) and by minting against attested work (`earn`), and destroyed by repayment, liquidation and redemption. [How imdUSD holds a dollar](../overview/how-it-holds-a-dollar.md) explains the peg; this page covers the accounting underneath it.

## Issuance

**Borrowing** mints imdUSD against a position's sIMD, priced in dollars through ETH/USD, as long as the position stays above `mat` and total principal stays under the debt ceiling `line`.

**Work issuance** (`earn`) mints imdUSD to an agent's controller against work rights, with no collateral and no debt. Rights are credited at the `wage` in force when they are claimed. While `wage` is zero, claims are refused outright (`WorkMintingOff`), so no agent's tasks are marked used for nothing, and so is `earn` itself, so rights claimed under an earlier wage wait until a wage is set again; turning minting from work on is a governance proposal, not a redeployment. Minting is also capped by a running total, the work ceiling:

> `earnLine` = discounted reserve value + backed debt × `earnMat`

Backed debt is principal less recorded bad debt; principal borrowed in the same transaction does not count, and while work minting is on, new debt counts only as it warms up (see below). The ceiling limits new minting only: if it later falls below what has been minted, nothing is burned. Whether work issuance is open at launch is not yet decided.

## The stability fee

Debt grows at the annual rate `duty`, through an index `chi` that rises linearly over a 365-day year. A position's fee is its principal times the rise in `chi` since its own checkpoint; fees do not earn fees. When a governance change alters `duty`, the index is checkpointed first, so the new rate applies only from then on.

Repayment and liquidation pay fees before principal: the full amount is burned, and the fee part is minted back to the Treasury. Redemption cancels a candidate's fees without minting them back. So supply always equals:

> supply = `totalDebt` + `totalEarned` − `totalNonPrincipalRedeemed`

`totalFeesMinted` counts revenue and is not part of that equation.

## The redemption fee

The fee has a fixed floor and cap. Between them it is a base rate that rises with each redemption (by the amount redeemed ÷ the fee base ÷ `redemptionDivisor`) and decays every second, halving every twelve hours. The fee base is warm supply: debt drawn in the last few hours does not count yet (it is still new, as for backing), while a repayment of seasoned debt stays counted for a few hours, its share halving every six hours, until that borrower borrows it back. So a large borrower can neither dilute the fee by borrowing for a block before a redemption nor pin it at the cap by repaying, redeeming a little and redrawing. Right after launch, or after a very large new loan, the base is small and redemptions pay more, up to the cap; it never counts as less than 100,000 imdUSD, so a small redemption cannot set everyone's fee at the cap: doing so from the floor takes a 9,000 imdUSD redemption that pays the cap itself. The fee applies to the redemption that raises it, not just the next one, and is rounded against the redeemer. Debt minted recently and then redeemed against still pays the full fee, but does not raise the base for later redeemers, so a borrower cannot cheaply pump it. The payout itself is described in [Redeem](../guides/redeem.md).

## Backing per imdUSD

`backingPerUnit()` is the figure redemption pays against, capped at $1. It adds:

- the Treasury's sIMD at the vault's own price, plus other listed reserve assets at their discounted value; and
- collateral that stands behind debt, counted position by position and never more than each position's debt requires. Surplus collateral and debt-free deposits count for nothing.

It divides the total by imdUSD supply.

**New capital warms up over hours.** Backing is the lower of the live figure and a lagged one in which newly added collateral and newly borrowed imdUSD are both left out until they have aged. What is still new halves every six hours (`BACKING_HALF_LIFE`), and new capital left untouched for a day counts in full; under steady activity a day counts about 94% and two days over 99%. A reduction counts at once. Each position's new capital is tracked separately, so one borrower's repayment can never make another borrower's new debt count early, in either order. The reserve backs every imdUSD, new or not, so the lagged figure counts only the warm supply's share of it. This stops someone from depositing and borrowing just before a redemption to lift backing to $1, taking the reserve at par, and unwinding afterwards, including in the first hours after launch, when almost all supply is new.

Because new debt and the imdUSD minted against it are excluded together, the lag mostly leaves an honest redemption's payout where it would be. It errs low in a few cases, each accepted as the safe direction: a large new loan dilutes the reserve's part until it warms; after a price fall, collateral long held can count as new for a few hours; and a position untouched for a day can leave its share in the vault's total until it cools. One edge errs high and is accepted with a bound; see [Risks and open questions](./risks-and-open-questions.md).

This is deliberately conservative, not the market value of everything in custody, and it can fall after a redemption that cancels a borrower's debt. Below $1, holders share the shortfall through a smaller payout; above it, the surplus stays with borrowers rather than paying redeemers a premium.

## Revenue and what leaves the Treasury

The Treasury receives the protocol's share of each liquidation bonus (`cut`, in sIMD) and paid stability fees (in imdUSD). How the bonus is split is in [Keeper economics](../keepers/keeper-economics.md). The redemption fee is not transferred anywhere: it stays behind as collateral, in the reserve or in the candidate's position.

Five things can leave the Treasury:

- **Redemptions.** `cash` pays from the Treasury's sIMD before it touches any position. This is the reserve doing its job, at the same backing-scaled price as any other payout.
- **Price updates.** `fundOracle()` sends `OracleAsker` up to the governed daily IMD budget to buy updates ([how updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). This is an expense: it lowers the reserve, and backing, by at most the budget.
- **Covering bad debt.** `cover()` spends Treasury imdUSD to cancel a drained position's bad debt, which raises backing for every holder.
- **The stream.** `payStream()` pays a governed payee up to a governed daily amount of imdUSD. It is off until proposed and never spends imdUSD that bad debt still needs.
- **Operator withdrawals.** The operator may withdraw other tokens, but never sIMD, never a listed reserve asset, and imdUSD only above what bad debt needs.

There is no automatic revenue distribution or buyback.
