---
title: Keeper economics
section: keepers
order: 4
audience: keepers
sources:
  - src/CDPVault.sol:99-101
  - src/CDPVault.sol:143-164
  - src/CDPVault.sol:703-755
  - src/DeploymentConfig.sol:103-122
  - src/SwarmRelay.sol:59-114
  - src/Parameters.sol:296-310
  - docs/MAINNET-RUNBOOK.md:72-86
---

# Keeper economics

A keeper does three jobs: relay attestations, Mark unsafe positions and Liquidate them. This page covers what you are paid, what you must hold and what you risk. All parameter values are (under consideration); the page explains how the pieces fit, not their size.

## The bonus and its three parts

When you Liquidate (`bite`), you repay `debtToRepay` of the borrower's debt and receive collateral worth `debtToRepay` plus a bonus. The bonus rate is `CHOP_PERCENT`, a source constant.

> bonus = sIMD seized − `debtToRepay` valued in sIMD

The bonus is divided:

| Part | Name | Goes to |
|---|---|---|
| Marker's share | `chip` | The address recorded when the position was marked |
| Protocol's share | `cut` | The Treasury (`feeRecipient()`) |
| The rest | | The biter, plus the whole of the debt's value in sIMD |

`chip` and `cut` are fractions of the bonus, in basis points. Together they cannot exceed the whole bonus: the parameter contract refuses such a proposal (`SharesExceedBonus`) and the vault refuses a liquidation with `InvalidBonusShares` if it ever happened.

The split divides a bonus that already exists. The borrower's loss is the same whatever the split.

Three cases for who is paid:

- **You mark and bite.** You receive everything except the protocol's cut. You are both marker and biter.
- **You bite someone else's mark.** You receive the seized collateral less the protocol's cut and the marker's chip; the marker is sent their chip in the same transaction.
- **You mark, someone else bites.** You receive the chip at their liquidation.

If a partial liquidation leaves a remainder too small to seize, it is added to the biter's payout. It is not part of the bonus, so neither the marker's nor the protocol's share changes.

Because the protocol takes a cut and the marker takes a chip, a biter who did not mark receives the bonus minus both. The only bound on the two is that together they may not exceed the whole bonus. At the top of that bound a biter who did not mark receives only the debt's value back and has no reason to liquidate. Whether a given split leaves liquidation worth doing is an open question: [Risks and open questions](../economics/risks-and-open-questions.md).

## Marking costs gas and pays later

A mark pays nothing at the time. You are paid the chip only if the position is eventually liquidated while your mark stands. If the borrower recovers, you are paid nothing, and the mark costs you gas. Marks also expire after the liquidation window. Marking with `barkFor` credits a beneficiary, which is how a bundled `relayAndBark` pays the keeper rather than the relay.

## Relaying costs money

Relaying an attestation costs gas, and obtaining the attestation costs whatever the oracle service charges.

The protocol pays for its own attestations: the Treasury streams IMD to `OracleAsker`, which buys an update when a feed nears staleness or IMD's pool drifts from it ([How updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). Calling `ask`, `arm` or `fundOracle` costs only gas. Relayers are not reimbursed.

Relaying has no direct on-chain reward in the source. The benefit is indirect: it opens the actions that pay (Mark, Liquidate) and it keeps the protocol operable.

## What you must hold

Three separate balances, not interchangeable:

1. **ETH for gas.** Every relay, mark, liquidation and clear mark.
2. **imdUSD inventory.** Liquidation burns the caller's imdUSD. A keeper with none cannot liquidate anything. This is working capital, not an expense, and it comes back as sIMD at a discount, which you then hold, or unstake and sell.
3. **Nothing for attestations, normally.** The Treasury pays for them. Hold IMD only if you want to buy an attestation yourself when the protocol's daily budget is spent.

If you liquidate through `SwarmRelay`, also approve the relay to spend at least `debtToRepay` of imdUSD.

## Risks you carry

- **Inventory risk.** You are paid in sIMD, whose dollar price moves with IMD's. Between receiving it and selling it, you carry that risk, and unstaking adds at least one block: sIMD received in a block cannot be unstaked in that same block.
- **Smaller positions.** Gas must be less than the bonus on the debt you can cover, after the cut and chip.
- **Races.** Other keepers can mark, bite or relay first. You lose gas on a reverted transaction. Bundling with `relayAndBite` removes the gap between your update and your action, not the race to the block.
- **Feed risk.** A stale or divergent feed halts every action that pays you.
- **Bad debt.** If a position is worth less than its debt plus the bonus, no one can profitably liquidate it in full, and the shortfall becomes recorded bad debt.
- **Grace.** You cannot liquidate before grace ends, and the borrower can recover in that time, in which case your mark earns nothing.
- **Stranded rewards.** If `SwarmRelay` is a position's recorded marker and the position is then liquidated by a direct `bite`, the chip is paid to the relay and cannot be recovered. A `relayAndBite` passes it on to its caller with the rest of the payout. Mark with `relayAndBark` or `barkFor` naming your own address.

## Operating notes

Run the keeper from a hot wallet on its own machine; the contract does not need a privileged key. The Treasury is not a funding source for keepers: its withdrawals are restricted to a fixed operator account, so a keeper tops up from its own funds. The off-chain keeper software that watches prices and relays is not part of this repository.
