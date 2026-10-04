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

Previous-round verification: offline `forge build` passed; default `forge test` reported **198 passed, 0 failed, 2 skipped** across 22 suites. The supplemental 1,000-BPS source variant reported **6 passed, 0 failed, 0 skipped**. The three invariant campaigns executed 65,536 randomized handler calls in total, with zero unexpected reverts. No new contract defect was reproduced in the covered paths. Production files and configuration were unchanged.

## Recovery-guard revision

`DivergenceGuard.t.sol` now exercises the accepted recovery fix through explicit mark clearing, one-wei collateral deposits and one-wei repayments. Both exact divergence boundaries permit recovery. One wei beyond either boundary, a stale spot feed or a zero spot price preserves the original mature mark during automatic recovery, while the deposit or repayment still succeeds. Once feeds agree again at an underwater price, liquidation executes immediately and pays the original marker its exact share. Explicit clearing is also included in the existing stale/zero-feed rollback checks.

The new explicit-divergence and automatic-recovery regressions were run against a disposable copy of the vault before the recovery fix: both failed because invalid observations cleared the mark. They pass against the accepted source. The copied source was confined to `test/scratch` and removed afterward; the submitted tests import the current production contract.

Revision verification: offline `forge build` passed, and `forge test` reported **202 passed, 0 failed, 2 skipped** across 22 suites, including all three invariant campaigns. The skips remain the live Sepolia suite and the nonzero-rate contract under the shipped zero constant. The supplemental 1,000-BPS runner separately passed all **6 tests**, including exact linear accrual. No new contract defect was reproduced. Only this coverage note and `DivergenceGuard.t.sol` changed.

## Work ceiling and reserve valuation

`WorkCeiling.t.sol` exercises the deployed `ParameterizedVault`: an empty ceiling,
reserve-only and debt-only backing, sum and rounding arithmetic, full-precision
products, multiple workers sharing one ceiling, exact mint boundaries, atomic
failure, the 2500-bps governance limit, and contraction after repayments,
withdrawals or ratio changes. The backing-ratio fuzz property compares exact
cross-products at `minCR`, avoiding fixed-point rounding that could hide the
surplus as reserves grow. Strict backing greater than one requires positive debt;
reserve-only backing is exactly one and the empty balance sheet has no ratio.

`ReserveValuation.t.sol` covers decimal scaling, aggregate valuation, governance,
COMP exclusion, stale or unavailable USD legs, and a liquidation that sends both
collateral revenue and minted stability fees to the vault-created Treasury.
Haircut endpoint regressions require zero backing at 0 and full market value at
10000, including rejection of work without valued backing and of one wei past
fully valued backing. Valuation fuzzing varies the retained factor across the
entire 0–10000 range together with token decimals, balances and prices.
The Chainlink leg is a local fixture at the source-pinned address; no network or
environment mutation is required.

`WorkBacking.invariant.t.sol` runs 256 sequences of 128 calls through the real
ParameterizedVault and Treasury. Deposit/withdrawal, debt/fee, work-right and
custody histories independently reconcile after random borrowing, repayments,
work mints, reserve price changes, donations, withdrawals, syncs and governance
of the work ratio and reserve haircut. The expected retained factor is tracked
independently, including deterministic sequences through both haircut endpoints.
A successful work mint must respect the ceiling at execution. The invariant does
not falsely require previously minted work to remain below a ceiling that later
falls after an authorized withdrawal, price change or repayment.

The older mechanics suites deliberately use CDPVault subclasses with pinned
zero/ten-percent economics. `LegacyWorkBacking.sol` funds a distinct borrower and
opens real collateral-backed debt before their successful work mints. Added
principal and collateral are included explicitly in the existing accounting
assertions. Random work actions in the existing handlers use available debt
backing; initialization and failure-path checks retain their original expected
errors. No successful work test is replaced by an expected ceiling revert.

The prior haircut endpoint finding is resolved in the accepted source. The
regressions above exercise the corrected behavior without changing production
contracts or weakening the earlier ceiling, stale-feed or fee-routing tests.

### Revised ceiling formula (independent review of 2026-10-03)

The accepted revision changed three things the suites above now pin, and the
fixture was re-based so the arithmetic still reads in whole units. The reserve
asset is priced at 2000 USD, the fixture's Chainlink ETH/USD answer, so one token
is worth one ETH: `reserveValueUsd` is asserted in dollars and `reserveValue`,
`backedDebt` and `workCeiling` in the vault's unit.

- **Unit conversion.** `reserveValue` must equal `reserveValueUsd x 1e18 / ethUsdPrice`,
  rounded down, for fuzzed balances and ETH/USD answers; the unconverted USD
  figure is refused as a mint amount; a dearer ETH shrinks the reserve term with
  the register unchanged; an ETH/USD leg one second past `ETH_USD_MAX_AGE` zeroes
  the reserve term while the asset's own USD source stays fresh and the debt term
  survives. For IMD priced through `UsdPriceFeed` the leg cancels to
  `balance x primary x haircut`. Eight- and eighteen-place aggregator answers scale
  to the same 1e18 price.
- **Same-transaction debt.** Every top-level test call is its own transaction, so
  the transient cap is reached through an `AtomicWorkBorrower` contract that
  chains the calls: borrow-then-mint, the full borrow/mint/repay/withdraw round
  trip, and a read of `backedDebt`/`workCeiling` inside the transaction all see
  zero for debt opened in that transaction, while the same position counts in
  full one transaction later. A repayment in the same transaction tightens the
  term immediately (the smaller of the start-of-transaction and live totals).
- **Bad debt.** A liquidation that drains a position at exactly its 110% payout
  leaves residual principal in `totalDebt` that `backedDebt` excludes; after a
  year of fees a one-wei repayment re-records the residual as accrued debt above
  the principal, and the subtraction saturates to zero instead of reverting; a
  healthy position opened afterwards counts less that over-count, which only
  tightens.
- **Divergence.** Against a finite ceiling, a spot price one wei beyond either
  divergence bound reverts `PriceDivergence`, a stale spot reverts `StaleFeed`, and
  the exact bound is accepted (independent spot feed on a second vault).
- **Backing bound on chain.** In addition to the pure-arithmetic fuzz, a 1000-run
  fuzz opens the only position at exactly `minCR` (collateral rounded up to the
  wei), funds any reserve size, governs any ratio up to 2500, mints the whole
  ceiling and checks collateral-plus-reserve exceeds all COMP by at least
  `(minCR - 1 - r) x D`.
- **Register validation.** A source with code that reverts on, or returns short
  words from, either `isStale` or `latestValue` is refused at proposal with
  `InvalidPriceSource`; a token claiming 78 decimals is refused and 77 is valued
  without a panic; a source that dies after listing counts for nothing without
  reverting the ceiling, and can still be delisted.

The invariant handler now also moves and expires the ETH/USD leg, tracks the
expected reserve term in the vault's unit, and asserts `totalBadDebt` stays zero
and `backedDebt` equals outstanding principal between transactions.

One defect was found and is reported in `.imd-findings.json` rather than tested
around: `Treasury.reserveValueOf` wraps both feed reads but not the token's
`balanceOf`, so a listed token that later reverts there makes `reserveValueUsd`,
`reserveValue`, `workCeiling` and every `mintFromWork` revert until a delisting
matures, against the view's documented promise never to revert. Low: only a
governance-listed token reaches it and the delisting path reads nothing from the
token.

Verification: offline `forge build` passed and `forge test` reported **319 passed,
0 failed, 2 skipped** across 37 suites, including all four invariant campaigns.

## USD denomination, the audit fixes, and attested work

In-house increments, not swarm-delivered. Three changes and the suites that cover them.

**USD denomination.** `ParameterizedVault` overrides the pricing seam so a position is measured in
dollars rather than wei of ETH, through a `UsdPriceFeed` the vault creates from its primary feed and
Chainlink ETH/USD. The divergence guard deliberately keeps reading the **raw** primary feed, because
both legs quote IMD in ETH and the ETH/USD factor cancels. `UsdDenomination.t.sol` covers the
denomination; 33 expectations across four existing suites moved from ETH to USD terms.

**Audit `da7d5b1c`.** Five findings, all fixed, reproduced in `audit/Audit20261004.t.sol`. Each
`test_regression_*` fails on the audited commit and passes on the fix; reverting `src/` fails 8 of 8.
The important one was a mixed-unit path the denomination created — `_clearIfRecovered` compared an
ETH-valued ratio against `minCR` — and two more were `try/catch` not covering ABI **decoding** in
`Treasury.reserveValueOf`, which made a malformed listed feed revert `workCeiling()` instead of
counting for nothing.

**Attested work.** `SwarmWorkOracle` extends `SwarmFeed`, so verification, replay, panel floors,
freshness and question binding are the inherited audited code. `SwarmWorkOracle.t.sol` covers the
factory wiring, the rights accounting under a falling count, the governed rate, and pins the Solidity
`expectedQuestionHash` against the JavaScript one for two windows — so the contract provably computes
what the service signs. These tests drive the figure through the reporter fallback rather than buying
an attestation, because the question is not yet answerable.

Verification: offline `forge build` passed; default `forge test` reported **360 passed, 0 failed,
2 skipped** across 41 suites, and `test/InHouse.t.sol` reported **14 passed** against live Sepolia
state. All three deploy scripts dry-ran green. The two skips remain the live Sepolia suite off-fork
and the gated auditor proofs whose API no longer exists.

## IMD redemption

Run the entire offline suite with plain `forge test` (and `forge build` to include
scripts). The existing `isolate = true` profile is required: the work ceiling
reads transaction boundaries. The artifact/cache environment variables at the
top of this document only keep generated files inside the permitted scratch area;
no additional profile, RPC, downloaded dependency or scratch source is needed.

- `Redemption.t.sol` covers reserve-only execution without touching a position,
  exact reserve exhaustion, same-call continuation into a borrower, a one-wei
  reserve shortfall, and refusal to spend other Treasury assets. Ceiling equality
  is refused and one wei below is accepted at both 150% and 200% minimum ratios.
  Tests compare exact collateral/debt fractions, including full repayment,
  accrued fees, recovery below minCR, and candidate-independent payouts.
- Failure cases cover zero/dust burns, excessive amounts, insufficient caller
  balance or candidate debt, ineligible candidates, minimum output, stale/zero
  prices, spot divergence, deeply underwater positions, direct Treasury calls,
  repeated spending and a failed final transfer after the reserve transfer.
  Atomic snapshots include balances, debt, fee state and Treasury receipts.
- `RedemptionEconomics.t.sol` checks the pre-burn supply fraction divided by four,
  the 50-bps floor and 500-bps cap, repeated pressure, twelve-hour half-life and
  eventual decay to the floor. A run passes through reserve, mixed and position
  funding until the candidate's improved ratio takes it outside the band.
  Separate reserve, mixed and position redemptions contract the work ceiling and
  reject further work minting without governance or restored work rights. Spread
  tests pin authority, the 48-hour delay, 25–100 bounds and live NHI derivation.
- Each deterministic suite includes a 1,000-case fuzz property: price/payout and
  reserve-split rounding in one, elapsed time and the next fee increase in the
  other. Exact cross-products avoid hiding ratio changes through rounding.
- `Redemption.invariant.t.sol` runs 256 sequences of 96 calls through four actors
  and eleven operations: reserve funding, deposits, borrowing, work minting,
  repayment, withdrawals, COMP transfers, time, NHI, redemption and slippage
  rejection. Independent histories reconcile supply, minted principal, paid
  stability fees, burned COMP, reserve spending and every unit of IMD custody.
  Every successful redemption checks one burn/one payout, reserve priority,
  collateral released only against retired debt, each affected position's ratio,
  fee bounds and work-ceiling contraction. Unexpected reverts fail the campaign;
  all three redemption routes are seeded and exercised in a deterministic
  handler sequence as well.

**Resolved backing finding:** the accepted source now rejects redemptions that
would worsen aggregate backing, including after repayment and collateral
withdrawal leave work-issued COMP outstanding. The original 100-IMD/250-COMP
counterexample now expects `RedemptionWorsensBacking` and verifies full rollback.
Additional regressions cover a safe underbacked redemption at exact equality,
one wei below that boundary, borrower and mixed payouts whose position ratio
would improve while aggregate backing would fall, fractional-value dust, and
discounted reserve valuation before and after recapitalization.

The invariant now checks aggregate backing after **every** successful redemption,
without the former solvent-state exception. Its failure model independently
compares exact payout/burn and backing/supply fractions at the fixture's $1 price
and 100% reserve factor. A deterministic handler sequence mints work, repays
borrower debt, withdraws collateral and attempts an unsafe reserve redemption.
It reproduced an unexpected `RedemptionWorsensBacking` revert before the model
repair and passes afterward; unexpected reverts still fail the campaign.

Disposable mutation checks confirmed that these tests fail if reserve priority
is disabled, ceiling equality becomes eligible, or the fee divisor becomes two.
Those source variants are not submitted.

The full-suite run also exposed a pre-existing liquidation-handler accounting
error: its receipt assertions included swept collateral dust, but its cumulative
seizure history omitted it. `Protocol.invariant.t.sol` now records the already
validated sweep and has a deterministic regression for the one-wei remainder.
The contract's liquidation behavior is unchanged.

Previous-round verification: `forge build` passed; the full `forge test`
run passed **405 tests, 0 failed, 2 skipped** across 44 suites. The existing skips
are `InHouseTest` without live Sepolia state and the gated `PermissionlessRelayTest`.
All new redemption tests run offline and none are skipped. The liquidation
invariant also passed replay of the original failing fuzz seed after the model
repair. The reported backing counterexample was separately executed and failed
at its intended assertion. That source defect is resolved as described above.

Revision verification: `forge build` passed, and the full default `forge test`
passed **412 tests, 0 failed, 2 existing optional skips** across 44 suites, using
only the scratch artifact/cache paths documented above. The 49 redemption tests
all pass without skips; their invariant executes 256 sequences of 96 calls with
zero unexpected reverts. No new contract defect was reproduced. This revision
changes only the redemption tests, their handler and this coverage note.

### Revised guards (fee rounding, secured backing, fresh principal)

The source revision after the previous round changed four things these tests
pin, and the suite was brought up to the accepted source rather than rewritten:

- The charged fee is the floor plus the base rounded **up** to a whole basis
  point. The two fuzz properties and the run test now expect `ceilDiv`.
- Principal the candidate minted within twelve hours is charged the full quoted
  fee but excluded from the stored base. The run test seasons its principal first
  so it exercises the documented curve; a new economics test pins the exclusion at
  the window boundary (one second either side) and a burn partly against fresh
  principal. The invariant handler mirrors the per-position fresh record and
  asserts the stored base after **every** successful redemption, with time steps
  of up to twelve hours so both regimes occur.
- The backing guard counts Treasury IMD plus vault IMD only up to `minCR()`
  percent of pre-transaction principal less realized bad debt. The invariant's
  backing model uses that figure; its seeded redemptions moved out of the handler
  constructor into a separate top-level call, because a constructor shares one
  transaction with everything it creates and the vault excludes same-transaction
  deposits and mints, which is exactly what made the previous attempt's `setUp`
  revert `RedemptionWorsensBacking`.
- `RedemptionGuards.t.sol` covers the rest: the sub-basis-point remainder
  (0.39 of a 1000 supply quotes, charges and emits 51 while the stored base keeps
  the exact fraction, fuzzed over 1,000 amounts); the cap refusing a burn the
  whole balance would allow and accepting it once principal stands behind the
  collateral again; stressed NHI raising what counts; realized bad debt deciding
  a refusal by itself; and, through a contract that makes several vault calls in
  one transaction (the only way to do that under `isolate = true`), a debt-free
  same-call deposit counting for nothing, a same-call mint neither diluting the
  fee nor passing the guard, a first-ever burn saturating at the cap, and the
  accepted slow path across a transaction boundary succeeding.

**Reported, not asserted:** the twelve-hour freshness window is re-dated whole
by any mint inside it, so one wei of new principal per half-day keeps any amount
of principal permanently excluded from the base, and a run against such a
position pays only the floor however large it is. That contradicts the brief's
curve and the source's own cost claim, so it is in `.imd-findings.json` with a
proof rather than pinned here. The guard closing channel A entirely when secured
backing per COMP falls below one minus the fee is noted there as well, as a
design consequence for the requester.

Current verification: `forge build` passed; the full default `forge test` passed
**422 tests, 0 failed, 2 existing optional skips** across 45 suites. The 60
redemption tests pass without skips; the invariant runs 256 sequences of 96
calls with zero unexpected reverts. The scratch proof fails on the current source
for the stated reason and is not part of the submitted suite.
