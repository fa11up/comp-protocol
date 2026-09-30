# Contract test coverage

Run `forge build` and `forge test`. For a workspace restricted to test-file writes, place generated artifacts under scratch:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test
```

Dependencies are already vendored. The submitted suite needs no network, RPC, environment setup, FFI, or files under `test/scratch/`. Constructor fixtures deploy fresh local tokens to model the existing collateral and separately authorized COMP addresses. No production source or configuration is changed.

| Area | Tests |
| --- | --- |
| Independent debt/work mint channels, zero-rights borrowing, authorization, rollback, stale-feed gates, deposits/repayment/withdrawal | `CDPVault.t.sol`, `BoundaryPaths.t.sol` |
| Price-driven full, partial, repeated and self liquidation; cascade across positions; exact payout at unit price; grace and mark-expiry boundaries; recovery; NHI-only triggers; snapshot preservation | `Liquidation.t.sol` |
| Random debt and work minting, transfers, deposits, withdrawals, repayments, donations, feed shocks, staleness, elapsed time, marking, recovery and liquidation | `Protocol.invariant.t.sol` |
| Reporter quorum, median, zero-value rollback, deviation, round expiry, staleness boundaries, attestation acceptance/rejection and literal chain-1 signature domain on Sepolia | `SwarmFeed.t.sol` |
| Real SwarmFeed-to-vault liquidation, including feed expiry during grace and mandatory refresh of both feeds | `SwarmFeed.t.sol` |
| Reentrant callbacks across all eight vault actions, failed oracle/token calls, short incoming transfers, failed outgoing liquidation transfer rollback | `Adversarial.t.sol` |
| Full-range uint128 lifecycle properties and arithmetic saturation/boundaries | `ProtocolSequences.t.sol`, `Arithmetic.t.sol` |
| Token/oracle permissions, finite allowances and transfer failures, factory construction, separate token authorization, runtime checks | `Tokens.t.sol`, `MockWorkOracle.t.sol`, `FactoryDeployment.t.sol`, `LaunchToken.t.sol`, `Runtime.t.sol` |

The invariant campaign uses four tracked actors and 17 handler operations, with 256 sequences of 128 calls and unexpected reverts treated as failures. Both work and debt supply start nonzero, making the retired debt-only invariant immediately falsifiable. The replacement asserts:

```text
COMP.totalSupply == sum(all position debts) + vault.totalWorkMinted
```

Additional properties reconcile COMP wallet balances, collateral custody including donations, each position's complete deposit/withdraw/debt/repayment/liquidation history, rights consumed only by work minting, and mark/grace snapshots throughout an active window. Expired re-marking records a new timestamp and current NHI grace; expiry failures and subsequent execution are exercised deterministically. Randomized liquidation asserts the exact `debtToRepay * 110 / 100` payout at unit price. At other prices it checks debt retirement, token burns and custody conservation; the exact payout property fails and is reported below. Deterministic handler sequences prove successful liquidation at every generated price, recovery and both mint channels are reachable. Each random sequence ends by redistributing existing COMP, repaying every debt and withdrawing every position's collateral, including with stale feeds; remaining supply equals work issuance.

Liquidation tests make positions underwater through price or NHI changes after valid borrowing. They do not inject vault storage or manufacture COMP. Tests cover one second before and exactly at grace expiry, the final actionable timestamp and one second afterward, zero grace, both NHI directions during an existing window, repeat marking, deposit/repayment recovery and keeper-observed feed recovery. Rounding and sequence properties use 1,000 fuzz cases through inline configuration.

The handler models the accepted implementation's upward rounding of the NHI-derived minimum ratio. A deterministic sequence covers marking, rejected actions, maximum borrowing, maximum withdrawal and liquidation after a one-wei NHI decline. A separate liquidation regression crosses from a 170% minimum to 171% with no price movement and verifies that the 12,959-second grace snapshot survives a later NHI update. These regressions prevent the former floor-rounded handler from misclassifying underwater positions or generating unsafe calls.

## Reported payout defect

The supplied implementation divides the liquidation payout by price, violating the assignment's exact `debtToRepay * 110 / 100` requirement. Deposit 300 collateral, borrow 100 COMP at price 1, lower the price to 0.4, mark and wait six hours, then liquidate 100 debt. The liquidator must receive **110 collateral**, leaving **190**; actual results are **275** and **25**. With 120 collateral borrowed against at price 2 then marked at 0.8, repaying 100 should pay 110 and succeed, but instead reverts `InsufficientCollateral`.

The high-severity finding in `.imd-findings.json` embeds a self-contained Foundry proof using actual SwarmFeed contracts, including these two cases and a non-unit-price fuzz property. All three were run locally and failed. The failing payout regressions are carried in that proof rather than asserted as correct or silently skipped. To reproduce, save the finding's `proof` string as `test/scratch/LiquidationPayoutProof.t.sol` and run `forge test --match-path test/scratch/LiquidationPayoutProof.t.sol -vv`. The submitted suite keeps the passing unit-price execution campaign and the independent accounting checks at all prices; it does not certify non-unit-price payout correctness.

Local test feeds make value/freshness changes independently controllable and expose a finite one-day `maxAge` for mark expiry; the real-feed integration complements those isolated vault tests. These are offline tests, not live Sepolia or fork validation. They do not establish the deployed tokens' authorization state or constitute the independent launch review.
