# Final pre-launch adversarial review — 2026-10-07

Job `d744e818-03e4-42ad-9cea-192ec55f49d6` (explorer: https://explorer.imd.fun/jobs/d744e818-03e4-42ad-9cea-192ec55f49d6), `adversarial-review`, pinned to `002605fdfe2610f12f957007f19ee2c6ee3147b1`.

Seat 687 (agent 52207), claude-fable-5-1 on claude, 57 turns, 30 min, 111,803 output tokens. Accepted on attempt 1. Submission hash `077db6979ab4dbfb2cef70c3b0d5101426e2bc80b1be651087f7e7fe2010253c`; raw record beside this file (`audit-final-2026-10-07-submission.json`, sha256 `91cfe639260b0e958ad7e269fabd6cabca475725bdb0a38608fb6912633b9c18`).

**Reviewer's summary:** partial review: the turn budget ran out with 6 finding(s) written. — the review is PARTIAL: of the nine numbered questions in the request, the findings cite Q1, Q4, Q5, Q7 and Q9; Q2 (askPaidMany), Q3 (the governed work-oracle slot), Q6 (the pinned bodies) and Q8 (the open items) are not addressed.

Payload: `whitepaper/requests/audit/audit-final-quote.json` in the operator's workspace (built by `build_audits.py`).

| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | high | yes | `src/SwarmFeed.sol:327` | SwarmFeed: the stale bound never widens, so a single-step market move above 40% (or 20% while fresh) can never be followed and the vault halts permanently |
| 2 | medium | no | `docs/PARAMETERS-2026-10-05.md:184` | PARAMETERS 'No rolling bound': the walk is profitable from a $1.53M line under the doc's own fee model (not ~$2M), and the fee model counts seven round trips per rung where one held ramp costs ~$39k f |
| 3 | medium | no | `docs/MAINNET-RUNBOOK.md:328` | Launch sequence: the Treasury holds no sIMD until the first liquidation, so the NHI keep-alive is unfunded and the vault halts 24 hours after the hand-seeded NHI value unless someone buys NHI updates  |
| 4 | low | no | `src/CDPVault.sol:528` | cover: a drained borrower re-locking ~2.8e-20 sIMD (one raw unit above the one-wei seizure) blocks cover for a full mark+grace cycle, repeatably and for free |
| 5 | low | no | `script/DeployMainnet.s.sol:95` | DeployMainnet NatSpec: 'OracleAsker asks on pool drift at HALF of this ... 10% drift' describes the trigger 84182f0 replaced (a quarter of the cap on falls, never on rises) |
| 6 | low | no | `script/DeployMainnet.s.sol:307` | DeployMainnet.verify never reads the two external links the Treasury-paid oracle path depends on: the Intake's IMD price for oracle.request and the pool slot behind poolPrice() |


## 1. [HIGH] SwarmFeed: the stale bound never widens, so a single-step market move above 40% (or 20% while fresh) can never be followed and the vault halts permanently

`src/SwarmFeed.sol:327` — blocking: yes; citation: resolved

```solidity
uint256 bound = _tooOld(_updatedAt) ? maxDeviationBps * STALE_DEVIATION_MULTIPLE : maxDeviationBps;
```

Q1/Q9. ce39fc6 replaced the lifted stale bound with STALE_DEVIATION_MULTIPLE x cap (40% at the launch cap of 2,000 bps), and the bound never widens further however long the feed has been stale. The pinned PriceFeed question is 'the median of 13 evenly spaced samples' of IMD's v4 pool and the SpotFeed question is the window's last block, and toBlock must be within maxAge/12 = 300 blocks of head. After a gap move of more than 40% (IMD moved 44.6% in one day, docs/MAINNET-RUNBOOK.md section 7.1; the parameters doc counts a -30.84% single trade as the observed worst day and the pool thins after each sale) every honest answer the swarm can sign is the post-move price: a step function sampled at any 13 blocks has a median equal to one of its two levels, and the spot reads one block. So every attestation reverts ExcessDeviation, for ever, unless the market itself returns to within 40% of the stale value. Both feeds are immutable, the vault pins them, and _requireFreshFeeds gates draw, free-with-debt, bark, bite, cash and cover's dust path: a healthy +50% rally in a quiet week (nobody pays for a rise: DRIFT_RISE_TRIGGER_OF_CAP_BPS = 0, the keeper never buys one) or a crash that two large sells produce freezes the whole protocol with no admin path and no redeploy path short of a new vault. In the fall case the Treasury also keeps paying: pool below feed by >5% arms, ask is bought every ASK_TIMEOUT after each refused delivery, 6 IMD a day per feed until the budget is gone. The NatSpec at src/SwarmFeed.sol:24-25 ('a genuine large move is followed in steps, each later step being fresh and so bounded normally') claims a property the code does not have: the intermediate steps require honest intermediate medians that a pinned recipe over a gapped pool cannot produce. The NHI feed shares the cap: a control-plane outage that drops the index from 0.9 below 0.54 (services down and participation halved) leaves NHI stuck until health recovers, and the vault halted once it is 24h old. Reachable with the constants as committed. Smallest fix: let the bound grow with staleness (e.g. multiply the cap by the number of whole lifetimes elapsed, or lift it after N lifetimes) so a stale-feed re-anchor costs an attacker N hours during which anyone can refresh honestly for 0.5 IMD, while a genuine gap is followed within N hours; or accept two attestations with advancing windows that agree within the cap. Either preserves the internal audit's intent (no single-attestation re-anchor) without making a gap terminal.

**Reproduction.** Feed at value V with updatedAt more than 1 hour old (its normal state). The pool gaps to 0.55V. submitAttestation with figure 0.55V (honest, correctly signed, advancing window within 300 blocks) -> expected: accepted at some point (the feed should be able to read the market); actual: ExcessDeviation on every attempt, every hour, for a week (test/scratch/FeedCannotFollowGapMove.t.sol, both tests fail: 45% fall and 50% rally). Meanwhile ParameterizedVault._pricingStale() is true and draw/bark/bite/cash all revert StaleFeed.

**Proof (the reviewer's test, verbatim).**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";

/// @dev A concrete SwarmFeed with the PriceFeed's launch policy (1-hour life, 2,000 bps cap) and an
/// attester whose key this test holds. No question prefix, so only the deviation bound is exercised:
/// the window rules are not what this finding is about.
contract GapFeed is SwarmFeed {
    constructor(address attester_, address relayer_) SwarmFeed(attester_, relayer_, 1, 3, 1 hours, 2_000) {}
}

/// @notice FINDING: a genuine single-step move larger than STALE_DEVIATION_MULTIPLE x the cap (40%)
/// can never be followed. `_checkValue` bounds every attestation against the last accepted value,
/// 20% while fresh and 40% once stale, and the bound never widens further however long the feed has
/// been stale. The pinned PriceFeed/SpotFeed questions read IMD's pool (a 13-sample median / the last
/// block), so after the pool gaps 45% (IMD moved 44.6% in one day per the runbook) every honest answer
/// is 0.55x the stale value and is refused with ExcessDeviation, forever, unless the market itself
/// returns to within 40% of the old value. The feed is immutable and the vault's price-dependent
/// actions (draw, free with debt, bark, bite, cash) require it fresh, so the protocol halts permanently.
///
/// The NatSpec says "a genuine large move is followed in steps, each later step being fresh and so
/// bounded normally" -- but the steps do not exist: a step function sampled at any 13 blocks has a
/// median equal to one of its two levels, and the spot feed reads one block.
///
/// This test fails on the committed code (the honest figure is refused at every attempt for a week)
/// and passes once the bound can widen with staleness, lift after a bounded number of lifetimes, or
/// accept two agreeing honest attestations.
contract FeedCannotFollowGapMoveTest is Test {
    uint256 private constant ATTESTER_KEY = 0xA11CE;
    uint256 private constant V = 1_000_000 gwei; // ~0.001 ETH per IMD, the live order of magnitude
    GapFeed private feed;
    uint256 private nonce;

    function setUp() public {
        vm.chainId(1);
        vm.warp(10 days);
        // This test is the relayer (SwarmRelay on mainnet, which anyone may call).
        feed = new GapFeed(vm.addr(ATTESTER_KEY), address(this));
        SwarmFeed.OracleAttestation memory a = _attestation(V);
        feed.submitAttestation(a, _sign(a));
        (uint256 value,) = feed.latestValue();
        assertEq(value, V);
    }

    function test_aFeedCanEventuallyFollowAGenuine45PercentGap() public {
        uint256 honest = V * 55 / 100; // the pool after a 45% fall; every honest answer is this
        bool followed;
        // One attempt an hour for a week: a single honest attestation, then a second honest one ten
        // blocks later (so a fix that wants two agreeing readings also passes).
        for (uint256 hour = 1; hour <= 7 * 24 && !followed; ++hour) {
            vm.warp(10 days + hour * 1 hours + 1);
            vm.roll(block.number + 300);
            followed = _trySubmit(honest);
            if (!followed) {
                vm.roll(block.number + 10);
                vm.warp(block.timestamp + 120);
                followed = _trySubmit(honest);
            }
        }
        (uint256 value,) = feed.latestValue();
        assertTrue(followed, "no honest attestation was ever accepted: the feed is bricked");
        assertEq(value, honest, "the feed should read the market");
    }

    /// @dev Companion: the same gap upward (a +50% rally while nobody bought a rise) is just as final.
    function test_aFeedCanEventuallyFollowAGenuine50PercentRally() public {
        uint256 honest = V * 150 / 100;
        bool followed;
        for (uint256 hour = 1; hour <= 7 * 24 && !followed; ++hour) {
            vm.warp(10 days + hour * 1 hours + 1);
            vm.roll(block.number + 300);
            followed = _trySubmit(honest);
        }
        assertTrue(followed, "no honest attestation was ever accepted: the feed is bricked");
    }

    function _trySubmit(uint256 figure) private returns (bool ok) {
        SwarmFeed.OracleAttestation memory a = _attestation(figure);
        bytes memory sig = _sign(a);
        try feed.submitAttestation(a, sig) {
            ok = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), SwarmFeed.ExcessDeviation.selector, "refused for another reason");
        }
    }

    function _attestation(uint256 figure) private returns (SwarmFeed.OracleAttestation memory a) {
        a.requestId = keccak256(abi.encode("request", ++nonce));
        a.chainId = 1;
        a.questionHash = keccak256("question");
        a.answerType = 3;
        a.answer = abi.encode(figure);
        a.figure = figure;
        a.fromBlock = uint64(block.number > 300 ? block.number - 300 : 0);
        a.toBlock = uint64(block.number);
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("panel");
        a.panelSize = 60;
        a.quorum = 20;
        a.agreed = 40;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(SwarmFeed.OracleAttestation memory a) private view returns (bytes memory) {
        bytes32 body = keccak256(
            bytes.concat(
                abi.encode(
                    feed.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ATTESTER_KEY, keccak256(abi.encodePacked("\x19\x01", feed.DOMAIN_SEPARATOR(), body)));
        return abi.encodePacked(r, s, v);
    }
}
```


## 2. [MEDIUM] PARAMETERS 'No rolling bound': the walk is profitable from a $1.53M line under the doc's own fee model (not ~$2M), and the fee model counts seven round trips per rung where one held ramp costs ~$39k f

`docs/PARAMETERS-2026-10-05.md:184` — blocking: no; citation: resolved

```solidity
$5M line makes the 3.48x walk worth ~$2.5M against ~$950k of fees. Any `proposeLine` above roughly HALF the
```

Q1. The multiplier arithmetic is right: with STALE_DEVIATION_MULTIPLE = 2 and a 2,000 bps cap, N attestations bought within one hour and relayed together move the value by at most 1.4 x 1.2^(N-1) (the first re-anchors a stale value at 40%, every later one is measured against a now-fresh value at 20%); six give 3.484. Nothing in SwarmFeed bounds N below the number of distinct advancing toBlocks inside the 300-block recency window, so N = 6 is an economic choice, not a contract limit. The window rules do not prevent the chain: with span 300 and a monotone pool path, window [T-300, T]'s 13-sample median is the sample at T-150, so six windows ending at B+150..B+155 have medians equal to the pool price at blocks B..B+5. Two errors in the cost arithmetic follow. (1) Using the doc's own per-rung fees ($58k, $93k, $130k, $174k, $221k, $273k, cumulative $281k/$455k/$676k/$949k at rungs 3-6) and gain = line x (1 - 1.7/m), the walk breaks even at line = $1.79M (2.016x), $1.53M (2.419x), $1.63M (2.903x), $1.85M (3.484x). The cheapest profitable walk flips at a $1.53M line, so the revisit rule's threshold ('roughly HALF the pool's depth (about $2M today)') is above the point where the attack is already positive: a proposeLine of $1.6M-$2M would pass the stated rule while the 4-rung walk nets ~$20k-$140k. (2) The $950k assumes the pool is pushed and restored at each of seven sample blocks per rung. An attacker who instead ramps the pool 20% per block at blocks B..B+5 and HOLDS it at 3.48x for the following 150 blocks produces the same six medians (samples before B sit at the base, the centre sample at the rung, samples after B+5 at the top) and the six spot readings at B..B+5, and pays one round trip: 841 x (sqrt(3.484) - 1) = 729 ETH (~$1.97M) in and out at 1% = ~$39k (rung 4 alone: ~$25k). At the committed $1M line the gain is $297k-$512k, so 'round-trip fees alone ... negative at every rung' does not hold across strategies; what actually defends the walk at launch is the attacker's exposure to IMD holders selling into a 3.5x pump during a ~30-minute hold, which the doc does not model. This is the one safety condition the doc attaches to raising line, so it should be restated with the hold model, a quantified exposure estimate, and a threshold at or below $1.5M (and lower if the pool thins). Doc inconsistency in the same file: line 36 still says the Treasury pays at 'half a feed's deviation bound'; the committed constants are a quarter of the cap on falls and never on rises.

**Reproduction.** Inputs as the doc states them: 841 ETH + 207,881 IMD, 1% fee, IMD $10.92 (ETH $2,699), mat 170, line $1M, cap 2,000 bps, STALE_DEVIATION_MULTIPLE 2. Expected per the doc: the walk is negative at every rung at today's line and flips only above ~$2M. Actual: cumulative doc fees / (1 - 1.7/m) gives $1.53M at m = 2.419 (four attestations), and one held ramp to 3.484x costs ~$39k in pool fees against a $512k gain at the committed $1M line. python3: X=841; eth=207881*10.92/X; fees=[58,93,130,174,221,273]; m=1.4; cum=0; for f in fees: cum+=f; print(m, cum/(1-1.7/m) if m>1.7 else None, X*(m**0.5-1)*eth*0.02); m*=1.2


## 3. [MEDIUM] Launch sequence: the Treasury holds no sIMD until the first liquidation, so the NHI keep-alive is unfunded and the vault halts 24 hours after the hand-seeded NHI value unless someone buys NHI updates 

`docs/MAINNET-RUNBOOK.md:328` — blocking: no; citation: resolved

```solidity
4. **Start the keeper** before announcing. An unattended protocol with live positions and no
```

Q5/Q9 (the Treasury-vault-asker seam at day zero). Treasury.fundOracle pays the asker only from sIMD the Treasury already holds (`available = maxWithdraw(treasury)`, Treasury.sol:494), and the Treasury's only sIMD income is the protocol's liquidation cut and cover's dust sweeps; stability fees arrive as imdUSD, which the Intake does not take. On a freshly deployed stack the Treasury holds nothing, fundOracle returns 0 without reverting, OracleAsker.ask(nhiFeed, body) reverts inside IIntake.request when the Intake pulls 0.5 IMD from an asker with no balance, and NhiFeed -- seeded by hand in runbook step 7.1 -- goes stale 24 hours later. _pricingStale() then refuses draw, free-with-debt, bark, bite, cash and cover's dust path for the whole vault until an NHI attestation is bought with askPaid. The keeper policy in docs/PARAMETERS-2026-10-05.md:190-192 buys with its own IMD only for a fall past the trigger and 'never to refresh a quiet stale price', so nothing in the documented sequence keeps NHI alive until the first liquidation happens to land sIMD in the Treasury (and 15 IMD/day of budget needs ~2 sIMD a day thereafter). Neither verify() nor the runbook's section 7 checks or seeds the oracle budget. Smallest fix: a runbook step before announcing that transfers IMD straight to ORACLE_ASKER (fundOracle tops up only to the budget, so prefunding the asker is harmless) or sIMD to the Treasury sized for N days of NHI asks, plus a line in verify()/the keeper's start-up that refuses to run while asker IMD + Treasury maxWithdraw < one day's budget; or have the keeper's fallback cover a near-stale keep-alive feed as well as a fall.

**Reproduction.** State: stack deployed per DeployMainnet; three feeds seeded by hand (runbook 7.1); no deposits yet or only healthy ones. t = seed + 18h: OracleAsker.nearStale(nhiFeed) is true; Treasury.fundOracle() returns 0 (Treasury sIMD balance 0, maxWithdraw 0); OracleAsker.ask(nhiFeed, nhiBody) -> expected: a request is bought; actual: reverts in the Intake's transferFrom (asker IMD balance 0; with the rehearsal's MockIntake: ERC20InsufficientBalance). t = seed + 24h + 1s: NhiFeed.isStale() == true; ParameterizedVault.draw(1) reverts StaleFeed, bark/bite/cash likewise. The fork rehearsal does not reach this state because it never advances 24 hours and seeds NHI by storage write each time it warps.


## 4. [LOW] cover: a drained borrower re-locking ~2.8e-20 sIMD (one raw unit above the one-wei seizure) blocks cover for a full mark+grace cycle, repeatably and for free

`src/CDPVault.sol:528` — blocking: no; citation: resolved

```solidity
if (position.collateral >= _oneWeiSeizure(price)) revert NoRealizedBadDebt();
```

Q4 (the lock(1) freeze, F2). The dust path sweeps collateral strictly below _oneWeiSeizure(price) = 1.2e18 / price raw units, which at the launch sIMD price (~8.7e13 per 1e18 raw) is ~13,800 raw units, i.e. 1.4e-20 sIMD. Collateral of that seizure plus one unit is worth nothing but is 'collateral a bite could still reach', so cover reverts NoRealizedBadDebt and the only way back to a coverable position is bark, the full lull (6 h at NHI >= 0.85) and a bite that pays the liquidator ~14k raw units. Unlike accepted finding D9 (re-collateralising to health costs a real, fee-paying position), this costs the drained borrower one lock transaction per cycle and no capital, so the Treasury imdUSD held behind BadDebtFirst (Treasury.withdraw, payStream) for that position's record can be kept there indefinitely by a borrower who re-locks after each bite; totalBadDebt also keeps growing with fees meanwhile (internal audit info 8). Griefing only: no funds move to the attacker. Not reachable while a mark is live (a one-wei bite sweeps it at once), so the cadence is one lock per grace+tail (~7 h). Smallest fix: let cover sweep any collateral whose value at `price` is below some floor that is dust in economic terms (e.g. below 1e-6 of the position's debt, or below the seizure for `debt / 1e6` wei), or allow cover on a marked position once its grace has elapsed.

**Reproduction.** test/scratch/CoverDustAboveSeizure.t.sol (passes: it demonstrates the state). Borrower locks 20e24 raw, draws 1,000 imdUSD; price halves; bark; +6h; bite drains the position (bad debt 276.7); cover(borrower, 1e18) succeeds. Mark expires (+1h+1s); borrower lock(27,650) raw (one above _oneWeiSeizure = 27,649 at the halved price). Expected: cover(borrower, 1e18) burns Treasury imdUSD against the realized bad debt. Actual: NoRealizedBadDebt; bite(borrower, 1) reverts MarkExpired; after bark it reverts GracePeriodNotElapsed for 6 hours; only then does a 1-wei bite sweep the dust and cover work again, and the borrower can lock again.


## 5. [LOW] DeployMainnet NatSpec: 'OracleAsker asks on pool drift at HALF of this ... 10% drift' describes the trigger 84182f0 replaced (a quarter of the cap on falls, never on rises)

`script/DeployMainnet.s.sol:95` — blocking: no; citation: resolved

```solidity
/// HALF of this, so 2000 means a Treasury-paid update at 10% drift and a refusal past 20%.
```

Q7/comment audit. The comment on FEED_MAX_DEVIATION_BPS still states the symmetric half-cap trigger. The committed constants are DRIFT_FALL_TRIGGER_OF_CAP_BPS = 2,500 (a 5% fall) and DRIFT_RISE_TRIGGER_OF_CAP_BPS = 0 (never for a rise), and OracleAsker.triggerBps returns (500, 0) for a 2,000 bps feed. Same stale statement at docs/PARAMETERS-2026-10-05.md:36 ('drifted more than half a feed's deviation bound'), which the Final confirmation section of the same file contradicts. Also unmentioned: the refusal past 20% is only while the value is fresh; past 40% once stale. Fix: restate as a quarter of the cap on a fall, never on a rise, 20%/40% fresh/stale.

**Reproduction.** Deploy per the script and call OracleAsker.triggerBps(priceFeed): expected per the comment (1000, 1000); actual (500, 0). With the pool 8% BELOW the feed, arm() succeeds; with the pool 8% (or 19%) ABOVE the feed, arm() reverts NotNeeded, contrary to the comment's 'Treasury-paid update at 10% drift'.


## 6. [LOW] DeployMainnet.verify never reads the two external links the Treasury-paid oracle path depends on: the Intake's IMD price for oracle.request and the pool slot behind poolPrice()

`script/DeployMainnet.s.sol:307` — blocking: no; citation: resolved

```solidity
require(tracksPool == tracks[i] && keepAlive == alive[i], "asker: wrong trigger policy");
```

Q5/Q7. verify() reads back every wiring link between contracts this script deploys, but not the two reads that decide whether the Treasury ever pays for an update: (1) OracleAsker.price() = IIntake(INTAKE).priceOf(ORACLE_ACTION, IMD). If the swarm's Intake does not list IMD for 'oracle.request@oracle-1', or lists it above ASK_MAX_PRICE (1 IMD), every ask() reverts NotSold / PriceTooHigh, the NHI keep-alive never fires, NhiFeed goes stale 24 h after its first seed and the vault halts; the preflight checks only INTAKE.code.length. ASK_MAX_PRICE is a constant, so the only recovery is askPaid by hand at whatever price. (2) OracleAsker.poolPrice() != 0: IMD_POOL_ID and the extsload slot (keccak256(poolId, 6)) are pinned constants; a wrong id reads as 'no drift' forever and the Treasury never pays for a fall (I read the slot live on 2026-10-07: sqrtPriceX96 = 1330305773205498520043022607746, i.e. IMD ~0.00355 ETH, so the committed constants are right today, but nothing in the script proves it at deploy time). Other values not read back: Parameters.gap (50), parameters.workOracle() == 0, usdPriceFeed.maxAge() == 1 hour, triggerBps(feed) == (500, 0). Smallest fix: in verify(), require asker.price() != 0 && asker.price() <= ASK_MAX_PRICE, require asker.poolPrice() != 0, require vault.gap() == 50 and parameters.workOracle() == address(0).

**Reproduction.** Run `forge script script/DeployMainnet.s.sol --sig 'verify((address,address,address,address,address,address,address,address,bytes,bytes,bytes))'` (or run()) against a fork where the Intake at INTAKE has code but priceOf(ORACLE_ACTION, IMD) returns 0 (the rehearsal's MockIntake before setPrice does exactly this): expected: verification fails naming the dead Treasury path; actual: 'Deployed and verified' is printed, and the first OracleAsker.ask(nhiFeed, body) on the live stack reverts NotSold.

