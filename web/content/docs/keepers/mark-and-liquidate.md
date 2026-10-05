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

This is the procedure for finding an unsafe position, marking it and liquidating it. It assumes you have read [How liquidation works](./how-liquidation-works.md).

## Prerequisites

- imdUSD in your wallet to burn. Liquidation burns your tokens, not an approved allowance. Via `SwarmRelay`, the relay pulls them, so you must approve the relay first.
- ETH for gas.
- Usable feeds. If a feed is stale, relay an attestation first: [Relay oracle updates](./relay-oracle-updates.md).

## Find a target

1. In the terminal's Loan book, positions in the leftmost band are below `mat`. Click one to open it in the Keeper tab.
2. Or read it yourself. `collateralRatio(owner)` returns the ratio as a whole percentage; compare it with `mat()`. `positions(owner)` returns collateral and debt (with fees); `liquidationMarks(owner)` returns the mark.
3. Check the button label: Mark (borrower unsafe, unmarked), Grace with a countdown, Liquidate (window open), or "Mark again" (expired).

## Mark: `bark` / `barkFor`

1. Press Mark in the Keeper tab, or call `bark(owner)`.
2. To credit another address with the marker's share, use Mark for a beneficiary, or call `barkFor(owner, beneficiary)`.
3. The vault emits `Bark(owner, markedAt, grace)`. Note `markedAt + grace`: the earliest time you can liquidate.

Do not name the `SwarmRelay` contract as the beneficiary. It has no owner and no way to move tokens out, so its share would be stranded.

Marking an already marked, unexpired position succeeds and changes nothing; the first marker keeps the share.

### If it reverts

| Revert | Cause | Recovery |
|---|---|---|
| `HealthyPosition` | The position is at or above `mat` | Nothing to do; pick another |
| `StaleFeed` / `PriceDivergence` | Feeds unusable | Relay fresh attestations; wait for convergence |
| `InvalidBeneficiary` | Beneficiary is the zero address | Name a real address |

## Liquidate: `bite`

1. Wait until `markedAt + grace`. Before that, `bite` reverts with `GracePeriodNotElapsed`; the terminal shows the countdown.
2. Choose `debtToRepay`: how much of the borrower's debt to cancel. It must be no more than their `debtOf` and no more than the collateral can cover with the bonus.
3. Press Liquidate or call `bite(owner, debtToRepay)`. The vault burns that imdUSD from you and sends you the seized sIMD, less the protocol's cut, and less the marker's chip if someone else marked.
4. The vault emits `Bite(owner, liquidator, debtRepaid, collateralSeized)`.

Do it before the window closes: `markedAt + grace + tail()`.

### If it reverts

| Revert | Cause | Recovery |
|---|---|---|
| `ZeroAmount` | `debtToRepay` is zero | Use a positive amount |
| `StaleFeed` / `PriceDivergence` | Feeds unusable | Relay; wait |
| `HealthyPosition` | Recovered, or earlier partial liquidation restored it | Stop; Clear mark if it is still marked |
| `PositionNotMarked` | No mark | Mark first |
| `GracePeriodNotElapsed` | Still in grace | Wait |
| `MarkExpired` | Window ended | Mark again, then wait out a new grace |
| `ExcessRepayment` | `debtToRepay` exceeds the debt | Lower it |
| `InsufficientCollateral` | Collateral cannot cover the amount plus bonus | Lower `debtToRepay` |
| `InvalidBonusShares` | The configured shares exceed the bonus | Not recoverable by a keeper |
| ERC-20 balance error | Not enough imdUSD | Lower the amount or acquire imdUSD |

## Bundle the update with the action

If the feed needed to make the position unsafe or live is stale, or the moment matters, send the attestation and the action in one transaction with `SwarmRelay.relayAndBark` or `relayAndBite`. See [Relay oracle updates](./relay-oracle-updates.md). The terminal does not offer this; it calls the vault directly.

## Clear marks you notice

If the Keeper tab shows "Recovered, clearable", press Clear mark (`heel(owner)`). It costs gas and earns nothing directly, but it keeps stale marks out of the vault. `heel` reverts with `UnderwaterPosition` if the position is still unsafe.
