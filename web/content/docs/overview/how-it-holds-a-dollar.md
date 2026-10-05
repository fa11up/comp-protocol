---
title: How imdUSD holds a dollar
section: overview
order: 2
audience: everyone
sources:
  - src/CDPVault.sol:360-390
  - src/CDPVault.sol:432-511
  - src/CDPVault.sol:653-755
  - src/CDPVault.sol:830-848
  - src/CDPVault.sol:871-883
  - src/ParameterizedVault.sol:142-164
  - src/UsdPriceFeed.sol:9-95
  - src/SwarmFeed.sol:160-185
---

# How imdUSD holds a dollar

This page explains the four mechanisms that keep one imdUSD close to one dollar: borrowing, redemption, liquidation and the price they all read. It explains why; for steps see the [guides](../guides/open-a-position.md).

## Borrowing creates imdUSD against more collateral than debt

When you Borrow (`draw`), the vault checks that your collateral, valued in dollars, divided by your debt is at least the collateral ratio `mat`. Only then does it mint imdUSD to you. A position with no debt has an unlimited ratio. Total principal minted is also bounded by the debt ceiling `line`.

`mat` is not fixed. It is derived from the network health index: the healthier the swarm, the lower the requirement, and the reverse. The curve and its endpoints are (under consideration).

Debt grows with the stability fee `duty`, an annual rate accrued linearly through the index `chi`. Fees accrue as a claim on the position and are paid first when you Repay (`wipe`).

## Redemption puts a floor under the price

Anyone can burn imdUSD with Redeem (`cash`) and receive sIMD. The vault pays:

> sIMD out = imdUSD burned × payout ÷ sIMD price in dollars, where payout = min($1, backing per imdUSD) × (1 − fee)

Backing per imdUSD is the reserve plus the collateral that stands behind debt, divided by imdUSD supply, and it is capped at $1. The cap means a surplus is not paid out as a windfall. The cost of undercollateralisation is shared by redeemers pro rata rather than by closing the channel: there is no backing threshold below which redemption halts. Each redemption still needs fresh agreeing prices, an eligible candidate when the reserve is short, and a nonzero payout.

The fee has a floor and a cap, rises with the share of supply burned and decays over time. The values are (under consideration).

Redemption is paid from the Treasury's sIMD first. If the Treasury cannot cover it, the shortfall is taken from a **candidate position** the redeemer names: that position's debt is cancelled and its collateral is paid out. Only positions whose collateral ratio is below `mat` plus the spread `gap` are eligible, so redemption is aimed at the thinnest positions first. See [Redeem](../guides/redeem.md).

If imdUSD trades below the redemption price, buying it and redeeming earns a profit, which pushes the price up. That is the floor. The source implements no equivalent mechanism that pulls the price down from above; whether new borrowing does so in practice is an inference, not something the contracts guarantee.

## Liquidation removes positions that fall short

If a position's ratio falls below `mat`, any keeper can Mark it (`bark`). This starts a wait called the grace period (`lull`), which is also derived from network health and is fixed at the moment of marking. After grace ends, the mark stays usable for a liquidation window (`tail`). In that window any keeper can Liquidate (`bite`): the keeper burns imdUSD to cancel some of the borrower's debt and receives sIMD worth the debt plus a bonus (`CHOP_PERCENT`).

The bonus is split three ways: the marker's share `chip`, the protocol's share `cut`, and the rest to the biter. The sizes are (under consideration). The split divides the existing bonus; it never takes more from the borrower. Full detail is in [How liquidation works](../keepers/how-liquidation-works.md).

If the borrower restores the ratio, or the price recovers and anyone calls Clear mark (`heel`), the mark is removed.

## The price: swarm-attested, in dollars

Every figure above needs the value of the collateral, sIMD, in dollars. It is built from three parts:

1. **IMD/ETH**, a price over a block window that IdentityMD panels compute by answering a fixed question. The panel signs the answer (an EIP-712 attestation). The `PriceFeed` accepts it only if the signature, panel floors, freshness and the question itself check out.
2. **ETH/USD**, read from a Chainlink aggregator by `UsdPriceFeed`.
3. **The sIMD exchange rate**, the IMD each sIMD is worth, read from the staking vault itself by `SharePriceFeed`.

`UsdPriceFeed` multiplies the first two into IMD/USD; it is stale if either leg is stale, and it is dated at the older leg. `SharePriceFeed` multiplies that by the exchange rate. Its product is the collateral price the vault uses (`collateralPriceFeed()`), so one imdUSD of debt is one dollar's worth of collateral. Prices are per 10^18 raw units, which is why sIMD's 24 decimals against IMD's 18 cannot misvalue it.

Feeds cannot be pushed by a key. A value changes only when a valid attestation is submitted, and anyone may submit one through `SwarmRelay` ([Relay oracle updates](../keepers/relay-oracle-updates.md)). When a feed is older than its maximum age, price-dependent actions refuse with `StaleFeed` until a fresh one arrives. The maximum age is (under consideration).

### The primary and spot divergence guard

The vault holds a second feed, the spot feed: the IMD/ETH price at the last block of a window rather than the median of samples across it. It is never used to price anything. It is only compared with the primary. If the two differ by more than `skew`, the vault refuses with `PriceDivergence`.

The guard compares the raw IMD/ETH values, not the dollar price, so the ETH/USD factor cancels out. It protects against a bad or manipulated primary: an attacker would need both the window median and the last-block price to agree.

Under the guard, these actions pause: Borrow, Withdraw while debt is outstanding, Mint from work, Mark, Liquidate, Clear mark and Redeem. Deposit and Repay stay open. The `skew` bound and its limits are (under consideration).

## What can still go wrong

A stale or divergent feed halts the actions that need a price. A fast price fall can outrun liquidation and leave bad debt. Backing per imdUSD can sit below $1 and then redemption pays less than $1 per imdUSD. These are covered in [Risks and open questions](../economics/risks-and-open-questions.md).
