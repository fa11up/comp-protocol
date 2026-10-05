---
title: Open a position
section: guides
order: 2
audience: borrowers
sources:
  - src/CDPVault.sol:328-338
  - src/CDPVault.sol:360-390
  - src/CDPVault.sol:55-79
  - src/CDPVault.sol:759-801
  - src/CDPVault.sol:863-883
  - web/src/Panes.tsx:117-207
---

# Open a position

This guide takes you from holding IMD to holding borrowed imdUSD. It uses two vault calls: Deposit (`lock`) and Borrow (`draw`). For how the numbers work, read [How imdUSD holds a dollar](../overview/how-it-holds-a-dollar.md) first if you have not.

## Before you start

- A wallet holding IMD on the same chain as the vault, and a little ETH for gas.
- The terminal open at `/terminal/` with the wallet connected ([Use the terminal](./use-the-terminal.md)).
- The Oracle tab showing **Price actions: Open**. Borrowing is refused while a feed is stale or primary and spot disagree. Depositing is not.
- The vault address (waiting for mainnet launch). Check it against [Contracts and addresses](../reference/contracts-and-addresses.md) before approving anything.

## Steps

1. **Approve IMD.** In Position, choose Deposit and enter the amount. The first button reads "Approve IMD". It sends an ERC-20 `approve` to the vault for exactly that amount. This is a separate transaction.
2. **Deposit (`lock(amount)`).** Press the button again, now labelled "Review deposit", and confirm. The vault pulls your IMD, adds it to your position and emits `Lock`. You owe nothing yet and can withdraw it at any time, with no price check, while you have no debt.
3. **Check what you can borrow.** The **Can still borrow** figure is the most imdUSD you could add at the current price without going below the required ratio `mat`. Do not borrow all of it. `mat` moves with network health, and the IMD price moves, so a position at the limit can become unsafe without any action from you. See [Manage and protect a position](./manage-and-protect-a-position.md).
4. **Borrow (`draw(amount)`).** Choose Borrow, enter an imdUSD amount smaller than the maximum and confirm. The vault checks your resulting debt against `mat`, checks the total against the debt ceiling `line`, mints the imdUSD to you and emits `Draw`.
5. **Read the result.** Collateral ratio, Liquidation price and Accrued debt update. Note the liquidation price.

Your debt is the principal you drew plus the stability fee (`duty`) accrued through the index `chi`. It rises over time even if you do nothing.

## What can block it

| Revert | Where | Cause | Recovery |
|---|---|---|---|
| `ZeroAmount` | Deposit, Borrow | Amount is zero | Enter a positive amount |
| `ERC20InsufficientAllowance` / `ERC20InsufficientBalance` | Deposit | Approval is smaller than the amount, or you hold too little IMD | Approve the exact amount again; lower the amount |
| `UnexpectedCollateralReceived` | Deposit | The token delivered a different amount than requested | The vault refuses such tokens; there is no recovery for that token |
| `StaleFeed` | Borrow | The IMD/ETH, network health, spot or ETH/USD feed is older than its maximum age | Wait for someone to relay a fresh attestation; check the Oracle tab |
| `PriceDivergence` | Borrow | Primary and spot differ by more than `skew` | Wait for them to converge |
| `InvalidPrice` | Borrow | A price reads as zero | Wait for a valid attestation |
| `UnsafeCollateralRatio` | Borrow | Your debt after borrowing would be above what `mat` allows | Borrow less, or Deposit more |
| `DebtCeilingReached` | Borrow | Total principal would pass the ceiling `line` | Borrow less; wait for others to Repay |
| `NotInitialized` | Borrow | The stablecoin is not linked to this vault | Do not use this contract |

Nothing is sent when a simulation fails; the note under the button names the figure that blocked you.

## What you now hold

You hold imdUSD in your wallet and a position in the vault. To end it, [Manage and protect a position](./manage-and-protect-a-position.md) shows how to Repay and Withdraw.
