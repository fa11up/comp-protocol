# Internal audit — 2026-10-04

Scope: what is proven, what is only argued, and what stands between this tree and mainnet.
Every claim below was re-verified today against the chain, the compiler or a test run. Claims
carried over from notes without re-verification are marked *(unverified)*.

HEAD at audit time: `0f15ba8`, on both `main` and `master` of `fa11up/infer-protocol`.

---

## 0. The one-sentence summary

The contracts are in good shape and the **deployed** stack is five generations behind them, so
almost nothing current has ever executed on a chain. The gap to mainnet is not contract work —
four of the runbook's six prerequisites have not been started, and the two newest subsystems
(the redemption cap and the swarm-wide work oracle) have had no independent review.

---

## 1. Proven

### 1.1 Proven on chain (Sepolia, against the live v3 stack)

These executed as real transactions and were verified by reading chain state afterwards, not by
trusting a script's own output.

| What | Evidence |
|---|---|
| Deposit / mint / repay cycle | CR 449, supply identity held |
| Divergence guard | spot pushed +600 bps past a 500 bps bound: `mintCOMP` and `markUnderwater` both revert `0x8f038d91`, `withdrawCollateral` succeeds |
| NHI → minCR/grace curve | 0.900 → 150/6h, 0.725 → 175/3h, 0.600 → 200/0, the linear interpolation live |
| Liquidation three-way split | 1.0 COMP at price 2219784507040719: seized 495543597367679961133, bonus 45049417942516360103, marker exactly 10% = 4504941794251636010, liquidator 491038655573428325123 — all three matched independent computation to the wei |
| `badDebtOf` | returned 157364181818182858, exact against independent computation |
| **The attested path, end to end** | oracle request `50d9b023`, figure 3172735462421828, panel 60/20, relayed in `0x15854076…b9e` block 11830282, 79,328 gas. Verified after: the feed's value IS the attested figure, `usedRequests[requestId]` true, not stale, divergence 119 bps against 500 |
| Attestation v2 schema | domain version 2 and typehash match the live service; panel floors 25/15 |
| SwarmRelay deploys as written | deployed bytecode byte-identical to the local artifact, no owner, zero balance |

### 1.2 Proven against live mainnet state (fork tests, re-run today)

- **12/12** `test/SharePriceFeedFork.t.sol` against live mainnet. `StakedIMD`
  `0x9efa934d…`: `owner() == 0` (renounced, and `renounceOwnership` reverts while paused, so it
  was renounced in the good state and can never be paused), not a proxy, monotone rate,
  `SameBlockRedeem` confined to `_withdraw` so a plain transfer is unblocked.
  `SharePriceFeed` prices it per 1e18 raw units, which is the convention the oracle questions
  already use, so the composition is decimal-agnostic (sIMD is 24 decimals, IMD is 18).
- **14/14** `test/InHouse.t.sol` against live Sepolia, including the typehash and domain pinned
  against the live service, and the faucet-operator / price-setter separation.

### 1.3 Proven in tests only

- **414 pass, 0 fail, 3 skipped** (417 total) under `forge test` with `isolate = true`.
- **56/56** `script/checks/Redemption.t.sol`, including a 256-case fuzz test.
- Round 5's nine reproducible findings: all fixed, each traceable to a `REVISION (finding …)`
  comment in source — `8936befa` (high), `998ff6b2`, `fcd5b261`, `b952037a`, `883fa030`,
  `7cd5035c`, `5ee3f2bc`, `b8aa4a98`, and `b92320ae`.
- `b92320ae`'s own sequence (borrow, work-mint, repay, withdraw, redeem) is replayed by
  `test_debtUnwindCannotLeaveReserveRedemptionWorseningBacking`. Its deterioration is still
  refused — by paying 3.94 where par paid 9.85, instead of refusing the burn.
- The `compPerTaskWad` repricing advisory (`d4017013` / `d83c51d6`) is fixed and pinned by
  `test_aLaterRateChangeDoesNotRepriceWhatWasAlreadyClaimed`: rights accumulate at the rate in
  force when claimed, so a later change cannot reprice credit already granted.
- Question binding's proof chain, both halves: `oracle/question-prefix.mjs` reproduces request
  `50d9b023`'s **live** questionHash exactly, and the Solidity `expectedQuestionHash` equals the
  JS hash for all three feeds. So the contract computes what the service signs.

### 1.4 Measured today, and it changed what the tests may assert

`backingPerComp` is **not monotone** under redemption. Cancelling a borrower's debt disqualifies
`minCR` worth of collateral while retiring only one COMP of supply, so four successive 10 COMP
burns walk it `0.9375 → 0.9194 → 0.9000 → 0.8793 → 0.8571` while economic backing rises
`1.0938 → 1.1219` at every step.

The conservative measure is telling the truth — work-issued COMP that no borrower debt stands
behind really is unbacked — but it must not be asserted as an invariant. Every "must not worsen
backing" assertion now reads an `_econBacking()` helper computed from balances rather than from
the vault, so it can disagree with it.

---

## 2. Argued but not proven

### 2.1 Never executed on any chain

Everything in this list is covered by tests and by nothing else.

- **Redemption, in its entirety.** Channel A is the newest subsystem and the live vault has no
  `redemptionFeeBps` and no `backingPerComp` — verified by `cast call`, both revert.
- **The backing cap** (today's change). Replaces a halt that three separate round 5 reviews
  objected to; zero external review, zero chain time.
- **The swarm-wide work oracle.** Also unbuyable today: migration 0090 does not reconstruct
  history and `GET /agents/51450/oracle-records` returns `{"oracleBatches":[]}`, so a panel
  would have to report inability. Costs nothing — `workCeiling()` is 0 on a fresh stack.
- **Keeper bundling.** `relayAndLiquidate` / `relayAndMark` have never run on chain, and see
  §3.2 for why they cannot currently be deployed into.
- **The governed stack**: `Parameters`, `Registry`, `Governed`'s 48h timelock,
  `ParameterizedVault`. Dry-runs pass and nothing has been deployed.
- `mintFromWork` — the compute channel, the protocol's thesis.
- `clearRecoveredMark` (the recovery path) and `MarkExpired` (a mark going stale after 86,400s).
- The **stability fee at its shipped 200 bps**. It was 0 bps when the live stack was deployed, so
  `debtIndex` / `stabilityFeeOf` have never produced a nonzero figure on chain.
- `protocolBonusShareBps` at its shipped 3333 bps — `FEE_RECIPIENT` has never received anything.
- `DebtCeilingReached` — never reached live.

### 2.2 Question binding is unverified against a live purchase

The three frozen payloads (`price-univ4-v3`, `nhi-composite-v3`, `spot-univ4`) have **never been
bought**, so no generated prefix has been checked with `--verify <requestId>` against a live
attestation. The runbook requires exactly this per feed before deploying one.

This is the highest-value cheap check remaining: 0.5 IMD buys certainty on the mechanism that the
HIGH finding turned on, and `preflight-oracle.mjs` now calls the feed's own
`expectedQuestionHash`, so a disagreement is free to find rather than costing a request.

### 2.3 The keeper has never run against anything

`fa11up/imd-keeper` (private, commit `1ae8286`+) is report-only until `--execute` and has never
been pointed at a live stack. Position discovery is the part most likely to be wrong in
practice, and its own trap is recorded: a 50,000-block `eth_getLogs` span found the one real
depositor while a 40,669-block span *inside* that range returned nothing, neither erroring.

### 2.4 A verification tree nothing runs

`foundry.toml` sets `test = "test"`, so **`forge test` never runs `script/checks/`** — 116 tests,
of which **23 fail**. They are byte-identically red at the parent commit and the swarm diagnosed
each family: liquidation payouts still expecting the former bonus split (2), recovery and
repayment expectations omitting the shipped stability fee (10), and earlier ETH-denomination,
debt-coverage and freshness expectations (11). So they are **stale assertions against superseded
increments, not contract defects** — but nothing distinguishes that from a real regression
automatically, and 23 permanently red tests is indistinguishable from 24.

The same blind spot hid a second thing: the `AUDIT_PROOFS=true` gate is also outside the default
run, and that is where §3.1 was found.

---

## 3. Gaps to mainnet

### 3.1 FINDING — `SwarmFeed`'s constructor does not enforce the pairing it documents

Found today by running the gated audit proofs. Audit #1's HIGH proof
`test_aStrangerCannotReanchorAStaleFeedThroughTheRelay` still reproduces, and not because the
fix regressed: the constructor's unbound-question branch requires only that the relayer be
**nonzero**, and `SwarmRelay` is a nonzero relayer that admits everyone. So
*(no pinned question, `ATTESTATION_RELAYER`)* passes construction and is precisely the
configuration the finding describes, while the comment above the check asserted otherwise.

**Not reachable in anything shipped**, verified leaf by leaf: `PriceFeed`, `NhiFeed`, `SpotFeed`
and `SwarmWorkOracle` all override `questionPolicy` with a generated prefix, so all four take the
bound branch and their relayer is not load-bearing. The three unbound leaves are test
infrastructure.

Fixed today: the false claim (`0f15ba8`). **Open decision:** closing it in the constructor needs
a sound on-chain test for "a relayer that restricts its callers", and `code.length` is not one —
a relay contract may legitimately carry an allowlist. Until that is decided it is a review rule:
a new feed leaf overrides `questionPolicy`, and a missing override is the thing to catch.

### 3.2 The deployed stack is five generations behind source

Read off chain today, Sepolia v3:

| Read | Result | Means |
|---|---|---|
| `PriceFeed.expectedQuestionHash()` | **reverts** | no question binding: audit #1's HIGH is live on it |
| `PriceFeed.isReporter(W0)` | **true** | the reporter fallback is live: one key can re-anchor the price past `maxAge` |
| `PriceFeed.relayer()` | `0x1d0074aB…` (W0 EOA) | not the relay |
| `CDPVault.backingPerComp()` | **reverts** | no redemption, no backing cap |
| `CDPVault.securedCollateral()` | **reverts** | none of round 5's guard work |
| `CDPVault.totalDebt()` | 157364181818182858 | the frozen stress-test position, pre-sweep-fix |

Consequence: the live stack is a demo of an older design. Every current property is
test-only. A redeploy is not optional for any of it.

### 3.3 The pinned relayer cannot do keeper bundling

`ATTESTATION_RELAYER` is `0xe36FFc26…`, a **source constant** the feeds compile in. Measured
today: that address holds **1,556 bytes** against the local `SwarmRelay`'s **3,963**, and it has
`relay` (`43ead661`) and `relayMany` (`45ec0a42`) but **not** `relayAndLiquidate` (`1746005c`)
or `relayAndMark` (`ee6b53b2`).

So a redeploy against the current constant produces feeds that pin a relay without the bundling
the keeper is built around. This is round 5's advisory `d7f72926` / `baae247f`, still open, and
it is a deployment-order problem: the relay must exist before the feeds compile.

### 3.4 `DeployPrereqs` has never run, and three constants depend on it

`WORK_ORACLE_FACTORY` is `0x…0f05` — a placeholder with no code, and the sentinel path reverts
rather than silently downgrading to the faucet. `FEE_RECIPIENT` is still miyagod.eth, not a
Treasury. `ATTESTATION_RELAYER` is §3.3.

All three are read as source constants by contracts that are immutable once deployed, so none can
be deployed by the launch that consumes it. Still blocked on key access: the sandbox will not
read W0's key out of `whitepaper/sim/sim.config.js` *(unverified today)*.

### 3.5 Four of the runbook's six prerequisites have not been started

| # | Prerequisite | State |
|---|---|---|
| 1 | Rename COMP → imdUSD | **not started.** `CompToken.sol:29` is still `ERC20("Compute Money", "COMP")` |
| 2 | sIMD as collateral (wrap on deposit) | **not started.** No `depositCollateralIMD` anywhere in `src/`. `SharePriceFeed` is built and fork-proven, which is the hard half |
| 3 | Delete the reporter fallback | **done** (`9becda1`) |
| 4 | CREATE2 deploy script with address assertions | **not started.** No script references the deterministic deployer |
| 5 | Independent audit of this configuration | **not started.** Both audits predate the reporter deletion, the redemption cap and the swarm-wide work oracle |
| 6 | Keeper / watcher daemon | **built, never executed** (§2.3) |

`COMP` also collides with Compound's token, which is top-200 and listed everywhere, so it must
not ship. The on-chain cost of the rename is one line, and the Solidity identifier never reaches
a manifest because the token is created in-constructor.

### 3.6 `ParameterizedVault` is running out of initcode

Measured today: **16,959** runtime (7,617 under EIP-170) and **41,548** initcode
(**7,604** under EIP-3860). The initcode margin is the tightest number in the stack, and three
of the five open prerequisites add to it — the rename, the sIMD wrap, and anything the audit
comes back asking for. This is the constraint most likely to force an unplanned refactor; measure
it after each change rather than at the end.

### 3.7 Operational hazards found today

- **A spent payload is sitting in the submit directory.**
  `whitepaper/requests/round5-quote.json` pins baseCommit `5cc5745e` — the commit round 5 was
  delivered against (merge `aeaa72e`, documented in `docs/REDEMPTION-CHECKS.md`). `submit.js`
  moves a paid payload to `archive/` precisely to stop a double spend, and this one was never
  moved, so `node submit.js requests/round5-quote.json` would pay 0.5 IMD to redo finished work.
  **Moved to `archive/` as part of this audit.**
- **Payloads still name the old repository.** That same payload carries
  `https://github.com/fa11up/comp-protocol`. GitHub redirects, so in-flight work resolves, but
  every *new* payload must use `infer-protocol`.
- **Six ABI exports were stale.** Four of the feeds had been wrong since the reporter deletion
  (still exporting `report`, `isReporter`, `quorum` and the four-argument constructor);
  `CDPVault` and `ParameterizedVault` were wrong from yesterday's cap. Regenerated in `66b142a`;
  all fifteen now match `forge inspect`. Worth a pre-commit check, since nothing catches it.

### 3.8 Known and accepted, recorded so they are not rediscovered

- **`Registry` is write-only.** The feeds read `ATTESTATION_RELAYER` as a constant, the vault
  reads `FEE_RECIPIENT` as a constant, and the work oracle is a constructor argument. Governance
  over the registry is a published record of intent for the *next* deployment, not a live
  control. Found by us, confirmed by audit #1.
- **OEV: the payer of an update is not guaranteed to capture it.** `GET /oracle/requests` lists
  the last 100 requests unauthenticated and serves their signed attestations, and the relay is
  permissionless, so `relayAndLiquidate` buys atomicity, not priority. Protocol revenue is
  unaffected — `protocolCut → feeRecipient()` and `markerCut → marker` are both independent of
  `msg.sender` — so the contestable amount is the liquidator's margin plus the request fee.
  Decision taken: run the keeper in-house and ship.
- **One signer on the price path.** `ORACLE_ATTESTER` is a single key. Question binding plus the
  panel floors bound what a signature can say, but this is a trust assumption of the protocol.
- **Work credit accrues forward only.** Migration 0090 does not reconstruct history, so none of
  our 1,327 accepted tasks score. A worker outage now costs permanent credit, not just volume.
- **Round 5 advisory `08f0352c` is still an open requester decision** — the fresh-principal
  exclusion switches the redemption brake off for same-block chunks against a fresh borrower.

---

## 4. What I would do next, in order

1. **Buy one oracle request per feed and run `--verify`.** 1.5 IMD total, and it is the only
   thing standing between "the prefix generator agrees with itself" and "the prefix agrees with
   the service". Cheapest unresolved risk on the critical path. (§2.2)
2. **Decide §3.1** — whether the constructor should refuse an unbound question outright. One
   line either way, and it is the last loose end from audit #1's HIGH.
3. **Rename, then wrap sIMD, then CREATE2** — in that order, measuring initcode after each.
   These are prerequisites 1, 2 and 4, they all touch the vault, and §3.6 says to watch the size.
4. **Then buy the independent audit** of the whole configuration, once the three above have
   stopped moving the code. Reviewing it before them wastes the review.
5. **Run the keeper against the Sepolia stack in report-only mode** before any of this reaches
   mainnet. It has never seen a live vault.

Deliberately not next: deploying anything. Four prerequisites are open and a redeploy against the
current constants produces feeds pinned to a relay that cannot bundle (§3.3).
