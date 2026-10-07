# Sweep panel audit, oracle — 2026-10-07

Job `ecd0a279-c5d7-4167-8e75-9fbbc85b41fe` (explorer: https://explorer.imd.fun/jobs/ecd0a279-c5d7-4167-8e75-9fbbc85b41fe), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `8756817e66e973b05ea08e2aa99ee627de225d09`. Order 2f09998c, paid 2026-10-07.

Scope: the price path (SwarmFeed and its leaves, SwarmRelay, OracleAsker, UsdPriceFeed, SharePriceFeed, DeployMainnet.verify and verifySeeded), after the final panels' fixes (8756817). Payload: `whitepaper/requests/audit/audit-sweep-panel-oracle-quote.json` (`build_audits.py`, SWEEP_PANELS).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 1473 (agent 51481) | audit_judge | completed | 11 | 50 | 56,100 |
| 608 (agent 51726) | audit_judge | failed (not accepted) | 0 | 1 | 0 |
| 158 (agent 51474) | audit_permissions | completed | 7 | 53 | 96,053 |
| 1212 (agent 52182) | audit_economics | completed | 6 | 45 | 86,925 |
| 729 (agent 50988) | audit_math | completed | 5 | 62 | 93,073 |
| 346 (agent 52289) | audit_flow | completed | 5 | 53 | 78,051 |

The judge's merged list is the result: 4 low, 7 info. Judge submission hash `1db7293d2481b80a187762d1d5323701628e86b6e65bb71a6ad0463aa639f5a8`; raw record of every seat beside this file (`audit-sweep-panel-oracle-2026-10-07-submission.json`, sha256 `090651b4b7e2ab623b5b1b5ca681a9c7617e5dd69b2a2a844537489bf426617b`).

**Judge's summary, verbatim:**

> The review is complete. The findings file holds 11 entries, all reproduced against the code, with the one attached proof confirmed to fail on this tree for its stated reason. Nothing in the tracked tree changed; only the findings file and test/scratch/ were written.
> 
> ## Judgement
> 
> **Kept (4 low, 7 info), merged from 23 specialist reports:**
> 
> - **Low, OracleAsker back-off forgery** (merged from all four specialists). The catch writes lastAsk to now + 6,600 s, a mainnet slot boundary, so a caller-paid askPaid mined in that second satisfies the Treasury-paid test and its refusal extends the back-off. The attached proof fails here with `949500 != 942600`. Fix: an explicit treasuryPaid flag in the Feed struct.
> - **Low, verifySeeded is advisory** (merged from four; I kept the panel's low rather than the math specialist's medium). The vault is live from its constructor, the check compares against the live pool and never reads the vault. My test shows the LINE drawn against a raced 2x first value, and verifySeeded printing "Seeded and verified" over that vault while the pool mock sits at 2x.
> - **Low, dead-leg wipe keeps the whole term.** The 8756817 fix keeps min(before, collateral) with no price, so a borrower repaying 490 of 500 during an outage keeps a term for 500. Reproduced: backingPerUnit reads par where the honest figure is 0.686, and a redemption against the reserve pays over 1.4x what it should.
> - **Low, oversized ETH/USD answer reverts** instead of reading zero, reaching the ungated lock and wipe. Reproduced with an answer of 1e70.
> - **Info:** uint32/uint24 NatSpec; "cap per hour" is per epoch (44% across a boundary, demonstrated); "nobody can make a feed age faster" (held attestation lands aged, demonstrated); asker budget sentence; DeploymentConfig relayer NatSpec; PriceFeed prefix actually reproduces the archived live attestation's questionHash; and the numbered answers below.
> 
> **Dropped:** nothing failed to reproduce. The specialists' "$169k collateral at 3.48x" figure was wrong (debt times mat over k gives $475k at 1.2^7); corrected in the Q6 answer.
> 
> ## Numbered answers, briefly
> 
> 1. Acceptance is sound: domain binds chain and feed, replay per feed, issuedAt bounded both ways, panel floors enforced, question hash spliced from the signed window with span, advance and recency bounds. No cross-question, chain, feed or window acceptance.
> 2. The bound holds per epoch: 1.2 per hour on price feeds, 1.2 per day on NHI, first step after H hours of silence 40% + 2.5%(H−2) (NHI: H−25), 100% at 26 hours. Packing is exactly 32 bytes and every cast is exact. The hold-then-relay variant is closed. No sequence beats the cap per epoch after the first step.
> 3. Ask paths behave as documented except the back-off gap. No budget overrun, no lost paid answer.
> 4. The check is not sufficient for the racer's own deposit, and a failed check costs a redeploy or the unrecoverable share of any draw made first.
> 5. Units are right; dead legs read zero and stale, with the two gaps reported.
> 6. The walk costs about $40k of pool fees over six hours for roughly $500k of unbacked imdUSD at the LINE; downward, at most the $200k bonus less resale loss, needing the dump held through the six-hour grace.
> 
> **Coverage:** read in full SwarmFeed, OracleAsker, SwarmRelay, the three leaves, UsdPriceFeed, SharePriceFeed, DeploymentConfig and DeployMainnet. CDPVault and ParameterizedVault were read on every price-consuming path. Not read in full: Treasury, Parameters, SwarmWorkOracle, and the bite/bark internals.


| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | low | no | `src/OracleAsker.sol:273` | OracleAsker.onOracleResult: the Treasury-paid test (lastAsk == inFlightAt) is satisfied by a caller-paid askPaid sent in the block whose timestamp equals a prior back-off's future lastAsk, so a caller |
| 2 | low | no | `script/DeployMainnet.s.sol:356` | DeployMainnet.verifySeeded is advisory and compares against the live pool: the vault accepts lock and draw from its constructor, so a raced first value prices the racer's own deposit before the check  |
| 3 | low | no | `src/CDPVault.sol:865` | CDPVault._resecure with a dead price leg keeps the position's whole secured term through a wipe, so principal repaid during a Chainlink or share-vault outage leaves a term sized for debt that no longe |
| 4 | low | no | `src/UsdPriceFeed.sol:43` | UsdPriceFeed.latestValue (and SharePriceFeed through it) reverts instead of reading zero when the ETH/USD answer is oversized, contradicting the 'anything unreadable reads as zero' contract that the v |
| 5 | info | no | `src/SwarmFeed.sol:114` | SwarmFeed NatSpec: MAX_ALLOWANCE_BPS 'keeps the packed uint32 exact' (the field is uint24 since 8756817) and 'Zero is rejected on both paths' (there is one path); the packing and every cast are correc |
| 6 | info | no | `src/SwarmFeed.sol:30` | SwarmFeed NatSpec 'moves at most the cap per hour however it is driven' is per epoch, not per sliding hour: two steps straddling an epoch boundary land 44% apart twelve seconds apart |
| 7 | info | no | `src/OracleAsker.sol:38` | OracleAsker NatSpec 'nobody can make a feed age faster' is false for a held attestation, which lands already aged; nearStale reads the signed issuedAt |
| 8 | info | no | `src/OracleAsker.sol:55` | OracleAsker NatSpec: the daily budget is 'all this contract can ever hold', but anyone can transfer IMD to the asker and ask() spends whatever it holds; the runbook itself prefunds it |
| 9 | info | no | `src/DeploymentConfig.sol:63` | DeploymentConfig.ATTESTATION_RELAYER NatSpec still says a zero relayer is 'documented as unsafe' by SwarmFeed.submitAttestation and that the relayer is a Sepolia deployment; submitAttestation now says |
| 10 | info | no | `src/PriceFeed.sol:38` | PriceFeed NatSpec says the pinned prefix 'has NOT been checked against a live attestation'; it reproduces the questionHash signed in the archived live attestation oracle/attestation-e2c85027.json byte |
| 11 | info | no | `src/SwarmFeed.sol:436` | Numbered answers and coverage: acceptance sound; the per-epoch bound holds at the cap per epoch (1.2/h price feeds, 1.2/day NHI) with the first step after H hours of silence 40% + 2.5%(H-2) (NHI: H-25 |

## 1. [LOW] OracleAsker.onOracleResult: the Treasury-paid test (lastAsk == inFlightAt) is satisfied by a caller-paid askPaid sent in the block whose timestamp equals a prior back-off's future lastAsk, so a caller

`src/OracleAsker.sol:273` — blocking: no; citation: resolved

```solidity
        bool treasuryPaid = live && f.lastAsk == f.inFlightAt;
```

Merged from four specialists (audit_permissions, audit_math, audit_economics, audit_flow); all four reproduce the same mechanism. The 8756817 fix for the final oracle panel's low #2 decides that the live request was the Treasury's own purchase by comparing two timestamps, on the reasoning at lines 266-268 that only `ask` writes lastAsk and inFlightAt together and no request can follow an `ask` within its second. But the catch branch at line 293 also writes lastAsk, to a FUTURE second: block.timestamp + ASK_TIMEOUT - ASK_MIN_INTERVAL = now + 6,600 s. 6,600 is a multiple of the 12-second slot, so on mainnet that instant is itself a block timestamp. In that block `ask` is still refused (TooSoon until lastAsk + 10 min) but `askPaid`/`askPaidMany` are not (lines 180-190: no interval check), and they write inFlightAt = block.timestamp = lastAsk. When the Intake later delivers that caller-paid request and the feed refuses it (the same signed attestation is public before the callback and SwarmRelay forwards for anyone, so a hand relay first makes the callback's relay revert ReplayedAttestation), `treasuryPaid` reads true and the catch writes lastAsk another 6,600 s out, landing exactly on the next slot boundary. Repeated, each cycle costs the caller the Intake's price (0.5 IMD) per two hours per feed and keeps Treasury-paid `ask` reverting TooSoon: the NHI keep-alive, an armed fall and a wide-open refresh are not bought with protocol money, which is the state the panel's low described (the keeper's own IMD remains the fallback, nothing is mispriced, so low as the panel rated it). The chain starts from any refusal of a Treasury purchase, which also needs no cause: hand-relaying the Treasury's own published answer before the Intake's callback makes that callback revert ReplayedAttestation and back the Treasury off two hours although its value landed. Reachable with the constants as committed (ASK_TIMEOUT 2 h, ASK_MIN_INTERVAL 10 min, 12 s slots; a missed slot costs one cycle). NatSpec claims the code does not have: lines 266-268 ('no request can follow an `ask` within its second') and 269-272 / 290-292 ('only the Treasury's own live purchase holds the Treasury back'). Smallest fix: record who paid instead of inferring it from timestamps: add `bool treasuryPaid` to `Feed` (the struct's second slot has spare bytes), set it in `ask` and clear it in `askPaid`/`askPaidMany` next to the inFlightAt write, and test `live && f.treasuryPaid` in the catch. Independently, do not back off on ReplayedAttestation / WindowNotAdvancing / StaleAttestation, which only say a value already landed or was overtaken.

**Reproduction.** test/scratch/Proof_fe155663af54.t.sol (the audit_economics proof, run by the judge: FAILS on this code with '949500 != 942600'). Fixture: SwarmRelay at ATTESTATION_RELAYER, a mock Intake at INTAKE selling oracle.request for 0.5 IMD, a 1-day/2000-bps keep-alive feed seeded at 0.9e18, asker holding 100 IMD, block.timestamp = 10 days (a multiple of 12). (1) T0+20h: ask(healthFeed, body) -> R1 (lastAsk = inFlightAt = T1). The Intake completes R1 with bytes the feed refuses: Delivered(relayed=false), feeds(healthFeed).lastAsk == T1 + 6600 (the Treasury's own back-off, expected). (2) vm.warp(T1 + 6600): ATTACKER approves 0.5 IMD and calls askPaid(healthFeed, body, 0.5e18) -> R2; feeds(healthFeed).inFlightAt == lastAsk (asserted). (3) +5 min: ATTACKER relays R2's attested answer through SwarmRelay by hand (accepted), then the Intake completes R2 with the same bytes: the callback's relay reverts ReplayedAttestation. EXPECTED (OracleAsker.sol:266-293): lastAsk unchanged at T1 + 6600 = 942600. ACTUAL: lastAsk == 949500 = (T1 + 6600 + 300) + 6600; the caller-paid refusal extended the back-off by two more hours, during which ask() reverts TooSoon. The test passes once the catch keys on an explicit Treasury-paid flag.


## 2. [LOW] DeployMainnet.verifySeeded is advisory and compares against the live pool: the vault accepts lock and draw from its constructor, so a raced first value prices the racer's own deposit before the check 

`script/DeployMainnet.s.sol:356` — blocking: no; citation: resolved

```solidity
        uint256 pool = asker.poolPrice();
```

Merged from four specialists (audit_permissions low, audit_math medium, audit_economics info, audit_flow low). Q4. The 8756817 fix for the final oracle panel's low #3 (an unbounded first value relayed by anyone) is an operator-side view run after the broadcast. Two gaps remain against the scenario it was written for. (1) It is not a gate. ParameterizedVault is live from its constructor: lock, lockIMD and draw run as soon as the three feeds hold fresh values, and runbook 7.1 step 5 ('only then open deposits') is an announcement with no on-chain switch. run() deploys the feeds (layer 2) several transactions before the vault and never seeds; verify() REQUIRES every feed stale (line 298). The feed addresses are pure functions of the source and the Intake bodies name them, so attester-signed attestations for the planned addresses can be bought before the broadcast (a window must close within maxAge/12 blocks of the relay) and relayed in the block the feeds land. SwarmFeed._checkValue applies no bound while !_hasValue, so the first relayer anchors each feed, and in the same block can draw against it up to LINE at mat 170. (2) The comparison reference is `asker.poolPrice()` at the moment the script runs: the same pool the attested window sampled. Held at the attested level through the check, price, spot and the pool agree and the check prints 'Seeded and verified'. It also never reads the vault, so it reports success over a vault whose LINE is already drawn. Cost of a failed check: the honest value is refused ExcessDeviation until the allowance reaches the gap (a 2x anchor needs 5,000 bps: six hours of silence after the raced relay; a 3x anchor 6,667 bps, thirteen hours), and any draw made against the raced value stands: at a 2x anchor a position drawn to LINE sits at or under 100% once the market lands, so about $200k of each $1M drawn is unrecoverable at mat 170 by any bite. The runbook's rollback table allows abandoning the stack only before anyone deposits, so the practical remedy is a redeploy with new salts if the race is noticed before the announcement. Kept at low, as the panel rated the race: it needs attestations bought for an unknown deployment hour over a pool held through a 13-sample window, the imdUSD drawn has no market on day one, and verify()'s stale requirement catches a race that lands before run() returns. NatSpec claims the code does not have: SwarmFeed.sol:372-375 ('a raced first value is caught before deposits open') and 236-238, and this function's @notice (lines 341-349). Smallest fix: seed in the deployment itself so no block exists in which a feed is unseeded and the vault live (buy the three attestations for the planned addresses before the broadcast and relay them in run() right after layer 2, before the vault; replace verify()'s `require(f.isStale())` with verifySeeded's bands); and in verifySeeded also require `vault.totalDebt() == 0` and `gem.balanceOf(vault) == 0`, and compare against a reference the moment's pool does not set (the operator's reference price passed as an argument, or a pool TWAP over the hours before).

**Reproduction.** test/scratch/FirstValueRace.t.sol (passes on this code: it demonstrates the state). ParameterizedVault over MockIMD with three SwarmFeed leaves (relayer SwarmRelay at ATTESTATION_RELAYER, data chain 1, cap 2000; price/spot 1 h, NHI 1 day), Chainlink etched at CHAINLINK_ETH_USD answering 2500e8, TreasuryFactory etched; all three feeds stale, as verify() requires. test_aRacedFirstValuePricesADrawBeforeAnyCheckCanRun: STRANGER relays attester-signed first values price 0.008 ETH (2x the 0.004 market), spot 0.008, NHI 0.9 through SwarmRelay: accepted, epoch anchor 2V, allowance 2000. Same block STRANGER lock(100_000e18) and draw(1_000_000e18): EXPECTED per the NatSpec no deposit is priced by a raced first value; ACTUAL draw succeeds, totalDebt == LINE, collateralRatio == 200. DEPLOYER's honest 0.004 attestation reverts ExcessDeviation now and at +5h59m59s; accepted at +6h; collateralRatio then reads 99. test_verifySeededPassesWhilePoolIsHeldAndADepositIsAlreadyPriced: after the same race and draw, `new DeployMainnet().verifySeeded(plan)` with the pool mock at the market reverts 'seeded: the price feed's first value is off the pool' (as designed, after the draw); with the pool mock at 2V it logs 'Seeded and verified' while vault.totalDebt() == LINE (asserted).


## 3. [LOW] CDPVault._resecure with a dead price leg keeps the position's whole secured term through a wipe, so principal repaid during a Chainlink or share-vault outage leaves a term sized for debt that no longe

`src/CDPVault.sol:865` — blocking: no; citation: resolved

```solidity
            ? (position.debt == 0 ? 0 : Math.min(before, position.collateral))
```

From audit_permissions; reproduced. Q5. The 8756817 fix for the final oracle panel's low #4 stopped a zero price from zeroing the term, but it keeps `before` whole whatever the position's new principal. `_secured` bounds every term by SECURED_COLLATERAL_MULTIPLE x principal / price (line 851), and that per-position bound is why securedCollateral exists (finding 7cd5035c). The ungated `wipe` (line 514) calls `_reduceDebt` -> `_resecure(position, _priceOrZero())` (line 1215); while UsdPriceFeed._ethUsd or SharePriceFeed._rateOf reads zero (a reverting or malformed Chainlink answer, or convertToAssets reverting: the cases the code handles by reading zero) the term written is min(before, collateral), not min(before, 2 x newPrincipal / lastPrice). A borrower who repays most of their principal during such an outage keeps a term sized for the old principal, and nothing re-prices it until that borrower is touched again (their own lock/free/draw/wipe, a redemption against them, or a bite); other actors' checkpoints leave it. `_securedCollateralValue` (line 757) counts it up to the aggregate cap prior x mat / 100, which is where the per-position bound was doing the work: when positions hold less than mat (a price fall, the state in which backing is below par and the redemption cap matters), the kept term fills the gap and `_backingPerUnit` (line 707) reads par. `cash` (line 662) then pays min(1, backing) x (1 - fee) of par from the Treasury's collateral first, so redeemers are overpaid from the reserve by the difference, and backingPerUnit() reports a backing the protocol does not have. The lag does not help: `_clampLag` only lowers lagged values and the wipe lowers neither securedCollateral nor the lag. Reachable with the constants as committed by any borrower; the amplifier is the outage (a stale Chainlink answer does not do this, only a reverting or malformed one), so low like the finding whose fix this is. The prior zeroing erred toward under-counting; this errs toward over-counting, the unsafe direction for the redemption cap. NatSpec claim the code does not have: lines 842-845 ('its collateral, bounded by the IMD that the multiple of its principal buys at that price') is not true of a term written while the leg is down. Smallest fix: with no price, shrink the term in proportion to the principal that remains rather than keeping it whole: pass the principal before the change into `_resecure` (or store it next to `secured`) and write `current = position.debt == 0 ? 0 : Math.min(Math.min(before, position.collateral), Math.mulDiv(before, position.debt, debtBefore))`. A term that shrinks with the principal never exceeds 2 x principal / lastPrice, so the per-position bound survives the outage.

**Reproduction.** test/scratch/DeadLegWipeKeepsTerm.t.sol (passes on this code: it demonstrates the state). Real ParameterizedVault over MockIMD priced $1 per 1e18 raw units (primary 5e14 wei per unit, an aggregator etched at CHAINLINK_ETH_USD answering 2000e8 at block.timestamp), NHI 0.9 (mat 170), reserve 100e18 units in the Treasury. B locks 1,000e18 and draws 500e18; A locks 2,000e18 and draws 500e18 (securedCollateral == 2,000e18: each term min(C, 2 x 500 / 1)); a day passes. Price falls to $0.30: backingPerUnit() == 0.63e18 ((100 + 2,000) x 0.3 / 1,000). vm.mockCallRevert on the aggregator's latestRoundData: collateralPriceFeed.isStale() is true; A calls wipe(490e18) and succeeds (ungated). Clear the mock. securedCollateral is still 2,000e18 with A owing about 10 imdUSD (EXPECTED at most 2 x 10 / 0.3 = 66.7 for A's term). backingPerUnit() == 1e18 (EXPECTED about 0.686e18 = (30 + (1,000 + 66.7) x 0.3) / 510). B's cash(25e18, 0, A) against the reserve pays more than 1.4x what the same cash pays after A's term is re-priced by any touch (A lock(1): backingPerUnit() then reads 0.686e18 within 1%), asserted.


## 4. [LOW] UsdPriceFeed.latestValue (and SharePriceFeed through it) reverts instead of reading zero when the ETH/USD answer is oversized, contradicting the 'anything unreadable reads as zero' contract that the v

`src/UsdPriceFeed.sol:43` — blocking: no; citation: resolved

```solidity
        value = Math.mulDiv(imdEth, ethUsd, 10 ** decimals);
```

From audit_math; reproduced. Q5. UsdPriceFeed documents (lines 18-22) and SharePriceFeed repeats (lines 28-34) that a missing, paused or malformed aggregator answer reads as zero so that no consumer reverts; _ethUsd refuses non-positive answers, zero or over-uint64 timestamps and more than 77 decimal places for exactly that reason. It does not bound the answer's magnitude. latestRoundData's answer is an int256; for any positive answer with imdEth x answer >= 2^256 x 10^decimals, Math.mulDiv reverts (OpenZeppelin v5 MathOverflowedMulDiv) because the RESULT does not fit, and the revert propagates: UsdPriceFeed.latestValue, ethUsdPrice and SharePriceFeed.latestValue all revert while isStale() answers false (it reads the same answer as well formed). Consumers: ParameterizedVault._priceOrZero -> collateralPriceFeed.latestValue() is read on the ungated paths that promise never to revert (lock, lockIMD, wipe via _reduceDebt -> _resecure, cover's `last = _priceOrZero()`), so a borrower can neither repay nor add collateral while the leg answers that way; the Treasury's reserve valuation is unaffected (it uses _boundedCall, which reads a failed call as nothing). At the committed scale (imdEth about 4e15, 8 decimals) the threshold is an answer above about 2.9e69 against a real answer of about 2.5e11: not a market condition, but exactly the 'malformed' class the two feeds say they absorb, and the same class (over-uint80 round ids, over-77 decimals) that earlier fixes in this file bounded. Low. Smallest fix: in _ethUsd, refuse an answer that cannot be a price, e.g. `if (uint256(answer) > type(uint256).max / 1e36) return (0, 0, 0);` (far above any real price, far below the overflow point), so the documented zero is what every consumer sees.

**Reproduction.** test/scratch/UsdLegOverflow.t.sol (passes on this code: it demonstrates the state). An aggregator etched at CHAINLINK_ETH_USD with 8 decimals and a settable answer; a never-stale IMD/ETH leg at 4e15; a ParameterizedVault over them with 1e18 of MockIMD locked. Answer 2500e8: usd.latestValue() == 4e15 x 2500e8 / 1e8 (correct). Answer 1e70 with a fresh timestamp: usd.isStale() == false; EXPECTED per the NatSpec latestValue() == (0, 0) and vault.lock(1e18) proceeds; ACTUAL usd.latestValue(), usd.ethUsdPrice() and vault.lock(1e18) all revert (MathOverflowedMulDiv).


## 5. [INFO] SwarmFeed NatSpec: MAX_ALLOWANCE_BPS 'keeps the packed uint32 exact' (the field is uint24 since 8756817) and 'Zero is rejected on both paths' (there is one path); the packing and every cast are correc

`src/SwarmFeed.sol:114` — blocking: no; citation: resolved

```solidity
    /// packed uint32 exact.
```

Merged from four specialists. The slot-3 repack in 8756817 (forge inspect: _updatedAt uint64 @0, _hasValue bool @8, _anchorAt uint40 @9, _anchorBound uint24 @14, _acceptedAt uint40 @17, _epochFirst uint80 @22; exactly 32 bytes) narrowed `_anchorBound` from uint32 to uint24 (line 144, whose own comment is right: 'so 24 bits are exact'), and `_accept` casts with uint24 (lines 475, 478). The constant's NatSpec at lines 113-114 and test/SwarmFeed.t.sol:600 still name uint32. Line 21 ('Zero is rejected on both paths') predates the removal of the reporter fallback; there is one path. Every cast checked (Q2): uint24(maxDeviationBps) <= 10,000 and uint24(bound) <= 1,000,000 < 16,777,216; uint40(block.timestamp) to year 36812; uint80(value) only when value <= type(uint80).max; uint64(_anchorAt) in epoch(). Documentation only.

**Reproduction.** Read src/SwarmFeed.sol:113-115 against line 144 (`uint24 private _anchorBound;`) and line 478 (`uint24(bound)`), and `forge inspect src/PriceFeed.sol:PriceFeed storage-layout`. EXPECTED per line 114 a uint32 field; ACTUAL uint24 at slot 3 offset 14, 3 bytes.


## 6. [INFO] SwarmFeed NatSpec 'moves at most the cap per hour however it is driven' is per epoch, not per sliding hour: two steps straddling an epoch boundary land 44% apart twelve seconds apart

`src/SwarmFeed.sol:30` — blocking: no; citation: resolved

```solidity
/// now a feed anyone keeps alive moves at most the cap per hour however it is driven. An epoch opened
```

From audit_economics; reproduced. Q2. The bound is exactly as `_checkValue`/`_epoch` state it: every value accepted within maxAge of an epoch's open lies within the allowance of the ANCHOR, and the next epoch anchors at whatever value was last accepted, with the cap because that value is fresh. Nothing holds the last value of one epoch and the first of the next apart in time, so a buyer who joins at the end of an honest epoch lands 1.2V in the epoch's last block and 1.44V in the next block, then 1.2 per hour. The figures the doc gives (2.07x at R+3h from the honest value at R) are right counted from the honest epoch's open; measured over any sliding hour the feed can move 44%, and from the buyer's first step 2.07x is two hours and one block. docs/PARAMETERS-2026-10-05.md 'a run of steps compounds at the cap per hour after the first' has the same imprecision (and 1.2^7 is 3.58, not 3.48). The precise statement is 'within one epoch, within the allowance of the anchor; consecutive epochs compound'. Documentation only; the sustained rate is unchanged.

**Reproduction.** test/scratch/InfoDemos.t.sol test_twoStepsStraddleAnEpochBoundaryTwelveSecondsApart (passes on this code). StepFeed (SwarmFeed, maxAge 1h, cap 2000): seed V at R; at R+3588 accept 1.2V; at R+3600 epoch() reports anchor 1.2V with allowance 2000 and 1.44V is accepted. EXPECTED per line 30: refused as a second step inside one hour; ACTUAL accepted.


## 7. [INFO] OracleAsker NatSpec 'nobody can make a feed age faster' is false for a held attestation, which lands already aged; nearStale reads the signed issuedAt

`src/OracleAsker.sol:38` — blocking: no; citation: resolved

```solidity
///     nobody can make a feed age faster. Price feeds are NOT kept fresh on a clock; their one-hour
```

Merged from audit_permissions and audit_flow; confirmed. `nearStale` (lines 301-306) measures age from `latestValue().updatedAt`, which SwarmFeed sets to the attestation's SIGNED issuedAt, and `submitAttestation` admits an issuedAt up to maxAge old (`_tooOld` is false at equality). A relayer who holds an NHI attestation 18 hours and then relays it puts in a value that is near stale the moment it lands, so `ask(nhi)` pays at once. It is one-for-one, not an amplifier: the held attestation cost its buyer the same 0.5 IMD the Treasury then spends, the value is genuinely 18 hours old, and it only works while no newer honest value has landed (StaleAttestation otherwise). The staleness trigger is still sound; only the sentence is wrong. The same held-relay asymmetry (freshness from the signature, silence from the relay) is the one 8756817 closed in `_allowanceNow`.

**Reproduction.** test/scratch/InfoDemos.t.sol test_aHeldAttestationLandsAlreadyAged (passes on this code). A 1-hour feed accepts a value whose issuedAt is exactly now - 1 hours; latestValue().updatedAt reads now - 1 hours (so nearStale's age x 10,000 >= maxAge x 7,500 at once), isStale() is false in the acceptance block and true one second later. EXPECTED per line 38 a relay cannot advance the feed's age; ACTUAL it arrives a full lifetime old.


## 8. [INFO] OracleAsker NatSpec: the daily budget is 'all this contract can ever hold', but anyone can transfer IMD to the asker and ask() spends whatever it holds; the runbook itself prefunds it

`src/OracleAsker.sol:55` — blocking: no; citation: resolved

```solidity
/// daily budget, which is all this contract can ever hold. Exhausting the budget does NOT freeze the
```

From audit_permissions; confirmed. Treasury.fundOracle tops the asker up to ORACLE_BUDGET_PER_DAY (Treasury.sol:509-511), but the asker is a plain IERC20 balance holder with no cap: a direct transfer (runbook 7.4(b) tells the operator to send a day's budget right after the deploy) raises what `ask` can spend, and `ask` is permissionless and spends from balance with only the per-feed ASK_MIN_INTERVAL, in-flight and price-ceiling limits. The bound that holds is the Treasury's own daily outflow, not the asker's holdings. No harm: extra IMD in the asker is only ever spent on attestations the chain shows a need for. The sentence should say the Treasury streams at most a day's budget, and whatever else the asker is given is spendable the same way.

**Reproduction.** test/OracleAsker.t.sol setUp mints 100 IMD to the asker (6.7 days of budget) and every ask() in that suite pays from it with no reference to oracleBudget. EXPECTED per line 55 at most 15 IMD held; ACTUAL any balance, and the shipped test fixture already holds 100.


## 9. [INFO] DeploymentConfig.ATTESTATION_RELAYER NatSpec still says a zero relayer is 'documented as unsafe' by SwarmFeed.submitAttestation and that the relayer is a Sepolia deployment; submitAttestation now says

`src/DeploymentConfig.sol:63` — blocking: no; citation: resolved

```solidity
/// which SwarmFeed.submitAttestation documents as unsafe for as long as questionHash binds a
```

Merged from three specialists; confirmed. 8756817 rewrote SwarmFeed.submitAttestation (lines 228-238) and the SwarmRelay header to say the relayer is not load-bearing on the shipped feeds: every shipped feed pins its question and SwarmRelay forwards for anyone. The constant's NatSpec (lines 62-78) still carries the pre-epoch claim it cites ('Zero would mean permissionless relay, which SwarmFeed.submitAttestation documents as unsafe') and describes the address as 'deployed to Sepolia', while DeployMainnet._refuseUnlessReady requires it to equal the planned mainnet SwarmRelay. A reader of the constant alone concludes the relayer guards the first value, which the final panel's low #3 and the verifySeeded fix both say it does not. Documentation only.

**Reproduction.** Read src/DeploymentConfig.sol:62-64 against src/SwarmFeed.sol:235-236 ('The relayer is not a trust boundary on the shipped feeds: it is SwarmRelay, which forwards for anyone'). The two sentences contradict each other; the code matches the latter (SwarmRelay.relay has no caller check).


## 10. [INFO] PriceFeed NatSpec says the pinned prefix 'has NOT been checked against a live attestation'; it reproduces the questionHash signed in the archived live attestation oracle/attestation-e2c85027.json byte

`src/PriceFeed.sol:38` — blocking: no; citation: resolved

```solidity
    /// yet, so this constant has NOT been checked against a live attestation.
```

From audit_economics; recomputed by the judge. keccak256(QUESTION_PREFIX || '26120928' || ',"toBlock":' || '26121526' || '}}') == 0xc87aa8a9fa49ca4885e3c3048e9159cd00578e7ad37188b1fce70199c510c16e, the questionHash in oracle/attestation-e2c85027.json (window 26120928..26121526, span 598, figure 3729511079526129, domain version 2). So PriceFeed's pinned prefix is verified against a live signature and the sentence at lines 36-38 is stale in the pessimistic direction. SpotFeed.sol:43 and NhiFeed.sol:36 still say 'Nothing has been bought with it yet' while docs/LAUNCH-READINESS.md says live NHI and SPOT attestations were proven on testnet; their request ids are not archived in this repository. Documentation and launch-record item: archive those two request ids (or re-verify with --verify before the freeze) and reword the three passages.

**Reproduction.** python3: prefix = bytes.fromhex(PriceFeed.QUESTION_PREFIX); doc = prefix + b'26120928,"toBlock":26121526}}'; `cast keccak` of doc prints 0xc87aa8a9...c510c16e, equal to message.questionHash in oracle/attestation-e2c85027.json. EXPECTED per the NatSpec: no live attestation checks the constant; ACTUAL: one in the repository does and matches.


## 11. [INFO] Numbered answers and coverage: acceptance sound; the per-epoch bound holds at the cap per epoch (1.2/h price feeds, 1.2/day NHI) with the first step after H hours of silence 40% + 2.5%(H-2) (NHI: H-25

`src/SwarmFeed.sol:436` — blocking: no; citation: resolved

```solidity
        uint256 since = _acceptedAt > _updatedAt ? _acceptedAt : _updatedAt;
```

Not a defect: the answers the task asks for where nothing is wrong, checked against the code and the shipped tests. Q1: the EIP-712 domain binds block.chainid and address(this), so an attestation signed for PriceFeed is refused by SpotFeed and by any other chain; usedRequests is per feed; issuedAt must be <= now, <= expiresAt, not older than maxAge and not older than the last accepted value; panelSize >= 25 and 15 <= agreed <= panelSize; the question hash is recomputed from the pinned prefix and the SIGNED fromBlock/toBlock, the span is bounded (300..1200 price, 150..1200 spot/NHI), toBlock must advance past lastToBlock, and on chain 1 (every mainnet feed) must be <= block.number and at most maxAge/12 blocks old; s is low and v is 27/28. No attestation for a different question, chain, feed or window is accepted. Q2: an epoch opens at the relay block and lasts maxAge; every value in it is within the stored bound of the anchor; the next epoch anchors at the last accepted value. Sustained rate from a fresh feed: (1 + cap) per maxAge in either direction, 1.2 per hour for price/spot (2.07x at 3 h, 3.58x at 6 h; 0.8/h down), 1.2 per DAY for NHI; two steps can straddle an epoch boundary (info above). Silence from the LATER of signature and relay (this line) earns the stale base only after a whole hour past the lifetime, so the largest single step after H hours of silence is 20% for H < 2, else 4,000 + 250 x (H - 2) bps (40% at 2 h, 50% at 6 h, 60% at 10 h, 100% at 26 h, the 1e6 cap at about 3,986 h); NHI the same with H - 25. A stale opening is slower than the cap per hour (1.4 per 2 h < 1.44), every acceptance resets the silence, holding an attestation back cannot help (test_aHeldAttestationDoesNotEarnTheStaleBase passes), and a wide epoch holds later values to the cap around its first. Every gap is followed as a delay. Packing and casts: see the info above. Q3: ask (keep-alive near stale, wideOpen = stale and no live epoch and allowance >= 6,000, armed fall), askPaid, askPaidMany, _request (feedOf survives a timeout) and onOracleResult behave as documented except the back-off gap (low above). Nobody can exceed the Treasury's daily outflow; a held attestation can advance the keep-alive one-for-one (info); no paid answer is lost (feedOf persists; a refused answer stays public). Q4: reported (low above). Q5: units are right throughout (imdEth x ethUsd / 10^dec = USD per 1e18 raw IMD; rate x assetUsd / 1e18 = USD per 1e18 raw sIMD, which _collateralRatio handles through its remainder path since the price is far below 1e16); a reverting, short or malformed Chainlink or share-vault answer reads as (0,0) and stale: gated paths revert StaleFeed, lock/lockIMD/wipe keep the secured term (with the over-counting gap above), cover with a zero last price requires fresh feeds, _clearIfRecovered preserves the mark, the Treasury counts the asset for nothing; the one exception is the oversized-answer revert (low above). Q6, at LINE $1M, mat 170, cap 2000, pool $2.3M a side at 1%: up, seven rungs over six hours from a fresh feed (six over five from a two-hour-silent one), each rung the 13-sample median held for 7 samples (about an hour) plus a single pushed block for spot; pool fees about $40k cumulative plus unbounded exposure to holders selling into it; prize: draw $1M against collateral worth $1M x 1.7 / 3.58 = $475k at market, then a self-liquidation after the correction leaves about $500k of imdUSD unbacked, which has no market on day one. Down: 0.8/h; two rungs (0.64) put every position at mat under water; the bonus is 20% of debt repaid, at most $200k on the whole LINE, less the loss on reselling seized sIMD into the dumped pool, and it needs the dump held through the six-hour grace. The hold-then-relay variant earns nothing since 8756817 (silence from the relay). What stops the walk is cost and visibility, not a gate: the Treasury never pays for a rise, and no honest value can land once the walk is two rungs ahead. Coverage: read in full Swar

**Reproduction.** Not a defect; the arithmetic above is checked against SwarmFeed._allowanceNow (lines 428-443), _accept (466-490), _checkValue (388-404), _requireQuestion (315-329) and the regression tests test_relayingAnHourApartNeverEarnsTheStaleBase and test_aHeldAttestationDoesNotEarnTheStaleBase, which pass on this tree.
