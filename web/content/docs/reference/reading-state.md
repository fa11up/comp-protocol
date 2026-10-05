---
title: Reading state
section: reference
order: 5
audience: integrators
sources:
  - src/CDPVault.sol:239-262
  - src/CDPVault.sol:494-537
  - src/CDPVault.sol:760-849
  - src/ParameterizedVault.sol:86-199
  - src/Treasury.sol:92-230
  - src/SwarmFeed.sol:152-185
  - src/UsdPriceFeed.sol:38-95
  - src/SwarmWorkOracle.sol:66-191
  - web/src/history.ts:76-211
  - docs/INTERNAL-AUDIT-2026-10-04.md:115-122
---

# Reading state

`positions(owner)` returns sIMD collateral (24-decimal raw units) and imdUSD debt including accrued fees. It is an account lookup, not an enumerable list. Use the [Vault functions](./vault-functions.md) inventory for exact signatures and units; use the [terminal guide](../guides/use-the-terminal.md) for display terminology.

## Read a coherent snapshot

1. Resolve `stablecoin`, `parameters`, `treasury`, `oracle`, `priceFeed`, `nhiFeed`, `spotFeed` and `usdPriceFeed` from the vault and verify the [contract links](./contracts-and-addresses.md). Addresses are (waiting for mainnet launch).
2. Choose one block number and read all dependent state at that block. Record its hash and timestamp. Derive grace and feed age from that timestamp rather than the browser clock.
3. Read `positions(owner)`, `debtOf(owner)`, `stabilityFeeOf(owner)`, `collateralRatio(owner)` and `liquidationMarks(owner)`. Debt minus fees gives principal. Show a debt-free ratio as “No debt”, not the maximum integer as a percentage.
4. Read feed `(value, updatedAt)` pairs, each `isStale()`, and `maxAge()`. Check raw primary/spot agreement against `skew()`, and read the derived dollar price with its staleness flag. A nonzero number alone is not an actionable price.
5. Read `mat()`, `lull()`, `tail()` and the pending parameter payload at the same block. Mark grace is stored: later NHI changes do not rewrite it. Liquidation is allowed from `markedAt + grace` through `markedAt + grace + tail()` inclusive, provided other guards still pass.
6. Simulate an intended write with the actual sender and inputs close to submission. A snapshot or quote is not a reservation; another transaction or elapsed time can change eligibility.

## Discover positions without inventing an empty book

Index `Lock` events from the vault's creation block to find depositing accounts, deduplicate owners, then read their positions. Retain accounts with debt even when collateral is exhausted. Event amounts alone cannot reconstruct accrued fees. Index later changes for refreshes and account for reorganizations using block hashes and log indices.

A public RPC can return an empty log array for a range it declines to serve, without an error. The internal audit records overlapping ranges with inconsistent results. Splitting requests into smaller ranges is useful but does not certify an empty result.

1. Scan bounded ranges with `eth_getLogs`, recording completed ranges and errors.
2. Use an explorer log API as a fallback and cross-check, especially for empty or incomplete RPC history. Follow every pagination cursor through the requested interval and filter the exact vault and event topic. Do not interpret a page limit as end of history.
3. Keep trusted creation-block and checkpoint information. Verify known event-bearing ranges where possible and handle RPC/explorer disagreement as incomplete coverage.
4. Represent “unreadable” or “coverage unverified” separately from “none”. Only report no positions when discovery coverage is established and candidate accounts have been read successfully. A failed account read is unknown, not a zero balance.

An explorer is another availability and correctness dependency, not an on-chain completeness proof. Keep user-supplied owner lookups available even if full-book discovery is incomplete.

## Backing and supply

`totalDebt()` is principal, whereas `totalBadDebt()` records residual accrued debt at accounting updates. It is not the sum of a fresh `badDebtOf(owner)` scan. `backedDebt()` subtracts recorded losses and excludes principal added within the transaction when calculating work capacity.

Read `reserveValue()` and `treasury.reserveAssets()` with `reserveAsset(asset)` and `reserveValueOf(asset)` to explain the discounted USD reserve. `haircutBps` is the retained fraction, not the percentage removed. Unlisted or unreadable assets count for nothing. `totalReceived` is a cumulative receipt counter, not a spendable balance; use token `balanceOf(treasury)` for holdings.

`redemptionReserve()` is the Treasury collateral balance, regardless of listing. `backingPerUnit()` uses that collateral at the vault's own price, adds other listed discounted assets and conservative secured collateral, divides by imdUSD supply and caps at par. Consequently it is not simply `reserveValue() + backedDebt()` divided by supply. See [Monetary policy](../economics/monetary-policy.md).

The supply identity is `stablecoin.totalSupply() = totalDebt() + totalEarned() - totalNonPrincipalRedeemed()`. `totalFeesMinted()` is not added: fees reminted to Treasury were burned from the payer. Work issuance is cumulative and redemption does not restore its allowance.

## Work and governance readers

The `SwarmWorkOracle` figure is a 32-byte root represented as `uint256`; never format it as a price or total task count. Read `acceptedRoots(root)`, `creditedTasks(agentId)`, `creditedRights(account)`, `consumedRights(account)` and `mintingRights(account)` for claim accounting. Freshness gates new attestation acceptance; accepted roots and previously credited rights do not expire in `claim` or `consumeRights`.

Read `Parameters.current()` for the five-value economic tuple, then `earnMat()`, `wage()` and `gap()` separately. `pendingChange()` identifies the pending kind; a zero ETA from a kind-specific getter may mean another kind is pending. Decode raw `pending()` for `Wage`; no `pendingWage()` getter exists. See [Timelock and proposals](../governance/timelock-and-proposals.md).
