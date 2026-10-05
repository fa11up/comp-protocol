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
  - src/CDPVault.sol:778-790
---

# Timelock and proposals

`Governed` gives `Parameters` one pending proposal slot. `governor()` is the source-pinned `APPROVED_OPERATOR`: (waiting for mainnet launch). Only that account may propose or cancel. Anyone may apply a mature proposal. The fixed `TIMELOCK` duration is (under consideration), in seconds.

## Propose, wait, apply or cancel

1. Read the live parameters and `pendingEta()`. If a proposal is present, inspect it before proceeding: another proposal cannot overwrite it (`ProposalPending`).
2. As governor, call the appropriate proposal function from the table below. `Parameters._validate` runs before the slot is written. An invalid proposal leaves the slot empty.
3. Read `pending()` and `pendingEta()`. `Proposed(bytes payload, uint256 eta)` publishes the complete encoded payload and earliest application timestamp. Pending values have no effect on vault behavior.
4. Wait until the chain timestamp reaches `eta`. There is no automatic execution. Anyone can call `applyPending()` once it matures; earlier calls revert with `TooEarly(eta)`.
5. On application, the contract clears the pending slot, revalidates the payload, applies it, and emits `Applied(bytes payload)`. All steps are atomic. If validation or application fails, the pending slot and live values are restored by the revert.
6. Alternatively, the governor can call `cancel()` any time before successful application, including after maturity. It clears the slot and emits `Cancelled(bytes payload)`. A replacement proposal starts a full new delay.

`NotGovernor` rejects unauthorized proposals and cancellation. `NothingPending` rejects cancellation or application when the slot is empty. Validation errors and their bounds are explained in [Parameters](./parameters.md).

## Payloads and readers

`pending()` is ABI-encoded bytes. Its first word is the `Change` enum; decode by kind, not by guessing from a zero-valued field.

| Proposal | Encoded payload | Typed reader |
|---|---|---|
| `propose(ParamSet next)` | `(Change.Economics, ParamSet)`; order `line`, `cut`, `duty`, `skew`, `chip` | `pendingSet()` returns the tuple and ETA. |
| `proposeEarnMat(uint256 bps)` | `(Change.EarnMat, uint256)` | `pendingEarnMat()` |
| `proposeReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps)` | `(Change.ReserveAsset, address, address, uint256)` | `pendingReserveAsset()` |
| `proposeWage(uint256 wad)` | `(Change.Wage, uint256)` | Decode `pending()`; there is no `pendingWage()`. |
| `proposeGap(uint256 spread)` | `(Change.Gap, uint256)` | `pendingGap()` |
| `proposeOracleBudget(uint256 imdPerDay)` | `(Change.OracleBudget, uint256)` | `pendingOracleBudget()` |

`pendingChange()` returns the kind and ETA. Enum encodings follow declaration order from `Economics` through `OracleBudget`. When ETA is zero seconds, there is no pending change; the default enum is not a real economics proposal. A kind-specific reader also returns zero ETA when some other kind is pending.

Applying `Economics` calls `vault.drip()` while the old `duty` is still readable, then replaces the whole set. This makes the fee change forward-only. Reserve application calls `Treasury.setReserveAsset`; other kinds replace their respective stored values. A ceiling below outstanding principal is permitted, so a borrower cannot block application by borrowing above a proposed lower ceiling.

## Timing and authority limits

A matured proposal never expires. The timelock guarantees a minimum notice period, not execution at ETA or a final deadline. Continue monitoring pending payloads until they are applied or cancelled. Permissionless application does not guarantee someone pays the gas.

There is no voting, delegation or operator-rotation mechanism in these contracts. No proposal may replace the vault's immutable feeds, attester, collateral or Treasury. `Treasury.withdraw` uses the same pinned operator without this delay, and can change backing immediately. The [risk page](../economics/risks-and-open-questions.md) separates those powers.
