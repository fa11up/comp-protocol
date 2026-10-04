# Keeper

The off-chain half of the protocol. Three loops that share one key, one machine and one reason to
exist: **a CDP protocol with no keeper is not a protocol, it is a contract that accumulates bad debt.**

| loop | what it does | state |
|---|---|---|
| **watcher** | reads the live v4 pool, decides when a feed needs a new attestation | **built** — `watch.mjs`, read-only |
| **relayer** | finds our attested oracle requests and relays them through `SwarmRelay` | one-shot exists at `../oracle/relay-attestation.js`; the loop around it is not built |
| **liquidator** | marks underwater positions and liquidates after grace | **not built** |

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
