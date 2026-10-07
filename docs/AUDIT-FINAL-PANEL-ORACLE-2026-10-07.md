# Final pre-launch panel audit, oracle — 2026-10-07

Job `f1346a93-e4d4-40da-9e2d-cf536b24e57a` (explorer: https://explorer.imd.fun/jobs/f1346a93-e4d4-40da-9e2d-cf536b24e57a), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `b73a05f0f9185bae139f46c56f044ed9c7391c4c`. Order 9856ebc3, paid 2026-10-07.

Scope: the price path (SwarmFeed and its leaves, SwarmRelay, OracleAsker, UsdPriceFeed, SharePriceFeed, SwarmWorkOracle). Payload: `whitepaper/requests/audit/audit-final-panel-oracle-quote.json` in the operator's workspace (`build_audits.py`, FINAL_PANELS).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 81 (agent 52178) | audit_judge | completed | 7 | 36 | 38,315 |
| 727 (agent 52174) | audit_math | completed | 2 | 34 | 56,249 |
| 225 (agent 52158) | audit_economics | completed | 3 | 44 | 75,826 |
| 808 (agent 52166) | audit_flow | completed | 2 | 44 | 74,447 |
| 852 (agent 52167) | audit_permissions | completed | 4 | 50 | 79,980 |
| 1701 (agent 51324) | audit_math | failed (not accepted) | 0 | 6 | 0 |
| 1202 (agent 51363) | audit_economics | failed (not accepted) | 0 | 3 | 0 |
| 613 (agent 51187) | audit_flow | failed (not accepted) | 0 | 3 | 0 |
| 525 (agent 52199) | audit_permissions | failed (not accepted) | 0 | 2 | 0 |

The judge's merged list is the result: 1 medium, 3 low, 3 info. Judge submission hash `5b558cf512f0f43527e77b8bfec686a4a631a2522fa1160237f59918235cef00`; raw record of every seat beside this file (`audit-final-panel-oracle-2026-10-07-submission.json`, sha256 `6938c3cf4eddfa472490d886fd92311a5b2c521dddb84ae6447c70f7e552c698`).

**Judge's summary, verbatim:**

> All seven findings validate against the tree; `src/SwarmFeed.sol` is back to the committed state and only `.imd-findings.json` and `test/scratch/` were written.
> 
> ## Judgement
> 
> **Kept (7 findings in `.imd-findings.json`)**
> 
> | Sev | Where | Verdict |
> |---|---|---|
> | medium | `SwarmFeed._allowanceNow` L415 | **Merged from 4 specialists.** Stale base measured from signed `issuedAt`, not acceptance; a buyer holding each attestation ~55 min relays into 4,000 bps every ~65 min (3.29x in 4h15m vs committed 2.07x). All three specialist proofs fail on this code; with the `since = max(_anchorAt, _updatedAt)` patch they pass and the SwarmFeed/OracleAsker/QuestionBinding/RelayBundling/SwarmRelay suites still pass (88/88). Proof attached (audit_math's, self-contained). |
> | low | `OracleAsker.onOracleResult` L284 | A hand-relayed `askPaid` answer makes the callback's refusal set `lastAsk`, blocking Treasury `ask` for 2h at ~$5/cycle. Reproduced in `test/scratch/PaidRefusalBacksOffTreasury.t.sol`. |
> | low | `SwarmFeed._checkValue` NatSpec L356 | First value is unbounded and SwarmRelay is permissionless; DeployMainnet does not seed in the deploy tx and `verify()` never checks the anchor. Reproduced in `test/scratch/FirstValueRace.t.sol` (deployer's honest value refused for 6h). |
> | low | `CDPVault._secured` L819 | Reverting Chainlink leg → `_priceOrZero()==0` → ungated `wipe` writes a zero secured term that persists past recovery; `backingPerUnit` 0, `cash` reverts `ZeroAmount` for up to a day. Reproduced in `test/scratch/StaleLegZeroesSecured.t.sol`. Kept as a consumer effect under Q5. |
> | info ×3 | SwarmFeed L156 (merged duplicate), L221–222, `docs/ABI.md` L84 | NatSpec/doc claims the code does not have. |
> 
> **Dropped:** none — every specialist finding reproduced. Duplicates merged: 4→1 (medium), 2→1 (constructor NatSpec).
> 
> **Numbered questions, briefly**
> 1. Acceptance is sound: domain binds chain + feed address; `usedRequests` per feed; issuedAt bounded both ways; floors enforced; question hash spliced from signed window with span/advance/recency bounds. No cross-question/chain/feed/window acceptance found.
> 2. N attestations in one lifetime: the epoch allowance (cap when fresh). After H hours of silence: 4,000 + 250·(H−2) bps for H ≥ 2 (table in `_allowanceNow` is arithmetically right). Sustained rate **as committed is not the cap per hour** — see the medium. Packing (64+8+64+32+88 = 256 bits, `MAX_ALLOWANCE_BPS` < 2³²) and the unseeded case are correct; `SwarmWorkOracle._checkValue` correctly keeps only the zero check; NHI inherits the same hold weakness (one day).
> 3. `ask`/`wideOpen`/arming logic correct; pool slot `keccak256(abi.encode(poolId, 6))` and inversion correct. The one gap is the back-off (low).
> 4. Costing unchanged from PARAMETERS except that the medium roughly halves the attacker's exposure time to 3.48x (4–5h vs 6–7h); pool-fee cost (~$39–50k) unchanged.
> 5. Units correct (`imdEth × ethUsd / 10^dec`, `rate × assetUsd / 1e18`); staleness propagates via `isStale`; a reverting leg degrades to zero rather than reverting — with the persistence side-effect in the low above.
> 6. `tail()`, `_requireFreshFeeds`, `_requirePriceAgreement` check all three feeds; relay bundles strand nothing (`relayAndBite` asserts both balance deltas, `relayAndBark` uses `barkFor`); work oracle rights cannot be claimed twice (monotone `creditedTasks`) or for others (`isController`); old roots can only under-credit.
> 
> **Coverage:** read in full — SwarmFeed, OracleAsker, SwarmRelay, PriceFeed, SpotFeed, NhiFeed, UsdPriceFeed, SharePriceFeed, SwarmWorkOracle, DeploymentConfig; CDPVault/ParameterizedVault read for the price-consuming paths (`_resecure`, `_backingPerUnit`, `_requireFreshFeeds`, `_requirePriceAgreement`, `barkFor`) and DeployMainnet/runbook §7 for the seeding order. Not read in full: CDPVault/ParameterizedVault/Treasury beyond those paths.


| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | medium | no | `src/SwarmFeed.sol:415` | SwarmFeed._allowanceNow measures the hour of silence that earns the stale base from the signed issuedAt, which a relayer may hold back up to maxAge, so a held-and-relayed walk compounds at 2x the cap  |
| 2 | low | no | `src/OracleAsker.sol:284` | OracleAsker.onOracleResult backs the Treasury off for ASK_TIMEOUT after a refused delivery of a CALLER-paid request, so a ~$5 askPaid whose public answer is hand-relayed first disables Treasury-paid a |
| 3 | low | no | `src/SwarmFeed.sol:356` | SwarmFeed: the unbounded first value is 'the one we buy and check at deployment' only by convention; with SwarmRelay as the pinned relayer whoever relays first anchors a freshly deployed feed, and the |
| 4 | low | no | `src/CDPVault.sol:819` | A reverting ETH/USD (or share-vault) leg reads as price 0, and a wipe/lock made while it is down re-prices the position's secured term at zero; the zero persists past recovery and shuts or underpays ` |
| 5 | info | no | `src/SwarmFeed.sol:156` | SwarmFeed constructor NatSpec describes maxDeviationBps_ as a bound on the change from the LAST accepted value; the shipped bound is per epoch, measured from the epoch's anchor and widening with stale |
| 6 | info | no | `src/SwarmFeed.sol:221` | SwarmFeed.submitAttestation NatSpec still describes the pre-epoch guard: a bound that holds only 'while the previous value is fresh' and a relayer that 'covers the unseeded first value and stale re-an |
| 7 | info | no | `docs/ABI.md:84` | docs/ABI.md describes the attestation as a 12-field tuple under EIP-712 domain version '1' and says there is no questionHash gate or getter; SwarmFeed signs 15 fields (panelSize, quorum, agreed added) |

## 1. [MEDIUM] SwarmFeed._allowanceNow measures the hour of silence that earns the stale base from the signed issuedAt, which a relayer may hold back up to maxAge, so a held-and-relayed walk compounds at 2x the cap 

`src/SwarmFeed.sol:415` — blocking: no; citation: resolved

```solidity
        uint256 periods = (block.timestamp - _updatedAt - maxAge) / STALE_GROWTH_PERIOD;
```

Merged from four specialist reports (audit_permissions, audit_flow, audit_economics, audit_math), all reproduced. The b73a05f fix for the second-half review's medium requires a whole STALE_GROWTH_PERIOD of staleness past maxAge before `_allowanceNow` returns STALE_DEVIATION_MULTIPLE x cap, but it measures that staleness from `_updatedAt`, which `_accept` (line 463) sets to the attestation's SIGNED `issuedAt`, while the epoch itself is dated from the relay block (`_anchorAt = block.timestamp`, line 455). `submitAttestation` admits an issuedAt up to maxAge old (line 233, `_tooOld(a.issuedAt)` is false at exactly one lifetime) and `_requireQuestion` admits a window that closed up to maxAge/12 = 300 blocks ago (line 309); the shipped bodies sign `validForSeconds: 86400`. So a buyer who holds each purchased attestation ~55-57 minutes before relaying it through the permissionless SwarmRelay opens every epoch with `_updatedAt` already ~an hour old. One lifetime plus a few minutes after that relay the stored epoch has expired AND `block.timestamp - _updatedAt - maxAge >= 1 hour`, so `periods == 1` and the next acceptance gets 4,000 bps at the shipped 2,000 cap. The walk then compounds at 1.4 per ~65 minutes instead of 1.2 per hour: from a fresh feed 1.2, 1.68, 2.35, 3.29x (T0+4h15m), 4.61x (T0+5h20m) against the committed 2.07x at 4h and 2.49x at 5h; 3.48x (the level docs/PARAMETERS-2026-10-05.md costs at ~$39k of pool fees against ~$500k over-borrowing at LINE $1M / mat 170) is reached in 4-5 hours of holding the pool instead of 6-7. The same hold works in the fall direction (forced liquidation) and on the one-day NHI feed (hold 23h59m; a value held that long reads 4,000 + 250 x 22 = 9,500 bps on the next step instead of the cap). It also shifts OracleAsker.wideOpen and the H-hours table one hour early relative to the actual relay. NatSpec claims the code does not have: SwarmFeed.sol lines 27-30 ('The stale base is earned by silence, never by timing ... a feed anyone keeps alive moves at most the cap per hour however it is driven'), lines 47-51 ('a run of steps compounds at no more than the cap per hour after the first'), and lines 412-414 inside `_allowanceNow`; docs/PARAMETERS-2026-10-05.md 'The walk, at the committed constants'. The regression test `test_relayingAnHourApartNeverEarnsTheStaleBase` only relays with issuedAt == block.timestamp, which is why it passes. Reachable with the constants as committed (maxAge 1h, cap 2000, spans 300..1200 / 150..1200, ATTESTATION_CHAIN_ID 1, SwarmRelay permissionless); needs no privileged role, only off-chain purchase of the attestations and a wait before relaying, which the runbook and NatSpec describe as the normal fallback. SMALLEST FIX (verified by the judge: all three specialist proofs pass and test/SwarmFeed.t.sol, OracleAsker*.t.sol, QuestionBinding, RelayBundling and SwarmRelay suites still pass): measure the silence from the later of the signed time and the epoch's open, in `_allowanceNow`: `uint256 since = _anchorAt > _updatedAt ? _anchorAt : _updatedAt; if (block.timestamp - since <= maxAge) return maxDeviationBps; uint256 periods = (block.timestamp - since - maxAge) / STALE_GROWTH_PERIOD;` — both fields are in the slot `_accept` already writes, so no gas change for the Intake's 200k stipend. (A mid-epoch late relay still cannot help the attacker: inside an epoch every value is bounded by the anchor's allowance, so the residual under-measurement from `_anchorAt` yields at most 40% per two hours, no faster than the cap per hour.) An exact alternative is a new `_acceptedAt` slot written in `_accept` (+22,100 gas on a first delivery, still inside the stipend). Then regenerate the PARAMETERS walk table and reword the three NatSpec passages.

**Reproduction.** HeldFeed (SwarmFeed with maxAge 1 hours, cap 2_000, relayer = test, attester key held by the test; the same policy as PriceFeed), chain id 1. T0: submit V = 3.55e15 with issuedAt = T0. T0+1h: submit 1.2V with issuedAt = T0+1h-55min (accepted: issuedAt >= _updatedAt and not too old; epoch opens, allowance 2000). T0+2h05m (65 minutes after that relay): EXPECTED per NatSpec 27-30 feed.epoch() allowanceBps == 2000 and a figure 1.68V (a 40% step) refused with ExcessDeviation; ACTUAL allowanceBps == 4000 and 1.68V is accepted (issuedAt = now - 55min). Repeating every 65 minutes: 2.352V at T0+3h10m, 3.293V at T0+4h15m, latestValue 11,689,440,000,000,000 against the cap-per-hour ceiling 1.2^4 V = 7,361,280,000,000,000. The attached test (test/scratch/Proof_bf1bb6b60b3d.t.sol, from the audit_math specialist) fails on the committed code with '4000 > 2000' and '11689440000000000 > 7361280000000001' and passes with the `since = max(_anchorAt, _updatedAt)` patch above. The same reproduction with a question-bound feed (span 300..1200, toBlock = head-300, issuedAt = toBlock*12+130) in test/scratch/Proof_95b1f17cb9d0.t.sol also fails on this code and passes with the fix.


## 2. [LOW] OracleAsker.onOracleResult backs the Treasury off for ASK_TIMEOUT after a refused delivery of a CALLER-paid request, so a ~$5 askPaid whose public answer is hand-relayed first disables Treasury-paid a

`src/OracleAsker.sol:284` — blocking: no; citation: resolved

```solidity
            if (live) f.lastAsk = uint64(block.timestamp + ASK_TIMEOUT - ASK_MIN_INTERVAL);
```

Reproduced from the audit_permissions specialist. The back-off was written for a Treasury-bought answer the feed refused ('A refused answer must not be bought again ten minutes later') and the catch comment says 'askPaid is unaffected: its caller pays'. But `live` (line 265) is true for ANY request still in the feed's in-flight slot, including one bought with `askPaid`/`askPaidMany`, and `lastAsk` is the gate `ask` applies to Treasury money (`TooSoon`, lines 156-158). The plane publishes the signed attestation before the Intake's callback lands and SwarmRelay admits everyone, so the buyer (or anyone watching) relays the same bytes first; the callback's `relay` then reverts `ReplayedAttestation`, the catch writes `lastAsk = now + 2h - 10m`, and `ask` reverts `TooSoon` for two hours whatever the pool does. Repeated every two hours this costs 0.5 IMD (~$5) per cycle, about $60 a day, and removes the Treasury as a buyer: an armed 5% fall is not bought (collateral stays over-valued until the hour-old value goes stale and the vault pauses), the NHI keep-alive at 18h is not bought, a wide-open silent feed is not refreshed. Manual fallbacks (askPaid by a keeper, hand relay) remain and nothing is mispriced, so low. The NatSpec claim the code does not have: lines 281-282 'askPaid is unaffected: its caller pays' is true of the gate on askPaid but not of what a paid request's refusal does to the Treasury's own gate. Smallest fix: remember who paid and back off only on the Treasury's own refusal: add `bool treasuryPaid;` to `Feed` (the struct's second slot has room), set it in `ask` and clear it in `askPaid`/`askPaidMany` where they take the slot, and change the catch to `if (live && f.treasuryPaid) f.lastAsk = ...`. Alternatively do not back off on `ReplayedAttestation`/`WindowNotAdvancing`, which only say the answer already landed.

**Reproduction.** test/scratch/PaidRefusalBacksOffTreasury.t.sol (passes on this code: it demonstrates the state). Fixture as test/OracleAsker.t.sol: MockIntake at INTAKE, SwarmRelay at ATTESTATION_RELAYER, MockPoolManager at POOL_MANAGER, ConfigurableSwarmFeed(maxAge 1h, cap 2000) seeded at 0.001 ETH, asker holding 15 IMD, tracksPool true, keepAlive false. ATTACKER approves 0.5 IMD and calls askPaid(priceFeed, body, 0.5e18) -> R. ATTACKER calls SwarmRelay.relay(priceFeed, a, sig) with the attestation signed for R (figure 0.001 ETH, issuedAt now): accepted. The Intake completes R with the same bytes: Delivered(relayed=false) and `feeds(priceFeed).lastAsk == now + 2h - 10min` (asserted). Ten minutes later the pool slot0 is set to a 10% fall, `arm(priceFeed)` succeeds, five blocks later `ask(priceFeed, body)`: EXPECTED the Treasury pays the Intake 0.5 IMD (an armed fall still present, its documented trigger); ACTUAL reverts TooSoon(lastAsk + ASK_MIN_INTERVAL) and the asker's balance is unchanged (asserted).


## 3. [LOW] SwarmFeed: the unbounded first value is 'the one we buy and check at deployment' only by convention; with SwarmRelay as the pinned relayer whoever relays first anchors a freshly deployed feed, and the

`src/SwarmFeed.sol:356` — blocking: no; citation: resolved

```solidity
    /// stale (`_allowanceNow`). The first value ever has no
    /// bound: it is the one we buy and check at deployment, and it anchors the first epoch.
```

Reproduced from the audit_flow specialist. `_checkValue` applies no deviation bound while `_hasValue` is false (line 372), and the NatSpec here and at lines 221-222 ('a nonzero relayer covers the unseeded first value and stale re-anchors') says the first value is the deployer's. On mainnet the pinned relayer is SwarmRelay, which forwards for anyone (constructor comment, lines 181-193), the question bodies are public (deploy/mainnet/bodies, `{{FEED}}` filled with the planned CREATE2 address) and script/DeployMainnet.s.sol deploys the feeds without seeding them: docs/MAINNET-RUNBOOK.md section 7.1 buys and relays the first attestations as a later operational act, and `verify()` checks relayer/attester/policy but never the anchor against the pool. So the first accepted value of PriceFeed, SpotFeed and NhiFeed is set by whoever relays first, and ParameterizedVault (permissionless from its constructor; 'only then open deposits' is an announcement, not an on-chain gate) prices every position off that anchor. A first value at 2x market is a signed, honest answer to the pinned question if the pool is held at 2x for 7 of the window's 13 samples (the Q4 ramp-and-hold, without a prior walk or any silence). The deployer's honest attestation (market, 0.5x the anchor) is refused ExcessDeviation for the first epoch's hour and afterwards until `_allowanceNow` reaches 5,000 bps, which is periods >= 5, six hours after the attacker's issuedAt (five with the hold of the medium finding). Reachable with the constants as committed; it is a race the attacker must win in the minutes between deployment and the deployer's relay while holding a pumped pool through a window, so low. NatSpec claims the code does not have: lines 356-357 and 221-222. Smallest fix, either: have DeployMainnet buy the three attestations for the planned addresses before the broadcast and relay them in the same transaction as the deployment (the attester signs for the consumer address in the body, which the plan already fixes), so no block exists in which the feeds are unseeded; or make the first anchor checkable before deposits are announced, e.g. `verify()` requires `|priceFeed.latestValue() - asker.poolPrice()| <= cap`. Reword 356-357 and 221-222 to say the first value is bounded by nothing on chain and belongs to whoever relays first.

**Reproduction.** test/scratch/FirstValueRace.t.sol (passes on this code: it demonstrates the state). RaceFeed(maxAge 1h, cap 2000, relayer = a fresh SwarmRelay), no value. STRANGER calls SwarmRelay.relay(feed, a, sig) with a valid attester-signed attestation, figure 2V (V = 3.55e15): EXPECTED per the NatSpec the first value is the deployer's; ACTUAL accepted, epoch() reports anchor 2V, allowance 2000. DEPLOYER relays an honest attestation with figure V: reverts ExcessDeviation (|V - 2V| = V > 0.2 x 2V). At T+5h59m the allowance is 4750 and V is still refused; at T+6h00m01s the allowance is 5000 and V is finally accepted.


## 4. [LOW] A reverting ETH/USD (or share-vault) leg reads as price 0, and a wipe/lock made while it is down re-prices the position's secured term at zero; the zero persists past recovery and shuts or underpays `

`src/CDPVault.sol:819` — blocking: no; citation: resolved

```solidity
        if (principal == 0 || price == 0) return 0;
```

Reproduced from the audit_economics specialist (Q5: what a reverting or non-standard leg does to every consumer). UsdPriceFeed._ethUsd maps an aggregator that reverts or answers malformed to (0, 0, 0), so UsdPriceFeed.latestValue returns (0, 0) and SharePriceFeed.latestValue returns (0, 0) too (also when sIMD's convertToAssets reverts); ParameterizedVault._priceOrZero then returns 0. Price actions are refused (StaleFeed), the documented safe direction, but `lock`, `lockIMD` and `wipe` are deliberately ungated and each calls `_resecure(position, _priceOrZero())` (CDPVault.sol lines 378, 403, 1151); `_secured` (this line) returns 0 for a zero price, so the position's whole term leaves `securedCollateral`, and `_clampLag` (lines 849-850) treats the drop as a real decrease and clamps `laggedSecured` down with it. Nothing re-prices the term when the leg recovers: only that borrower's next lock/free/draw/wipe does, and the restored amount then counts only as it warms up over BACKING_WARMUP (a day). `_backingPerUnit` (line 677) therefore reads 0 for a single-borrower vault (or is depressed by that borrower's share in general) after the leg is back, and `cash` computes payoutScale = 0 and reverts ZeroAmount (line 634), or pays below par, while every position is as collateralised as before; the redemption channel, the peg defence, is shut or underpaying for the rest of that day because of an oracle outage that is otherwise over. A merely STALE Chainlink answer does not do this (latestValue still returns the old figure); it needs the aggregator to revert or return malformed words, or sIMD's convertToAssets to revert, both cases the code explicitly handles by reading zero. Nothing is stolen and redeemers can protect themselves with minGemOut, so low. NatSpec at lines 813-815 ('an unpriced feed counts the position for nothing') describes the write but not that it persists past recovery and feeds the lag clamp. Smallest fix: in `_resecure`, when `price == 0` leave `position.secured` and `securedCollateral` untouched (skip the re-pricing) instead of writing a zero term.

**Reproduction.** test/scratch/StaleLegZeroesSecured.t.sol (passes on this code: it demonstrates the state). WorkBackingFixture (ParameterizedVault, $1 per collateral unit, Chainlink etched at CHAINLINK_ETH_USD). BORROWER locks 200e18 and draws 100e18; two days pass, a wipe(1e18) checkpoint warms the lag: securedCollateral ~198e18, backingPerUnit() == 1e18. vm.mockCallRevert on the aggregator's latestRoundData: collateralPriceFeed.isStale() is true, draw(1e18) reverts; BORROWER wipe(1e18) succeeds and securedCollateral becomes 0. Clear the mock and refresh the answer: isStale false, collateralRatio(BORROWER) >= 200, yet backingPerUnit() == 0 (EXPECTED 1e18) and cash(1e18, 0, BORROWER) reverts ZeroAmount. BORROWER wipe(1e18) again: backingPerUnit still 0 (lag warms from zero); one day later it reads 1e18 again.


## 5. [INFO] SwarmFeed constructor NatSpec describes maxDeviationBps_ as a bound on the change from the LAST accepted value; the shipped bound is per epoch, measured from the epoch's anchor and widening with stale

`src/SwarmFeed.sol:156` — blocking: no; citation: resolved

```solidity
    /// @param maxDeviationBps_ Maximum change from the last accepted value, from 0 to 10,000 bps.
```

Merged from audit_permissions and audit_economics (duplicates). Since cc4103f the guard is per epoch: every value accepted within maxAge of an epoch's start must lie within the epoch's allowance of the ANCHOR (the value held when the epoch opened); the allowance is the cap only for an epoch opened on a fresh value, STALE_DEVIATION_MULTIPLE x cap and growing on a stale one, and a wide epoch additionally holds later values to the cap around its first value (`_checkValue`, `_epoch`, `_allowanceNow`, `_epochFirst`). The @param line still states the pre-epoch rule, and a reader sizing the cap from it would conclude 20% means at most 20% between consecutive accepted values, which is false in both directions. Documentation only. Fix: '@param maxDeviationBps_ The per-epoch deviation cap in bps against the epoch's anchor when the epoch opens on a fresh value; wider on a stale one (see `_checkValue`, `_allowanceNow`), 0 to 10,000.'

**Reproduction.** Feed with maxAge 1h and cap 2000 seeded V at T0. At T0+30m accept 1.2V (within the cap of the anchor V). At T0+40m submit 1.44V: EXPECTED per the @param text (20% from the LAST accepted value 1.2V) accepted; ACTUAL ExcessDeviation, because the anchor is V and 1.44V is 44% from it. Conversely, test/SwarmFeed.t.sol test_staleValueReanchorsOnlyWithinTheWidenedBound: with cap 1000, a value 20% above the last accepted value is accepted after a two-hour silence, so the cap is not 'the maximum change from the last accepted value'.


## 6. [INFO] SwarmFeed.submitAttestation NatSpec still describes the pre-epoch guard: a bound that holds only 'while the previous value is fresh' and a relayer that 'covers the unseeded first value and stale re-an

`src/SwarmFeed.sol:221` — blocking: no; citation: resolved

```solidity
    /// The deviation guard bounds a wrong-question figure once seeded while the previous value is fresh;
    /// a nonzero relayer covers the unseeded first value and stale re-anchors. A feed that pins its
```

From the audit_math specialist, confirmed by reading lines 221-222 against `_checkValue`/`_epoch`/`_allowanceNow` (370-420) and DeploymentConfig.sol ATTESTATION_RELAYER. The bound no longer lifts when the value is stale: it widens by `_allowanceNow` and is measured against the epoch's anchor, not the last accepted value. And the relayer covers nothing on the shipped feeds, since ATTESTATION_RELAYER is SwarmRelay, which admits everyone (the constructor comment at lines 181-193 says so itself; SwarmRelay.sol lines 11-13 repeat the stale claim). No code effect; the sentences could mislead a reader into thinking a stale feed is unbounded or that the relayer is a trust boundary. Fix: state the per-epoch, widening bound and that the relayer is not load-bearing; the first value is bounded by nothing on chain (see the low finding at line 356).

**Reproduction.** Read src/SwarmFeed.sol:221-222. A stale feed (value two hours old) submitted a value 3x its anchor: EXPECTED per 'bounds ... while the previous value is fresh' (i.e. no bound once stale) accepted; ACTUAL ExcessDeviation (allowance 4000 bps). A stranger calling SwarmRelay.relay on an unseeded shipped feed: EXPECTED per 'a nonzero relayer covers the unseeded first value' refused; ACTUAL accepted (test/scratch/FirstValueRace.t.sol).


## 7. [INFO] docs/ABI.md describes the attestation as a 12-field tuple under EIP-712 domain version '1' and says there is no questionHash gate or getter; SwarmFeed signs 15 fields (panelSize, quorum, agreed added)

`docs/ABI.md:84` — blocking: no; citation: resolved

```
`submitAttestation` takes an `OracleAttestation` tuple in this exact order: `(bytes32 requestId, uint256 chainId, bytes32 questionHash, uint8 answerType, bytes answer, uint256 figure, uint64 fromBlock, uint64 toBlock, bytes32 blockHash, bytes32 panelJobId, uint64 issuedAt, uint64 expiresAt)`, followed by a 65-byte signature. The EIP-712 domain is `IdentityMD Oracle`, version `1`, with the deployment chain ID and the receiving feed's address, computed once in its constructor. Payload chainId and answerType must equal `attestationChainId()` and `attestationAnswerType()`; the payload data chain may differ from the consumer chain (for example, mainnet data consumed on Sepolia). requestId is consumed once per feed; issuedAt cannot be in the future, exceed expiresAt, precede the last accepted update, or be older than maxAge. Delivery after expiresAt is rejected. The feed publishes figure and uses signed issuedAt for freshness, then discards any unfinished reporter round.
```

From the audit_permissions specialist, confirmed against src/SwarmFeed.sol: ATTESTATION_TYPEHASH (lines 117-119) covers `...bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt` and DOMAIN_SEPARATOR (166-174) hashes version "2". ABI.md, the integrator-facing reference, documents the v1 shape (12 fields, `panelJobId` followed directly by `issuedAt`, domain version `1`), omits the panel floors (MIN_PANEL_SIZE 25, MIN_AGREED 15) the v2 fields enable, and the next paragraph (line 86) still says 'there is no immutable questionHash gate or getter' although `expectedQuestionHash(fromBlock, toBlock)` and `_requireQuestion` exist. An integrator encoding `submitAttestation` from this page produces calldata that does not decode or a digest the feed rejects. Documentation only; regenerate the paragraphs from the struct, the domain and `_requireQuestion` in SwarmFeed.sol.

**Reproduction.** Build the tuple as ABI.md line 84 lists it (12 members), sign under EIP712Domain('IdentityMD Oracle','1',chainid,feed) with the attester key and call `submitAttestation` on any shipped feed: EXPECTED per the doc accepted; ACTUAL the call fails in ABI decoding (the struct has 15 members), and with the three fields added but version '1' it reverts InvalidSignature because DOMAIN_SEPARATOR hashes version '2'.
