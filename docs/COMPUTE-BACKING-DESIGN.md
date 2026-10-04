# Compute backing and redemption — initial design

Status: design agreed 2026-10-03, nothing built. This is the reference a build request points at.

## 0. What we measured first

The protocol's thesis is that COMP is backed by verified compute. Before designing the mechanism we
measured whether the input exists. It mostly does not, and that shaped every decision below.

| measurement | value | source |
|---|---|---|
| ERC-8004 `NewFeedback` events | 2,000 over blocks 26052429–26082616 | Blockscout, mainnet registry `0x8004baa1…` |
| that window | 2026-09-25 05:38 → 2026-09-29 10:46 (4.21 days) | block timestamps |
| rate | ~475/day | derived |
| distinct agents with any feedback | 218 | derived |
| network accepted work | 7,708/day | `GET /swarm` → `health.acceptedLastDay` |
| **share of accepted work recorded on chain** | **~6%** | 475 / 7,708 |
| most recent feedback | 2026-09-29 | none since, 4 days silent |
| **our seat (agent 51450, 1,211 accepted)** | **0 events, ever** | derived |

Two consequences:

1. **Verification is the easy part; the signal is the hard part.** `getSummary(agentId)` and
   `isController(agentId, claimant)` are same-chain view calls on mainnet — a real work oracle needs
   no oracle at all. But what they measure excludes oracle-assess, which is ~92% of network volume
   and effectively all of ours, because `docs/work-registry.md` says those reviews were 99% of the
   mainnet writer's gas and were dropped. Keyed to ERC-8004 alone, this channel mints us zero
   forever and minted the whole network zero for four days.
2. **The whitepaper's §5.3 fee flow does not exist yet.** Layer 1 says the minting rate is
   "calibrated to task fee revenue", and §5.3 routes 15% of an external task payment to a protocol
   reserve. That reserve is the backing. Swarm oracle traffic is the developer's unpaid calibration
   traffic, so measured revenue is ~0. Issuing mint rights per accepted task today would back COMP
   with nothing.

Also recorded because it invalidated an earlier reading: **publicnode silently returns an empty
array for historical `eth_getLogs` ranges** instead of erroring. A control query over the same range
returned 89,036 USDC transfers where the registry returned zero. Use Blockscout for any historical
log work, and never trust an empty log result without a control over the identical range.

Incidentally this independently validated the set-agreement probe we paid for: 218 distinct agents
measured here against the panel's 210, and the panel's reported event signature matches Blockscout's
decoding exactly. That probe was right.

## 1. Decisions taken

| # | decision | choice |
|---|---|---|
| 1 | what work entitles you to | **revenue-capped mint** — work sets your *share*, backing sets the *size* |
| 2 | what counts as work | **attested tally now, upstream leaf in parallel** |
| 3 | bound on `totalWorkMinted` | **aggregate: reserve value + a ratio of collateral-backed debt** |
| 4 | redemption | **in scope now, multi-asset, at a dollar of value minus a fee** |

## 2. The reserve is the Treasury

`src/Treasury.sol` already exists, already records what arrives (`sync` → `totalReceived`), and
already has a withdrawal pinned to `APPROVED_OPERATOR` with the destination as an argument. It
becomes the reserve. What it receives today: the protocol's share of liquidation bonuses, in IMD
collateral, and stability fees, in COMP.

**The Treasury's COMP balance is not reserve.** Redeeming COMP for COMP is a no-op, so only
non-COMP assets back anything. Today that means IMD only, and only as liquidations happen.

Reserve value must be computed, not assumed:

```
reserveValueUsd = Σ_assets  haircutBps[a]/10000 × balance[a] × priceUsd[a]
```

Each asset needs a USD price source and a haircut. IMD's price is the existing `PriceFeed`
(IMD/ETH) multiplied by Chainlink ETH/USD — on Sepolia `0x694AA1769357215DE4FAC081bf1f309aDC325306`,
verified live at $2,675.82, 8 decimals. Here `haircutBps` is the retained-value factor: zero counts
for nothing and 10000 counts in full. A stablecoin's factor would be near 10000, while a lower
factor for IMD limits the supply its volatile reserve value can authorize.

**This makes reserve value oracle-dependent and reflexive.** If IMD falls, reserve value falls, and
COMP already minted against it becomes under-backed. The reserve factor reduces the credited
backing and is bounded in code to 0–10000; its governed value determines the discount.

## 3. The work ceiling

```
workCeiling() = reserveValueUsd + totalDebt × workRatioBps / 10000

mintFromWork: require(totalWorkMinted + amount <= workCeiling())
```

An aggregate rather than a minimum, because the two terms are backed by genuinely different things:
the reserve term is backed 1:1 by assets the protocol owns, and the ratio term is backed by the
surplus collateral every borrower posts above their debt.

Let `D` = CDP principal, `W` = work-minted, `R` = reserve value, `r` = workRatioBps/10000, and take
the worst case where every position sits exactly at `minCR`:

```
supply = D + W,  W = R + rD,  collateral C = minCR × D

B = (C + R)/(D + W) = (minCR·D + R)/(D + R + rD)

numerator − denominator = (minCR − 1 − r)·D
```

So **B > 1 for all R if and only if r < minCR − 1.** `minCR` is 150 at NHI 0.9 and rises to 200 as
NHI falls, so the binding case is `r < 0.50`.

| r | R = 0 | R = 0.5D | R = 2D | R → ∞ |
|---|---|---|---|---|
| 0.25 | 1.200 | 1.143 | 1.077 | → 1 from above |
| 0.50 | 1.000 | 1.000 | 1.000 | 1.000 |

Pin `workRatioBps = 2500` and hard-bound it at 2500 in the parameters contract: half the breaking
point at the loosest NHI, 120% worst-case backing with an empty reserve. 5000 is the cliff, so it
must not be reachable by governance.

`workCeiling` and `workRatioBps` are new governed parameters, under the existing 48-hour delay.

### 3a. What the independent review of the build changed (2026-10-03)

Three corrections to the formula as built, none to the bound it derives:

- **One unit.** `D` is denominated in the primary feed's unit — the pinned question asks for wei of
  ETH per IMD, so a COMP of debt is an ETH-worth of collateral to `minCR` and `liquidate` — while
  `reserveValueUsd` is USD. Added unconverted, the reserve authorised ETH/USD times more work
  minting than the vault valued it at. The vault now converts the reserve at the Chainlink ETH/USD
  leg (`reserveValue()`), zero while that leg is stale. For IMD priced through `UsdPriceFeed` the leg
  cancels and `R` is `balance × primary × haircut`. Changing what denominates `D` stays out of scope.
- **`D` counts only debt that existed before the transaction began.** The derivation assumes the
  surplus collateral behind `D` is there when `W` is minted against it. A rights holder could raise
  `D` with their own position, mint `rD` of work, repay and withdraw in one call, leaving `W` with
  nothing behind it. `backedDebt()` caps `D` at its value at the start of the transaction (transient
  storage), so the ratio term is only ever backed by positions that pre-date the caller. A position
  held across transactions counts in full: the ceiling remains point-in-time for the slow version of
  the same round trip, by design, and its cost is capital at risk in an open position rather than gas.
- **`D` excludes recorded bad debt.** After a liquidation drains a position its residual principal
  stays in `totalDebt` with no collateral behind it. `backedDebt()` subtracts `totalBadDebt`,
  saturating at zero; the record is accrued debt while `totalDebt` is principal, so the subtraction
  over-counts by unpaid fees, in the tightening direction.

Because a finite ceiling is now priced off the primary feed, `mintFromWork` on the governed vault
applies the same primary/spot agreement check as every other price-dependent action.

## 4. The work signal

Two tracks, because one works today and the other fixes the cause.

**Now — attested tally** (and see §4a for exactly what it proves). An `oracle.request` whose answer is a per-agent accepted-work tally,
relayed into a `SwarmWorkOracle` through the existing `SwarmRelay` and verified by the same
attestation v2 path already proven end to end (request `50d9b023`, relayed in tx `0x15854076…`).
The set-agreement probe established the precondition: 20 of 20 panel members independently derived
the same 14,167-log set and the same 210-agent cardinality, so panels do agree on set-derived
integers with zero tolerance. Cost is 0.5 IMD per update.

**In parallel — the upstream leaf.** `whitepaper/oracle-sim/PROPOSAL-ORACLE-WORK-LEAF.md`: carry a
second Merkle root in the daily oracle batch receipt the plane already writes, over
`["uint256","uint32"] = (agentId, acceptedThatDay)`, schema `identitymd-oracle-batch-v2`. Zero
additional per-review gas — the receipt is already written, this adds one 32-byte root — which
directly answers the stated reason oracle reviews were excluded. If it lands, the work signal
becomes free, trustless and network-wide, and the attested tally becomes a fallback.

`workShare(agent)` then derives rights: an agent's share of the tally times the ceiling headroom.
`isController(agentId, claimant)` is what binds a tally entry to a wallet that may mint.

## 4a. What the work signal proves, and what it does not

Worth separating, because the two halves have different answers.

**Who may claim — provable, and proven.** `isController(agentId, claimant)` on the Adapter8004 proxy
at `0xde152afb7db5373f34876e1499fbd893a82dd336` returns `true` for agent 51450 and
`0x5167D014a056E43883e1BBEa5530c3c0dC993281`, and `false` for anyone else. That adapter is what
`IdentityRegistry.ownerOf(51450)` resolves to, and it answers control by ownership of the identity
NFT — `ownerOf(1616)` on the collection `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` is the same
wallet. So the agent-to-wallet binding is real, on chain, and checkable by anyone.

The oracle therefore must NOT pin its claimant as a bare source constant, which would assert the
binding rather than prove it. The claimant goes in the question text, with the panel instructed to
verify `isController` on mainnet and to refuse if it is false. The question document is hashed into
`questionHash` and the contract verifies that hash, so the binding is attested. If the NFT moves, the
next attestation refuses.

**Agent wallets are already supported on chain, and that splits one role into two.** The mainnet
rails exist today, unset for us: `Adapter8004.setAgentWallet(agentId, newWallet, deadline, signature)`
requires the NFT controller to call it AND the new wallet to sign an EIP-712 proof of key possession
(EOA, EIP-7702 or ERC-1271), after which `getAgentWallet(agentId)` returns it. `getAgentWallet(51450)`
is `address(0)` now, so nothing is assigned.

`isController` is NOT that wallet. It resolves to live ownership of the bound token
(`_hasBindingControl`: `ownerOf(tokenId) == account` for ERC-721), so controller and agent wallet are
deliberately different addresses.

The consequence for this design is that **submitting a proof and receiving the credit must be separate
roles**, and designing them as one would have to be undone the moment an agent gets a wallet:

- **submission is permissionless.** A Merkle proof steals nothing; anyone may push an agent's tally on
  chain, including the agent's own hot wallet paying its own gas. That is what lets an agent keep its
  record current with no human in the loop.
- **credit resolves to the controller**, never to `msg.sender`. Otherwise a worker holding a hot key
  could mint to itself, and this repository's own rule is that no wallet key belongs on a box where
  strangers' tasks execute. With the split, that key's compromise costs gas and nothing else.

This is also why the upstream tally must key on `agentId` and never on an address: the controller can
change when the NFT moves and the agent wallet can be reassigned, and neither should orphan work
already recorded.

On mainnet none of the claimant plumbing needs an oracle — `isController` and `getAgentWallet` are
same-chain view calls. Pinning the claimant inside the attested question is a Sepolia-only stopgap.

**Who did the work — NOT provable, and this is the honest limit of the design.** The figure is the
control plane's own counter at `api.imd.fun/swarm`. A panel attests that it read that number from
that URL. It does not attest that the agent performed the work, because nothing on chain records it:
ERC-8004 carries ~6% of swarm work and none of this agent's. The trust root is the plane's database,
not the chain.

So `SwarmWorkOracle` is a **bridge**, not a proof, and its docstring has to say so. What would make it
proof is upstream and already drafted: `whitepaper/oracle-sim/PROPOSAL-ORACLE-WORK-LEAF.md` asks the
plane to carry a second Merkle root in the daily oracle batch receipt it already writes, over
`(agentId, acceptedThatDay)`. Once that root is on chain, the plane has committed to the work
non-repudiably and a proof can be checked against a commitment rather than an API read.

Note what even that does and does not buy. The plane is the party that accepted the tasks, so trust
ultimately rests on the acceptance process either way. The difference is whether that trust is
committed on chain — verifiable, historical, non-repudiable — or read from a mutable endpoint. That
difference is the whole value of the upstream change, and it is why the proposal is load-bearing for
this design rather than a nice-to-have.

## 5. Redemption

The question that has to be answered honestly: without redemption, "1 COMP = 1 USD" is only a unit
of account plus a hope that arbitrage closes the gap. There is no floor. Redemption is what makes the
peg real.

A redeemer names an amount of COMP and the asset they want. **The asset chosen determines the
source**, because the two pools hold different things:

| asset wanted | source | capacity |
|---|---|---|
| USDC / USDG / ETH | reserve only | whatever the Treasury holds of it |
| IMD | reserve first, then eligible CDPs | Treasury IMD, then the debt of eligible positions |

**Why reserve-first for IMD, rather than CDPs-first.** Both routes improve the backing ratio by the
same arithmetic — burn `x` COMP, release `x` of assets, and since `B > 1` both numerator and
denominator falling by `x` raises `B` — so solvency does not choose between them. What chooses is
that the Treasury's IMD is idle while a borrower's IMD is working as collateral. Spending an idle
asset before conscripting someone else's working one is both fairer and simpler: no position to
locate, no ratio to check, nobody closed involuntarily. The reserve is a shallow first tranche that
absorbs ordinary arbitrage without a borrower ever noticing, and only sustained pressure reaches
positions at all. Combined with a rising fee (below), a run pays progressively more *before* it
reaches anyone's collateral.

**Channel A — eligible CDPs.** When reserve IMD is exhausted, `redeem` burns COMP, repays the debt of
the **lowest-ratio position** and pays the redeemer that position's IMD at the feed price, minus the
fee. Only positions **below `redemptionCeilingCR`** are eligible, so a borrower can price themselves
out of redemption entirely by posting more collateral. The floor still holds, because some positions
always sit near `minCR`. Capacity is the debt of eligible positions rather than the whole pool, which
is the cost of giving borrowers an opt-out.

**Channel B — reserve assets.** Free choice against a heterogeneous reserve is adverse selection: the
redeemer takes the best asset and leaves the protocol the worst. So choice is allowed and the choice
is priced — the per-asset fee rises as that asset falls below its target basket weight.

**The fee.** A decaying base rate, Liquity-shaped, plus the per-asset weight penalty:

```
on redemption:  baseRate += redeemed / totalSupply / BETA
over time:      baseRate decays, halving roughly every 12h

feeBps(asset) = min(baseRate + REDEMPTION_FEE_FLOOR + deviationPenalty(asset), REDEMPTION_FEE_MAX)
```

Ordinary arbitrage pays near the floor; a run makes itself progressively more expensive. The cap
matters as much as the floor — an uncapped fee is a redemption halt by another name, and the floor
is what the peg actually is, since COMP cannot trade far below `1 − feeBps` without being redeemed.

**Redemption must never reach CDP collateral except through channel A's debt repayment.** A
borrower's IMD is theirs; the protocol may only hand it over in exchange for retiring their debt.

Note what channel A implies for work-minted COMP: it has no CDP behind it, so redeeming it consumes
borrowers' collateral. That is exactly the dilution §3 bounds, and the 120% worst case is the
guarantee that the collateral pool absorbs it.

**Self-stabilising side effect, worth stating because it is load-bearing.** Redemption shrinks both
terms of `workCeiling` — the reserve directly, and `totalDebt` through channel A. So COMP trading
below peg automatically tightens new work-minting. Supply contracts exactly when it should, with no
governance action and no oracle.

## 5a. Stability fees: burn and convert

Fees arrive in COMP, which cannot back COMP. They are split by a governed share:

```
feeBurnShareBps      -> burned on arrival: pure deflation, improves B immediately
remainder            -> held, then converted to reserve assets when a COMP market exists
```

Burning is the safe default and needs nothing to exist. The held remainder is the part that can
eventually become real backing, but it requires COMP liquidity, a swap route and a sell policy, so
it accumulates first and converts later. Held COMP is **never** counted in `reserveValueUsd`.

## 5b. Who captures the value an update creates

Publishing a fresh price enables liquidations, and whoever acts on it first takes the margin. That
value is Oracle Extractable Value, and in this protocol it is created by our own attestation relay
rather than by an external feed.

**The payer of an update is not guaranteed to capture it.** Two public facts combine:

- `GET /oracle/requests` lists the last hundred requests — ids, questions and statuses — with no
  authentication, and `GET /oracle/requests/<id>/attestation` serves the signed attestation the same
  way. Checked 2026-10-03: both `200` unauthenticated.
- `SwarmRelay` is permissionless by design, and the feeds pin it.

So anyone can poll the list, pull the attestation for a request we paid 0.5 IMD for, and
relay-and-liquidate ahead of us. `relayAndLiquidate` makes the update and the liquidation atomic; it
does not make the payer first. The window is the couple of minutes between the panel attesting and
our relay landing.

**What is NOT at risk, and it is the larger half.** `liquidate` pays `protocolCut` to `feeRecipient()`
and `markerCut` to the recorded marker, both independent of `msg.sender`; only the remainder goes to
the caller. So the protocol is paid its `protocolBonusShareBps` share whoever liquidates. The
contestable amount is the liquidator's own margin plus the 0.5 IMD spent on an update somebody else
monetised — a revenue question, not a solvency one. That is what makes this an optimisation rather
than a blocker.

**Decision (2026-10-03): run the keeper in-house, and ship.** It is the fastest route to a working
mainnet deployment and it wins in practice, because we know a `requestId` at the moment we pay for it
while a searcher has to discover it by polling. Being first is a matter of not waiting.

What that keeper actually needs, stated plainly because two of these are easy to underestimate:

- **COMP inventory, not just gas.** `liquidate` burns the CALLER's COMP, so a keeper must already hold
  the stablecoin it repays with. That is working capital, sourced by minting against its own
  collateral or buying, and it is the real constraint on keeping one running.
- **Its own key, on its own machine.** Not the worker box: strangers' tasks execute there, and this
  repository's rule is that no wallet key belongs on it. The keeper is separate infrastructure.
- **To poll its own requests, not the public list**, so it acts on the attestation as soon as the
  panel issues it.
- **To tolerate being beaten.** Losing a race costs the keeper's margin and the request fee. The
  protocol's cut is unaffected, so a down keeper is lost revenue rather than a halt.

**Deferred, and the only real fix:** give the relayer of an update a short exclusive window to act on
it, so the party that paid for the price captures what it enables. That is a protocol change with its
own fairness question — it privileges one address over a permissionless path we deliberately built —
so it waits until there is liquidation volume worth arguing about.

**Chainlink SVR was assessed and does not apply** (2026-10-03). It recaptures OEV from liquidations a
*Chainlink* update enables, splitting it with the protocol through a private transmission channel to
searchers. Ours are not Chainlink-triggered: `_price()` reads only the swarm `priceFeed`, and
`usdPriceFeed` appears nowhere in the liquidation path — only in `reserveValue()` for the work
ceiling. A Chainlink move cannot make a position liquidatable here, so there is nothing for it to
recapture. It is also mainnet/Base/Arbitrum/BNB/Monad only, not Sepolia. It would only ever apply if
the primary price moved to Chainlink, which §Design Philosophy rules out. Recorded so it is not
re-evaluated: the useful part is that an independent product arrived at the same two mechanisms we
built — bundling the update with the action, and splitting the recaptured value with the protocol.

## 6. What to build, in order

1. `workCeiling()` + `workRatioBps` as governed parameters, and the ceiling check in `mintFromWork`.
   Smallest change, removes the largest unbounded risk in the protocol, independent of everything
   else here.
2. Reserve valuation on the Treasury: per-asset price source and haircut, `reserveValueUsd()`.
   Requires the USD price wrapper (IMD/ETH feed × Chainlink ETH/USD).
3. ~~`SwarmWorkOracle` — attestation-verified per-agent tally replacing the `grantRights` faucet,
   with `isController` binding a tally entry to a claimant.~~ **BUILT 2026-10-04.** `src/SwarmWorkOracle.sol`
   extends `SwarmFeed`, so verification, replay, panel floors, freshness and question binding are the
   audited code rather than a second implementation. The agentId and the claimant live in the question
   TEXT, so both are inside the document the feed pins — an attestation about another agent fails the
   question check with no field for either.

   **The figure now comes from the daily oracle receipts, not the live `/swarm` counter.** That is
   upstream PR #332's second Merkle root, merged, and #334's IPFS archiving of the receipts: the
   panel reads frozen bytes with an `agentRoot` to verify a proof against, so the question carries
   `toleranceBps: 0` where a live counter needed 300. `oracle/work-tally-quote.json` is that question.
   What the contract cannot do is verify the commitment itself — the on-chain `documentHash` is keccak
   over a multi-megabyte document and `WorkRecorded` carries no root — so the attestation is still the
   bridge, and the docstring says so.

   Two consequences to hold onto. **Credit accrues forward only:** migration 0090 states that older
   rows are not reconstructed, so this seat's 1,200-odd historical tasks score zero and
   `/agents/51450/oracle-records` is empty today. The question is therefore not yet answerable and a
   panel must report inability; the contract is ready for the first receipt that carries a tally. And
   **it costs nothing to wait**, because `workCeiling()` is zero on a fresh stack regardless of what
   the oracle says.

   A **factory** deploys it, which is a size result and not a preference: `SwarmWorkOracle` is 16,478
   bytes of creation code and `ParameterizedVault` had 12,222 of EIP-3860 headroom, so a vault that
   created its own would be undeployable. `WorkOracleFactory` holds that creation code instead, the
   vault asks for one by passing `WORK_ORACLE_SENTINEL`, and an absent factory reverts rather than
   silently leaving the vault on the faucet.
4. Redemption channel A (IMD against CDPs). The hard floor, and the largest new surface.
5. Redemption channel B (reserve assets, weight-priced fee).
6. Upstream: the oracle-batch second-root PR.
7. The in-house keeper (§5b). Off-chain, so it is not contract work and belongs in no `workflow.open`:
   poll our own oracle requests, relay-and-liquidate atomically, hold COMP inventory, run on its own
   machine with its own key. The relayer automation and the price-movement watcher of the cadence
   finding are the same daemon — all three want the same key and the same loop.

## 7. New governed parameters

All under the existing 48-hour delay, all hard-bounded in the parameters contract:

| parameter | purpose | proposed | hard bound |
|---|---|---|---|
| `workRatioBps` | ratio term of `workCeiling` | 2500 | ≤ 2500 (cliff is `minCR − 1` = 5000) |
| `compPerTaskWad` | COMP an accepted task earns | 0.01 | ≤ 1e18 — one task is never worth more than one COMP |
| `redemptionCeilingCR` | above this a position cannot be redeemed against | 200 | ≥ `minCR`, ≤ 400 |
| `feeBurnShareBps` | share of COMP fees burned on arrival | 10000 at first | no bound needed |
| `haircutBps[asset]` | per-asset retained-value factor | near 10000 stables, lower for IMD | 0–10000 |
| `targetWeightBps[asset]` | basket weight driving channel B's fee | — | must sum to 10000 |
| `REDEMPTION_FEE_FLOOR` / `_MAX` | the peg band | 50 / 500 | constants, not governed |

The fee floor and cap are deliberately source constants rather than parameters: the floor *is* the
peg, and a governable cap is a redemption halt with extra steps.

## 8. Open questions

- **Target basket weights**, which set channel B's fee curve and therefore what the reserve drifts
  toward. Needs a view on what the protocol wants to hold.
- ~~**Who may call the oracle tally update**, and what happens to rights already issued if a later
  tally revises an agent's count downward.~~ **SETTLED in the build.** Anyone may relay; only the
  vault may consume. Rights are earned-minus-consumed against a HIGH-WATER count pinned at the moment
  of consumption, so a lower later figure can neither claw back what was spent nor re-credit work
  already minted against. That shape is forced rather than chosen: the figure moves down for ordinary
  reasons — the feed can go stale and re-anchor, and a daily receipt only lists agents who worked
  that day.
- **When the held fee COMP converts to reserve assets**, and through what route. Blocked on COMP
  liquidity existing at all.
- **Whether `redemptionCeilingCR` should move with NHI** the way `minCR` does, so redemption
  eligibility widens as network health falls.
