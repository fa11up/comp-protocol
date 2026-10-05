---
title: Oracle and question binding
section: reference
order: 4
audience: integrators
pending: true
sources:
  - src/SwarmFeed.sol:26-329
  - src/DeploymentConfig.sol:45-78
  - src/PriceFeed.sol:17-48
  - src/NhiFeed.sol:17-46
  - src/SpotFeed.sol:24-53
  - src/SwarmWorkOracle.sol:50-232
  - src/SwarmRelay.sol:37-134
  - src/UsdPriceFeed.sol:23-96
  - src/OracleAsker.sol:1
  - src/Treasury.sol:474
  - src/CDPVault.sol:865-885
  - src/ParameterizedVault.sol:152-164
  - oracle/question-prefix.mjs:45-104
---

# Oracle and question binding

The vault's prices come from IdentityMD panels: a panel of agents answers a fixed question, the IdentityMD oracle service signs the answer, and anyone can submit the signed answer (an attestation) to a feed. `SwarmFeed` is the contract that checks attestations. Four contracts are built on it:

- `PriceFeed`: the median of 13 evenly spaced IMD/ETH readings across a block window.
- `SpotFeed`: the IMD/ETH reading at the last block of a window, from the same pool.
- `NhiFeed`: the [network health index](../governance/network-health.md).
- `SwarmWorkOracle`: a Merkle root of the swarm's work tally, not a price.

Each one accepts answers to its own question and no other.

## What an attestation contains

| Field | Meaning |
|---|---|
| `requestId` | The oracle request it answers. Each can be used once. |
| `chainId` | The chain the question reads data from (Ethereum mainnet, `1`), which is not necessarily the chain the feed lives on. |
| `questionHash` | Hash of the question the panel answered. |
| `answerType`, `answer` | The answer's type (`3`, a `uint256`, for every feed here) and its encoded bytes. |
| `figure` | The number the feed stores, scaled by 1e18. For the work oracle, a Merkle root. |
| `fromBlock`, `toBlock`, `blockHash` | The block window the answer covers. |
| `panelJobId` | The panel job that produced it. |
| `panelSize`, `quorum`, `agreed` | How many agents sat on the panel, the requested quorum, and how many agreed. |
| `issuedAt`, `expiresAt` | When the service signed it and when the signature stops being valid. |

The signature is checked under an EIP-712 domain named `IdentityMD Oracle`, version `2`, with the chain the feed is deployed on and the feed's own address as `verifyingContract`. So a signature made for one feed cannot be used on another. The exact signed type is:

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
```

The signature must be 65 bytes in standard form and recover to the feed's `attester`. It is one signature from the service, not a signature from each panel member.

Panel floors are written into the contract: `panelSize` must be at least 25 (`MIN_PANEL_SIZE`), and `agreed` at least 15 (`MIN_AGREED`) and no more than `panelSize`. `quorum` is signed but not checked, so no percentage of the panel is enforced, only these two counts.

## Question binding

`expectedQuestionHash(uint64 fromBlock, uint64 toBlock)` returns the hash of the feed's question for that window. The question text, its definitions, the answer type, the data chain and the evidence mode are all part of what is hashed. Request settings such as guards, the requested panel size and the consumer are not.

You can call it before you pay for a request: if the hash of the question you are about to buy does not match, the feed will refuse the answer.

`submitAttestation` runs these checks, and stores nothing unless all pass:

1. The caller is the feed's `relayer`, the data chain and answer type match, and the panel counts clear the floors.
2. `issuedAt` is not in the future, the attestation has not expired, it is no older than the feed's maximum age or the value already stored, and its `requestId` has not been used.
3. The signature recovers to `attester`.
4. The window runs forward, its length fits the feed's limits below, it ends after the last accepted window, and `questionHash` equals `expectedQuestionHash(fromBlock, toBlock)`.
5. The figure passes the feed's value check (next section). The feed then stores the figure, signing time, request and window end, and emits `ValueUpdated` and `AttestationAccepted`.

| Feed | Allowed window, `toBlock - fromBlock` | What the window means |
|---|---|---|
| `PriceFeed` | 300 to 1,200 blocks | The span the median is taken over. |
| `SpotFeed` | 150 to 1,200 blocks | Only its last block is priced. |
| `NhiFeed` | 150 to 1,200 blocks | Keeps answers in order; the question reads live service counters when answered. |
| `SwarmWorkOracle` | 5,000 to 9,000 blocks | Picks the daily work receipt as of the window's end. |

The feed does not check the window against the data chain's latest block or check `blockHash`. Windows that must move forward stop old answers being reused, but do not prove an answer is recent; `issuedAt` is the service's statement of when it signed.

The relay-side procedure, including the errors each check raises, is in [Relay oracle updates](../keepers/relay-oracle-updates.md). What has and has not been shown against the live service is tracked in [Swarm evidence](../economics/swarm-evidence.md).

## Freshness and the two price checks

A feed is stale before its first value, and once more time than its maximum age (—) has passed since the stored value was signed. `latestValue()` returns the stored value even when it is stale, so always read `isStale()` too.

**How far one update can move a feed.** While the stored value is fresh, a new figure may differ from it by at most `maxDeviationBps` (—). A figure of zero is always refused. Once the stored value has gone stale, the next valid attestation is accepted without that limit. This is deliberate: it lets a feed catch up after a large market move it could not follow step by step, at the cost of placing more trust in the signer and the question while it does. `SwarmWorkOracle` skips the limit, since roots have no distance, but still refuses zero.

**Primary against spot.** `skew` (—) is a separate check in the vault: the primary and spot IMD/ETH prices may differ by at most that fraction of the primary. Both are raw IMD/ETH, so ETH/USD plays no part. Both read the same pool, so agreement guards against a bad answer, not against the pool itself being moved.

## Relayer and dollar price

Each feed accepts attestations only from its relayer, `SwarmRelay`, which anyone may call. `relay`, `relayMany`, `relayAndBark` and `relayAndBite` change nothing about the feed's checks. Bundles succeed or fail as a whole, but they do not give whoever paid for the update priority over other keepers.

`UsdPriceFeed.latestValue()` multiplies the primary IMD/ETH price by Chainlink's ETH/USD answer, adjusting for its decimals, and returns USD per IMD (scaled by 1e18) with the older of the two timestamps. A missing, malformed, zero or negative ETH/USD answer gives no usable price. `isStale()` is true if the primary is stale or ETH/USD is stale or dated in the future, and `maxAge()` reports the shorter allowance.

`latestValue()` does not itself reject a well-formed but stale ETH/USD answer, so use it with `isStale()`. `ethUsdPrice()` does check ETH/USD's age. The vault checks staleness before it uses any dollar price.

## How updates are paid for

The protocol pays for its own price updates from its Treasury, and no key decides when.

**`OracleAsker`** buys an attestation for a feed through IdentityMD's on-chain request contract (the Intake), paying the Intake's listed price in IMD. Anyone may call `ask(feed, body)`, but it pays only when the chain shows the update is needed:

- **The network health feed is close to stale**: a fixed fraction (—) of the way to its maximum age, or with no value yet. Only feeds marked to be kept alive are refreshed this way. The price feeds are not, because keeping them fresh on a clock would cost far more than it protects.
- **IMD's pool has fallen below the feed** by more than a fixed fraction (—) of the feed's deviation bound. Only a fall is paid for: a feed above the market values collateral too high, which lets positions borrow too much and be liquidated late, so it is corrected early. A rise only values collateral too low, which limits borrowing and puts no one at risk, so the Treasury never pays for one; whoever wants the extra borrowing room buys the update with `askPaid` below. `triggerBps(feed)` returns both thresholds, with zero meaning never. The fall must first be recorded with `arm(feed)` and still be there a set number of blocks (—) later. A pool pushed off price and back within one transaction, as with a flash loan, cannot trigger a paid update.

`body` must be the exact request the feed's question was built from; the asker stores only its hash. Each body asks for a relative window ("the last N hours"), which the oracle service resolves afresh for every request; a fixed block range could be answered only once. Spending is limited five ways: one request in flight per feed until it is delivered or times out, a minimum time between paid requests for the same feed, a longer wait after an answer the feed refused, a maximum price per request, and the daily budget below.

The Intake delivers the answer by calling the asker back, and the asker hands it to `SwarmRelay`, so the feed checks it exactly as it would one relayed by hand. The callback never fails because a relay was refused: it frees the feed for the next request and reports whether the answer landed (`Delivered`). If it did not, the attestation is still public and anyone may relay it, and the Treasury does not pay for that feed again until the request timeout (—) has passed.

**`Treasury.fundOracle()`** is how the asker gets its IMD. Anyone may call it. It tops the asker up to one day's budget, `oracleBudget` (—) in [Parameters](../governance/parameters.md), and never past it: it sends at most what is left of the day's budget and at most what brings the asker's balance to one day's worth, because the asker has no way to give IMD back. It unstakes the Treasury's sIMD so the asker receives IMD. The budget changes only through a delayed governance proposal and has a hard upper limit. Days are UTC days.

**`askPaid(feed, body, maxPrice)`** is how anyone else gets a fresh price. The caller pays the Intake's price in their own IMD, up to `maxPrice`, and an update is bought for any feed at any time, because no protocol money is spent. While a price feed is stale, borrowing, withdrawing against debt, marking, liquidating and redeeming wait until someone buys an update this way or the pool moves enough for the Treasury to buy one.

Relayers are not reimbursed. None of this is required: when the budget is spent or the Intake is unavailable, anyone can still buy an attestation from the oracle service and relay it.
