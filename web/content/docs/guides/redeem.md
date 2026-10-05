---
title: Redeem imdUSD for IMD
section: guides
order: 4
audience: everyone
sources:
  - src/CDPVault.sol:182-189
  - src/CDPVault.sol:429-511
  - src/CDPVault.sol:549-610
  - src/ParameterizedVault.sol:85-113
  - src/Treasury.sol:287-293
  - web/src/Redemption.tsx:28-379
---

# Redeem imdUSD for IMD

Redeem (`cash`) burns imdUSD from your wallet and pays you IMD. It is the floor under the price: while the market price is below what redemption pays, redeeming is a way to turn cheap imdUSD into IMD.

## What you are paid

The vault pays IMD worth the lesser of $1 and backing per imdUSD, less the fee, for each imdUSD burned:

> IMD out = imdUSD burned × min($1, backing per imdUSD) × (1 − fee) ÷ IMD price in dollars

- **Backing per imdUSD** is read with `backingPerUnit()` and shown in the terminal. It is capped at $1.
- **The fee** has a floor and a cap. It rises with the share of imdUSD supply your burn represents, and decays as time passes since the last redemption. Values are (under consideration). The fee is quoted before you send: `redemptionFeeBps(amount)`.
- If backing is below $1, you are paid less than $1 per imdUSD. The channel does not close.

## Who funds the payout

1. **The reserve first.** The vault pays from the Treasury's idle IMD.
2. **A candidate position for any shortfall.** If the reserve cannot cover the whole payout, you must name a candidate: a borrower's address. The vault cancels that borrower's debt by the matching amount and pays the rest of your IMD from their collateral.

A candidate must have debt, and its collateral ratio must be below `mat` plus the spread `gap`. The Loan book's redeemable band shows such positions. The candidate must also stay no worse off in ratio: the IMD taken may not exceed their collateral in proportion to the debt cancelled.

## Prerequisites

- imdUSD in your wallet. No approval is required: the vault burns it directly.
- The Oracle tab showing **Price actions: Open**.
- Whether the reserve covers your amount: **Reserve on hand** on the Redeem tab. If not, a candidate address.

## Steps in the terminal

1. Open the Redeem desk tab.
2. Enter the imdUSD amount. Leave slippage at its default or set your own tolerance in basis points (1 basis point is 0.01%).
3. If the reserve is short, paste a candidate address.
4. Press Quote redemption. Read **You receive**, **Your fee**, **Served by**, **Debt cancelled** and **Minimum received**.
5. Press Review redemption and confirm. This sends Redeem (`cash(amount, minImdOut, candidate)`).

`minImdOut` protects you: the call reverts if the payout falls below it, for example because someone redeemed first and raised the fee. With no candidate, pass the zero address.

## What can block it

| Revert | Cause | Recovery |
|---|---|---|
| `ZeroAmount` | Amount is zero, or it rounds to zero IMD out | Increase the amount |
| `StaleFeed`, `PriceDivergence`, `InvalidPrice` | Feeds unusable | Wait for fresh agreeing attestations |
| `ExcessRepayment` | Amount exceeds total imdUSD supply, or the shortfall exceeds the candidate's debt | Reduce the amount |
| `MinimumOutNotMet` | Payout fell below `minImdOut` | Get a new quote; widen slippage |
| `IneligibleRedemptionPosition` | The candidate has no debt, is at or above `mat` plus `gap`, or none was given when needed | Choose another candidate from the redeemable band |
| `RedemptionWorsensRatio` | The IMD taken would exceed the candidate's collateral share of the debt cancelled; typical for a position that is already deeply short | Choose another candidate or a smaller amount |
| ERC-20 balance error | You hold less imdUSD than the amount | Reduce the amount |

Each revert rolls back the whole call; your imdUSD is not burned.

## What your redemption changes

Your fee remains in the protocol and raises backing per imdUSD for everyone left. A larger burn raises the fee that the next redeemer pays, until it decays. Principal minted only recently and then cancelled does not raise that fee, which stops a borrower from pumping it at no cost.
