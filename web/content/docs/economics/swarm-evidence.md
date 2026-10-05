---
title: Swarm evidence
section: economics
order: 2
audience: everyone
sources:
  - src/SwarmFeed.sol:26-329
  - src/PriceFeed.sol:32-48
  - src/NhiFeed.sol:30-46
  - src/SpotFeed.sol:39-53
  - src/SwarmWorkOracle.sol:50-232
  - oracle/question-prefix.mjs:45-104
  - test/InHouse.t.sol:129-151
  - test/QuestionBinding.t.sol:47-145
  - docs/INTERNAL-AUDIT-2026-10-04.md:21-113
  - docs/RESEARCH-PARAMS-2026-10-04.md:1-182
---

# Swarm evidence

`SwarmFeed` establishes that a pinned service signer attested specified fields under a pinned question policy. It does not independently prove the economic truth of the figure or verify a separate signature from every panel member. The [oracle reference](../reference/oracle-and-question-binding.md) describes the exact on-chain checks.

## What is attested

| Consumer | Attested subject | What remains outside the contract |
|---|---|---|
| `PriceFeed` | Median of 13 evenly spaced pool observations over the pinned block window, in wei of ETH per 1e18 raw IMD units. | Correct observation, pool interpretation, meaningful liquidity and resistance to sustained manipulation. |
| `SpotFeed` | IMD/ETH at the window's final block from the named pool. | Independence from the primary market: it uses the same pool and is a comparison, not an independent economic source. |
| `NhiFeed` | Weighted health measure from live participation, service availability and job-state counters. | Truth of published counters and their relationship to collateral-market risk. |
| `SwarmWorkOracle` | Agent-tally Merkle root in the qualifying published daily receipt. | Whether the reported accepted work happened or had the economic value attributed to it. |

The consumer requires at least 25 panel members and 15 agreeing members, with `agreed` no larger than `panelSize`. `quorum` is signed but not enforced as a separate acceptance threshold. A larger panel does not automatically raise the agreement floor. The source verifies one service signature reporting those counts; it cannot establish independence of the members.

## Evidence ledger: measurements, tests and open checks

The dated audit records are evidence about the checks they report, not certification of the launch stack. Their observations were not rerun for this documentation assignment.

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| Internal audit, section 1.1: a service-signed attestation with a 60-member panel and 20 agreeing members was relayed; value, consumed request and freshness were read back. | A recorded end-to-end service/relay transaction and state check. | Launch-address identity or acceptance by every pinned launch question. |
| Internal audit, sections 1.1 and 1.3; `test/InHouse.t.sol`: attestation v2 typehash/domain checked against service signatures. | Recorded compatibility of the signed schema; test expectations tie the domain to consumer and chain. | A decentralized signing threshold or proof of answer correctness. |
| Internal audit, section 1.3: the prefix generator matched service request `50d9b023`, and Solidity/JavaScript hashes agreed for three leaves. | Evidence for the canonical-document reconstruction mechanism. | A per-leaf successful on-chain acceptance of the exact launch payloads. |
| Internal audit, section 2.2: frozen leaf payloads still required live-purchase verification. | An explicit remaining evidence gap rather than an assumed pass. | Any later completion of that check; no such receipt is supplied here. |
| `test/QuestionBinding.t.sol` | Source contains tests for wrong questions, bounded windows, advancing windows and distinct leaf questions. | A service purchase or deployment receipt; local signatures and fixtures are not live-service evidence. |

Question binding is checked on chain during `submitAttestation`: the signed `questionHash` must equal the feed's own `expectedQuestionHash(fromBlock, toBlock)`. To substantiate that this matches the live service for a particular immutable leaf, the evidence must join the canonical document, service-signed attestation, domain and recovered signer, deployed getter result, and acceptance receipt. A generator matching its own output is only one part of that chain.

That chain is assembled for `PriceFeed`, `SpotFeed`, `NhiFeed` and `SwarmWorkOracle` before launch, and published with their addresses: (waiting for mainnet launch). A feed without a published receipt is not labelled proven on chain.

## Work tally and rights

The pinned work question asks the panel to fetch the receipt identified by the external work registry, verify its canonical document hash and rebuild its agent Merkle tree. A missing or inconsistent receipt calls for inability rather than an invented zero tally. Those document checks are instructions in the pinned question to the panel; the work oracle verifies the signed root, not the full receipt bytes or their registry commitment.

After attestation, anyone may call `recordRoot()` to save the latest nonzero figure in `acceptedRoots`. Roots must be recorded before a later observation replaces them if claimants need to use them. The function itself has no staleness gate.

`claim(agentId, accepted, cumulative, proof, root)` requires an accepted root, controller authorization through the pinned ERC-8004 adapter, and a sorted-pair Merkle proof. The leaf double-hashes ABI encoding of `uint256 agentId`, `uint32 accepted` and `uint64 cumulative`. `accepted` is authenticated but only the cumulative count determines new credit.

New rights equal the uncredited cumulative increment times `wage`, whose value is (under consideration). `creditedTasks` prevents claiming the same increment again, including across root changes or controller changes. Rights go to the controller at claim time. Previously claimed rights remain with their recipient; a new controller can claim the untaken increment. `TallyClaimed.tasks` carries the cumulative count, not just the newly credited increment.

Old accepted roots remain valid and neither `claim` nor `consumeRights` checks feed freshness. A valid proof therefore establishes inclusion and accounting eligibility, not recent work. `earn` separately requires usable vault pricing, rights and the cumulative `earnLine` ceiling. Whether earn is open at launch is (under consideration).

## Parameter research is analysis, not configuration

`docs/RESEARCH-PARAMS-2026-10-04.md` compares incentive denominators, collateral ratios, oracle recovery and fee budgets. Its opening explicitly says IMD-market figures supplied by its assignment were not independently verified. Its recommendations are conditional engineering judgments, not the values implemented by governance. All proposed economic values and bounds remain (under consideration).

**Recorded measurements and sourced comparisons.** The research reports external-protocol parameter snapshots and source-based bonus-split calculations. It distinguishes a fraction of the bonus from a fraction of principal or total collateral seized. The economic inference for imdUSD is that the executor must cover gas, token acquisition, sale impact and inventory risk after `chip` and `cut`; the research does not measure the resulting number of willing imdUSD liquidators.

**Supplied observations and scenarios.** A reported upward IMD price movement is used to motivate a downward stress scenario. The downward move, sale-impact allowance and oracle-overvaluation allowance are hypotheses, not observed losses or statistical tail estimates. Marked vault value is not executable market depth. The research says a depth-derived optimum cannot be established from its inputs.

**Recommendations.** The report argues for greater collateral buffers and executor compensation, a lower protocol take until competition is demonstrated, shorter usable-price ages with funded refresh/recovery, and calibrated stability/redemption fees. It questions health-based relaxation of the collateral floor. It recommends separating fresh authenticated recovery from ordinary deviation rejection and warns that a second observation of one pool is not independent price evidence.

Several recommendations cannot be enacted by the available setters: `mat`, `lull`, the gross bonus and the redemption curve are fixed; `line` cannot be set to no debt capacity via a zero ceiling. The source also permits stale-value re-anchoring, whereas the research advises a separately specified recovery mechanism. These are differences between analysis and implementation, not implied governance decisions.

**Unanswered measurements.** Stressed executable depth, concentrated sales, liquidity-provider withdrawals, wrapper redemption constraints, funded keeper competition and service response latency are not established for this launch by the research. Its illustrative oracle budget is not a funding commitment. See [Risks and open questions](./risks-and-open-questions.md).
