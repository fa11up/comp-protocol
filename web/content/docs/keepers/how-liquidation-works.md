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

Liquidation is a two-step process in the vault, `bark` then `bite`, with a wait in between. Anyone can run both. This page explains the rules; [Mark and liquidate](./mark-and-liquidate.md) gives the procedure.

## Safe, unsafe, marked

A position is **safe** if it has no debt or its collateral ratio is at least `mat`. It is **unsafe** otherwise. Unsafe is a property of the current prices. A **mark** is a stored record that the position was found unsafe: `liquidationMarks(owner)` holds `markedAt`, `grace`, `marked` and `marker`.

Every price-dependent step requires fresh feeds that agree with each other (`StaleFeed`, `PriceDivergence`). If the feeds are unusable, nobody can mark or liquidate until a fresh attestation is relayed.

## Step one: Mark (`bark`)

`bark(owner)` or `barkFor(owner, beneficiary)` reverts with `HealthyPosition` if the position is safe. Otherwise it stores a mark with:

- the current time;
- the grace length, `lull()`, read from the network health index at that moment and kept fixed afterwards;
- the **marker**: `msg.sender` for `bark`, or `beneficiary` for `barkFor`. A zero beneficiary reverts with `InvalidBeneficiary`.

It emits `Bark(owner, markedAt, grace)`.

If the position is already marked and the mark has not expired, `bark` does nothing and does not revert. The first marker keeps the credit.

## Grace and the liquidation window

`lull()` is derived from the network health index: it is short when health is low and longer when health is high, so a degraded network gives borrowers less time. The curve is (under consideration).

Time since the mark decides what is possible:

| Time since `markedAt` | State | `bite` result |
|---|---|---|
| Less than `grace` | Grace | Reverts `GracePeriodNotElapsed` |
| From `grace` to `grace` plus `tail()` | Liquidation window | Allowed if still unsafe |
| After `grace` plus `tail()` | Expired | Reverts `MarkExpired`; Mark again, which restarts grace |

`tail()` is the shorter of the primary price feed's and the network health feed's maximum ages. After that long without a liquidation, either feed may have recovered the position unobserved, so the mark is void. A bounded mark lifetime also prevents an old mark turning a later dip into an instant liquidation with no grace.

## Step two: Liquidate (`bite`)

`bite(owner, debtToRepay)` requires fresh agreeing feeds, an unsafe position, a mark (`PositionNotMarked`), an elapsed grace and an unexpired mark. It then:

1. Accrues the borrower's stability fee and checks `debtToRepay` is at most their debt (`ExcessRepayment`).
2. Computes the collateral seized: `debtToRepay` plus the bonus, converted to sIMD at the vault's collateral price. The bonus is `CHOP_PERCENT`, a source constant whose value is (under consideration). If that exceeds the borrower's collateral it reverts with `InsufficientCollateral`; a smaller `debtToRepay` is the remedy.
3. Burns `debtToRepay` of the caller's imdUSD. No approval is needed. Fees paid are minted to the Treasury.
4. Splits the seized sIMD ([Keeper economics](./keeper-economics.md)).
5. Emits `Bite(owner, liquidator, debtRepaid, collateralSeized)`.

You can liquidate part of the debt. Partial liquidation is how a keeper handles a position larger than their imdUSD inventory. If the position becomes safe after a partial `bite`, the mark is cleared and further `bite` calls revert with `HealthyPosition`.

## The dust sweep

If a partial liquidation would leave a remainder of collateral too small to seize for even one unit of debt, while debt remains, the vault gives the remainder to the biter. Without it, such a position could never be drained: every later `bite` would revert with `InsufficientCollateral`. The sweep is added after the bonus split, so it does not enlarge the marker's or protocol's share.

## Clearing recovered marks

A mark on a position that has become safe is housekeeping. It is cleared by:

- the borrower's Deposit (`lock`) or Repay (`wipe`) when feeds are usable and the ratio is back at or above `mat`, or at once when debt reaches zero;
- the borrower's successful Borrow (`draw`) or Withdraw (`free`);
- anyone calling Clear mark (`heel(owner)`), which reverts with `UnderwaterPosition` if the position is still unsafe.

Each clearing emits `Heel(owner)`. A recovered mark cannot be used to liquidate: `bite` re-checks that the position is unsafe. Keepers should still clear marks they see, because a recovery that no transaction observed does not restart grace if the position dips again before the mark expires.

## Bad debt

If a liquidation drains a position's collateral and debt remains, that residual is recorded in `totalBadDebt` once it is realised. There is no insurance fund and no write-off. See [Risks and open questions](../economics/risks-and-open-questions.md).

## Which guards a liquidation depends on

- Prices come from the attested feeds ([How imdUSD holds a dollar](../overview/how-it-holds-a-dollar.md)).
- The divergence guard (`skew`) pauses marking and liquidation when primary and spot disagree.
- Both protocol-share and marker-share bounds are enforced on the parameter contract; the vault refuses a liquidation with `InvalidBonusShares` if they ever exceeded the bonus.
