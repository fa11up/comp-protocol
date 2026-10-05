---
title: Timelock and proposals
section: governance
order: 2
audience: governance
sources:
  - src/Governed.sol:23-94
  - src/Parameters.sol:38-58
  - src/Parameters.sol:157-348
  - src/Treasury.sol:149-161
  - src/Treasury.sol:330-350
  - src/CDPVault.sol:778-790
---

# Timelock and proposals

Every parameter change is proposed, waits out a fixed delay (`TIMELOCK`), and is then applied. Only the governor, `governor()`, may propose or cancel; anyone may apply a proposal once its delay has passed. The governor is a single account written into the contract: (waiting for mainnet launch). There is one pending slot at a time.

## Propose, wait, apply or cancel

1. Check `pendingEta()`. If a proposal is already pending, a new one is refused (`ProposalPending`).
2. The governor calls the proposal function for the change (table below). It is checked against the limits before it is stored, so an invalid proposal never enters the slot.
3. `Proposed(bytes payload, uint256 eta)` publishes the full change and the earliest time it can apply. A pending change has no effect until applied.
4. Once the chain time reaches `eta`, anyone may call `applyPending()`. Earlier calls revert with `TooEarly(eta)`. Nothing applies automatically.
5. Applying clears the slot, re-checks the change, applies it and emits `Applied(bytes payload)`, all in one step: if anything fails, nothing changes.
6. The governor may instead `cancel()` at any point before it is applied, even after the delay. That emits `Cancelled(bytes payload)`; a replacement starts a full new delay.

`NotGovernor` rejects anyone else proposing or cancelling. `NothingPending` rejects applying or cancelling an empty slot. The limits each change is checked against are in [Parameters](./parameters.md).

## Payloads and readers

| Proposal | Encoded payload | Typed reader |
|---|---|---|
| `propose(ParamSet next)` | `(Change.Economics, ParamSet)`; order `line`, `cut`, `duty`, `skew`, `chip` | `pendingSet()` returns the tuple and ETA. |
| `proposeEarnMat(uint256 bps)` | `(Change.EarnMat, uint256)` | `pendingEarnMat()` |
| `proposeReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps)` | `(Change.ReserveAsset, address, address, uint256)` | `pendingReserveAsset()` |
| `proposeWage(uint256 wad)` | `(Change.Wage, uint256)` | Decode `pending()`; there is no `pendingWage()`. |
| `proposeGap(uint256 spread)` | `(Change.Gap, uint256)` | `pendingGap()` |
| `proposeOracleBudget(uint256 imdPerDay)` | `(Change.OracleBudget, uint256)` | `pendingOracleBudget()` |
| `proposeRedemptionDivisor(uint256 divisor)` | `(Change.RedemptionDivisor, uint256)` | `pendingRedemptionDivisor()` |
| `proposeStream(address payee, uint256 perDay)` | `(Change.Stream, address, uint256)` | `pendingStream()` |
| `proposeWorkOracle(address next)` | `(Change.WorkOracle, address)` | Decode `pending()`; there is no `pendingWorkOracle()`. |

`pending()` is ABI-encoded bytes whose first word is the kind of change. `pendingChange()` returns the kind and ETA; an ETA of zero means nothing is pending. A kind-specific reader also returns zero when a different kind is pending.

Applying an economics change first calls `vault.drip()` under the old `duty`, so a new fee rate applies only from then on. A debt ceiling below current principal is allowed, so a borrower cannot block a lower ceiling by borrowing up to the old one.

## Timing and authority limits

A proposal whose delay has passed never expires. The delay guarantees a minimum notice period, not that the change lands at ETA: watch pending changes until they are applied or cancelled, and note that nobody is obliged to pay the gas to apply one.

There is no voting, delegation or way to rotate the governor. No proposal can replace the vault's feeds, the price signer, the collateral or the Treasury. The one replaceable dependency is the work oracle, and only while minting from work is off (see [Parameters](./parameters.md)). The same operator can withdraw from the Treasury without a delay, but not sIMD, not a listed reserve asset, and not imdUSD that outstanding bad debt needs; removing backing takes a delisting proposal like any other change. See [Risks and open questions](../economics/risks-and-open-questions.md).
