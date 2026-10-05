---
title: Oracle and question binding
section: reference
order: 4
audience: integrators
sources:
  - src/SwarmFeed.sol:26-329
  - src/DeploymentConfig.sol:45-78
  - src/PriceFeed.sol:17-48
  - src/NhiFeed.sol:17-46
  - src/SpotFeed.sol:24-53
  - src/SwarmWorkOracle.sol:50-232
  - src/SwarmRelay.sol:37-134
  - src/UsdPriceFeed.sol:23-96
  - src/CDPVault.sol:865-885
  - src/ParameterizedVault.sol:152-164
  - oracle/question-prefix.mjs:45-104
  - docs/INTERNAL-AUDIT-2026-10-04.md:21-113
---

# Oracle and question binding

`SwarmFeed` verifies service-signed numeric attestations. Its concrete leaves pin the question they accept. `PriceFeed` supplies a median of 13 evenly spaced IMD/ETH observations in a window; `SpotFeed` supplies the final-block observation from the same named pool. `NhiFeed` supplies [Network health](../governance/network-health.md). `SwarmWorkOracle` interprets the figure as a Merkle root, not a price.

## Attestation v2 and its domain

The EIP-712 domain has name `IdentityMD Oracle`, version `2`, the consumer chain's `block.chainid`, and the receiving feed as `verifyingContract`. Feed addresses are (waiting for mainnet launch). `DOMAIN_SEPARATOR` is fixed at construction. The payload's `chainId` is separately checked against `attestationChainId`: it identifies the data chain, not the consumer domain. The pinned data chain is Ethereum mainnet, chain ID `1`; `attestationAnswerType` is enum code `3` for `uint256`.

The exact signed structure behind `ATTESTATION_TYPEHASH` is:

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
```

Dynamic `answer` bytes are hashed in the struct encoding. The digest is the EIP-712 prefix, `DOMAIN_SEPARATOR` and struct hash. Signature recovery requires 65 bytes, a low `s`, an accepted recovery `v`, and the immutable `attester` as signer. The signature is one service signature, not a set of independently verified panel signatures.

`panelSize` must be at least 25 members (`MIN_PANEL_SIZE`). `agreed` must be at least 15 members (`MIN_AGREED`) and cannot exceed `panelSize`. `quorum` is signed metadata but is not compared with `agreed` by the consumer. Thus neither a quorum percentage nor a majority of a larger panel is enforced. These are technical validation floors, not economic parameter proposals.

## Question and window binding

`expectedQuestionHash(uint64 fromBlock, uint64 toBlock)` returns the hash of the canonical question document reconstructed from `QUESTION_PREFIX`, decimal block numbers, and the exact closing JSON suffix. It does not itself validate the window. Question text, definitions, answer type, data chain and evidence mode are in that document. Request guards, requested panel size/quorum and consumer settings are outside the question document.

`submitAttestation` checks the following before any update can persist:

1. The caller is the configured `relayer`, the data chain and answer type match, and the signed panel counts clear the floors.
2. `issuedAt` is not in the future or after `expiresAt`; expiry has not passed; issue time is no older than `maxAge` or the accepted observation. Reusing a `requestId` is refused.
3. The signature recovers to `attester`.
4. The window is ordered, its span fits the leaf's pinned limits, `toBlock` strictly exceeds `lastToBlock`, and `questionHash` equals `expectedQuestionHash` for those exact bounds.
5. The figure passes the leaf's value guard. Successful acceptance stores the figure, signed issue time, used request and closing block, and emits `ValueUpdated` and `AttestationAccepted`.

| Leaf | Pinned span, measured as `toBlock - fromBlock` | Meaning of window |
|---|---|---|
| `PriceFeed` | 300–1,200 blocks | Bounded sampling window for the median. |
| `SpotFeed` | 150–1,200 blocks | Only its last block prices spot. |
| `NhiFeed` | 150–1,200 blocks | Ordering/hygiene; the question reads live service counters at answer time. |
| `SwarmWorkOracle` | 5,000–9,000 blocks | Selects the qualifying daily receipt as of the closing block. |

The contract does not compare `toBlock` with a live data-chain head or verify `blockHash` against that chain. Advancing windows prevent reuse or regression, but do not prove absolute observation recency. `issuedAt` proves the signer's stated issue time. Panel behavior and service observation policy remain trust assumptions.

## Freshness and two different deviation checks

A feed is stale before its first accepted value, or once elapsed time since signed issue exceeds `maxAge`; equality remains fresh. `latestValue()` can return a stale stored value, so read `isStale()` separately. Feed maximum ages and all economic deviation settings and bounds are (under consideration).

`maxDeviationBps` limits change from a feed's own previous value while that value is fresh. Zero figures always fail. When the previous value has aged beyond `maxAge`, the next otherwise valid attestation can re-anchor without that change bound. `SwarmWorkOracle` overrides this check because roots have no numeric distance; it retains the nonzero requirement.

`skew` is a separate vault guard: the absolute primary/spot difference must not exceed the primary value multiplied by the allowed basis-point fraction. Both inputs are raw IMD/ETH, so ETH/USD is not part of that comparison. It does not establish an independent market price when both readings use the same pool.

## Relayer and dollar price

`SwarmRelay` is permissionless even though feeds require its address as caller. `relay`, `relayMany`, `relayAndBark` and `relayAndBite` preserve all feed checks. Bundles are atomic, but do not give the update purchaser priority over other keepers. Follow [Relay oracle updates](../keepers/relay-oracle-updates.md) for the procedure.

`UsdPriceFeed.latestValue()` multiplies the primary IMD/ETH value by the Chainlink ETH/USD answer, normalizing the aggregator's decimals. It returns USD per IMD scaled by 1e18 and the older leg's timestamp. Missing, malformed, nonpositive or timestamp-less ETH/USD data returns no usable price. `isStale()` rejects a stale primary and stale or future-dated ETH/USD observations; `maxAge()` reports the shorter allowance.

Crucially, `latestValue()` does not itself reject an otherwise well-formed stale or future-dated ETH/USD answer. Use it together with `isStale()`. `ethUsdPrice()` does apply the ETH/USD age check. The vault's action gates consult staleness before using the dollar price.

## Evidence boundary

The internal audit records a live service-signature/schema check and a generator match against a service request, plus local Solidity/JavaScript question-hash agreement. It separately records that the frozen leaf payloads still needed their own live-attestation comparison. This is not proof of a mainnet acceptance for every leaf. See [Swarm evidence](../economics/swarm-evidence.md) for the evidence ledger.

Before launch, one attestation is bought for each feed and its `questionHash` compared with the deployed feed's own `expectedQuestionHash(fromBlock, toBlock)`, then submitted and accepted on chain. Those receipts are published with the addresses: (waiting for mainnet launch). Until a feed's receipt is published, treat its question binding as tested locally, not proven against the live service.

## How updates are paid for

The protocol pays for its own price updates from its Treasury, and no key decides when.

**`OracleAsker`** buys an attestation for a feed through IdentityMD's on-chain request contract (the Intake), paying the Intake's listed price in IMD. Anyone may call `ask(feed, body)`, but it pays only when the chain shows the update is needed:

- **The network health feed is close to stale**, a fixed fraction of the way to its maximum age (under consideration), or has no value yet. Only feeds marked to be kept alive are refreshed this way; the price feeds are not, because keeping them fresh on a clock would cost far more than it protects.
- **IMD's own pool has drifted from the feed** by more than half the feed's deviation bound, so an update is bought before the market moves further than the feed can follow in one step. Drift must first be recorded with `arm(feed)` and still be present a number of blocks later (under consideration). A pool pushed off price and back within one transaction, as with a flash loan, cannot trigger a paid update.

`body` must be the exact request the feed's pinned question was built from; the asker stores only its hash. Spending is bounded four ways: one request in flight per feed until it is delivered or times out, a minimum interval between paid requests for the same feed, a maximum price per request, and the daily budget below. Each value is (under consideration).

The Intake delivers the answer by calling the asker back, and the asker hands the attestation to `SwarmRelay`, so the feed checks it exactly as it checks one relayed by hand. If that delivery fails, the attestation is still public and anyone may relay it.

**`Treasury.fundOracle()`** is how the asker gets its IMD. Anyone may call it. It sends the asker what remains of the day's budget, `oracleBudget` on [Parameters](../governance/parameters.md), unstaking the Treasury's sIMD so the asker receives the IMD the Intake is paid in. The budget changes only through a delayed governance proposal and has a hard upper limit, both (under consideration). Days are UTC days.

**`askPaid(feed, body, maxPrice)`** is how anyone else gets a fresh price. The caller pays the Intake's price in their own IMD, at most `maxPrice`, and an update is bought for any feed at any time, with no condition, because no protocol money is spent. When a price feed is stale, borrowing, withdrawing against debt, marking, liquidating and redeeming wait until someone buys an update this way or the pool moves enough for the Treasury to buy one.

Relayers are not reimbursed, and none of this is required: when the budget is spent, or the Intake is unavailable, anyone can still buy an attestation from the oracle service and relay it themselves.
