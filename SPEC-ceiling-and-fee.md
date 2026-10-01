# Debt ceiling and liquidation fee split

Both implemented in `patches/cdpvault-ceiling-fee.patch`, both tested, both **inert by default** so the
swarm's 185 tests pass unchanged. A deployment turns them on by overriding two functions.

## Why these two, and why now

The vault currently has **no fee of any kind and no cap on exposure**. The only percentage anywhere is
`LIQUIDATION_BONUS_PERCENT = 10`, all of which goes to the liquidator. For a mainnet MVP the ceiling is
the single highest-value safety feature missing — it converts "unbounded risk" into "a known maximum
loss" — and the fee split is the cheapest revenue mechanism that needs no new accounting.

## Debt ceiling

```solidity
function debtCeiling() public view virtual returns (uint256) { return type(uint256).max; }
uint256 public totalDebt;   // collateral-backed debt only
```

`mintCOMP` reverts `DebtCeilingReached` when `totalDebt + amount > debtCeiling()`. `repayCOMP` and
`liquidate` decrement `totalDebt`, so repaid headroom is reusable.

**It caps the collateral-backed channel only.** `mintFromWork` consumes oracle rights and records no
debt, so it is deliberately outside the cap: work-minted supply is not a solvency risk, and capping it
would throttle the mechanism the protocol exists to demonstrate. The supply invariant
`totalSupply == summed debt + totalWorkMinted` is unaffected.

**There is no admin, so a ceiling is permanent for that vault.** Raising it means a new vault and a
migration. That is the price of having no keys, and it is the right trade for a first mainnet
deployment — but it means the opening number should be one you are willing to live with for as long as
that vault runs, not an optimistic guess.

## Liquidation fee split

```solidity
function protocolBonusShareBps() public view virtual returns (uint256) { return 0; }
```

```
seized    = floor(debtToRepay * 1.1e18 / price)        // unchanged
principal = floor(debtToRepay * 1e18 / price)
cut       = floor((seized - principal) * shareBps / 10000)
liquidator receives seized - cut
FEE_RECIPIENT receives cut
```

**The cut comes out of the bonus, never the principal.** The borrower loses exactly `seized` whether the
fee is on or off, so turning it on never makes liquidation harsher — it only moves value from the
liquidator to the protocol. A liquidator is always made whole on the debt it burned; the test asserts
`seized - cut > principal`.

At `shareBps = 2000` the protocol takes a fifth of the bonus, so 2% of the repaid debt, and the
liquidator keeps 8%.

### The conflict this creates

Revenue from liquidations means **the party that sets the price profits when positions are liquidated.**
Today that party is a single key in `sim.config.js` which is both the feed's reporter and its relayer.
`FEE_RECIPIENT` is pinned in `DeploymentConfig.sol` with a comment saying it must not be the reporter or
relayer, but a comment is not a guarantee — nothing in the contract enforces it, because the feed and the
vault do not know about each other's authorities.

Before this is switched on with real money: the price must come from attestations rather than a reporter
key, and `FEE_RECIPIENT` must be an address that cannot move the feed. Until then the honest setting is
`0`.

## What is not specced here

A **stability fee** — interest accruing on debt, paid on repay — is the only mechanism that scales with
usage rather than with distress, and it is the real revenue line. It needs per-position accrual against a
timestamp and a global index, which is a materially larger change than either of the above and wants its
own review. Worth doing, not worth bundling.

## Tests

`test/InHouse.t.sol`, run against a Sepolia fork:

- `test_debtCeilingStopsMintingAndFreesOnRepay` — mints to the ceiling, asserts the next wei reverts
  `DebtCeilingReached`, repays, asserts the freed headroom is reusable, and checks `totalDebt` tracks.
- `test_feeSplitTakesFromBonusNotPrincipal` — asserts the borrower's loss is identical to the no-fee case,
  the recipient receives exactly the computed cut, the liquidator receives the remainder, and the
  liquidator still clears the principal. Borrower, liquidator and fee recipient are three separate
  accounts, because collapsing any two of them hides the bug.

A `CappedFeeVault` subclass in the test file overrides both functions, so the mechanism is exercised while
the production defaults stay inert.
