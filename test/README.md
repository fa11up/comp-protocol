# Contract test coverage

Run `forge build` and `forge test`. For a workspace restricted to test-file writes, place generated artifacts under scratch:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test
```

Dependencies are already vendored. The submitted suite needs no network, RPC, environment setup, FFI, or files under `test/scratch/`. Constructor fixtures cover both separately authorized COMP and self-contained vault deployment with zero COMP/oracle arguments. No production source or configuration is changed.

| Area | Tests |
| --- | --- |
| Independent spot/primary divergence: exact upper/lower bounds, one-wei failures, small/full-width arithmetic, stale/zero feeds, atomic rollback and borrower exits | `DivergenceGuard.t.sol` |
| Distinct marker/liquidator/protocol shares, rounding, combined transfers, keeper ownership, payment failures and exact shortfall accounting | `MarkerBadDebt.t.sol` |
| Independent debt/work mint channels, zero-rights borrowing, authorization, rollback, shared-feed constructor rejection, stale-feed gates, deposits/repayment/withdrawal | `CDPVault.t.sol`, `BoundaryPaths.t.sol` |
| Price-driven full, partial, repeated and self liquidation; cascade across positions; exact payouts at prices 0.5, 1 and 2 including floor rounding; insufficient collateral rollback; grace and mark-expiry boundaries; recovery; NHI-only triggers; snapshot preservation | `Liquidation.t.sol` |
| Random debt and work minting, transfers, deposits, withdrawals, repayments, donations, feed shocks, staleness, elapsed time, marking, recovery and liquidation | `Protocol.invariant.t.sol` |
| Both concrete PriceFeed and NhiFeed: reporter quorum, median, zero-value rollback, deviation, round expiry, staleness boundaries, consumer-domain isolation, relayer/data-chain/answer-type gates, changing signed window hashes and attestation acceptance/rejection | `SwarmFeed.t.sol` |
| Real PriceFeed/NhiFeed-to-vault liquidation, including feed expiry during grace and mandatory refresh of both feeds | `SwarmFeed.t.sol` |
| Reentrant callbacks across all eight vault actions, failed oracle/token calls, short incoming transfers, failed outgoing liquidation transfer rollback | `Adversarial.t.sol` |
| Full-range uint128 lifecycle properties and arithmetic saturation/boundaries | `ProtocolSequences.t.sol`, `Arithmetic.t.sol` |
| Token/oracle permissions, finite allowances and transfer failures, factory construction, separate token authorization, runtime checks | `Tokens.t.sol`, `MockWorkOracle.t.sol`, `FactoryDeployment.t.sol`, `LaunchToken.t.sol`, `Runtime.t.sol` |
| CREATE/CREATE2 from an unrelated caller and origin, constructor-bound token/oracle, reporter-seeded real feeds, borrowing/work minting/full exit without initialization, caller locks and atomic failures | `FactoryDeployment.t.sol` |
| Self-contained CREATE2 vault with real reporter-seeded feeds: random borrower actions, rights consumption, supply/custody conservation, rejected operations and full exit | `SelfContainedDeployment.invariant.t.sol` |

The original protocol invariant campaign uses four tracked actors and 17 handler operations, with 256 sequences of 128 calls and unexpected reverts treated as failures. Both work and debt supply start nonzero, making the retired debt-only invariant immediately falsifiable. The replacement asserts:

```text
STABILITY_FEE_BPS == 0
vault.totalFeesMinted == 0
COMP.totalSupply == sum(all position debts) + vault.totalWorkMinted + vault.totalFeesMinted
```

Additional properties reconcile COMP wallet balances, collateral custody including donations, each position's complete deposit/withdraw/debt/repayment/liquidation history, rights consumed only by work minting, and mark/grace snapshots throughout an active window. Expired re-marking records a new timestamp and current NHI grace; expiry failures and subsequent execution are exercised deterministically. Every successful randomized liquidation asserts the exact `floor(debtToRepay * 1.1e18 / price)` total seizure, the marker's bonus share, and the liquidator's remaining payout. Marker custody is reconciled separately with the complete collateral supply. The price set includes 0.5, 0.8, 1, 1.2 and 2; deterministic handler sequences prove successful liquidation at every generated price, recovery and both mint channels are reachable. Each random sequence ends by redistributing existing COMP, repaying every debt and withdrawing every position's collateral, including with stale feeds; remaining supply equals work issuance.

The additional self-contained deployment invariant runs 128 sequences of 64 calls across four borrowers and nine handler actions, also failing on unexpected reverts. It checks the same supply identity against independent debt/work histories, exact token and collateral balances, consumed rights and permanent constructor links. Random failure attempts cover initialization, privileged calls, invalid amounts, unsafe positions and independently expired feeds; the reporter refreshes feeds through `report`. Every sequence ends with full debt repayment and collateral withdrawal.

Liquidation tests make positions underwater through price or NHI changes after valid borrowing. They do not inject vault storage or manufacture COMP. Tests cover one second before and exactly at grace expiry, the final actionable timestamp and one second afterward, zero grace, both NHI directions during an existing window, repeat marking, deposit/repayment recovery and keeper-observed feed recovery. Rounding and sequence properties use 1,000 fuzz cases through inline configuration.

The handler models the accepted implementation's upward rounding of the NHI-derived minimum ratio. A deterministic sequence covers marking, rejected actions, maximum borrowing, maximum withdrawal and liquidation after a one-wei NHI decline. A separate liquidation regression crosses from a 170% minimum to 171% with no price movement and verifies that the 12,959-second grace snapshot survives a later NHI update. These regressions prevent the former floor-rounded handler from misclassifying underwater positions or generating unsafe calls.

## Revision coverage

The self-contained factory tests pass `compToken_ = oracle_ = address(0)` and assert reciprocal links immediately after construction. Real `PriceFeed` and `NhiFeed` instances receive their first values through the configured reporter before feed-dependent calls. Deterministic CREATE and CREATE2 round trips and 1,000 fuzz cases fund the borrower through MockIMD, borrow without work rights, mint earned work, repay without COMP allowance and recover all collateral without an initialization call. Both modes reject unsafe borrowing, excess repayment, unauthorized faucets and token/oracle consumption; `setVault` returns `AlreadyInitialized` for the operator, factory and unrelated callers from genesis. A seeded-feed expiry regression checks each stale feed independently and proves debt repayment and debt-free withdrawal remain possible.

The existing constructor-rejection test now uses code-less collateral with zero COMP: zero COMP itself is valid under the approved construction change. All existing test cases are retained. Historical findings about the removed `setOracle` API are outside this increment; the current vault binds its oracle in its constructor.

The approved price-divided liquidation formula passes. The previous fixed-payout requirement at non-unit prices is withdrawn and is not a defect.

The revised sources replace the constant signature domain and immutable question-hash gate with a deployment-specific consumer domain and relayer/data-chain/answer-type policy, and reject a shared price/NHI feed. Regressions exercise these fixes in addition to the preserved reporter, signature integrity, freshness, replay and deviation tests. Both concrete feeds run the same inherited coverage. Signed question hashes may change between requests; signature validation still rejects tampering with them.

Local test feeds make value/freshness changes independently controllable and expose a finite one-day `maxAge` for mark expiry; the real-feed integration complements those isolated vault tests. These are offline tests, not live Sepolia or fork validation. They do not establish the deployed tokens' authorization state or constitute the independent launch review.

## Unattended-liquidation increment

Legacy fixtures now pass the sixth constructor address and read the fourth liquidation-mark field. `MirroredSwarmFeed` supplies a distinct spot address tied to the existing primary price for scenarios about deployment, arithmetic, grace or custody. `DivergenceGuard.t.sol`, `MarkerBadDebt.t.sol` and `StabilityFee.t.sol` instead deploy independently controlled spot and primary feeds. The mirror does not establish independent oracle security. Existing liquidation assertions now account for the marker's share without changing the borrower's total seizure or disabling the configured marker rate.

`MarkerBadDebt.t.sol` covers exactly exhausted collateral, insufficient-collateral rollback one wei beyond capacity, remaining repayable debt, multiple borrowers, repeated liquidation and recapitalization. Its fuzz properties verify the maximum debt payable under the integer payout formula, including collateral dust. The focused `BadDebtSequences.invariant.t.sol` additionally checks shortfall and custody accounting across random repayments, recapitalization, withdrawals and repeated exhaustion.

`StabilityFee.t.sol` exercises the shipped zero-rate deployment through real borrowing, elapsed-time reads, work issuance, repayment, liquidation and failed repayments. It checks untouched positions, late opening, partial repayment, unchanged principal supply and absence of stablecoin fee mints. Nonzero-rate behavior cannot be reached by a constructor argument or subclass override: `STABILITY_FEE_BPS` is a source constant. Separate parameterized tests and a disposable source-variant runner cover that case; a passing zero-rate run alone is not evidence for a nonzero fee deployment.

Run the supplemental nonzero-rate suite with:

```sh
python3 test/check_stability_fee.py
```

The runner uses vendored dependencies and offline Foundry. It copies the current source into a temporary directory under `test/scratch`, changes only the stability rate to 1,000 BPS, verifies that every source file otherwise matches, runs `NonzeroStabilityFeeTest`, and removes the copied project. The tests cover exact elapsed-time linear accrual, an idle position across years, late borrowing, changes in principal, fee-first repayment without compounding, fee-aware health/liquidation and rollback on an unfunded repayment. Default `forge test` explicitly skips this nonzero-only contract because the production constant is zero. The existing Sepolia fork suite also remains explicitly skipped without live chain state. Neither skip is counted as a passing check.

Final local verification: offline `forge build` passed; default `forge test` reported **198 passed, 0 failed, 2 skipped** across 22 suites. The supplemental 1,000-BPS source variant reported **6 passed, 0 failed, 0 skipped**. The three invariant campaigns executed 65,536 randomized handler calls in total, with zero unexpected reverts. No new contract defect was reproduced in the covered paths. Production files and configuration were unchanged.
