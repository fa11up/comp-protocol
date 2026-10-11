---
title: Swarm evidence
section: economics
order: 2
audience: everyone
sources:
  - src/SwarmFeed.sol
  - src/PriceFeed.sol
  - src/NhiFeed.sol
  - src/SpotFeed.sol
  - src/SwarmWorkOracle.sol
  - oracle/question-prefix.mjs
  - test/QuestionBinding.t.sol
  - docs/INTERNAL-AUDIT-2026-10-04.md
  - docs/AUDIT-ORACLE-2026-10-05.md
  - docs/RESEARCH-PARAMS-2026-10-04.md
  - docs/PARAMETERS-2026-10-05.md
---

# Swarm evidence

imdUSD's prices come from IdentityMD: a panel of agents answers a fixed question and the oracle service signs the answer. This page says what that proves, what it does not, and what is published at launch. The checks themselves are in [Oracle and question binding](../reference/oracle-and-question-binding.md).

## What a signed answer proves

When a feed accepts an update, the contract has confirmed that:

- the oracle service's key signed it, for this feed on this chain;
- it answers this feed's own question for that block window, and no other;
- the service reported a panel of at least 25 agents with at least 15 agreeing;
- the window is newer than the last accepted one and the answer is recent.

## What it does not prove

- **That the answer is true.** The contract trusts the service's signature. It does not see individual agents' answers, check they worked independently, or re-read the pool.
- **That the market is deep.** A correct price for a thin pool is still a price few can trade at.
- **That the two prices are independent.** The primary price is the median of 13 readings across a window; the spot price is the last block's reading. Both come from the same pool.
- **That the network is healthy in a market sense.** The health index measures the swarm's participation, uptime and completed jobs, as published by IdentityMD. Nothing on chain checks those counts.

## Work tally

Mint from work uses a different answer: the root of a daily tally of each agent's accepted tasks, published by IdentityMD. An agent's controller claims its tasks against that root with a proof, and each task can be claimed once. A valid claim shows the task is in the published tally; it does not show the work was valuable or recent. Minting from work is off at launch: the wage is zero until a governance proposal sets one, after the 48-hour delay.

## Parameter research is analysis, not configuration

The parameter research (linked under Sources) compares imdUSD's settings with other lending protocols and stress-tests them. It argued for larger collateral buffers, a bigger share of the bonus for liquidators, shorter price ages and fees that cover oracle costs, and it questioned relaxing collateral requirements when the swarm is healthy. The launch parameters record which recommendations were taken. The research's market figures are scenarios, not measured losses, and it says itself that the pool's real depth could not be established.

## What is published at launch

Before the vault is deployed, one attestation is bought for each price feed (price, spot and network health) through the protocol's own `OracleAsker`. A feed accepts an answer only to its own question, and the first values are checked against IMD's pool and an outside reference before the vault exists. The work oracle is not seeded while minting from work is off. Those receipts are published here with the contract addresses. Until a feed's receipt is published, treat its question binding as tested, not proven against the live service.
