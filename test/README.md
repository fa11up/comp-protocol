# Contract test coverage

Run `forge build` and `forge test`. For a workspace restricted to test-file writes, place generated artifacts under scratch:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test
```

Dependencies are already vendored. The submitted suite needs no network, RPC, environment setup, FFI, or files under `test/scratch/`. Constructor fixtures cover both separately authorized COMP and self-contained vault deployment with zero COMP/oracle arguments. No production source or configuration is changed.

| Area | Tests |
| --- | --- |
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
COMP.totalSupply == sum(all position debts) + vault.totalWorkMinted
```

Additional properties reconcile COMP wallet balances, collateral custody including donations, each position's complete deposit/withdraw/debt/repayment/liquidation history, rights consumed only by work minting, and mark/grace snapshots throughout an active window. Expired re-marking records a new timestamp and current NHI grace; expiry failures and subsequent execution are exercised deterministically. Every successful randomized liquidation asserts the exact `floor(debtToRepay * 1.1e18 / price)` payout. The price set includes 0.5, 0.8, 1, 1.2 and 2; deterministic handler sequences prove successful liquidation at every generated price, recovery and both mint channels are reachable. Each random sequence ends by redistributing existing COMP, repaying every debt and withdrawing every position's collateral, including with stale feeds; remaining supply equals work issuance.

The additional self-contained deployment invariant runs 128 sequences of 64 calls across four borrowers and nine handler actions, also failing on unexpected reverts. It checks the same supply identity against independent debt/work histories, exact token and collateral balances, consumed rights and permanent constructor links. Random failure attempts cover initialization, privileged calls, invalid amounts, unsafe positions and independently expired feeds; the reporter refreshes feeds through `report`. Every sequence ends with full debt repayment and collateral withdrawal.

Liquidation tests make positions underwater through price or NHI changes after valid borrowing. They do not inject vault storage or manufacture COMP. Tests cover one second before and exactly at grace expiry, the final actionable timestamp and one second afterward, zero grace, both NHI directions during an existing window, repeat marking, deposit/repayment recovery and keeper-observed feed recovery. Rounding and sequence properties use 1,000 fuzz cases through inline configuration.

The handler models the accepted implementation's upward rounding of the NHI-derived minimum ratio. A deterministic sequence covers marking, rejected actions, maximum borrowing, maximum withdrawal and liquidation after a one-wei NHI decline. A separate liquidation regression crosses from a 170% minimum to 171% with no price movement and verifies that the 12,959-second grace snapshot survives a later NHI update. These regressions prevent the former floor-rounded handler from misclassifying underwater positions or generating unsafe calls.

## Revision coverage

The self-contained factory tests pass `compToken_ = oracle_ = address(0)` and assert reciprocal links immediately after construction. Real `PriceFeed` and `NhiFeed` instances receive their first values through the configured reporter before feed-dependent calls. Deterministic CREATE and CREATE2 round trips and 1,000 fuzz cases fund the borrower through MockIMD, borrow without work rights, mint earned work, repay without COMP allowance and recover all collateral without an initialization call. Both modes reject unsafe borrowing, excess repayment, unauthorized faucets and token/oracle consumption; `setVault` returns `AlreadyInitialized` for the operator, factory and unrelated callers from genesis. A seeded-feed expiry regression checks each stale feed independently and proves debt repayment and debt-free withdrawal remain possible.

The existing constructor-rejection test now uses code-less collateral with zero COMP: zero COMP itself is valid under the approved construction change. All other existing test cases are retained. The required `setOracle(address)`/`AlreadyInitialized` behavior cannot be asserted in a passing test because the source has no such entry point and returns empty revert data. This low-severity API mismatch is reported in `.imd-findings.json`, including a self-contained proof reproduced for the operator, factory and unrelated caller. The failing proof is excluded from the submitted passing suite; no test blesses the empty revert as correct.

The approved price-divided liquidation formula passes. The previous fixed-payout requirement at non-unit prices is withdrawn and is not a defect.

The revised sources replace the constant signature domain and immutable question-hash gate with a deployment-specific consumer domain and relayer/data-chain/answer-type policy, and reject a shared price/NHI feed. Regressions exercise these fixes in addition to the preserved reporter, signature integrity, freshness, replay and deviation tests. Both concrete feeds run the same inherited coverage. Signed question hashes may change between requests; signature validation still rejects tampering with them.

Local test feeds make value/freshness changes independently controllable and expose a finite one-day `maxAge` for mark expiry; the real-feed integration complements those isolated vault tests. These are offline tests, not live Sepolia or fork validation. They do not establish the deployed tokens' authorization state or constitute the independent launch review.
