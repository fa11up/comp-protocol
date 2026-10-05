---
title: Risks and open questions
section: economics
order: 3
audience: everyone
sources:
  - src/SwarmFeed.sol:100-185
  - src/SwarmFeed.sol:232-329
  - src/UsdPriceFeed.sol:38-95
  - src/CDPVault.sol:494-640
  - src/CDPVault.sol:676-849
  - src/ParameterizedVault.sol:185-199
  - src/Parameters.sol:264-348
  - src/Governed.sol:53-89
  - src/Treasury.sol:115-230
  - src/Treasury.sol:277-323
  - src/SharePriceFeed.sol:36-93
  - src/SwarmWorkOracle.sol:101-191
  - src/SwarmRelay.sol:24-134
  - docs/AUDIT-2026-10-03.md:1-184
  - docs/AUDIT-2026-10-04.md:1-139
  - docs/INTERNAL-AUDIT-2026-10-04.md:1-279
  - docs/RESEARCH-PARAMS-2026-10-04.md:1-182
---

# Risks and open questions

`ParameterizedVault` enforces collateral, pricing and accounting rules; those rules do not guarantee solvency, a dollar market price or keeper participation. imdUSD holders can receive less than $1 of IMD per imdUSD through `cash` when measured backing is below par, before fees and market execution costs.

All economic settings and bounds discussed here are (under consideration). Distinguish a **source-enforced condition**, a **recorded test or observation**, and an **unresolved economic assumption**.

## Oracle and service risk

**Source-enforced.** The concrete feeds require the pinned signer, question hash, panel floors, advancing bounded windows, request uniqueness and timestamp validity. Primary and spot have separate own-history deviation checks; the vault has the cross-feed `skew` check. Chainlink ETH/USD adds a separate availability and pricing dependency.

**Residual trust.** One service key attests panel counts and answers. The contract does not verify individual panel signatures, member independence, pool observations, absolute data-chain window recency or the signed `blockHash`. Both price questions use the same pool. Valid signatures and agreeing prices can therefore coexist with misleading economic value.

A fresh own-history deviation bound can reject a truthful large market move. After staleness the source allows a valid attestation to re-anchor without that bound. This restores update ability but places more weight on the signer and question. It is not the stronger independent recovery path recommended in the parameter research.

A stale or divergent feed also blocks liquidation and redemption, not just borrowing. Repayment, collateral addition and debt-free withdrawal bypass explicit price gates. Their token and dependency calls can still fail; “no freshness gate” is not an unconditional availability guarantee.

**Open evidence.** Per-leaf launch question binding must be tied to a live service-signed attestation and on-chain acceptance, as detailed in [Swarm evidence](./swarm-evidence.md). Freshness parameters and observation latency must be assessed together; a timestamp check alone does not make a slow service fast.

## Collateral and liquidity risk

The vault values sIMD at an attested IMD market observation times the staking vault's exchange rate. It does not guarantee that a liquidator can sell seized collateral at that price. Concentrated liquidity, disappearing liquidity providers, gas congestion and simultaneous liquidations can turn a nominal bonus into a loss.

`bite` requires collateral for its full priced payout. A keeper can choose a smaller amount, and unseizable dust may be swept, but a deeply short position can leave debt unpaid. `totalBadDebt` records exhausted-collateral residuals; it is not insurance or a write-off. `backedDebt` subtracts recorded losses for work capacity but does not cancel the liability.

Work issuance can remain outstanding after supporting borrower debt is repaid across transactions or reserves are withdrawn. `earnLine` controls new issuance rather than maintaining a permanent backing claim. `backingPerUnit` is conservative and can fall after a redemption reduces principal-based eligibility. A payout formula is not a guarantee that every requested redemption has a feasible candidate.

The runbook's share plan adds conversion, decimals and redemption-availability questions. `SharePriceFeed` uses raw-share units while Treasury values whole-token units. The source does not automatically wire a wrapper into the vault. See the visible integration TODO in [Contracts and addresses](../reference/contracts-and-addresses.md).

## Governance and Treasury risk

`Parameters` limits rates, splits, spreads, work conversion and reserve listings and exposes proposals during a delay. A valid parameter set can still make liquidation unattractive or reserves overvalued. In particular, the bonus-share bound allows no executor remainder for a non-marker liquidator.

`applyPending` is permissionless after the delay, but proposals never expire. A mature proposal can be applied much later than its ETA. Monitoring must include mature unapplied proposals.

The pinned operator can withdraw Treasury tokens to a chosen recipient without the parameter delay. This can immediately reduce redemption liquidity and work backing. The ability to govern a reserve price source also introduces valuation trust even though the vault's own primary feeds are immutable. The source contains no on-chain vote, rotating governor, withdrawal budget or guarantee of multisignature operation.

## Smart-contract risk and audit scope

The audit dated 2026-10-03 reports 11 findings: one high, two medium, four low and four informational findings. Its high finding concerned a permissionless relay paired with an unbound question. The concrete source leaves all override `questionPolicy`, but the abstract base only requires a nonzero relayer when a question is unbound. A future leaf lacking binding could reintroduce that unsafe combination; a nonzero relay address is not proof of restricted callers.

The audit dated 2026-10-04 reports five findings: three medium and two low findings involving dollar-denominated recovery checks, malformed reserve responses, token balance-read failure, Treasury receipt accounting and ETH/USD timestamp/decoding checks. The source contains corresponding fixes. The record says regression proofs were reconstructed from reported reproductions because proof source files were not delivered. These facts support targeted regression coverage, not whole-system correctness.

The internal audit identifies redemption/backing-cap and swarm-wide work logic as needing independent review in its assessed scope. It also distinguishes default-run tests from checks outside the default test directory. Test counts in dated reports are not a coverage measure for every function or proof of launch readiness.

Source inspection shows reentrancy guards on token-moving vault paths, exact-deposit accounting, guarded arithmetic and transient transaction accounting. None proves all call sequences safe. Immutable contracts cannot be repaired with a parameter proposal; configuration and bytecode identity need verification before users rely on a deployment.

## What is established on chain versus in tests

**On-chain rules in the source:** signature and question checks; collateral and debt gates; proposal permissions and timing; token mint/burn authority; Merkle inclusion and controller checks. These are implemented conditions, not a claim that this documentation deployed or exercised them.

**Recorded on-chain observations:** the internal audit records a borrow/repay cycle, liquidation split, health mapping and service attestation relay with state read-back. That record does not establish that the full launch configuration and every implemented subsystem were exercised.

**Recorded tests and fork observations:** the internal audit reports 414 passing tests and three skipped tests, plus fork checks for the share adapter and service schema. It assigns redemption, backing cap, swarm-wide work issuance, keeper bundles and the governed stack to test-only evidence in its assessed scope. Fork execution is not an independent production transaction.

**Not established here:** a complete launch acceptance receipt set, independent review of the full resulting configuration, stressed market depth, reliable funded keeper operation or a fully connected paid-oracle path. No contract suite, fork test or live transaction was run for this documentation deliverable. The [evidence page](./swarm-evidence.md) preserves the distinction between recorded results and open checks.

## Keeper and execution risk

Keepers need ETH for gas and imdUSD inventory to burn. Profit also depends on the price paid for that inventory, the amount that can be liquidated, `CHOP_PERCENT`, `chip`, `cut` and the price realized on IMD after unstaking. Marking earns nothing unless liquidation pays the recorded beneficiary. No contract promises a keeper profit.

`relayAndBite` makes update and liquidation atomic, but does not reserve the signed update or the liquidation opportunity. Another keeper may relay first, invalidate a repeated request or take the opportunity. The update purchaser may lose its purchase cost and transaction gas. Choosing the relay itself as marker beneficiary can strand a directly paid marker reward; the relay has no sweep function.

A public RPC's empty log result is not proof of an empty loan book. Use explorer fallback and explicit unreadable states as described in [Reading state](../reference/reading-state.md). A keeper that misses a position cannot liquidate it. Expired marks require a new mark and grace; an unobserved recovery followed by decline can reuse an unexpired mark.

## Oracle budget and payment gap

The source accepts and relays already signed attestations. It pays no direct relay reward and contains no Intake-funded request purchase, automatic Treasury reimbursement or budgeted keeper spending role. Treasury funds can move only through the implemented operator withdrawal and vault redemption paths. The runbook's separate keeper funding plan is an operational plan, not autonomous contract funding.

A useful budget separates request fees, failed or refused requests, relay gas, observation/monitoring costs and liquidation working capital. Request expense per period equals paid requests per period times request price, including unsuccessful purchases. Add gas and monitoring rather than treating liquidation inventory as a recurring expense. Price, cadence and budget values are (under consideration).

The parameter research's update-cost scenarios are illustrative analysis. They do not establish the service price, a launch refresh commitment or sufficient fee income. Tighter freshness can require more spending, but paying more does not prove the service can meet the latency target. Debt that remains open still needs monitoring when no borrower transacts.

Request fees are paid from the Treasury through `OracleAsker`, within a governed daily budget ([How updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). Three limits remain. A request the panel refuses still costs its fee, so refused requests count against the budget. A budget too small for a volatile market leaves feeds to go stale, which halts price-dependent actions rather than mispricing them. And the asker is triggered by anyone, so someone must call it: monitoring is still needed, and relay gas and liquidation inventory are still the keeper's. Relayers are not reimbursed.
