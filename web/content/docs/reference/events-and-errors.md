---
title: Events and errors
section: reference
order: 3
audience: integrators
sources:
  - src/CDPVault.sol:57-101
  - src/CDPVault.sol:274-1075
  - src/ParameterizedVault.sol:38-225
  - docs/abi/ParameterizedVault.json:1
  - lib/openzeppelin-contracts/contracts/utils/Address.sol:1
  - lib/openzeppelin-contracts/contracts/utils/math/Math.sol:1
  - lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:1
  - lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol:1
---

# Events and errors

`ParameterizedVault` inherits the events and errors below from `CDPVault` and its libraries. This inventory is generated from `docs/abi/ParameterizedVault.json`, with triggers checked against source. [Vault functions](./vault-functions.md) describes each operation's complete requirements and effects.

`indexed` marks an event topic field. Amounts are token raw units; timestamps and durations are seconds. Events describe completed changes; they do not themselves mutate state. A reverted call leaves no committed storage changes, token transfers, rights consumption or logs from that call.

## Events

### `Bark(address indexed owner, uint256 markedAt, uint256 grace)`

Emitted when `bark` or `barkFor` creates or replaces an expired mark. `markedAt` is Unix seconds; `grace` is the snapshotted duration in seconds. No reward is paid. The beneficiary is not in this event: read `liquidationMarks(owner)` at the appropriate block or index call data. Repeating an active mark emits nothing.

### `Bite(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized)`

Emitted after successful liquidation. `debtRepaid` is the total imdUSD burned, including fees. `collateralSeized` is total sIMD removed, including the marker and Treasury shares and any dust sweep; it is not the liquidator net receipt. Requires all `bite` guards.

### `Cash(address indexed redeemer, address indexed candidate, uint256 burned, uint256 gemOut, uint256 reserveOut, uint256 debtCancelled, uint256 feeBps)`

Emitted after successful redemption. `burned` is imdUSD raw units burned. `gemOut` is total collateral (sIMD) payout, `reserveOut` its Treasury portion, `debtCancelled` the candidate accrued debt cancelled, and `feeBps` the charged fee in basis points. Candidate can be unused when reserve covers the payout. Requires all `cash` guards.

### `Cover(address indexed owner, uint256 amount, address indexed payer)`

Emitted when `cover` repays a drained position's debt from the Treasury's imdUSD. `amount` is the imdUSD burned, fees first; `payer` is the Treasury.

### `Draw(address indexed account, uint256 amount)`

Positive imdUSD principal minted to `account` after `draw` checks; amount in imdUSD raw units.

### `Earn(address indexed account, uint256 amount)`

Positive imdUSD work issuance to `account` after rights, ceiling and feed checks; amount in imdUSD raw units. Creates no position debt.

### `Free(address indexed account, uint256 amount)`

sIMD withdrawn from caller position after `free` checks; amount in sIMD raw units.

### `Heel(address indexed owner)`

An existing mark was deleted by `heel` or an automatic clearing path in `lock`, `free`, `draw`, `wipe`, `bite` or `cash`. Does not identify the caller or reason. No event for an already absent mark.

### `IndexCheckpointed(uint256 index, uint256 at)`

`drip` stored `index`, scaled by 1e18, at Unix seconds `at`. Can also occur during application of governed economics. No fees are collected by this event.

### `Lock(address indexed account, uint256 amount)`

An exact positive collateral deposit was received and credited to `account`; amount in sIMD raw units. `lockIMD` emits it with the sIMD actually received from staking.

### `OracleSet(address indexed oracle)`

Constructor established the validated work-oracle binding. Not evidence of a mutable oracle setter; the reference is immutable.

### `Wipe(address indexed account, uint256 amount)`

Successful caller repayment, amount in imdUSD raw units including fees retired before principal. Paid fees are reminted to Treasury.

## Custom errors in the deployed vault ABI

All entries below reject the call and roll back its changes. Library errors are included even when ordinary launch operations do not reach their native-currency branch.

### `AddressEmptyCode(address target)`

An address utility expected code at `target`, including an empty-code token target during a safe transfer. Check the dependency address and deployed code.

### `AddressInsufficientBalance(address account)`

The address utility lacks native currency at `account` for its requested operation. Included by the linked library; ordinary vault token transfers send no native currency.

### `CollateralNotWrappable()`

`lockIMD` was called on a vault whose collateral is not a staking-vault share, so there is nothing to stake IMD into. Deposit the collateral token with `lock` instead.

### `DebtCeilingReached()`

`draw` would carry total minted principal above `line()`. Reduce the borrow or wait for principal repayment or an applied ceiling change.

### `ExcessRepayment()`

`wipe` or `bite` exceeds accrued position debt; a redemption quote/burn exceeds supply; or the candidate-funded part exceeds candidate debt. Re-read the relevant debt/supply and reduce amount.

### `FailedInnerCall()`

An address utility low-level call failed without revert data to bubble. Inspect the called token/dependency and transaction trace.

### `GracePeriodNotElapsed()`

`bite` is before `markedAt + grace`. Wait for the stored grace to elapse.

### `HealthyPosition()`

`bark`, `barkFor` or `bite` found the position at or above `mat()` or debt-free. No liquidation is due; clear any obsolete mark when eligible.

### `IneligibleRedemptionPosition()`

The candidate has no debt or is at/above `redemptionCeilingCR()`. An absent candidate also fails if reserve is short. Choose an eligible position.

### `InsufficientCollateral()`

`free` exceeds caller collateral, or `bite` full payout exceeds owner collateral. Reduce the amount. The base reserve-payment helper also declares this failure, but the deployed override pays through Treasury.

### `InsufficientRights()`

`earn` lacks caller minting rights. Claim valid uncredited work through the work oracle before minting.

### `InvalidBeneficiary()`

`barkFor` was given the zero-address sentinel. Choose a beneficiary able to receive and use the reward.

### `InvalidBonusShares()`

`bite` found `cut` larger than the bonus fraction left after `chip`. The deployed parameter validation prevents such settings; inspect wiring rather than retrying unchanged.

### `InvalidFeed()`

Constructor received missing or duplicate primary/NHI/spot feed contracts; also named by the dollar-feed constructor for a missing primary. Correct deployment inputs.

### `InvalidOracle()`

Constructor work-oracle validation failed: missing code/factory, malformed rights response or a mismatched exposed vault binding. Correct deployment wiring.

### `InvalidPrice()`

A price-dependent calculation received a zero dollar price, or the agreement check received zero primary or spot. Freshness and price validity are distinct; inspect both legs.

### `InvalidToken()`

Constructor found missing collateral/supplied stablecoin code or identical collateral and stablecoin. Correct deployment inputs.

### `MarkExpired()`

`bite` is strictly after `markedAt + grace + tail()`. Mark the still-unsafe position again, then observe the new grace.

### `MathOverflowedMulDiv()`

Full-precision multiplication/division cannot fit its result in `uint256`. Check magnitudes, feed scales and dependency values; this is not a usable quote.

### `MinimumOutNotMet()`

`cash` computed less sIMD than `minGemOut`. Obtain a new quote; change the minimum only if the new payout is acceptable.

### `NoRealizedBadDebt()`

`cover` named a position that still holds collateral or has no recorded bad debt. Only a drained position's realized shortfall can be covered.

### `NoSurplus()`

`cover` was called on a vault with no surplus account. The launch vault's surplus is its Treasury, so this is reached only by the base vault.

### `NotInitialized()`

`draw` or `earn` found `stablecoin.vault()` does not name this vault. Constructor-created `ImdUSD` binds immediately; inspect deployment identity.

### `PositionNotMarked()`

`bite` requires a stored mark and found none. Mark an unsafe position first.

### `PriceDivergence()`

Raw primary/spot difference exceeds the primary-relative `skew` tolerance. Await or relay truthful converging observations; do not manufacture intermediate prices.

### `RedemptionWorsensRatio()`

Candidate sIMD out exceeds the exact proportional collateral share of debt cancelled. Choose another candidate or a feasible smaller redemption; reducing size is not guaranteed to help an undercollateralised candidate.

### `ReentrancyGuardReentrantCall()`

A guarded entry point was called while another guarded operation was executing. Remove nested callbacks; `drip` is not guarded.

### `SafeERC20FailedOperation(address token)`

A safe ERC-20 operation on `token` returned failure. Check token behavior, balances and allowance; dependency reverts with their own data can bubble instead.

### `StaleFeed()`

A required primary, NHI, spot or ETH/USD leg is stale or unusable under its staleness check. Refresh the failing leg; a swarm relay cannot repair Chainlink.

### `UnderwaterPosition()`

`heel` found the position below `mat()` with debt. Restore safety before clearing.

### `UnexpectedCollateralReceived()`

`lock` received a balance increase different from `amount`. Fee-on-transfer or rebasing collateral is unsupported by this exact-deposit check.

### `UnsafeCollateralRatio()`

`draw` or indebted `free` would leave the caller below `mat()`. Borrow/withdraw less, deposit collateral or repay debt.

### `WorkCeilingReached()`

`earn` would make cumulative work issuance exceed `earnLine()`. More rights alone do not solve insufficient backing headroom.

### `ZeroAmount()`

A positive-amount vault operation received zero, or `cash` rounded to zero sIMD out. Use a positive amount with a nonzero feasible payout.

## Errors from other contracts

This is a complete vault ABI inventory, not a closed list of all possible revert data. `ImdUSD`, collateral, feeds, Treasury and the work oracle can revert with their own errors. Decode these against their own ABIs. Standard Solidity arithmetic panics and out-of-gas failures are not custom errors. ERC-20 mint/burn `Transfer` logs are emitted by the token, not the vault.

Do not discover positions from `Bark` alone: many positions have never been marked. See [Reading state](./reading-state.md) for complete-history and unreadable-history handling.
