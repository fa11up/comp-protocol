---
title: Vault functions
section: reference
order: 2
audience: integrators
pending: true
sources:
  - src/CDPVault.sol:32-1075
  - src/ParameterizedVault.sol:25-260
  - docs/abi/ParameterizedVault.json:1
  - docs/abi/CDPVault.json:1
---

# Vault functions

Every function in the `ParameterizedVault` ABI (`docs/abi/ParameterizedVault.json`), including those it inherits from `CDPVault` and the getters Solidity generates. How the contracts are wired together is in [Contracts and addresses](./contracts-and-addresses.md).

**Units.** Amounts are raw token units: sIMD has 24 decimals, IMD and imdUSD 18. The vault never reads `decimals()`; it prices collateral per 1e18 raw units, so the price carries the scale. Dollar prices and indices are scaled by 1e18. A basis point is a hundredth of a percent; ratios such as `mat` are whole percentages. Times are Unix seconds and durations are seconds.

**Who can call.** Every write is open to anyone, subject to its checks, and acts on `msg.sender`'s own position unless it names an `owner`. None accepts ETH. Every read is free and changes nothing, but a successful read does not mean a write will succeed. A failed write rolls back completely; see [Events and errors](./events-and-errors.md).

**Live prices.** Many functions need *live prices*: the primary, network health and dollar prices are not stale, the spot price is not stale or zero, and primary and spot agree within `skew`. `lock`, `lockIMD`, `wipe` and `free` with no debt do not need them. `mat` is the minimum collateral ratio and `line` the borrowing ceiling.

## Functions that change state

### `bark(address owner)`

Mark an unsafe position. Needs live prices and the owner below `mat()`. The caller is recorded as the marker. Same as `barkFor(owner, msg.sender)`.

### `barkFor(address owner, address beneficiary)`

Mark an unsafe position and record `beneficiary` as the marker. Needs a nonzero `beneficiary`, live prices and the owner below `mat()`. No permission from the owner is needed.

If the position already has a mark that has not expired, nothing changes and no event is emitted. Otherwise stores the time, the grace from `lull()` and the marker, and emits `Bark`. Nothing is paid.

### `bite(address owner, uint256 debtToRepay)`

Liquidate. Needs a positive `debtToRepay`, live prices, an unsafe owner with a mark whose grace has passed and whose window has not closed, enough debt to repay and enough collateral for the full payout, valid bonus shares, and enough imdUSD in the caller's wallet. No approval is needed.

Charges the owner's accrued fees, cancels fees then principal, burns the caller's imdUSD and remints the fee part to the Treasury. Takes the collateral and pays the marker, the Treasury and the caller (see [Keeper economics](../keepers/keeper-economics.md) for the split). Collateral too small for any further liquidation goes to the caller. If the collateral runs out with debt left, records the rest as bad debt. Clears the mark if the position is now safe. Emits `Bite`, and `Heel` if a mark was cleared.

### `cash(uint256 amount, uint256 minGemOut, address candidate)`

Redeem imdUSD for sIMD. Needs a positive `amount` no larger than total supply, enough imdUSD in the caller's wallet, live prices, and a payout above zero and at least `minGemOut`. If the Treasury cannot cover the payout, `candidate` must have debt, a ratio strictly below `mat() + gap()`, enough debt for the shortfall, and must not end up with a worse collateral-to-debt ratio.

Burns all of `amount`, pays from the Treasury's sIMD first and from the candidate's collateral for the rest, cancelling the candidate's fees before principal (fees are not reminted). Updates the fee base and redemption time. Emits `Cash`, and `Heel` if a mark was cleared. Returns `gemOut`, the sIMD paid. No partial fills and no approval.

### `cover(address owner, uint256 amount)`

Cancel a drained position's bad debt with the Treasury's imdUSD. Anyone may call it. Needs a positive `amount` no larger than the position's debt, and a position with recorded bad debt. The position may hold no collateral; or dust (worth under about 1.2 imdUSD, or a millionth of a debt above a million), which is moved to the Treasury first; or collateral worth less than the position's recorded bad debt, which the Treasury takes at its value, so `amount` must then be at least that value. Anything but no collateral needs live prices unless the dust is below what a liquidation of one wei of debt would seize.

Burns `amount` of the Treasury's imdUSD and applies it like a repayment: fees first (reminted to the Treasury), then principal. `totalDebt`, the position's bad debt and `totalBadDebt` fall together, which raises backing for every holder. Emits `Cover`. Reverts with `NoRealizedBadDebt` if the position holds collateral worth at least its recorded bad debt, or has no recorded bad debt, and with `CoverBelowCollateralValue` if it takes collateral for less than its value.

### `draw(uint256 amount)`

Borrow imdUSD. Needs a positive `amount`, live prices, the stablecoin linked to this vault, a resulting ratio of at least `mat()`, and total principal still within `line()`.

Charges the caller's accrued fees, adds the principal, mints imdUSD to the caller and clears any mark. Emits `Draw`, and `Heel` if a mark was cleared.

### `drip()`

Save the current stability-fee index. Anyone may call it; no balances, prices or positions involved.

Stores `chi()` and the time, and emits `IndexCheckpointed`. Collects no fees and touches no position.

### `earn(uint256 amount)`

Mint imdUSD against work rights. Needs a positive `amount`, live prices, the stablecoin linked to this vault, enough `oracle.mintingRights(msg.sender)`, and `totalEarned + amount` within `earnLine()`.

Uses up the caller's rights and mints imdUSD to them. Adds no debt or collateral. Emits `Earn`. Whether this is open at launch: —.

### `free(uint256 amount)`

Withdraw sIMD. Needs a positive `amount` no larger than the caller's collateral. With debt open, also needs live prices and a resulting ratio of at least `mat()`.

Reduces the collateral, clears any mark and sends the sIMD. Emits `Free`, and `Heel` if a mark was cleared.

### `heel(address owner)`

Clear a mark from a position that has recovered. Anyone may call it. Needs live prices and the owner at or above `mat()`, or with no debt.

Removes the mark and emits `Heel`. On a safe position with no mark it does nothing.

### `lock(uint256 amount)`

Deposit sIMD. Needs a positive `amount`, enough sIMD and approval to the vault, and exactly `amount` arriving. No price checks.

Adds to the caller's collateral. Clears a mark if the position can be seen to have recovered, or has no debt. Emits `Lock`, and `Heel` if a mark was cleared.

### `lockIMD(uint256 assets)`

Deposit IMD, which the vault stakes for you. Needs a positive `assets`, enough IMD and approval to the vault, and a collateral that is a staking-vault share (otherwise `CollateralNotWrappable`). No price checks.

Pulls the IMD, stakes it on the caller's behalf, and credits the sIMD that actually arrives (measured by balance). Otherwise the same as `lock`. Emits `Lock` with the sIMD credited, and `Heel` if a mark was cleared. The vault never unstakes; all payouts are in sIMD.

### `wipe(uint256 amount)`

Repay debt. Needs a positive `amount` no larger than the caller's debt and enough imdUSD in the wallet. No approval or price checks.

Charges accrued fees, burns the imdUSD, cancels fees before principal and remints the fee part to the Treasury. Clears a mark if the position can be seen to have recovered. Emits `Wipe`, and `Heel` if a mark was cleared.

## Read-only functions

None of these change anything. Reads that depend on a feed can still revert if the feed or arithmetic fails.

### `BACKING_WARMUP()`

Returns `uint256`. One day, in seconds. New debt and collateral not yet counted toward backing per imdUSD halve every six hours and count in full once a day passes in which the vault's new capital is not touched; decreases count immediately. A position's own warm capital that left (a repayment, a withdrawal, a liquidation or redemption against it) can come back and count at once, less what it would have cooled while away, and nothing after a day.

### `CHOP_PERCENT()`

Returns `uint256`. The liquidation bonus, as a percent of debt repaid: —. Fixed.

### `REDEMPTION_FEE_CAP_BPS()`

Returns `uint256`. The highest redemption fee, in basis points: —. Fixed.

### `REDEMPTION_FEE_FLOOR_BPS()`

Returns `uint256`. The lowest redemption fee, in basis points: —. Fixed.

### `backedDebt()`

Returns `uint256`. The principal that counts toward the work-minting ceiling: total principal, leaving out principal added in this transaction (and, while minting from work is on, principal that is still warming up), minus recorded bad debt, never below zero. In imdUSD raw units.

### `backingPerUnit()`

Returns `uint256`. Dollar backing per imdUSD, scaled by 1e18 and capped at $1: the Treasury's sIMD, other listed reserve assets and collateral that secures debt, divided by supply. It is the lower of the live figure and a lagged one in which newly added debt and collateral count only as they warm up (`BACKING_WARMUP`). Redemption pays against this. Needs a nonzero dollar price but does not check freshness. See [Monetary policy](../economics/monetary-policy.md).

### `badDebtOf(address owner)`

Returns `uint256`. How much of the position's debt its collateral cannot cover, counting the full liquidation bonus. Zero with no debt; all of the debt if collateral is gone. Otherwise needs a nonzero dollar price. No freshness check.

### `chi()`

Returns `uint256`. The stability-fee index, scaled by 1e18: the last saved value plus simple interest at `duty()` since. No compounding.

### `chiOf(address account)`

Returns `uint256 index`. The index value when this account's fees were last charged. Zero for an account that never borrowed.

### `chip()`

Returns `uint256`. The marker's share of the liquidation bonus, in basis points: —. Governed.

### `collateralPriceFeed()`

Returns `address`. The vault's `SharePriceFeed` (waiting for mainnet launch): USD per 1e18 raw sIMD units, the staking vault's `convertToAssets(1e18)` times `usdPriceFeed()`. Stale whenever `usdPriceFeed()` is. Every collateral figure uses this price.

### `collateralRatio(address owner)`

Returns `uint256`. Collateral value divided by debt, as a whole percentage. Debt-free or too large to represent returns the maximum integer. Needs a nonzero dollar price if there is debt; no freshness check.

### `cut()`

Returns `uint256`. The protocol's share of the liquidation bonus, in basis points: —. Governed.

### `debtOf(address owner)`

Returns `uint256`. Principal plus unpaid fees, in imdUSD raw units.

### `decayedRedemptionBaseRate()`

Returns `uint256`. The redemption fee base after decaying since `lastRedemptionAt`, as a fraction scaled by 1e18.

### `deployedAt()`

Returns `uint256`. When the vault was deployed. Fees are not measured from it.

### `duty()`

Returns `uint256`. The yearly stability fee, in basis points: —. Governed.

### `earnLine()`

Returns `uint256`. The ceiling on total work minting, in imdUSD raw units: `reserveValue()` plus `backedDebt()` times `earnMat()` basis points. Unreadable reserve entries count for nothing; no freshness check.

### `earnMat()`

Returns `uint256`. How much of `backedDebt()` counts toward the work ceiling, in basis points: —. Governed.

### `feeRecipient()`

Returns `address`. The vault's Treasury (waiting for mainnet launch). Receives the protocol's bonus share and paid fees.

### `gap()`

Returns `uint256`. How far above `mat()` a position can be redeemed against, in whole percentage points: —. Governed.

### `gem()`

Returns `address`. The collateral token, sIMD (waiting for mainnet launch).

### `indexCheckpoint()`

Returns `uint256`. The last saved stability-fee index, scaled by 1e18. Changed by `drip()`.

### `indexCheckpointAt()`

Returns `uint256`. When `drip()` last saved the index; starts at deployment.

### `laggedNow()`

Returns `uint256 debt, uint256 secured`. The lagged principal and secured collateral as of now: the live figures less what is still new, tracked position by position. These are what backing per imdUSD counts while new capital warms up.

### `lastRedemptionAt()`

Returns `uint256`. When the last redemption happened; starts at deployment.

### `line()`

Returns `uint256`. The ceiling on outstanding borrowed principal, in imdUSD raw units: —. Governed. Fees and work minting do not count against it.

### `liquidationMarks(address account)`

Returns `uint256 markedAt, uint256 grace, bool marked, address marker`. The stored mark: when it was made, the grace in seconds, whether it exists and who marked. An expired mark can still read `marked = true`.

### `lull()`

Returns `uint256`. The grace a new mark would get, in seconds, from the last accepted network health value. No freshness check.

### `mat()`

Returns `uint256`. The minimum collateral ratio as a whole percentage, from the last accepted network health value. No freshness check.

### `nhiFeed()`

Returns `address`. The network health feed (waiting for mainnet launch).

### `oracle()`

Returns `address`. The work oracle in use: a replacement applied through `Parameters.proposeWorkOracle` if there is one, otherwise the one this vault created (waiting for mainnet launch).

### `parameters()`

Returns `address`. The vault's `Parameters` (waiting for mainnet launch).

### `positions(address owner)`

Returns `uint256 collateral, uint256 debt`. Collateral in raw sIMD units and debt including fees in imdUSD raw units.

### `priceFeed()`

Returns `address`. The primary IMD/ETH feed (waiting for mainnet launch). This is not the dollar price.

### `redemptionBaseRate()`

Returns `uint256`. The stored redemption fee base, scaled by 1e18, before decay. Updated by `cash`.

### `redemptionCeilingCR()`

Returns `uint256`. `mat() + gap()`, in whole percentage points. A candidate must be strictly below it.

### `redemptionDivisor()`

Returns `uint256`. How fast the redemption fee climbs: each redemption adds redeemed ÷ supply ÷ this to the base. Governed: —.

### `redemptionFeeBps(uint256 amount)`

Returns `uint256`. The fee a redemption of `amount` would pay, in basis points, including the rise from its own size, rounded up. With zero it quotes the floor plus the decayed base. Reverts with `ExcessRepayment` above total supply. Does not check balances, candidates or prices.

### `redemptionReserve()`

Returns `uint256`. The Treasury's sIMD, in raw units, whether or not sIMD is listed as a reserve asset.

### `reserveValue()`

Returns `uint256`. The Treasury's listed assets at their discounted dollar value, scaled by 1e18. Same as `treasury.reserveValueUsd()`. Unreadable entries count for nothing.

### `securedCollateral()`

Returns `uint256`. Total collateral that counts as securing debt, in raw sIMD units, each position capped by its own principal as of its last change. Not the vault's token balance.

### `skew()`

Returns `uint256`. How far primary and spot may differ, as basis points of the primary: —. Governed.

### `spotFeed()`

Returns `address`. The spot IMD/ETH feed, used only for comparison (waiting for mainnet launch).

### `stabilityFeeOf(address owner)`

Returns `uint256`. Unpaid fees, in imdUSD raw units. Fees do not earn fees.

### `stablecoin()`

Returns `address`. The `ImdUSD` token (waiting for mainnet launch).

### `tail()`

Returns `uint256`. How long a mark stays usable after its grace, in seconds: the shorter of `priceFeed.maxAge()` and `nhiFeed.maxAge()`.

### `totalBadDebt()`

Returns `uint256`. Recorded bad debt, in imdUSD raw units. Rises when a position is drained and falls when bad debt is repaid or covered.

### `totalDebt()`

Returns `uint256`. Outstanding borrowed principal, in imdUSD raw units, including principal on drained positions. Excludes unpaid fees and work minting.

### `totalEarned()`

Returns `uint256`. Total imdUSD ever minted by `earn`. Never goes down.

### `totalFeesMinted()`

Returns `uint256`. Total fees reminted to the Treasury by `wipe`, `bite` and `cover`. Not extra supply: the payer burned the same amount.

### `totalNonPrincipalRedeemed()`

Returns `uint256`. Total imdUSD burned by `cash` without cancelling principal: reserve-paid burns and cancelled unpaid fees.

### `treasury()`

Returns `address`. The vault's Treasury (waiting for mainnet launch).

### `usdPriceFeed()`

Returns `address`. The vault's IMD/USD feed (waiting for mainnet launch). Prices IMD, not sIMD; `collateralPriceFeed()` builds on it.

For a consistent snapshot, see [Reading state](./reading-state.md). For step-by-step use, see [Open a position](../guides/open-a-position.md), [Redeem](../guides/redeem.md) and [Mark and liquidate](../keepers/mark-and-liquidate.md).
