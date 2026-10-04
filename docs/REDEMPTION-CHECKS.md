# Redemption channel A checks

The change adds vault methods, the governed spread, and a vault-only Treasury IMD release. It adds no deployment artifact, constructor argument or post-deployment call. The manifest, configuration, feed authorities, oracle question policy, existing economic settings and repayment/liquidation fee distribution are unchanged. ABI details and rounding are documented in [ABI.md](ABI.md#redemption-channel-a).

## Local verification

- `forge build`: passed with the existing compiler/lint warnings.
- `forge test`: 362 passed, zero failed, two skipped. The skips are the existing Sepolia fork suite and opt-in `AUDIT_PROOFS` relay test.
- `FOUNDRY_TEST=script/checks forge test --offline --match-contract RedemptionTest`: 28 passed, including 256 fuzz cases.
- The supplied `Contracts.protected.t.sol` was run unmodified in temporary scratch space against CREATE2 initcode and addresses derived from the current four-entry manifest on chain ID 11155111: passed.
- `DeployComp`, `DeployGoverned` and `DeployPrereqs` all completed offline dry-runs and their `verify()` assertions. Public `OPERATOR` and `--sender` both used `FEED_REPORTER_0`; `MOCK_IMD` was zero. No transaction was broadcast. `DeployPrereqs.verify()` now also checks that the Treasury's creating caller equals `OPERATOR`.
- ParameterizedVault runtime is 15,175 bytes; initcode including six constructor words is 39,882 bytes, below the 24,576/49,152 limits. The four manifest runtimes passed the supplied forbidden-opcode scan.
- The four affected JSON ABI exports match the compiled artifacts. All delivered changes are under `src`, `docs` or `script`.

The redemption tests cover reserve-only, borrower-only and mixed payouts; strict eligibility at the ceiling and NHI stress; spread authority, bounds and delay; minimum-out and insufficient-balance rollback; feed freshness and divergence; non-unit USD pricing; full closure; accrued-fee cancellation without reminting; work-minted COMP and the shrinking work ceiling; one-wei reserve-exhaustion rounding; and fee growth, cap, decay and checkpoints. Randomized checks assert token/collateral conservation and the exact collateral/debt ratio, including the `totalNonPrincipalRedeemed` supply adjustment.

An additional implementation review found no blocking issue in the single burn, partitioned payout, strict ceiling, exact ratio guard or Treasury authority. Its arithmetic check examined 691,467 small-value reserve-split cases. These are local checks, not a replacement for the stage's independent launch review.

## Existing optional check failures

Running **all** older checks with `FOUNDRY_TEST=script/checks forge test --offline` produced 65 passes and 23 failures. Running the same legacy suites against an isolated copy of the unmodified input commit produced the identical set of 23 failing test names (37 passes). The additional 28 passes are the new redemption suite. There are no new failures in those legacy suites.

| Existing suite | Baseline and current failures | Observed mismatch |
| --- | ---: | --- |
| `CDPVaultIncrementTest` | 2 | Liquidation payouts still expect the former bonus split |
| `CDPVaultRecoveryTest` | 10 | Recovery and repayment expectations omit the shipped stability fee |
| `ComputeBackingTest` | 11 | Earlier ETH denomination, debt coverage and freshness expectations |

Those checks and their old assumptions were left unchanged because this assignment does not change the bonus split, stability fee, denomination or oracle rules. Several older sections of `ABI.md` also describe earlier increments; the new redemption section explicitly uses the current USD-denominated ParameterizedVault behavior.
