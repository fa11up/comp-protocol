# COMP Protocol

A compute-backed CDP stablecoin on Sepolia whose risk parameters come from IdentityMD swarm oracle
attestations. IMD is the collateral, the vault mints COMP against it, and the swarm's answers decide
what a position is worth and how harshly it is liquidated.

Forked from `identity-md-launches/launch-519-mockimd-pricefeed-nhifeed-cdpvault`, so the history below
the fork point is the swarm's own build across launches 458 → 493 → 517 → 519 → 586. Everything above
it is ours.

**275 tests pass** on a plain `forge test`, plus 14 fork tests against live Sepolia state.

## Contracts

| | |
|---|---|
| `CDPVault` | positions, minting, the stability fee index, liquidation, bad debt |
| `ParameterizedVault` | `CDPVault` plus five overrides that read its economics from `Parameters` |
| `SwarmFeed` | attestation verification; `PriceFeed` / `NhiFeed` / `SpotFeed` are its three leaves |
| `SwarmRelay` | permissionless relay, and keeper bundling: relay-and-mark, relay-and-liquidate |
| `Parameters` / `Governed` | the five economic knobs behind a 48-hour delay |
| `Treasury` | where the protocol's own revenue lands |
| `Registry` | replaceable counterparties — **written, not yet wired to anything** |
| `CompToken` | the stablecoin; minted and burned only by its vault |
| `MockIMD` / `MockWorkOracle` / `LaunchToken` | testnet collateral faucet, work-credit faucet, launch token |

Three leaves exist rather than two `PriceFeed` instances because a launch manifest identifies a
deployment by contract name, has no alias field, and **names at most four contracts**. That cap is why
`CompToken`, `MockWorkOracle` and `Parameters` are created inside the vault's constructor rather than
deployed beside it.

## The three numbers

| input | what it decides |
|---|---|
| **price** | `collateralRatio = collateral * price * 100 / (debt * 1e18)`, from a window median |
| **NHI** | `minCR()` 150 at ≥0.85 rising to 200 at ≤0.60; `gracePeriod()` 6h falling to 0 |
| **spot** | not a price — a sanity bound. A gap over `MAX_DIVERGENCE_BPS` (500) halts minting, marking and liquidation while still allowing withdrawal |

Shipped economics: stability fee 200 bps, marker share 1000 bps of the liquidation bonus, protocol
share 3333 bps of it, divergence bound 500 bps.

## Question binding

A feed verifies **which question** an attestation answers, not merely that the service signed it.
This matters more than it sounds: `consumer.verifyingContract` is a field the *requester* chooses, so
without this check anyone can buy an attestation over a figure of their choosing, name someone else's
feed as the consumer, and present it as an answer to that feed's question. Every other guard —
signature, replay, freshness, panel floors — passes by construction. An independent audit found
exactly that, rated high, with a failing proof test.

`questionHash` is keccak of the control plane's canonical question document, which includes the
resolved block window, so there is no stable value to pin. But the canonicalisation is an RFC 8785
subset: keys are **sorted**, `window` sorts last, and the only part that varies between two otherwise
identical requests is a **suffix** whose two numbers the attestation carries as *signed* fields. So a
feed pins the document's prefix and splices them back in:

```solidity
bytes32 expected = keccak256(abi.encodePacked(
    QUESTION_PREFIX, _decimal(a.fromBlock), ',"toBlock":', _decimal(a.toBlock), "}}"
));
```

Two further bounds, because answering the right question is not yet answering it honestly: the window
span is bounded (a one-block window is a point read dressed as a window median; a month smooths away a
real move), and `toBlock` must **advance**, so a freshly signed attestation cannot answer over an
ancient window where the price was whatever the buyer needed. Replay protection misses that — the
`requestId` differs.

With the question bound, a feed needs no trusted relayer at all, so `SwarmRelay` being permissionless
costs nothing. A feed that pins *no* question cannot be deployed with a zero relayer; the constructor
refuses the pairing that has no defence.

The prefix is **generated, never hand-written**:

```bash
node oracle/question-prefix.mjs <payload.json>                      # emits the Solidity constant
node oracle/question-prefix.mjs <payload.json> --verify <requestId> # must print MATCH
```

`--verify` rebuilds the hash and compares it against a live attestation; the script refuses to emit a
prefix that fails. One consequence worth knowing: `definitions` is part of the hashed document, so a
figure that *moves* in there — a price band, a magnitude — changes the question and the feed stops
accepting. Moving numbers belong in `guards`, `panelSize`, `quorum` or `consumer`, none of which are
hashed.

## Governance

`Parameters` holds five numbers — debt ceiling, protocol bonus share, stability fee, divergence
bound, marker share — behind a 48-hour delay. One proposal at a time, readable by anyone for the whole
window, then applied by **anyone**: a governor who could also withhold application could hold a
validated change over the protocol and choose its moment. Cancelling is the only instant action,
because abandoning a change can only return things to what borrowers already priced.

The bounds are constants in the contract, not governance choices, so the governor cannot widen its own
authority. What is deliberately **not** governable: the attester, the three price feeds, and the
collateral token. A wrong parameter is a bad business decision a borrower can see coming and exit
ahead of; a wrong feed is not a cost, it is custody — whoever names the price feed can liquidate
everyone in one block. Those stay immutable, and so does a vault's reference to its own `Parameters`.

A rate change checkpoints the fee index first. Without that, the index recomputed from deployment at
the current rate, so raising the rate repriced history and *cutting* it made the index fall below a
borrower's stored index — reverting `stabilityFeeOf`, which is on every entry point. A rate cut would
have frozen every position.

## Live on Sepolia

| | |
|---|---|
| CDPVault | `0xD8CbC70B9C2dfC75762686dd4795e2aC033452c5` |
| PriceFeed | `0xC677A113e06d70a313FfB459B291ec4bEcF5AB18` |
| NhiFeed | `0x125100448612347ba2604E9dA26f40013C602b3A` |
| SpotFeed | `0x0535C1A564B2594676239428A113d542cd6c2Ed9` |
| SwarmRelay | `0xe36FFc2688Bf5974f2187AC9086492e372926D40` *(deployed, not wired to these feeds)* |
| CompToken | `0xd5B99590CC79592a6C2C46991a9F873dF72b4c0B` *(created in the vault's constructor)* |
| MockWorkOracle | `0x7df0f2Ea286738f905ab5b1B8899E9e207996198` *(same)* |
| MockIMD | `0xe44ab81ce23d34e29383dd158a1dffeb1c10d439` |

**These predate question binding and the governed parameters.** Their bytecode is 5,082 bytes against
the 8,243 the current source compiles to, and `expectedQuestionHash` reverts on them because the
function does not exist. They also pin the reporter key as their relayer rather than the `SwarmRelay`
above — that contract is deployed but no live feed accepts it, and it predates keeper bundling too.
This is the stack that proved the attested path; picking up anything above it is a redeploy.

The attested path is proven end to end: oracle request `50d9b023-30cf-402d-8568-867cbced57b7`, figure
`3172735462421828`, panel 60 with 20 agreed, relayed in
`0x15854076dbc9c33c73b36eaad1871350fd6e2d19a7510d863ecc4d41f47b6b9e` at block 11830282 for 79,328 gas.
Verified by reading chain state: the feed's value is the attested figure, replay protection engaged,
and divergence against the spot feed was 119 bps against a 500 bps bound.

## Oracle tooling

IMD's only liquid market is Uniswap v4 on mainnet, both pools paired with native ETH. The v3 WETH pool
is drained — `liquidity()` is 0 — so anything priced from it is a frozen leftover.

```bash
cd oracle && npm install
node preflight-oracle.mjs <payload.json> <feedAddress> --rpc <url>   # before paying
node relay-attestation.js <oracleRequestId>                          # after it attests
```

**Run the preflight before every paid request.** It reads the destination feed's own constraints from
chain and refuses a payload the feed could never accept — including, now, a question document the feed
does not pin and a moving number inside `definitions`. It exists because a request once attested
perfectly and still could not be relayed: `consumer` was missing, so the signature was under the
service's default domain, and the panel was under the feed's floor. Both were knowable in advance.

Other things learned the expensive way:

- **Walk the feed to the live market first, then pin guards, then pay** — in that order, in one
  sitting. A request bought with guards around a stale level was refused by the panel when IMD moved
  44% in a day. `--fix-guards` rewrites them to the feed's live band.
- `consumer.verifyingContract` must be **lowercase**, or `/requests/quote` returns a bare 400.
- `maxDeviationBps` and the update cadence are **one knob, not two**. A tight cap only works if
  updates are frequent enough that the market never moves further than the cap between them.

## Testing

```bash
forge test                                                              # 275, InHouse self-skips
forge test --match-path test/InHouse.t.sol --fork-url $SEPOLIA_RPC_URL   # 14, live state
AUDIT_PROOFS=true forge test --match-path 'test/audit/*'                 # auditor proofs
```

`test/InHouse.t.sol` covers what the inherited suite does not: the constructor arguments and the
deployment's own authorities. That is the layer that actually failed in production — an earlier launch
deployed with a manifest placeholder that resolved to the platform's address rather than ours, and an
answer-type constant that was simply wrong, both immutable. It skips itself off-fork because it reads
live state. Most public Sepolia RPCs are not archive nodes.

## Audit

`docs/AUDIT-2026-10-03.md`, with the raw record beside it. An independent review of the contracts
written outside the swarm returned **11 findings: 1 high, 2 medium, 4 low, 4 info**, each with a
Foundry proof test. All four supplied proofs were re-run and all four failed exactly as described.

Every finding is addressed. The high is the question binding above. Both mediums shared one root
cause — binding a `Parameters` to a vault was a separate transaction — and there is no fix that keeps
one, because a mid-construction callback cannot verify its caller: the vault has no code yet. So the
transaction is gone. The two proofs whose API no longer exists live in `audit/proofs/`, outside the
compiled tree, kept verbatim; the Treasury proof now **passes** and is a regression test.

## Known limits

- The live deployment's reporter and relayer are a single testnet key. **Mainnet must be a fresh
  deployment with a key held outside this repository.**
- `Registry` is written and governed but **nothing reads it**, so a rotation recorded there changes
  nothing. Wiring it means a feed resolving its relayer through a pinned registry instead of an
  immutable, which trades an immutable authority check for an external call on the attestation path.
- `mintFromWork` mints with no collateral, no debt entry and **no ceiling**. `totalWorkMinted` is
  unbounded, and that is the protocol's largest unbounded risk. `docs/COMPUTE-BACKING-DESIGN.md`
  specifies the fix and the bound it has to satisfy.
- Compute backing is not real yet. ERC-8004 records roughly 6% of swarm work and none of the
  oracle-assess work that is most of it, so a mint keyed to on-chain accepted work would issue almost
  nothing. The design document measures this before proposing anything.
- `protocolBonusShareBps` is bounded but the bound is economically empty at its top: at 10000 a
  liquidator who did not mark receives exactly the principal back, so liquidations stop.
- There is no insurance and no write-off path. A liquidation can leave bad debt; `liquidate` sweeps an
  unreachable remainder so the position closes rather than freezing, but the loss is realised.

## Documents

| | |
|---|---|
| `docs/COMPUTE-BACKING-DESIGN.md` | compute-backed minting and redemption, with the measurements behind it |
| `docs/AUDIT-2026-10-03.md` | the independent review and every finding |
| `docs/UPSTREAM-STABLE-QUESTION-ID.md` | why `questionHash` is unstable, and why that is not a PR yet |
| `docs/ABI.md` | the deployed interfaces |
