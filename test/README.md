# Contract test coverage

Run `forge build` and `forge test`. Dependencies are already vendored; the suite needs no network, RPC, environment variables, FFI, or files under `test/scratch/`.

| Area | Tests |
| --- | --- |
| Constructors, one-time initialization, permissions, getters, events, zero inputs, rejected collateral/debt changes | `CDPVault.t.sol`, `Tokens.t.sol`, `MockWorkOracle.t.sol`, `BoundaryPaths.t.sol` |
| ERC-20 transfers, finite/infinite allowances, zero addresses, rollback after failed transfers, supply overflow | `Tokens.t.sol`, `LaunchToken.t.sol`, `BoundaryPaths.t.sol` |
| Full-range `uint128` deposit/mint/repay/withdraw, repeat lifecycles, another borrower's debt, exact balances and rights after each operation | `ProtocolSequences.t.sol` |
| One-unit health boundaries, wide arithmetic, both ratio-saturation paths | `ProtocolSequences.t.sol`, `Arithmetic.t.sol` |
| Failed oracle/token calls, rollback of consumed rights, reentrant callbacks | `BoundaryPaths.t.sol`, `Adversarial.t.sol` |
| Liquidation payout, partial/full/repeated/self liquidation, rounding, other users' collateral, failed burns/transfers | `Liquidation.t.sol`, `Adversarial.t.sol` |
| Random sequences and repayment/withdrawal of every remaining position | `Protocol.invariant.t.sol` |

The new sequence, boundary and partial-liquidation fuzz properties each run 1,000 cases using inline Foundry configuration. Bounds promote inputs to `uint256` before arithmetic and include the entire `uint128` range. Valid sequence tests execute all four actions without swallowing reverts. Separate tests require the exact errors for invalid actions.

The invariant handler targets ten operations across four funded borrowers, each initially holding real collateral and debt. It runs 256 sequences of 128 calls with unexpected reverts treated as failures. After every call, the invariant checks COMP supply against the sum of **all** position debts and wallet balances, the independent inequality `collateral * 100 >= debt * 150`, each position against its deposit/withdraw/mint/repay history, work-credit consumption, and IMD conservation including uncredited donations. After each sequence, existing COMP is redistributed to its debtors, every debt is repaid and every position's collateral is withdrawn. No storage injection, privileged COMP mint, or credit restoration is used in these sequences.

Liquidation success tests explicitly inject a hypothetical collateral loss using a test-only storage write and move the same quantity of IMD out of custody. This is a branch-testing fixture, not a production transition. The requested healthy-position-to-liquidation withdrawal scenario conflicts with the specified 150% withdrawal guard: depositing 200 IMD, borrowing 100 COMP, then withdrawing 70 IMD must revert. `test_withdrawalCannotCreateLiquidatablePosition` checks that rejection and the subsequent rejection of liquidation. Synthetic liquidation properties assert the exact liquidator balance increase `debtToRepay * 110 / 100`, both owner position fields, supply, custody, unchanged rights, and an unrelated liquidator debt position.

The separately reported factory authorization conflict has a self-contained failing proof in the root findings sidecar requested by the assignment. It was reproduced under `test/scratch/` and is not included as a passing regression test. The sidecar also records the withdrawal/liquidation scenario conflict.

Source coverage was checked with `forge coverage --exclude-tests --no-match-contract ProtocolInvariantTest`: all five concrete contracts in `src/` reached 100% reported line, statement, branch and function coverage (115 lines, 158 statements, 37 branches and 21 functions). This measurement excludes dependency internals and does not establish deployment compatibility. The invariant campaign is checked separately by the full `forge test` run.
