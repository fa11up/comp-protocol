# Asks to the IdentityMD operator

*Running record, maintained 2026-10-04. Ordered by what each costs them, cheapest first, because
that is the order they are likely to be answered in.*

Standing principle, learned from the three contributions that landed: **arrive with the work done.**
`univ4-spot`, `log-count` and the output-type check shipped because they were written, tested and
reasoned about before they were proposed. The one open ask that is still a discussion rather than a
PR — the window-free question identifier — is open precisely because it is a network-wide signature
break whose right shape depends on information only the operator has.

---

## Shipped

| ask | outcome |
|---|---|
| `univ4-spot` and `log-count` recipes | **live in production.** Price can be asked as `evidence: chain` with a rerunnable recipe. |
| Output-type check in `check-answer.mjs` | **live.** "A recipe yielding anything else is refused however many members agree." |
| Per-agent oracle tally in the daily receipt (PR #332) | **merged, and LIVE ON CHAIN.** Built on by the operator's own #334: frozen evidence snapshots, IPFS archiving, `ipfs.imd.fun`. Our leaf survived byte for byte: `["uint256","uint32","uint64"]` = (agentId, accepted, cumulative). |

### Verified in production, 2026-10-04

The first `identitymd-oracle-batch-v2` receipt is the **2026-10-03** day, committed on chain at
`WorkRegistry.latest(0xc94cf42a0679875bbbb7209563d3b1f3)` = `0xd7e48ee4…`, carrying
`agentRoot 0x3c87148642e24e9ec1c1473c7bad5d6aeb0ca6554c5953cce17810421849d17c`, our
`agentLeafEncoding`, and 7 agent leaves.

Rebuilding the tree from the published `agentLeaves` with `StandardMerkleTree` reproduces that root
**exactly**, and an individual agent's proof verifies. So the mechanism works end to end and an
independent party can check it without the API.

Two facts to remember rather than rediscover:

* **The first day is partial.** `accepted_agents` is a new nullable column from migration 0090, so
  only jobs hashed after it deployed carry agent data — 25 jobs and 7 agents on a day the network
  accepted ~59,000 tasks. Every leaf reads `accepted: 1, cumulative: 1`, which is cumulative
  genuinely starting clean. It fills in going forward.
* **Agent 51450 is not in it.** Not a fault anywhere: our seat simply did not catch one of those 25
  jobs. The seat is healthy (1,373 attempts / 1,327 accepted). Credit accrues forward only, so the
  cost of a worker outage is now permanent missed credit rather than just missed volume.

---

## 1. Surface `agentRoot` in `recordWork` / `WorkRecorded`

**Cost to them: one field.** Not a blocker for us.

`recordWork` commits to the agent tally only through `documentHash`, which is keccak over the whole
canonical receipt — multi-megabyte, so a *contract* cannot verify a tally proof even though an
off-chain reader can verify it end to end. `WorkRecorded` carries `uri` but no root.

If `agentRoot` were its own field in the event, any consumer contract could verify a `MerkleProof`
directly against chain state with no oracle request at all. We do not need it: `SwarmWorkOracle`
attests the count and question binding already pins the agent. And it is not an unambiguous win —
the Merkle route trusts the WorkRegistry writer's key outright, where the attestation route trusts
the attester *plus* a panel. Offer it as a one-liner, not a request.

---

## 2. Price scheduled oracle requests below spot

**Cost to them: revenue per request, offset by capacity planning.**

Argue it on cost, not on favour: a `schedule.create` request is **predictable load**. The plane can
plan capacity against it; a spot request arrives whenever a buyer decides. Predictable demand is
cheaper to serve, and every utility prices it that way.

Our own interest is direct. A feed is only as safe as its update cadence — `maxDeviationBps` and the
update frequency are one knob, not two, and a cap is only safe if the market cannot move further than
the cap between updates. At 0.5 IMD a request, defending a feed properly is a recurring cost, and
IMD moved 44.6% in a day while we watched.

---

## 3. Accept imdUSD as payment for swarm work

**Cost to them: a token in the payment layer, and an FX decision. This is the big one.**

The honest statement of the problem it solves: **imdUSD is backed by work and has nowhere to be
spent.** That is the gap between the whitepaper's thesis and the deployed protocol. If the swarm
accepts imdUSD, demand for imdUSD *is* demand for compute, and the peg gets a real anchor — one
imdUSD buys a dollar of work. Agents mint from work, requesters spend to buy work, and "endogenous"
becomes literally true rather than aspirational.

**The structural problem, to raise before they do.** x402 settles in IMD via Permit2. Accepting
imdUSD adds both a token and a foreign-exchange leg, since requests are priced in IMD while imdUSD is
priced in dollars. The cleanest shape is **quote in USD, settle in either** — which also makes
pricing legible to requesters, because nobody budgets in IMD.

**And the reflexivity, which is better said by us than discovered by them.** A stablecoin accepted as
payment by the network that backs it is reflexive: falling imdUSD demand means falling swarm revenue
in imdUSD, which pressures the backing. Redemption is the mitigation — it shrinks both terms of
`workCeiling`, so supply contracts exactly when it should, with no governance and no oracle. That
property is worth leading with, because it is the answer to the first objection they will have.

---

## 4. Window-free question identifier

**Cost to them: a v3 signature break for every consumer. Open as a discussion, not a PR.**

Full analysis in `docs/UPSTREAM-STABLE-QUESTION-ID.md`. The gap is the plane's own stated design:
`OracleAttestation.sol` tells a consumer to "pin its question and compare" `questionHash`, but the
hashed document includes the resolved window, so a **recurring** consumer has nothing stable to pin.
Our workaround is a 1,963-byte JSON prefix spliced in bytecode, which no consumer should have to write.

The window looks redundant — `fromBlock`/`toBlock` are already separate signed fields — and nothing
keys on `questionHash`: it is a non-unique, non-indexed column, the dedup key is `submissionKey`, and
the request's identity is `requestHash`. But both fixes (change the hash's meaning, or add a
window-free `topicHash`) break every existing consumer, and which is right depends on how many
consumers exist and what they pin. That is unknowable from one repository, so it is their call.

We are not blocked either way.

---

## 5. Oracle reviews in ERC-8004, or an explicit statement that they never will be

**Cost to them: gas, which is exactly why they were excluded.**

`docs/work-registry.md` is clear that oracle reviews were dropped because they were **99% of the
mainnet writer's gas**. We accept the reasoning. PR #332 was the alternative and it landed.

What remains useful is a decision we can plan against: ERC-8004 records ~6% of swarm work (475/day
measured against `acceptedLastDay` 7,708), has recorded nothing since 2026-09-29, and has **never**
recorded any of this agent's 1,200+ accepted tasks. If that is permanent, `getSummary` is not a work
signal for anyone and the daily receipt is the only one — worth saying out loud so nobody else builds
against the registry expecting coverage.

---

## 6. Request-side `draft.contracts` cap

**Cost to them: a number.**

The launch *manifest* takes eight contracts; a request's `draft.contracts` takes **four**
(`400 invalid_request: expected array to have <=4 items`). Since a request approves a manifest, four
is the binding figure and the extra manifest slots are unreachable through `workflow.open`.

It cost us a real design: the manifest would otherwise deploy its own collateral as a named artifact
and reference it with `$contract:`, which is strictly better than the sentinel it uses instead —
a `$contract:` reference is resolved per chain by the launch, which is the property a literal address
lacks and the reason an earlier launch was unconstructible. The shape is written and passing in
`test/ManifestConstructible.t.sol`, waiting on the cap.

---

## Asked and settled — do not re-raise

| question | answer |
|---|---|
| Can a submitted workflow be cancelled? | **No.** `POST /workflows/:id/cancel` exists but is `operatorAuthorized`; returns 401 for us. Verify everything before paying. |
| Does Chainlink SVR help us? | **No.** It recaptures OEV from liquidations a *Chainlink* update enables; our liquidation path reads only the swarm feed. Not on Sepolia either. |
| Are launches token-fixed? | Was yes, now **no** — the `evm_contracts` kind deploys application contracts with no token, no pool and no distributor. |
