# On-chain intake: what it changes for us

Assessment of `Identity-md/protocol` **PR #66** (`feat/onchain-intake`), read 2026-10-04. Unmerged
at the time of writing; the dev pushed "The intake reads its own logs, and pins what it completes"
that day (the Ponder indexer is gone) and said he would merge shortly.

**Status: Sepolia only, priced in native ETH. "Mainnet in IMD follows, then L2s."** So nothing here
is on the mainnet critical path. This document exists so the integration is designed once, now,
while the compatibility work is cheap, and not rediscovered later.

---

## What it is

One transaction on a followed chain buys swarm work — no x402 signature and no conversation with
the plane at the moment of payment.

```solidity
request(bytes32 action, bytes body, (address target, bytes4 selector) callback,
        address asset, uint256 amount) returns (bytes32 requestId)
```

and, when the work ends, the plane's **writer** calls

```solidity
complete(bytes32 requestId, uint8 status, bytes32 resultHash, string uri, bytes args)
```

which, for `status == 0` and a named callback, does
`target.call{gas: callbackGas}(selector ++ args)`.

---

## Compatibility: three facts, all verified

### 1. The attestation struct is identical to ours

The plane's `OracleAttestation.Attestation` is **field-for-field identical** to our
`SwarmFeed.OracleAttestation` — 15 fields, diffed name by name and type by type — the EIP-712
typehash string is **byte-for-byte identical**, both are domain version `"2"`, and both split
`hashStruct` into the same two `abi.encode` halves for the same stack-depth reason.

Consequence: **a feed can be the callback target directly.** `selector ++ args` with
`args = abi.encode(attestation, signature)` *is* a valid `submitAttestation(OracleAttestation, bytes)`
call. No adapter contract, no struct translation, no second verification path.

### 2. The body is the payload we already have

`body` is "the same JSON the HTTP door takes for that action as UTF-8 bytes". So
`whitepaper/requests/price-univ4-v3-quote.json` and its two siblings **are** the body, unchanged —
and the pinned question prefix stays valid, because the question document derives from the same
body. No new payload work and no new prefix.

### 3. The gas fits

`callbackGas` is **200,000**. Measured across the suite, `submitAttestation` on the bound
production feeds is **61,361 min / 88,714 avg / 145,119 max**, so the worst case clears it with
about 27% to spare.

Caveat: `callbackGas` is owner-settable, so that headroom is not guaranteed. It is not a safety
problem — see "delivery is best-effort" below — but it is a liveness one.

---

## It does not tighten the trust story

Worth stating plainly, because the first reading suggests otherwise. Pinning
`ATTESTATION_RELAYER = Intake` would mean only the writer can call our feed. But **any payer may
name our feed as their callback target**, so the filter stays exactly what it is today:

> the attester signed it, **and** it answers our pinned question, **and** the window advances.

Question binding is doing all the work on both paths. That matches the dev's own framing of the
change ("kind of will have same risk/centralization as the oracle/general protocol"). The gain is
operational, not a reduction in trust assumptions.

It does, however, close the loose end in `docs/INTERNAL-AUDIT-2026-10-04.md` §3.1 *by
construction* on this path: there is no unbound-question configuration to get wrong, because the
only thing that calls the feed is a completion for a request whose body produced our question.

---

## Does it make running the protocol cheaper? No. It makes it automatable.

Measured, for the 1,977-byte price body:

| | request | delivery | ours, per update |
|---|---|---|---|
| **Today** (x402 + SwarmRelay) | 0 gas — an EIP-712 signature the plane settles | 61,361–145,119 gas, our relayer key | **61k–145k** |
| **Intake**, body in storage (the example's shape) | ~167,000 gas | 0 — the writer's `complete` pays the callback | **~167k+** |
| **Intake**, body hash-pinned, passed as calldata | ~71,000 gas | 0 | **~71k+** |

The request fee itself is unchanged: 0.5 IMD today, and mainnet intake is "in IMD".

So on gas it is **a wash at best**, and the naive shape is worse. The honest reason to want it is
different: **today's request requires the browser.** `submit.js` opens a MetaMask flow on `:3333`,
which is exactly why the price-movement watcher in
`docs/COMPUTE-BACKING-DESIGN.md` has never been built end to end — automating it would have meant
signing Permit2 programmatically from a daemon holding IMD spending power. `ask()` is a plain
contract call. That is the unlock, and it is the thing the watcher needs.

### Design note: hash-pin the body, do not store it

The 96,000 gas difference in the table is the whole design. The example consumer keeps
`bytes public body` in storage and passes it to `request`; reading ~2 KB back costs 62 cold SLOADs.

Instead, store `keccak256(body)` and take the body as calldata:

```solidity
function ask(bytes calldata body) external returns (bytes32) {
    if (keccak256(body) != bodyHash) revert WrongBody();
    return intake.request{value: price}(action, body, Callback(address(feed), SUBMIT_SELECTOR), address(0), price);
}
```

This keeps the body **pinned** — which matters, because a caller who supplied a different body
would buy an answer to a different question, our feed would refuse the callback, and the fee would
be spent for nothing — while paying calldata rates rather than storage rates. A wrong body reverts
immediately and costs the caller nothing but gas.

---

## The trade-off, which is a decision rather than a detail

**The Intake path is mutually exclusive with `relayAndLiquidate` bundling.**

On the Intake path the **writer** chooses when the update lands. We cannot bundle a liquidation
atomically with an update we do not schedule, so every liquidation that update enables is a public
race from the moment `complete` is mined. Today we at least know our own `requestId` when we pay,
which is the advantage `docs/COMPUTE-BACKING-DESIGN.md` §5b leans on.

The shape that follows:

- **Routine feed updates → Intake.** No key, no daemon, automatable.
- **Updates we intend to trade on → x402 + SwarmRelay**, bundled.

Supporting both means the feed accepts two relayers and the relayer is permissive again, which is
the thing to decide deliberately rather than drift into.

## Delivery is best-effort, and a request cannot be retried

`complete` records the outcome rather than requiring it: a callback that reverts — stale feed,
divergence, wrong question, insufficient stipend — still sets `completed = true` and emits
`delivered: false`. The fee is spent and **the same request cannot be completed again.**

Two consequences for any integration:

1. `submitAttestation` must stay callable as a recovery path. The answer is still on IPFS at the
   completion's `uri`, so a failed delivery can be relayed by hand.
2. Nothing may assume the callback ran. Read the feed, not the `Completed` event.

---

## What to build, when it merges

Parked on branch `feat/onchain-intake` of this repository rather than built on `main`, because the
contract is not on mainnet and its address and price list are not final.

1. **`src/IntakeAsker.sol`** — holds the fee balance, pins `keccak256(body)` and the action id,
   exposes a permissionless `ask(bytes calldata body)` as above. The feed stays fund-free, which is
   why this is a separate contract rather than a method on the feed.
2. **`ATTESTATION_RELAYER` becomes the Intake address** for feeds deployed to use this path — a
   source constant, as now, so a manifest cannot substitute it.
3. **Keeper**: replace the watcher's "fire an oracle request" step with a call to `ask()`. This is
   the piece that currently does not exist because it needed a browser.
4. **Decide the bundling question above** before pinning any feed's relayer.

## To feed back upstream

`src/examples/OracleIntakeConsumer.sol` makes `setSigner`, `setBody` and `setAction` owner-settable
and documents that as "the upgrade path". For a price consumer, an owner-settable **signer** is
control of the price — the same objection this repository raised against a governable feed address
(`docs/INTERNAL-AUDIT-2026-10-04.md` §3.8, and the parameters/authority split in
`src/Parameters.sol`). Worth telling him that question binding makes an owner-settable **body**
safe, because a body yielding a different `questionHash` is refused on arrival, while the signer
is not. We have push access and a merged PR already, so this is cheap to offer.
