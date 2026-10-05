---
title: Vault functions
section: reference
order: 2
audience: integrators
sources:
  - src/CDPVault.sol:32-1075
  - src/ParameterizedVault.sol:25-225
  - docs/abi/ParameterizedVault.json:1
  - docs/abi/CDPVault.json:1
---

# Vault functions

`ParameterizedVault` exposes the following complete ABI, including inherited `CDPVault` functions and compiler-generated getters. Signatures and return fields are generated from `docs/abi/ParameterizedVault.json`; behavior follows the Solidity implementation and overrides. Constructor wiring is in [Contracts and addresses](./contracts-and-addresses.md).

Amounts are raw token units: sIMD collateral has 24 decimals, IMD and imdUSD 18. The vault never reads `decimals()`; it prices collateral per 1e18 raw units, so the scale is carried by the price. Dollar prices and indices use a 1e18 fixed-point scale. A basis point is one hundredth of a percentage point; ratios such as `mat` use whole percentage points instead. Timestamps are Unix seconds and durations are seconds. Scaling conventions are not proposed economic values.

All writes are nonpayable and permissionless subject to their checks; caller-owned position actions act on `msg.sender`. There is no native-ETH entry point. All reads are `view`, require no authorization and change no storage, balances or events. A successful read does not establish transaction eligibility. Token, oracle and arithmetic failures can propagate; all reverted writes roll back atomically. See [Events and errors](./events-and-errors.md).

Here, **fresh agreeing prices** means fresh primary, NHI and dollar-price legs, a fresh nonzero spot, and raw IMD/ETH disagreement within `skew`, the tolerance (under consideration). `lock`, `wipe` and debt-free `free` bypass those gates. `mat` is the required ratio; `line` is the principal ceiling; both values are (under consideration).

## State-changing functions

### `bark(address owner)`

Mark an unsafe position. Requires fresh agreeing prices and owner ratio below `mat()`. Caller is the beneficiary.

Delegates to `barkFor(owner, msg.sender)`; see that entry for mark persistence and events.

### `barkFor(address owner, address beneficiary)`

Mark for a beneficiary. Nonzero `beneficiary`, fresh agreeing prices and owner ratio below `mat()` are required. No ownership permission.

An unexpired mark is preserved without an event. Otherwise writes timestamp, the grace from `lull()`, marked status and beneficiary; emits `Bark`. No collateral or reward moves.

### `bite(address owner, uint256 debtToRepay)`

Liquidate. Positive `debtToRepay`, fresh agreeing prices, an unsafe owner, a mark, elapsed stored grace, an unexpired window, enough debt and collateral to cover the full payout, valid bonus shares and enough caller imdUSD are required. No imdUSD allowance.

Accrues owner fees, reduces fees then principal, burns caller imdUSD and remints paid fees to Treasury. Seizes collateral; pays marker, Treasury and caller; may sweep unseizable dust to caller. Updates secured collateral and records residual debt if collateral is exhausted. Clears a recovered mark. Emits `Bite`, possibly `Heel`. Returns no value.

### `cash(uint256 amount, uint256 minGemOut, address candidate)`

Redeem. Positive `amount` within supply, enough caller imdUSD, fresh agreeing prices, nonzero calculated output and output at least `minGemOut` are required. If reserve is insufficient, `candidate` must have debt and ratio strictly below `mat()+gap()`, enough debt to cancel, and a non-worsening exact collateral/debt fraction.

Burns all `amount`, pays Treasury sIMD first and candidate collateral for the shortfall. Cancels candidate fees before principal without reminting fees. Updates secured collateral, loss/mark state, `totalNonPrincipalRedeemed`, base rate and redemption timestamp. Emits `Cash`, possibly `Heel`. Returns collateral (sIMD) raw units `gemOut`. Atomic; no partial fill or approval.

### `draw(uint256 amount)`

Borrow imdUSD. Positive `amount`, fresh agreeing prices, reciprocal stablecoin binding, resulting accrued-debt ratio at least `mat()`, and resulting total principal within `line()` are required.

Accrues caller fees, adds principal and supply, updates secured collateral and the weighted fresh-principal record, clears any mark, mints to caller. Emits `Draw` and possibly `Heel`.

### `drip()`

Checkpoint the stability-fee index. Permissionless; no token balance, price or position requirement.

Stores `chi()` in `indexCheckpoint`, stores block timestamp in `indexCheckpointAt`, emits `IndexCheckpointed`. Does not mint, collect fees or rewrite every position.

### `earn(uint256 amount)`

Mint against work rights. Positive `amount`, fresh pricing feeds, reciprocal stablecoin binding, enough `oracle.mintingRights(msg.sender)`, and `totalEarned + amount <= earnLine()` are required. The finite ceiling also requires primary/spot agreement.

Increases cumulative `totalEarned`, consumes caller work rights and mints imdUSD to caller. Adds no position debt or collateral. Emits `Earn`. Whether earn is open at launch is (under consideration).

### `free(uint256 amount)`

Withdraw collateral. Positive `amount` no greater than caller collateral. With debt, fresh agreeing prices and a resulting ratio at least `mat()` are required.

Reduces caller collateral, recomputes secured collateral, clears any mark, transfers sIMD out. Emits `Free` and possibly `Heel`.

### `heel(address owner)`

Clear a recovered mark. Fresh agreeing prices and owner ratio at least `mat()` or zero debt are required. Anyone may call.

Deletes an existing mark and emits `Heel`; a healthy unmarked position is a successful no-op.

### `lock(uint256 amount)`

Deposit collateral (sIMD). Positive `amount`, sufficient sIMD balance and allowance to the vault, and an exact balance increase are required. No freshness or agreement gate.

Adds caller collateral, transfers sIMD into the vault, recomputes secured collateral, and clears a mark only on observable recovery or zero debt. Emits `Lock` and possibly `Heel`.

### `lockIMD(uint256 assets)`

Deposit IMD as collateral; the vault stakes it. Positive `assets`, sufficient IMD balance and allowance to the vault, and a collateral token that is a staking-vault share are required (otherwise `CollateralNotWrappable`). No freshness or agreement gate.

Pulls IMD, deposits it into the staking vault on the caller's behalf, and credits the sIMD actually received, measured by balance rather than by what the staking vault reports. Otherwise identical to `lock`, including mark clearing. Emits `Lock` with the sIMD credited, and possibly `Heel`. The vault never unstakes; payouts are sIMD.

### `wipe(uint256 amount)`

Repay debt. Positive `amount` no greater than caller accrued debt, and enough caller imdUSD. No allowance or freshness gate.

Accrues fees, burns caller imdUSD, retires fees before principal, remints the paid fees to Treasury, updates principal, secured collateral, fresh-debt and recorded-loss accounting. Clears a recovered mark when observable. Emits `Wipe`, possibly `Heel`.

## Read-only functions and generated getters

Every entry below is unrestricted and changes nothing. Feed-dependent reads can propagate dependency or arithmetic errors even where they lack an explicit validity check.

### `CHOP_PERCENT()`

Returns `uint256`. Fixed liquidation bonus, percent of debt repaid: (under consideration).

### `REDEMPTION_FEE_CAP_BPS()`

Returns `uint256`. Fixed maximum redemption fee in basis points: (under consideration).

### `REDEMPTION_FEE_FLOOR_BPS()`

Returns `uint256`. Fixed minimum redemption fee in basis points: (under consideration).

### `backedDebt()`

Returns `uint256`. Principal eligible for work backing: min(total principal, principal at transaction start), less recorded bad debt, saturating at zero. In imdUSD raw units; no price read.

### `backingPerUnit()`

Returns `uint256`. USD backing per imdUSD, scaled by 1e18 and capped at $1 per imdUSD. Requires a nonzero dollar price, but does not itself enforce freshness or agreement. See monetary policy for the conservative numerator.

### `badDebtOf(address owner)`

Returns `uint256`. Accrued imdUSD debt beyond collateral capacity including the full liquidation bonus. No freshness/agreement check. Zero debt returns zero; exhausted collateral returns all debt; otherwise requires a nonzero dollar price.

### `chi()`

Returns `uint256`. Stability-fee index, scaled by 1e18: checkpoint plus linear time accrual at `duty()`. No compounding or price gate.

### `chiOf(address account)`

Returns `uint256 index`. Stored index checkpoint for this account, set when its debt is accrued. Scaled by 1e18; unset accounts return zero.

### `chip()`

Returns `uint256`. Governed marker share of the liquidation bonus, in basis points: (under consideration).

### `collateralPriceFeed()`

Returns `address`. Immutable vault-created `SharePriceFeed`: (waiting for mainnet launch). USD per 1e18 raw sIMD units, equal to the staking vault's `convertToAssets(1e18)` times `usdPriceFeed()`. Stale whenever `usdPriceFeed()` is stale. This is the price every collateral figure uses.

### `collateralRatio(address owner)`

Returns `uint256`. Whole percentage of collateral value (at `collateralPriceFeed()`) divided by accrued debt. Debt-free or unrepresentably large ratios return `type(uint256).max`. Requires a nonzero dollar price when debt exists; no freshness/agreement check.

### `cut()`

Returns `uint256`. Governed Treasury share of the liquidation bonus, in basis points: (under consideration).

### `debtOf(address owner)`

Returns `uint256`. Principal plus unpaid accrued stability fees for owner, in imdUSD raw units; does not store accrual.

### `decayedRedemptionBaseRate()`

Returns `uint256`. Base fee after per-second decay from `lastRedemptionAt`, as a fraction scaled by 1e18. No price or supply requirement; decay calibration is (under consideration).

### `deployedAt()`

Returns `uint256`. Immutable deployment timestamp in Unix seconds. Not the accrual origin.

### `duty()`

Returns `uint256`. Governed annual stability-fee rate in basis points: (under consideration).

### `earnLine()`

Returns `uint256`. Dynamic cumulative work-issuance ceiling in imdUSD raw units: `reserveValue()` plus `backedDebt()` scaled by `earnMat()` in basis points. Value is (under consideration); no direct freshness assertion, and unusable listed reserve entries count for nothing.

### `earnMat()`

Returns `uint256`. Governed work-backing ratio in basis points of `backedDebt()`: (under consideration).

### `feeRecipient()`

Returns `address`. Vault-created Treasury address: (waiting for mainnet launch). Receives protocol bonus share and paid fees.

### `gap()`

Returns `uint256`. Governed redemption-eligibility spread above `mat()`, in whole percentage points: (under consideration).

### `gem()`

Returns `address`. Immutable collateral-token address: (waiting for mainnet launch).

### `indexCheckpoint()`

Returns `uint256`. Stored stability-fee index, scaled by 1e18. Changed by `drip()`.

### `indexCheckpointAt()`

Returns `uint256`. Unix seconds of the last `drip()` checkpoint; initialized at deployment.

### `lastRedemptionAt()`

Returns `uint256`. Unix seconds of the last successful `cash`; initialized at deployment.

### `line()`

Returns `uint256`. Governed ceiling on outstanding minted principal, in imdUSD raw units: (under consideration). Excludes unpaid fees and work issuance.

### `liquidationMarks(address account)`

Returns `uint256 markedAt, uint256 grace, bool marked, address marker`. Stored `(markedAt, grace, marked, marker)` for account: timestamp and duration in seconds, boolean, beneficiary address. An expired mark can still have `marked=true`; no price check.

### `lull()`

Returns `uint256`. Grace duration in seconds derived from the last accepted NHI. Curve and endpoints are (under consideration). No freshness assertion.

### `mat()`

Returns `uint256`. Minimum collateral ratio as a whole percentage, derived from the last accepted NHI. Curve and endpoints are (under consideration). No freshness assertion.

### `nhiFeed()`

Returns `address`. Immutable network-health feed address: (waiting for mainnet launch).

### `oracle()`

Returns `address`. Immutable work-oracle address: (waiting for mainnet launch).

### `parameters()`

Returns `address`. Immutable `Parameters` address: (waiting for mainnet launch).

### `positions(address owner)`

Returns `uint256 collateral, uint256 debt`. Returns only collateral raw units and full accrued debt in imdUSD raw units. Does not expose the internal fresh-principal or secured fields; no price requirement.

### `priceFeed()`

Returns `address`. Immutable primary IMD/ETH feed address: (waiting for mainnet launch). This is not the derived dollar feed.

### `redemptionBaseRate()`

Returns `uint256`. Stored base fee fraction scaled by 1e18, before further elapsed-time decay. Updated by `cash`.

### `redemptionCeilingCR()`

Returns `uint256`. `mat() + gap()` in whole percentage points. Eligibility is strictly below this threshold; no freshness assertion.

### `redemptionFeeBps(uint256 amount)`

Returns `uint256`. Fee for proposed burn `amount`, in basis points, including the burn-size increase and upward basis-point rounding. Zero amount quotes floor plus decayed base. Reverts `ExcessRepayment` above total supply. No balance, candidate or price validation.

### `redemptionReserve()`

Returns `uint256`. Collateral raw units held by the vault-created Treasury, regardless of whether governance lists that collateral as a reserve asset.

### `reserveValue()`

Returns `uint256`. Registered Treasury assets at discounted USD value, scaled by 1e18. Identical to `treasury.reserveValueUsd()`; unlisted or unusable entries count for nothing.

### `securedCollateral()`

Returns `uint256`. Aggregate collateral (sIMD) raw units counted position by position and capped by each position principal at its last change. Not the vault token balance or a fresh repricing of every position.

### `skew()`

Returns `uint256`. Governed primary-relative price-disagreement tolerance, in basis points: (under consideration).

### `spotFeed()`

Returns `address`. Immutable comparison-only IMD/ETH feed address: (waiting for mainnet launch).

### `stabilityFeeOf(address owner)`

Returns `uint256`. Unpaid accrued fees in imdUSD raw units; uses principal and index difference, plus stored unpaid fees. Fees do not earn fees. No price read.

### `stablecoin()`

Returns `address`. Immutable `ImdUSD` address: (waiting for mainnet launch).

### `tail()`

Returns `uint256`. Mark lifetime after grace, in seconds: the shorter `priceFeed.maxAge()` and `nhiFeed.maxAge()`. Value is (under consideration); neither spot nor ETH/USD age determines this duration.

### `totalBadDebt()`

Returns `uint256`. Recorded residual accrued debt in imdUSD raw units, updated on exhausted-collateral accounting and subsequent repayment. Not a continuously repriced sum of `badDebtOf`.

### `totalDebt()`

Returns `uint256`. Outstanding minted principal in imdUSD raw units. Includes unrepaid residual principal; excludes unpaid fees and work mints.

### `totalEarned()`

Returns `uint256`. Cumulative imdUSD minted through `earn`, in raw units. Never reset by repayment or redemption.

### `totalFeesMinted()`

Returns `uint256`. Cumulative imdUSD fees reminted to Treasury on `wipe` and `bite`. Not extra net supply; the payer burned the same fee amount.

### `totalNonPrincipalRedeemed()`

Returns `uint256`. Cumulative imdUSD burned by `cash` without cancelling minted principal, including reserve-funded burns and cancelled unpaid fees.

### `treasury()`

Returns `address`. Immutable vault-created reserve Treasury address: (waiting for mainnet launch).

### `usdPriceFeed()`

Returns `address`. Immutable vault-created IMD/USD adapter address: (waiting for mainnet launch). Prices IMD, not sIMD; `collateralPriceFeed()` builds on it.

For snapshot design, see [Reading state](./reading-state.md). For transaction procedures, see [Open a position](../guides/open-a-position.md), [Redeem](../guides/redeem.md) and [Mark and liquidate](../keepers/mark-and-liquidate.md).
