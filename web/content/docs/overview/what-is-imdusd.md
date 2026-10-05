---
title: What is imdUSD
section: overview
order: 1
audience: everyone
sources:
  - src/ImdUSD.sol:12-75
  - src/ParameterizedVault.sol:11-25
  - src/ParameterizedVault.sol:142-154
  - src/CDPVault.sol:432-490
  - docs/NAMING.md:1-12
---

# What is imdUSD

imdUSD is a stablecoin meant to be worth one US dollar. You get it by locking IMD, the IdentityMD token, in a vault and borrowing imdUSD against it. How it holds that value is in [How imdUSD holds a dollar](./how-it-holds-a-dollar.md).

The vault is the only contract that can mint or burn imdUSD. There is no owner, pause switch or upgrade path on the token (`ImdUSD`). Contract addresses: (waiting for mainnet launch).

## Who it is for

- **Borrowers** who hold IMD and want dollars without selling it. Start with [Open a position](../guides/open-a-position.md).
- **Holders** who want to turn imdUSD back into IMD. See [Redeem](../guides/redeem.md).
- **Keepers**, who keep the system solvent by relaying prices and liquidating unsafe positions, and are paid a share of the liquidation bonus. See [How liquidation works](../keepers/how-liquidation-works.md).

## What backs it

Two things stand behind imdUSD:

1. **Collateral.** Every position must hold more IMD, valued in dollars, than the imdUSD it owes. The required margin (the collateral ratio, `mat`) rises and falls with the network health index.
2. **A reserve.** The protocol's Treasury holds IMD and any other assets governance lists. Redemptions are paid from it first.

The value of IMD in dollars is not read from an exchange contract. It is an attested price: a panel of IdentityMD agents answers a fixed question, the answer is signed, and anyone may submit it on chain.

## What it pays when redeemed

A holder can burn imdUSD for IMD at the lesser of $1 and the backing per imdUSD, less a fee. If the system is fully backed, that is $1 of IMD per imdUSD minus the fee. If it is not, the payout shrinks with the backing instead of the channel closing.

## What is unproven

- The peg depends on arbitrage between the market price and the redemption price. Nothing guarantees the market price stays at $1.
- The price comes from one signer (the IdentityMD attester) answering one pinned question. The panel size and agreement floors, the question binding and the divergence guard bound that trust; they do not remove it.
- Network health is also an attested figure. It moves the collateral requirement and the liquidation grace.
- A liquidation can leave bad debt. There is no insurance fund and no write-off path; the shortfall is recorded and stays.
- Work-backed issuance (Mint from work, `earn`) rests on a swarm-published task tally that a panel attests. It is not an on-chain proof that the work happened.
- The economic parameters are (under consideration); see [Risks and open questions](../economics/risks-and-open-questions.md).

## A note on names

The vault's verbs and parameters (`lock`, `draw`, `bite`, `mat`, `duty` and the rest) are an homage to MakerDAO, which invented the collateralised stablecoin; some are borrowed and some coined in its spirit. Their origins are recorded in `docs/NAMING.md`. The terminal and these guides name actions in plain words.
