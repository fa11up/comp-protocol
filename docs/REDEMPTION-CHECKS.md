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

## Revision: aggregate backing after debt unwind

Finding `b92320ae9dfde462a6d4854ce70a8e922f317c3cedbc7533016c3ad96067994c` reproduced with the supplied proof unchanged: after a permitted borrow/work-mint/repay/withdraw sequence, a reserve redemption reduced backing from 100/250 to 90.15/240. The prior solvent-case arithmetic assumed backing above one; the existing mint-time work ceiling does not maintain that precondition after a later debt unwind.

`redeem` now requires outgoing backing value to be at most `floor(pre-payout backing * burned / supply)`. It measures actual vault IMD at the cached redemption price plus the existing registered Treasury reserve value. Backing rounds down; the outgoing collateral and reserve values round up, including the Treasury's retained-factor conversion. This bounds both exact weighted value loss and the decrease in the existing integer-valued backing metric. An unsafe call reverts with `RedemptionWorsensBacking`, including any candidate debt changes. The payout, reserve-first ordering, fee, work ceiling, authority and deployment shape are unchanged. Conservative rounding may reject a marginal dust-sized payout.

Revision checks:

- `forge build`: passed, with existing compiler/lint warnings.
- `forge test`: 363 passed, zero failed, two existing optional skips; includes the supplied proof copied unchanged into `test/scratch/BackingRedemptionProof.t.sol`.
- `FOUNDRY_TEST=script/checks forge test --match-path script/checks/Redemption.t.sol`: 35 passed, including the existing 256-case fuzz test. Seven added regressions cover the debt unwind, atomic rollback, exact equality, one-wei deterioration, borrower and mixed routes, fractional-value rounding and haircuts.
- Offline dry-runs of `DeployComp`, `DeployGoverned` and `DeployPrereqs`: passed every `verify()` assertion, using the public reporter address as `OPERATOR` and sender, with zero `MOCK_IMD`. No transactions were broadcast.
- The three affected ABI exports match their compiled artifacts. ParameterizedVault runtime is 15,724 bytes; initcode including its six constructor words is 40,772 bytes.
- The supplied protected deployment harness passed unchanged against the current four-entry manifest on chain ID 11155111, including CREATE2 addresses, runtime limits and forbidden-opcode checks.

The reviewer response is in the explicitly requested repository-root `.imd-responses.json`. Implementation, regression tests and ABI documentation remain within `src`, `script` and `docs`; no manifest, configuration or dependencies were changed.

## Revision: what the guard counts, what the fee divides by, and what moves the rate

Four reproducible findings against the previous revision, each confirmed with the supplied proof before anything changed.

- `8936befa` (high): the guard counted the vault's whole IMD balance, so a debt-free deposit inflated it. Secured collateral now excludes anything deposited earlier in the same transaction (a transient tally, the idiom `backedDebt` already uses for debt) and is capped at `minCR` percent of the principal that existed before the transaction, less bad debt. One-for-one with debt was considered and rejected: it refuses the brief's own flow of redeeming work-issued COMP against an eligible position in a fully backed system, which an accepted test pins. The residual is the one `backedDebt` documents: a position held across transactions counts, and costs real capital in an open position.
- `998ff6b2` (medium): unlisted Treasury IMD was valued at zero on both sides, so the reserve route was unguarded in the launch configuration. The Treasury's IMD is now valued at the redemption price whether or not it is listed, and whatever retained factor it carries; other listed assets keep their registered value. `Treasury.reserveWithdrawalValue`, added last revision for this guard alone, is removed with it.
- `fcd5b261` (medium): the fee's denominator was the instantaneous supply. It is now the supply less principal minted earlier in the same transaction. The guard still divides by the supply as it stands, so a same-transaction mint only tightens it; the proof's attack reverts there, and with enough reserve for the guard to pass it is charged the undiluted fee.
- `b952037a` (medium): a self-funded redemption moved the base rate at no cost. The transient, same-transaction exclusion the finding suggested cannot pass its own proof, because `isolate = true` makes the proof's deposit, mint and self-redemption three transactions. The stored base now excludes principal the candidate minted within one half-life (twelve hours), tracked per position in storage and retired by any repayment, liquidation or redemption. This is a cost, not a closure: with the fee retained in the position, as the brief requires, a seasoned self-redemption is indistinguishable from an honest one, so a pump needs debt held in the eligible band, exposed to price and liquidation, for twelve hours per pinning. Changing where the fee goes would close it and is the requester's decision.
- `b8aa4a98` (low): the whole-basis-point fee now rounds up rather than down, so the sub-basis-point remainder is paid by the redeemer. The quote, the event and the charge all agree.

Checks:

- `forge build`: passed, with existing compiler/lint warnings.
- `forge test`: 366 passed, zero failed, two existing optional skips, with the four supplied proofs copied unchanged into `test/scratch/`.
- `FOUNDRY_TEST=script/checks forge test --match-path script/checks/Redemption.t.sol`: 46 passed, including eleven added regressions (deposit bypass across and within a transaction, one wei of debt, the minCR cap, unlisted and zero-factor reserve valuation, same-transaction mint, saturation with no prior supply, fresh principal charged but not stored, partial freshness, retirement by repayment, and fee rounding). The three legacy optional suites show the same 23 pre-existing failures and nothing new.
- Offline dry-runs of `DeployComp`, `DeployGoverned` and `DeployPrereqs` with `OPERATOR` and `--sender` set to the pinned reporter and zero `MOCK_IMD`: every `verify()` assertion passed; nothing broadcast.
- The supplied protected harness, run unmodified in scratch against CREATE2 initcode derived from the four-entry manifest on chain ID 11155111: passed. ParameterizedVault runtime is 16,592 bytes and its initcode with six constructor words 41,380 bytes.
- All twelve exports under `docs/abi/` match their compiled ABIs, including the regenerated `Treasury.json`, `PriceFeed.json` and `NhiFeed.json` and the added `SpotFeed.json`; the feed constructor paragraph in `ABI.md` now describes the two-argument constructor the manifest passes.

## Revision: how fresh principal ages

The review of the previous revision re-listed its four reproducible findings (`8936befa`, `fcd5b261`, `998ff6b2`, `b952037a`) with their proofs; all four proofs pass unchanged on this tree, and the function names those findings cite (`_checkRedemptionBacking`, `Treasury.reserveWithdrawalValue`) no longer exist. Nothing was changed for them. One new reproducible finding was confirmed and fixed:

- `883fa030` (medium): `mintCOMP` re-dated the whole fresh-principal record on every mint, so one wei every eleven hours and fifty-nine minutes kept any amount of principal fresh forever, and a redemption against such a position never moved the base rate. Reproduced in scratch before the change: a tenth of supply burned against a position kept alive that way for three days left `redemptionBaseRate` at zero, and so did a single one-wei top-up at 11h59m followed by eleven hours. The record's timestamp is now amount-weighted: a mint while the record is fresh moves it toward the present by the new principal's share of the enlarged record, rounded toward the present, and a mint after the record has aged out starts over at the present. Principal-time in the band is conserved however it is tranched, which is the cost the earlier revision claimed. The smaller inaccuracy reported alongside it is also corrected: the fresh part of a burn is now measured against the principal it cancelled, so cancelled stability fees always move the rate. That changes one accepted expectation in `script/checks/Redemption.t.sol` (`test_freshPrincipalIsChargedButDoesNotMoveTheRateOthersPay`), where a burn against a fresh position that had accrued twelve hours of fees now raises the base by the fees' share rather than by nothing. Four regressions were added: one-wei top-ups for three days, a one-wei top-up followed by eleven hours, two equal tranches ageing out at their average age, and cancelled fees never being fresh. No ABI changed.

Advisory findings were answered rather than changed: the aggregate guard halting redemption while backing per COMP is below one minus the fee (`3c1f49fc`, `6a96e6da`) is the accepted guard doing what it was added to do, and relaxing it on either route re-opens `b92320ae`, so the policy is left to the requester; the `compPerTask` repricing in `SwarmWorkOracle` (`d4017013`) reads as described but is a work-oracle defect outside this assignment and unreachable in this launch; the pinned Sepolia relay predating keeper bundling (`d7f72926`) was confirmed against chain state and is a deployment-order matter for the services and the manifest notes, not a vault source change; the ABI exports (`697701cd`) and the fee rounding (`b8aa4a98`) were already corrected in the previous revision, and the one remaining stale export, the abstract `SwarmFeed.json`, is regenerated here; the chunking (`ffe5af43`) and operator-withdrawal (`2a02220e`) notes describe the approved design.

Checks:

- `forge build`: passed, with existing compiler/lint warnings.
- `forge test`: 366 passed, zero failed, two existing optional skips, with the four supplied proofs copied unchanged into `test/scratch/` and passing.
- `FOUNDRY_TEST=script/checks forge test --match-path script/checks/Redemption.t.sol`: 50 passed. The three legacy optional suites show the same 23 pre-existing failures and nothing new.
- Offline dry-runs of `DeployComp`, `DeployGoverned` and `DeployPrereqs` with `OPERATOR` and `--sender` set to the pinned reporter and zero `MOCK_IMD`: every `verify()` assertion passed; nothing broadcast.
- The supplied protected harness, run unmodified in scratch against CREATE2 initcode derived from the four-entry manifest on chain ID 11155111: passed. ParameterizedVault runtime is 16,683 bytes and its initcode with six constructor words 41,471 bytes.
- All fifteen exports under `docs/abi/` match their compiled ABIs.
