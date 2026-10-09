---
title: Mark and liquidate
section: keepers
order: 2
audience: keepers
sources:
  - src/CDPVault.sol:653-755
  - src/CDPVault.sol:759-769
  - src/SwarmRelay.sol:59-114
  - web/src/Panes.tsx:511-774
  - web/src/math.ts:186-212
---

# Mark and liquidate

The steps for finding an unsafe position, marking it and liquidating it. For the rules behind each step, read [How liquidation works](./how-liquidation-works.md).

## Prerequisites

- imdUSD in your wallet. A direct liquidation burns it from your wallet with no approval; through `SwarmRelay`, approve the relay first.
- ETH for gas.
- Live prices. If a feed is stale, relay an update first: [Relay oracle updates](./relay-oracle-updates.md).

## Find a target

1. In the terminal's Loan book, positions in the leftmost band are below `mat`. Click one to open it in the Keeper tab.
2. Or read it yourself: `collateralRatio(owner)` returns the ratio as a whole percentage to compare with `mat()`; `positions(owner)` returns collateral and debt including fees; `liquidationMarks(owner)` returns the mark.
3. The Keeper tab's button tells you where it stands: Mark (unsafe, unmarked), Grace with a countdown, Liquidate (window open), or "Mark again" (expired).

## Mark: `bark` / `barkFor`

1. Press Mark in the Keeper tab, or call `bark(owner)`.
2. To credit another address with the marker's share, use Mark for a beneficiary, or call `barkFor(owner, beneficiary)`. Do not name the `SwarmRelay` contract: it cannot pass the share on, so it would be stranded.
3. The vault emits `Bark(owner, markedAt, grace)`. `markedAt + grace` is the earliest moment you can liquidate.

### If it reverts

| Revert | Cause | Recovery |
|---|---|---|
| `HealthyPosition` | The position is at or above `mat` | Nothing to do; pick another |
| `StaleFeed` / `PriceDivergence` | Prices not live | Relay fresh updates; wait for primary and spot to agree |
| `InvalidBeneficiary` | Beneficiary is the zero address | Name a real address |

## Liquidate: `bite`

1. Wait until `markedAt + grace`. The Keeper tab shows the countdown.
2. Choose how much debt to repay. It must be no more than the borrower's `debtOf(owner)` and no more than their collateral can cover with the bonus.
3. Press Liquidate or call `bite(owner, debtToRepay)`. The vault burns that imdUSD from you and sends you the seized sIMD, minus the protocol's share, and minus the marker's share if someone else marked.
4. The vault emits `Bite(owner, liquidator, debtRepaid, collateralSeized)`.

Finish before the window closes at `markedAt + grace + tail()`.

### If it reverts

| Revert | Cause | Recovery |
|---|---|---|
| `ZeroAmount` | Amount is zero | Use a positive amount |
| `StaleFeed` / `PriceDivergence` | Prices not live | Relay; wait |
| `HealthyPosition` | The position recovered, or an earlier partial liquidation restored it | Stop; clear the mark if it is still there |
| `PositionNotMarked` | No mark | Mark first |
| `GracePeriodNotElapsed` | Still in grace | Wait |
| `MarkExpired` | Window ended | Mark again, then wait out a new grace |
| `ExcessRepayment` | Amount exceeds the debt | Lower it |
| `InsufficientCollateral` | Collateral cannot cover the amount plus bonus | Lower the amount |
| `InvalidBonusShares` | The configured shares exceed the bonus | Not fixable by a keeper |
| ERC-20 balance error | Not enough imdUSD | Lower the amount or get more imdUSD |

## Bundle the update with the action

If a feed is stale, or timing matters, send the price update and the action in one transaction with `SwarmRelay.relayAndBark` or `relayAndBite`. See [Relay oracle updates](./relay-oracle-updates.md). The terminal does not offer this; it calls the vault directly.

## Clear marks you notice

If the Keeper tab shows "Recovered, clearable", press Clear mark (`heel(owner)`). It costs gas and pays nothing, but it removes a mark that could otherwise skip grace if the position dips again. It reverts with `UnderwaterPosition` if the position is still unsafe.

## Pace and re-price

Two more calls keep the vault's figures current. Neither pays anything; both cost a little gas and are open to anyone.

- **`pace()`** moves the vault's slow-moving figures (backing per imdUSD, the fee base, the work ceiling's debt and the payout price) forward from the state as it stands. Every call that moves capital paces first, so this only matters in a quiet spell: without it a recovery does not reach redeemers. Call it about once an hour; elapsed time beyond an hour between pacings is not counted.
- **`resecure(owner)`** re-prices one position's collateral term at the current price. A term stays at the price the position was last touched at, so after each price update re-price the positions whose term is limited by their debt, largest first. It needs live, agreeing prices.

