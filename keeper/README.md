# Keeper

The off-chain half of the protocol. Three loops that share one key, one machine and one reason to
exist: **a CDP protocol with no keeper is not a protocol, it is a contract that accumulates bad debt.**

| loop | what it does | state |
|---|---|---|
| **watcher** | reads the live v4 pool, decides when a feed needs a new attestation | **built** — `watch.mjs`, read-only |
| **relayer** | finds our attested oracle requests and relays them through `SwarmRelay` | one-shot exists at `../oracle/relay-attestation.js`; the loop around it is not built |
| **liquidator** | marks underwater positions and liquidates after grace | **built** — `positions.mjs`, reports by default |

## Why it watches movement rather than a clock

A `SwarmFeed` accepts at most `maxDeviationBps` of change per update while its current value is
fresh. So the cap and the update cadence are **one knob, not two**: a cap is only safe if the market
cannot move further than the cap between updates.

Updating on a schedule is wrong in both directions — it pays for requests in a flat market and still
misses a fast one. IMD moved **44.6% in a day** while we watched, and a request bought with guards
pinned to the old level was refused by the panel, costing 0.5 IMD for nothing.

So the watcher fires when spot leaves a band **narrower than the cap** (`TRIGGER_FRACTION_OF_CAP`,
default half), leaving room for the market to keep moving while a request is in flight. Cost then
scales with volatility instead of with time, which is also the right shape economically: a quiet
market costs nothing and a violent one pays for the updates it needs.

It also fires on approaching staleness, because a stale feed halts the vault **and** the first value
accepted afterwards re-anchors the band with no deviation bound at all.

## It does not spend

Buying an oracle request costs 0.5 IMD, is irreversible, and a submitted request cannot be cancelled
by us — `POST /workflows/:id/cancel` is operator-gated and returns 401. The watcher therefore prints
the exact preflight and submit commands and stops. Automating the spend is a deliberate later
decision with its own guard rails (a budget, a rate limit, a kill switch), not an oversight.

```bash
cd keeper && npm install && cp config.example.js config.js   # then edit addresses and bands
node watch.mjs
```

The pool read is a **port of the plane's own `univ4-spot` recipe**, not an approximation: a feed only
accepts an attestation answering the question it pins, and that question names that recipe. A watcher
computing the price differently would trigger on numbers nobody will attest to. `lib/pool.mjs` carries
the slot derivation (`_pools` at slot 6, `sqrtPriceX96` in the low 160 bits of the first State word)
and the exact integer arithmetic.

It refuses to report a spot at or above 1e18 and exits non-zero, because that means the direction is
inverted — the inverted reading is ~1e20 and looks like a market move rather than a misreading.

## Being the marker is the edge

`liquidate` pays the caller `seized - protocolCut` when the caller is **also the marker**, and
`seized - protocolCut - markerCut` otherwise. So marking a position ourselves and liquidating it
ourselves earns the marker share on top, and letting someone else mark it hands them that share even
if we do the liquidating. `markUnderwaterFor(owner, beneficiary)` exists for exactly this.

At the live price, on 1 COMP of debt, that share is **4.50 IMD of a 45.05 IMD bonus** — a tenth of
the only profit in the transaction. `positions.mjs` prints it as `marking it ourselves would add N`
whenever we are not already the marker.

The arithmetic in `lib/vault.mjs` is a transcription of `liquidate`, not an estimate, floors included.
It reproduces the live Sepolia stress-test figures to the wei — seized `495543597367679961133`,
bonus `45049417942516360103`, marker cut `4504941794251636010` — which is how we know a quote the
keeper computes is a quote the chain will honour. It also models the **dust sweep**, which is not a
pure function of the inputs and would otherwise make every payout estimate slightly wrong.

```bash
node positions.mjs              # report: who is underwater, what a liquidation pays, where the window is
node positions.mjs --execute    # mark and liquidate; needs KEEPER_MNEMONIC
```

Every transaction is simulated with `callStatic` before it is sent, so a doomed one costs nothing and
a revert is information rather than a loss.

**A stale feed blocks everything.** `liquidate` calls `_requireFreshFeeds` and
`_requirePriceAgreement` before anything else, so no position can be marked or liquidated however
underwater it is. `positions.mjs` says so as its first line rather than reporting an empty list — a
keeper that is blind must not look idle.

## Positions have no on-chain index, and the RPC is not a sound substitute

They live in a `mapping(address => Position)`, so events are the only index. Discovery therefore goes
through an **indexer, not `eth_getLogs`**, and the reason is measured rather than theoretical.
Against this vault on 2026-10-04, through a public RPC:

* a 50,000-block span returned the one real depositor;
* a **40,669-block span inside that same range returned nothing**, neither call erroring;
* ranges above 50,000 are refused outright (`-32701`);
* and `eth_getCode` at a historical block fails, because the node keeps no archive state.

For a liquidator, an empty array that means "the node declined to look" is indistinguishable from
"there are no positions" — and the second one makes it sit still while a position rots.
`discoverOwners` reads Blockscout, paginated, matching on **topic0 and topic1** rather than on decoded
parameter names, and **throws** if the source returns no logs at all, because a deployed vault has at
minimum emitted `OracleSet` in its constructor.

## Funding: three balances, not interchangeable

| balance | for | note |
|---|---|---|
| **ETH** | gas | relays and liquidations |
| **imdUSD** | liquidation inventory | `liquidate` burns the **caller's** stablecoin. A keeper with none cannot liquidate anything. **Working capital, not an expense.** |
| **IMD** | oracle requests | 0.5 IMD each |

`Treasury.withdraw` is `APPROVED_OPERATOR`-only, so the keeper **cannot fund itself** without the
cold governance key. Do not put that key here. The operator tops this wallet up; at ~$4.25 an update
the sums are small. A budgeted `spender` role on the Treasury would automate it and is deliberately
not built — it is new authority and wants its own audit.

## Security

* **Never run this on the swarm worker box.** Tasks from strangers execute as that user. This machine
  holds a hot key and stablecoin inventory.
* `config.js` is gitignored and holds **no keys** — addresses and bands only, so a leaked config
  reveals configuration, not custody. The signing key comes from the environment at run time.
* The watcher is read-only and needs no key at all.

## What the keeper cannot win

Paid attestations are discoverable: `GET /oracle/requests` lists the last hundred requests
unauthenticated, and `/oracle/requests/<id>/attestation` serves the signed attestation the same way.
`SwarmRelay` is permissionless. So a searcher can relay-and-liquidate ahead of whoever paid for the
update — `relayAndLiquidate` buys **atomicity, not priority**.

Running in-house wins in practice because we know a requestId when we pay for it while a searcher
must poll to find it. What is not at risk is the larger half: `protocolCut → feeRecipient()` and
`markerCut → marker` are both independent of `msg.sender`, so the protocol is paid whoever
liquidates. The contestable amount is the liquidator's margin plus the request fee — revenue, not
solvency. See `docs/COMPUTE-BACKING-DESIGN.md` §5b.
