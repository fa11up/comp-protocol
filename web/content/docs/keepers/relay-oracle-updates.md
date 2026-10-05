---
title: Relay oracle updates
section: keepers
order: 3
audience: keepers
sources:
  - src/SwarmRelay.sol:10-134
  - src/SwarmFeed.sol:26-62
  - src/SwarmFeed.sol:152-244
  - src/SwarmFeed.sol:283-303
  - src/UsdPriceFeed.sol:23-95
  - oracle/relay-attestation.js:1-60
  - docs/MAINNET-RUNBOOK.md:72-86
---

# Relay oracle updates

The vault's prices are not pushed by any key. A feed changes only when someone submits a valid signed attestation. You can do that permissionlessly through `SwarmRelay`. This page covers what you relay, how, and why the relay can also carry the action that needs the price.

## What the feeds are

| Feed | Contract | Holds |
|---|---|---|
| Primary | `PriceFeed` | IMD/ETH over a block window |
| Spot | `SpotFeed` | IMD/ETH at the last block of a window |
| Network health | `NhiFeed` | The network health index |

A fourth reading, IMD/USD, is computed by `UsdPriceFeed` from the primary feed and Chainlink ETH/USD. It takes no attestations. The Chainlink leg is maintained by Chainlink; the others only by relayed attestations. Addresses: (waiting for mainnet launch).

## Why a relay contract

Each feed pins one relayer in its bytecode, and that relayer is `SwarmRelay`. Calling `submitAttestation` on a feed from any other address reverts with `UnauthorizedRelayer`. `SwarmRelay` is open to everyone, has no owner, holds nothing on purpose and approves nothing. It cannot change an attestation. Every feed guard still runs on the forwarded call, so the worst a caller can do is relay an attestation the feed would have accepted anyway, or waste gas.

The relay is a contract and not a key for two reasons. Several feeds can update in one transaction, so the price and the network health index are never read a block apart, which matters because the vault compares feeds with each other. And an update can be bundled with the action it enables, which removes the race where someone else acts between your update and your call.

## What an attestation contains

`SwarmFeed.OracleAttestation` has these fields: `requestId`, `chainId`, `questionHash`, `answerType`, `answer`, `figure`, `fromBlock`, `toBlock`, `blockHash`, `panelJobId`, `panelSize`, `quorum`, `agreed`, `issuedAt`, `expiresAt`. You also pass a 65-byte signature. The `figure` is the value the feed will store, scaled by 1e18.

Attestations come from the IdentityMD oracle service, signed by its attester under an EIP-712 domain bound to the chain and the specific feed. A request must name the target feed as its consumer, or the signature will not verify.

TODO(oracle-funding): Describe how attestations are paid for on chain. Oracle updates purchased through an Intake contract and funded from treasury assets are being built and are not in this source. This page should say what the keeper submits, who pays, from which assets, and what the relayer is repaid.

## What a feed checks

On `submitAttestation`, in this order, a feed reverts with:

| Error | Meaning |
|---|---|
| `UnauthorizedRelayer` | The caller is not the pinned relayer |
| `InvalidAttestationChain` | `chainId` is not the chain the question reads |
| `PanelTooSmall` | `panelSize` is below the feed's floor (`MIN_PANEL_SIZE`) |
| `NotEnoughAgreement` | `agreed` is below `MIN_AGREED` or above `panelSize` |
| `InvalidAnswerType` | Wrong answer type |
| `ExpiredAttestation` | Past `expiresAt` |
| `InvalidTimestamp` | `issuedAt` is in the future or after `expiresAt` |
| `StaleAttestation` | `issuedAt` is older than the feed's maximum age, or older than the value the feed already holds |
| `ReplayedAttestation` | This `requestId` was used |
| `InvalidSignature` | The signature does not recover to the pinned attester |
| `InvalidWindow`, `WindowSpanOutOfRange`, `WindowNotAdvancing` | The block window is inverted, outside the allowed span, or does not close after the last accepted window |
| `WrongQuestion(expected, given)` | `questionHash` is not the hash of this feed's question for that window |
| `ZeroValue` | The figure is zero |
| `ExcessDeviation` | The figure moved too far from the current fresh value |

The floor values, the span bounds and the deviation bound are (under consideration).

A freshly deployed feed has no value and reads stale. Freshness is measured from the signed `issuedAt`, so delaying delivery does not extend it. A feed whose value has passed its maximum age accepts the next valid figure without the deviation check, so it can follow a large move.

Before you spend on a request, you can check from the chain what a feed expects: `expectedQuestionHash(fromBlock, toBlock)` returns the hash it will accept for a window. See [Oracle and question binding](../reference/oracle-and-question-binding.md).

## Relay: the four entry points

All four are on `SwarmRelay`. They are `external` and open to anyone.

1. **`relay(feed, attestation, signature)`** forwards one attestation to one feed.
2. **`relayMany(feeds, attestations, signatures)`** forwards several, each to its own feed, in one transaction. The array lengths must match (`LengthMismatch`). It is all or nothing: if any feed refuses, the whole call reverts, so you never half-update a set of feeds that the vault compares.
3. **`relayAndBark(feeds, attestations, signatures, vault, borrower)`** relays, then marks the borrower with you as the marker. It calls `vault.barkFor(borrower, msg.sender)`. A plain `bark` through the relay would record the relay as marker and strand the marker's share, so the relay uses `barkFor`. It moves no tokens.
4. **`relayAndBite(feeds, attestations, signatures, vault, borrower, debtToRepay)`** relays, then liquidates in the same transaction.

### Why bundle

Between your update and your call, another keeper can see the new price and act first, and a liquidation that depends on the fresh price fails if the feed is still stale. Bundling means the price update and the action succeed or fail together, and nobody can act on the fresh price in between.

### How `relayAndBite` handles tokens

The vault burns the caller's imdUSD and pays the caller the seized IMD, and here the caller is the relay. So:

1. You approve `SwarmRelay` for at least `debtToRepay` of imdUSD.
2. The relay pulls exactly `debtToRepay`, never more. Over-approving leaves the surplus with you.
3. It calls `vault.bite(borrower, debtToRepay)`.
4. It sends you whatever IMD the vault actually paid, measured as a balance change.
5. It checks that it holds no more imdUSD or IMD than before, and reverts with `StablecoinRetained` or `CollateralRetained` otherwise.
6. It emits `RelayedLiquidation(keeper, vault, borrower, debtRepaid, seized)`.

Because it uses balance changes, a donation to the relay cannot be taken by a liquidator and cannot make the checks fail for everyone.

## Failure modes

- A reverting feed reverts the whole relay call, including the action. That is intended. Find the failing guard in the table above.
- If another keeper relays the same attestation first, yours reverts with `ReplayedAttestation` or `StaleAttestation`. Read the feed state and move on.
- A feed that is still fresh does not need relaying. It counts as fresh until its maximum age passes; that age is (under consideration).
- The ETH/USD leg can go stale on its own. Then the dollar price is unusable and price-dependent actions revert with `StaleFeed`, and no attestation you relay fixes it.
