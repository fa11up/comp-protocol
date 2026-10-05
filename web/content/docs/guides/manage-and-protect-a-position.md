---
title: Manage and protect a position
section: guides
order: 3
audience: borrowers
sources:
  - src/CDPVault.sol:328-358
  - src/CDPVault.sol:420-427
  - src/CDPVault.sol:653-755
  - src/CDPVault.sol:691-697
  - src/CDPVault.sol:759-848
  - src/CDPVault.sol:999-1053
  - web/src/math.ts:128-212
---

# Manage and protect a position

This guide covers changing an open position and keeping it from being liquidated. It uses four calls: Deposit (`lock`), Withdraw (`free`), Repay (`wipe`) and, for marks, Clear mark (`heel`).

## Know your liquidation price

Your position is safe while collateral value divided by debt is at least `mat`. So the dollar price per IMD at which it stops being safe is:

> liquidation price = debt × `mat` ÷ 100 ÷ collateral

with debt in imdUSD, collateral in IMD and `mat` as a whole percentage. The terminal shows this as **Liquidation price**, with the cushion below the current price. Two things move it that are not the IMD price:

- **Stability fee.** Debt grows with `duty` through `chi`, so the liquidation price rises over time.
- **Network health.** `mat` is derived from the network health index. When health falls, `mat` rises and your liquidation price rises with it, even if IMD is flat. When health rises, `mat` falls. The curve is (under consideration); read the live value with `mat()` or in the Position tab.

Keep a cushion that covers a price fall and a health fall together. Check **Liquidation price** whenever the Oracle tab shows the network health feed has changed.

## Add collateral: Deposit (`lock`)

1. Choose Deposit, enter the IMD amount, approve if asked, then confirm.
2. The ratio rises and the liquidation price falls.

Deposit works even when feeds are stale. It reverts only with `ZeroAmount`, an ERC-20 balance or allowance error, or `UnexpectedCollateralReceived`.

## Repay debt: Repay (`wipe`)

1. Choose Repay, enter an imdUSD amount and confirm. No approval is needed: the vault burns the imdUSD from your wallet directly.
2. The vault takes accrued stability fees first, then principal. Fees paid are minted to the Treasury.
3. To close the position fully, repay the whole **Accrued debt**. Fees accrue every second, so an amount you read a moment earlier can leave a few units owed when your transaction lands. Repay again to clear the remainder. Sending more than you owe reverts, so do not round up.

Repay works even when feeds are stale. Errors: `ZeroAmount`; `ExcessRepayment` if you repay more than you owe; an ERC-20 balance error if you hold too little imdUSD.

## Take collateral out: Withdraw (`free`)

1. Choose Withdraw, enter an IMD amount and confirm.
2. With no debt, the vault just returns your IMD. With debt, it needs fresh agreeing feeds and refuses if the remainder would fall below `mat`.

Errors: `InsufficientCollateral` (you asked for more than you hold); `UnsafeCollateralRatio` (the remainder is too thin; the note gives the most you can take); `StaleFeed`, `PriceDivergence` (feeds not usable; wait).

## Borrow more: Borrow (`draw`)

See [Open a position](./open-a-position.md), steps 3 and 4. The same checks apply.

## Marks: what they are and how to clear one

A keeper can Mark (`bark`) any position that is below `mat`. The mark records the time and the grace length `lull()` at that moment. The mark does not liquidate you. A keeper may Liquidate (`bite`) only once the grace has passed, and only until the liquidation window `tail` ends. The terminal shows your status in the Keeper tab by inspecting your address: None, Grace (with a countdown), Active and liquidatable, or Recovered and clearable.

If you are marked and still below `mat`, act inside the grace period:

1. Deposit more collateral, or Repay debt, until the ratio is above `mat`.
2. If feeds are fresh and agree, a Deposit or Repay that restores the ratio clears the mark in the same transaction (the vault emits `Heel`). Repaying all debt also clears it.
3. Borrow and Withdraw also clear a mark when they succeed, because they require the ratio to be at least `mat` afterwards.

If a Deposit or Repay restores your ratio but a feed is stale or primary and spot disagree, the transaction succeeds but the mark stays. The vault never blocks a Deposit or Repay to inspect a mark. Once feeds are usable, press Clear mark (`heel(you)`), which anyone may call. Do this promptly. A recovery that happened only through a price move is not recorded by the contract, and an old mark does not restart grace if the position dips again before the mark expires. Clear mark reverts with `UnderwaterPosition` while you are still below `mat`.

## What liquidation costs you

If a keeper Liquidates you, the debt they repay is cancelled and they take IMD worth that debt plus the bonus (`CHOP_PERCENT`). The bonus is the cost to you. It is the same however it is split between marker, protocol and liquidator. If your collateral cannot cover the debt, the remainder is recorded as bad debt and is not forgiven to you in any later action.

## Other ways your position can change

- **Redemption.** If your ratio is below `mat` plus `gap`, a redeemer may name you as the candidate. Your debt is cancelled and some of your collateral is paid out at the redemption price, with the fee left behind in your position. See [Redeem](./redeem.md). Staying above that ceiling avoids it.
- **Paused actions.** While feeds are stale or diverge, you cannot Borrow or Withdraw with debt open, and keepers cannot Mark or Liquidate either. You can still Deposit and Repay.
