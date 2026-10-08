---
title: Events and errors
section: reference
order: 3
audience: integrators
sources:
  - src/CDPVault.sol:57-101
  - src/CDPVault.sol:274-1602
  - src/ParameterizedVault.sol:25-309
  - src/Parameters.sol:270-546
  - docs/abi/ParameterizedVault.json:1
  - lib/openzeppelin-contracts/contracts/utils/Address.sol:1
  - lib/openzeppelin-contracts/contracts/utils/math/Math.sol:1
  - lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:1
  - lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol:1
---

# Events and errors

Every event and custom error in the `ParameterizedVault` ABI (`docs/abi/ParameterizedVault.json`), with what triggers it. [Vault functions](./vault-functions.md) gives each function's full requirements.

`indexed` marks a field you can filter on. Amounts are raw token units; times and durations are seconds. A reverted call leaves nothing behind: no storage changes, transfers, consumed rights or logs.

## Events

### `Bark(address indexed owner, uint256 markedAt, uint256 grace)`

A mark was created by `bark` or `barkFor`, or an expired one replaced. `markedAt` is the Unix time; `grace` is the wait, fixed at marking. No reward moves. The beneficiary is not in the event: read `liquidationMarks(owner)` or the call data. Marking an already marked position emits nothing.

### `Bite(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized)`

A liquidation succeeded. `debtRepaid` is all the imdUSD burned, fees included. `collateralSeized` is all the sIMD taken from the position, including the marker's and Treasury's shares and any swept dust, so it is not what the liquidator received.

### `Cash(address indexed redeemer, address indexed candidate, uint256 burned, uint256 gemOut, uint256 reserveOut, uint256 debtCancelled, uint256 feeBps)`

A redemption succeeded. `burned` is the imdUSD burned. `gemOut` is the total sIMD paid, of which `reserveOut` came from the Treasury. `debtCancelled` is the candidate's debt cancelled, and `feeBps` the fee charged in basis points. The candidate is unused when the Treasury covered the whole payout.

### `Cover(address indexed owner, uint256 amount, address indexed payer)`

`cover` cancelled `amount` of a drained position's bad debt using the Treasury's imdUSD, fees first. `payer` is the Treasury.

### `Draw(address indexed account, uint256 amount)`

imdUSD was borrowed and minted to `account`.

### `Earn(address indexed account, uint256 amount)`

imdUSD was minted to `account` against work rights. It creates no debt.

### `Free(address indexed account, uint256 amount)`

sIMD was withdrawn from `account`'s position.

### `Heel(address indexed owner)`

A mark was removed, either by `heel` or automatically by `lock`, `lockIMD`, `free`, `draw`, `wipe`, `bite`, `cash` or `cover`. It does not say who or why. Nothing is emitted if there was no mark.

### `IndexCheckpointed(uint256 index, uint256 at)`

`drip` stored the stability-fee index `index` (scaled by 1e18) at time `at`. It also happens when a governance change to the economics is applied. No fees are collected.

### `Lock(address indexed account, uint256 amount)`

sIMD was deposited to `account`'s position. For `lockIMD`, `amount` is the sIMD that staking actually returned.

### `OracleSet(address indexed oracle)`

The constructor linked the work oracle it created. It is emitted once. Governance can later point `earn` at a replacement through `Parameters.proposeWorkOracle` (48-hour delay); that change is not logged here, so read `oracle()`.

### `Wipe(address indexed account, uint256 amount)`

`account` repaid `amount` of imdUSD, fees first. Paid fees are reminted to the Treasury.

## Errors

### `CollateralNotWrappable()`

`lockIMD` was called on a vault whose collateral is not a staking-vault share, so there is nothing to stake IMD into. Use `lock` instead.

### `DebtCeilingReached()`

`draw` would take total borrowed principal above `line()`. Borrow less, or wait for repayments or a higher ceiling.

### `ExcessRepayment()`

`wipe`, `bite` or `cover` asked to repay more than the position owes; a redemption exceeds total supply; or the candidate's share of a redemption exceeds the candidate's debt. Reduce the amount.

### `GracePeriodNotElapsed()`

`bite` came before `markedAt + grace`. Wait.

### `HealthyPosition()`

`bark`, `barkFor` or `bite` found the position at or above `mat()`, or debt-free. Nothing to liquidate; clear the mark if one is left.

### `IneligibleRedemptionPosition()`

The candidate has no debt or is at or above `redemptionCeilingCR()`, or no candidate was named when the Treasury could not cover the payout. Choose an eligible position.

### `InsufficientCollateral()`

`free` asked for more collateral than the position holds, or `bite`'s full payout is more than the position holds. Reduce the amount.

### `InsufficientRights()`

`earn` asked for more than the caller's minting rights. Claim work in the work oracle first.

### `InvalidBeneficiary()`

`barkFor` was given the zero address. Name a real address.

### `InvalidBonusShares()`

`bite` found the protocol's and marker's shares adding up to more than the whole bonus. `Parameters` refuses such settings, so this points to a wiring fault; retrying will not help.

### `InvalidFeed()`

Deployment only: a feed is missing or two feeds are the same contract.

### `InvalidOracle()`

Deployment only: the work oracle is missing, answers `mintingRights` badly, or names a different vault.

### `InvalidPrice()`

A price came back as zero: the dollar price, or the primary or spot price in the agreement check. This is separate from staleness, so check both.

### `InvalidToken()`

Deployment only: the collateral or a supplied stablecoin is not a deployed contract, or they are the same contract.

### `MarkExpired()`

`bite` came after `markedAt + grace + tail()`. Mark again and wait out the new grace.

### `MinimumOutNotMet()`

`cash` would pay less sIMD than `minGemOut`. Get a new quote.

### `NoRealizedBadDebt()`

`cover` named a position that has no recorded bad debt, or that holds collateral worth at least its recorded bad debt (a borrower rebuilding, liquidated if at all through a mark and grace). Dust, and a re-lock worth less than the recorded bad debt, do not count: `cover` moves them to the Treasury first.

### `CoverBelowCollateralValue()`

`cover` would take a drained position's re-lock, worth less than its recorded bad debt, for less than the re-lock is worth. Call it with an `amount` of at least the collateral's value at the current price.

### `NoSurplus()`

`cover` was called on a vault with no Treasury to pay from. The launch vault always has one, so only the base vault reaches this.

### `NotInitialized()`

`draw` or `earn` found the stablecoin is not linked to this vault. The launch vault creates and links its own, so check you have the right contracts.

### `PositionNotMarked()`

`bite` found no mark. Mark the position first.

### `PriceDivergence()`

The primary and spot IMD/ETH prices differ by more than `skew` allows. Wait for prices that agree; the next attestations will usually close the gap.

### `RedemptionWorsensRatio()`

The redemption would take more of the candidate's collateral than its share of the debt cancelled. Choose another candidate. A smaller amount does not always help when the candidate is undercollateralised.

### `StaleFeed()`

The primary, network health, spot or ETH/USD price is too old. Relay a fresh attestation; nothing relayed can fix a stale Chainlink ETH/USD.

### `TreasuryFactoryMissing()`

Deployment only: there is no `TreasuryFactory` at the address written into the vault.

### `TreasuryNotOurs()`

Deployment only: the factory returned a Treasury that does not serve this vault.

### `UnderwaterPosition()`

`heel` found the position below `mat()` with debt. It has not recovered.

### `UnexpectedCollateralReceived()`

`lock` received a different amount of collateral than requested. Tokens that charge a transfer fee or rebase are not supported.

### `UnsafeCollateralRatio()`

`draw`, or `free` with debt open, would leave the position below `mat()`. Borrow or withdraw less, or deposit or repay first.

### `WorkCeilingReached()`

`earn` would take total work minting above `earnLine()`. More rights do not help; the ceiling needs room.

### `WorkMintingOff()`

`earn` was called while the governed wage is zero, which switches minting from work off. Rights already claimed stay spendable once a wage is set.

### `ZeroAmount()`

An amount was zero, or `cash` would pay out zero sIMD.

### Low-level errors

These come from the OpenZeppelin libraries the vault uses. Ordinary use rarely reaches them.

| Error | Meaning |
|---|---|
| `AddressEmptyCode(address target)` | A call went to an address with no code, such as a missing token. |
| `AddressInsufficientBalance(address account)` | A native-currency send lacked balance. The vault sends no ETH, so this is not expected. |
| `FailedInnerCall()` | A low-level call failed without a reason. Check the trace. |
| `MathOverflowedMulDiv()` | A multiply-then-divide result did not fit in 256 bits. Check the magnitudes and feed scales. |
| `ReentrancyGuardReentrantCall()` | A guarded function was called while another was running. `drip` is not guarded. |
| `SafeERC20FailedOperation(address token)` | A token transfer returned failure. Check balances, approvals and the token. |

## Errors from other contracts

The list above is the vault's own. `ImdUSD`, the collateral, the feeds, the Treasury and the work oracle can revert with their own errors; decode those against their own ABIs. Arithmetic panics and out-of-gas are not custom errors. Token `Transfer` logs come from the token, not the vault.

Do not find positions from `Bark` alone: most positions are never marked. See [Reading state](./reading-state.md).
