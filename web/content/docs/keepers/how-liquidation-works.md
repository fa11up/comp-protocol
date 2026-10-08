---
title: How liquidation works
section: keepers
order: 1
audience: keepers
sources:
  - src/CDPVault.sol:44-49
  - src/CDPVault.sol:653-755
  - src/CDPVault.sol:830-848
  - src/CDPVault.sol:952-969
  - src/CDPVault.sol:1011-1053
  - src/Parameters.sol:296-310
---

# How liquidation works

Liquidation takes two transactions with a wait in between: mark (`bark`), then liquidate (`bite`). Anyone can do both. This page explains the rules; [Mark and liquidate](./mark-and-liquidate.md) gives the steps.

Every step below needs **live prices**: all feeds fresh, and the primary and spot IMD/ETH prices close enough to agree. Otherwise the call reverts with `StaleFeed` or `PriceDivergence`, and nobody can mark or liquidate until someone relays a fresh attestation.

## Safe, unsafe, marked

A position is **safe** if it has no debt or its collateral ratio is at least `mat`, and **unsafe** otherwise. Being unsafe depends on current prices, so it can change without any transaction.

A **mark** is a stored record that a position was found unsafe. `liquidationMarks(owner)` holds when it was marked, its grace, whether it is marked, and who marked it.

## Step one: mark

Marking a safe position reverts with `HealthyPosition`. Marking an unsafe one stores:

- the current time;
- the grace length, `lull()`, read from the network health index at that moment and never changed afterwards;
- the **marker**: the caller for `bark`, or a named address for `barkFor`, which must not be zero (`InvalidBeneficiary`).

It emits `Bark(owner, markedAt, grace)`. If the position already has a mark that has not expired, marking again does nothing and does not revert, so the first marker keeps the credit.

## Grace and the liquidation window

Grace is short when network health is low and longer when it is high, so a weaker network gives borrowers less time to recover.

| Time since the mark | State | Liquidating |
|---|---|---|
| Less than the grace | Grace | Reverts `GracePeriodNotElapsed` |
| From the end of grace until `tail()` later | Liquidation window | Allowed while still unsafe |
| After that | Expired | Reverts `MarkExpired`; mark again, which starts a new grace |

`tail()` is the shorter of the primary price feed's and the network health feed's maximum ages. A mark older than that is void, for two reasons: either feed may have recovered the position in the meantime, and an old mark must not turn a later dip into a liquidation with no grace.

## Step two: liquidate

Liquidating needs live prices, an unsafe position, a mark (`PositionNotMarked`), an elapsed grace and an unexpired window, for every position, a drained one too. A drained borrower's small re-deposit is handled by `cover` instead, which takes collateral worth less than the recorded bad debt at its value. Then the vault:

1. Adds the borrower's accrued stability fee and checks that the amount you repay is not more than their debt (`ExcessRepayment`).
2. Works out the collateral to seize: the amount repaid plus the bonus, converted to sIMD at the vault's price. If that is more than the borrower holds, it reverts with `InsufficientCollateral`; repay less.
3. Burns your imdUSD. No approval is needed. Any fees you paid off are minted to the Treasury.
4. Splits the seized sIMD between you, the marker and the Treasury. The split only divides the bonus and never takes more from the borrower; [Keeper economics](./keeper-economics.md) has the breakdown.
5. Emits `Bite(owner, liquidator, debtRepaid, collateralSeized)`.

You can liquidate part of the debt, which is how a keeper handles a position larger than their imdUSD. If a partial liquidation makes the position safe, the mark is cleared and further attempts revert with `HealthyPosition`.

## The dust sweep

If a partial liquidation would leave collateral too small to seize for even one unit of debt while debt remains, the vault gives that remainder to the liquidator. Without the sweep the position could never be closed, because every later attempt would revert with `InsufficientCollateral`. The sweep is added after the bonus split, so it does not change the marker's or the Treasury's share.

## Clearing recovered marks

A mark on a position that is safe again is cleared, emitting `Heel(owner)`, by any of:

- the borrower's Deposit (`lock`) or Repay (`wipe`), when prices are live and the ratio is back at or above `mat`, or at once if the debt reaches zero;
- the borrower's successful Borrow (`draw`) or Withdraw (`free`), since both require the ratio to be at least `mat` afterwards;
- anyone calling Clear mark (`heel(owner)`), which reverts with `UnderwaterPosition` if the position is still unsafe.

If a Deposit or Repay restores the ratio while prices are not live, it still succeeds but the mark stays; clear it once prices are live again.

A recovered mark cannot be used to liquidate, because liquidation re-checks that the position is unsafe. Still clear marks you see: a recovery that happened only through a price move is not recorded, and if the position dips again before the mark expires, the old mark applies with no new grace.

## Bad debt

If liquidation uses up a position's collateral and debt remains, the remainder is recorded as bad debt in `totalBadDebt`. There is no insurance fund, but the debt can be written off: anyone can call `cover(owner, amount)` to cancel it with imdUSD the Treasury holds from stability fees. Collateral too small to seize is moved to the Treasury first. Until it is covered, the shortfall stays on the books and lowers backing. See [Risks and open questions](../economics/risks-and-open-questions.md).

## What a liquidation depends on

- Prices from the attested feeds ([How imdUSD holds a dollar](../overview/how-it-holds-a-dollar.md)).
- The divergence guard (`skew`), which pauses marking and liquidation while primary and spot disagree.
- Bonus shares that fit inside the bonus. Governance cannot set them higher, and the vault refuses a liquidation with `InvalidBonusShares` if they ever were.
