# Launch audit, phase 2 — adversarial review (2026-10-05)

Job `5e2f7703-9fe2-4c2b-bf7d-cbafd53fb4bf`, `adversarial-review` at `03e8d0c` (the phase-1 fixes), accepted attempt 1, claude-opus-5-5. Raw submission: `audit-adversarial-2026-10-05-submissions.json`.

## Reviewer's summary

I found two medium, three low and one info finding, and nothing critical or high. They are in `.imd-findings.json`, most severe first. I changed no tracked files; the scratch tests are deleted. Each of the four findings that carries a proof has a self-contained Foundry test, and each fails on this commit for the stated reason. The dotfiles that `git status` lists as untracked were already in the working directory and aren't mine.

## Findings

1. **Medium: the redemption half of D1 is open at launch.** `src/ParameterizedVault.sol:110`, `_lagApplies` returns `parameters.wage() != 0`.
   - **Why the stated reason fails:** the plan keeps the lag dormant because it's about work minting. But `cash` can take the reserve at par with no work minting at all.
   - **Failing state:** at launch (wage 0), a 70% price fall leaves `backingPerUnit` at 0.64. In one block, an attacker sends two transactions: lock 1000 + draw 100, then `cash(3e18)`. The Treasury's reserve pays 9.875 IMD; at 0.64 backing it should pay 6.22. Then they repay and withdraw. No time passes, so they pay no fee and carry no price risk.
   - **Fix:** apply the lag whatever the wage. With the wage raised through governance, the same sequence pays 3.11.

2. **Medium: `OracleAsker` can only ever land one attestation per feed.** `src/OracleAsker.sol:141`.
   - **Why:** it fixes each request body by hash at construction, and the body carries a literal block window (the NHI body in `oracle/` has 26,099,000–26,100,000). The feeds refuse any window that doesn't advance, and since the F1 fix, any window that closed too long ago.
   - **Effect:** every paid ask after the first is refused. The F4 fix (the callback no longer reverts) now swallows the refusal, so the near-stale NHI feed is re-bought every 10 minutes until the daily budget is gone. The bodies the feeds actually name aren't in the repo, so this assumes they also carry a literal window.
   - **Failing input:** a feed bound like `NhiFeed`. The first ask lands 0.9. The second ask, 20 hours later, is paid for and refused with `WindowNotAdvancing`, and the feed still reads 0.9.

3. **Low: the lag warms up exponentially, not linearly.** `src/CDPVault.sol:812`. Every checkpoint re-bases the warm-up, and any account's lock, draw or wipe is a checkpoint. With one-wei locks every hour, 1000 of debt held a full day is credited at 639.9, not 1000. `earnLine` reads about 160 instead of 250.

4. **Low: the F9 fix is incomplete.** `src/ParameterizedVault.sol:259`. A listed reserve value that fits in 256 bits but sits near the top still overflows `earnLine`, `backingPerUnit` and `cash`. Failing input: one whole token listed with a price of `type(uint256).max`; all three revert.

5. **Low: the F6 fix is incomplete.** `src/CDPVault.sol:535`. Stability fees that `cover` re-mints to the Treasury never reach `totalReceived`. Your own regression test passes only because no fees accrue before it calls `cover`. With 90 days of fees it fails: 36.49 recorded against 36.81 expected.

6. **Info: seven comments claim properties the code doesn't have.** One example: `DeploymentConfig.sol:199` says "a stale tally grants nothing NEW", but `claim` never checks staleness. The full list is in the file.

## What I read

- **Read in full:** `CDPVault`, `ParameterizedVault`, `Treasury`, `TreasuryFactory`, `Parameters`, `Governed`, `ImdUSD`, `SwarmFeed`, `PriceFeed`, `NhiFeed`, `SpotFeed`, `SwarmRelay`, `OracleAsker`, `UsdPriceFeed`, `SharePriceFeed`, `SwarmWorkOracle`, `WorkOracleFactory`, `DeploymentConfig`, `Registry`, and the interfaces.
- **Skipped as out of scope:** the mocks (`MockIMD`, `MockWorkOracle`, `LaunchToken`), `script/`, `web/` and `points/`.
- **Couldn't reach:** sIMD's own contract, the Intake, and the request bodies under `whitepaper/requests/`, which are not in the repo. So I couldn't check share-price manipulation, the Intake's real behaviour, or exactly which window the production bodies carry.

Every other accepted item's stated reas

## 1. [medium] D1's redemption half is open at launch: the lag is gated on wage != 0, but fresh capital one transaction old (same block, zero interest) still lifts backingPerUnit to par and cash takes the Treasury r

`src/ParameterizedVault.sol:110`

D1 (vault panel, medium) has two halves: borrow -> earn -> unwind (work minting) and borrow -> cash -> unwind ('a redemption took the reserve at par while backing was 0.4'). The plan and the NatSpec (CDPVault.sol:281-289, ParameterizedVault.backedDebt) keep the fix DORMANT 'until minting from work is switched on', i.e. while WAGE_WAD = 0, on the stated reason that it is about work minting. That reason is wrong for the redemption half: `cash` reads `_backingPerUnit` -> `_securedCollateralValue`, whose only defence at wage 0 is the same-TRANSACTION transient tally. Backing below par needs no work minting: any price fall that leaves positions underwater before they are liquidated, or any realized bad debt (subtracted from `prior` and outstanding until covered), puts it there. An attacker then sends two transactions in the same block (a bundle): tx1 lock + draw (fresh secured collateral and principal), tx2 `cash` — the transient tally is empty, the fresh capital counts in full, backingPerUnit jumps to 1.0 and the reserve (Treasury sIMD, which `cash` spends first) is paid at (1 - fee) of par instead of at the true backing; tx2/tx3 wipe and free. No time passes, so no stability fee and no price exposure. Loss to remaining imdUSD holders = reserve paid x (1 - true backing), repeatable while backing stays below par. With the lag applied (it is already tracked from deployment) the same sequence pays at or below the pre-existing backing.

**Reproduction**

Launch constants (wage 0, mat 170 at NHI 0.85). MockIMD at $1; honest lock 200e18 / draw 100e18; Treasury holds 10e18 collateral (its reserve). Warp 1 day; IMD falls to $0.30: backingPerUnit() = 0.64e18. Same block, tx1: attacker lock(1000e18), draw(100e18). tx2: attacker cash(3e18, 0, address(0)) (fee 125 bps; funded wholly by the reserve). Expected per D1's fix: payout at the pre-existing backing, 3e18 x 0.64 x 0.9875 / 0.30 = 6.22e18 IMD. Actual: 9.875e18 IMD (par less fee); backingPerUnit() read 1.0e18 in tx2. tx3: wipe(97e18), free(950e18) unwinds. Raising the wage through governance first (lag on) makes the same sequence pay 3.11e18. Smallest fix: make `_lagApplies` (or at least the redemption path's use of it in `_securedCollateralValue`) unconditional — the lag is already maintained from deployment, so nothing else changes; keep the wage gate only for backedDebt/earnLine if desired.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract DFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 public value;

    constructor(uint256 v) {
        value = v;
    }

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract DMirror is ISwarmFeed {
    ISwarmFeed private immutable p;

    constructor(ISwarmFeed p_) {
        p = p_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return p.latestValue();
    }

    function isStale() external view returns (bool) {
        return p.isStale();
    }

    function maxAge() external view returns (uint256) {
        return p.maxAge();
    }
}

contract DAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice D1's REDEMPTION half needs no work minting, yet its fix (the lagged backing) is gated on
/// `wage() != 0` and so is off at launch (WAGE_WAD = 0). After a price fall leaves backing below par,
/// capital brought in ONE transaction earlier (same block, no interest, no price exposure) lifts
/// backingPerUnit to 1.0 and the next transaction redeems the Treasury's reserve at par.
/// Each top-level call below is its own transaction (isolate), so transient storage clears between them.
contract DormantRedemptionLagTest is Test {
    address private constant HONEST = address(0x40E);
    address private constant ATTACKER = address(0xBAD);
    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    DFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new DAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new DFeed(uint256(1 ether) * 1e18 / 2000 ether); // $1 per IMD
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(new DFeed(0.85 ether)), address(new DMirror(primary))
        );
        stable = vault.stablecoin();
        assertEq(vault.parameters().wage(), 0, "launch configuration: lag dormant");
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(HONEST, 200 ether);
        imd.mint(ATTACKER, 1_000 ether);
        imd.mint(address(vault.treasury()), 10 ether); // the Treasury's reserve (liquidation cuts, dust)
        vm.stopPrank();
        vm.prank(HONEST);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(ATTACKER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(HONEST);
        vault.lock(200 ether);
        vm.prank(HONEST);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7_200);
        // IMD falls 70%; the honest position is underwater and not yet liquidated (grace).
        primary.set(uint256(0.3 ether) * 1e18 / 2000 ether);
    }

    /// forge-config: default.isolate = true
    function test_freshCapitalOneTransactionOldDoesNotLiftTheReservePayoutAtLaunch() public {
        uint256 before = vault.backingPerUnit();
        assertLt(before, 0.7e18, "backing is ~0.64 after the fall");

        // Transaction 1: real capital, in the same block.
        vm.prank(ATTACKER);
        vault.lock(1_000 ether);
        vm.prank(ATTACKER);
        vault.draw(100 ether);

        // Transaction 2, same block: redeem 3 imdUSD; the Treasury's reserve alone funds it.
        uint256 feeBps = vault.redemptionFeeBps(3 ether);
        uint256 reserveBefore = imd.balanceOf(address(vault.treasury()));
        vm.prank(ATTACKER);
        uint256 gemOut = vault.cash(3 ether, 0, address(0));
        assertEq(reserveBefore - imd.balanceOf(address(vault.treasury())), gemOut, "paid from the reserve");

        // What D1's fix promises: the payout scale is the backing that stood before this capital arrived.
        uint256 price = uint256(0.3 ether); // USD per IMD, as the vault reads it
        uint256 fair = Math.mulDiv(3 ether, Math.mulDiv(before, 10_000 - feeBps, 10_000), price);
        emit log_named_decimal_uint("reserve IMD paid", gemOut, 18);
        emit log_named_decimal_uint("at the pre-existing backing", fair, 18);
        assertLe(gemOut, fair + 1e9, "fresh capital must not let a redemption take the reserve at par");

        // Transaction 3: unwind. Only 3 imdUSD of the 100 drawn stays owed; the rest of the capital leaves.
        vm.prank(ATTACKER);
        vault.wipe(97 ether);
        vm.prank(ATTACKER);
        vault.free(950 ether);
    }
}
```

## 2. [medium] OracleAsker pins each request body (and so its block window) forever; bound feeds refuse every repeat, so Treasury-paid asks after the first buy attestations that can never land, and F4 hides it

`src/OracleAsker.sol:141`

Seam Treasury -> OracleAsker -> Intake -> SwarmRelay -> SwarmFeed. `feeds[feed].bodyHash` is fixed in the constructor and `ask`/`askPaid` accept only that exact body. The oracle.request body carries the question's block window (oracle/nhi-composite-quote.json, the only NHI body in the tree: "window":{"fromBlock":26099000,"toBlock":26100000}; docs/AUDIT-ORACLE-2026-10-05.md item 2: 'The attester signs windows the buyer pins'), and every shipped feed binds that window: SwarmFeed._requireQuestion refuses a toBlock that does not advance past lastToBlock and, since F1, a toBlock more than maxAge/12 blocks behind the head on chain 1. So with a hash-pinned body the asker can land at most ONE attestation per feed for its lifetime; after F1 it lands none once the head is maxAge/12 blocks past the body's toBlock (300 blocks for the 1h price/spot feeds, 7,200 for NHI; mainnet was already at ~26,122,901 on 2026-10-05, i.e. the in-tree NHI window is refused today). Before F4 the refusal reverted the callback; F4 now catches it and only emits Delivered(relayed=false), so the keep-alive NHI feed stays nearStale and `ask` (permissionless) re-buys every ASK_MIN_INTERVAL until the asker's balance is gone; fundOracle (permissionless) refills it daily. Result: the whole oracle budget (10 IMD/day, ~$110/day at the committed constant) is spent on attestations the feeds must refuse, `askPaid` (the documented way a borrower buys a fresh price) also buys refused answers, and the 'prices on demand' design in docs/PARAMETERS-2026-10-05.md has no working on-chain path, so marks/bites/redemptions stay paused until someone buys and relays off chain. The OracleAsker suite never pairs the asker with a bound feed (it uses unbound ConfigurableSwarmFeeds and window-less bodies), which is why it passes. Conditional on the frozen bodies carrying a literal window, as the in-tree NHI body does; if the production bodies use a service-resolved relative window this reduces to the price span check (oracle/price-oracle-quote.json's {"hours":24} = 7,200 blocks exceeds PriceFeed's 1,200-block maxSpan).

**Reproduction**

Chain id 1, head 26,100,050. A SwarmFeed bound exactly like NhiFeed (prefix + spliced window, span 150..1200, maxAge 1 day, relayer SwarmRelay at ATTESTATION_RELAYER) and an OracleAsker(keepAlive) whose body is '{"q":"network health","window":{"fromBlock":26099000,"toBlock":26100000}}'; the Intake records the body and the swarm answers the window written in it. ask -> delivery: accepted (0.9e18). Warp 20h, roll 6,000 blocks: the feed is nearStale, ask(feed, BODY) pays 0.4 IMD, delivery of the body's window -> SwarmFeed reverts WindowNotAdvancing(26100000, 26100000), OracleAsker catches it and emits Delivered(relayed=false). Expected: the paid update reaches the feed (0.88e18). Actual: the feed still reads 0.9e18 and the asker's IMD is spent; the same call repeats every 10 minutes. Smallest fix: pin the body's PREFIX (the window-less part, as the feeds pin the question prefix) and have `ask` build or accept a window suffix it checks itself (toBlock <= block.number, toBlock > feed.lastToBlock(), within the feed's span and maxAge/12), or pin a service-resolved relative window and test the asker against a bound feed; and stop re-asking a feed whose last paid delivery was refused (e.g. keep lastAsk-based backoff until a delivery lands).

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleAsker} from "src/OracleAsker.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {SwarmRelay} from "src/SwarmRelay.sol";
import {MockIMD} from "src/MockIMD.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {APPROVED_OPERATOR, ATTESTATION_RELAYER, INTAKE, ORACLE_ACTION} from "src/DeploymentConfig.sol";

/// @dev A feed bound to a question exactly the way PriceFeed/NhiFeed/SpotFeed are: a pinned prefix, the
/// signed window spliced in, NhiFeed's span bounds, relayed only through SwarmRelay, data chain 1.
contract BoundNhiFeed is SwarmFeed {
    constructor(address attester_) SwarmFeed(attester_, ATTESTATION_RELAYER, 1, 3, 1 days, 2_000) {}

    function questionPolicy() internal pure override returns (bytes memory, uint64, uint64) {
        return ('{"q":"network health","window":{"fromBlock":', 150, 1_200);
    }
}

/// @dev The Intake's request side: takes the price and records the body it was asked to answer.
contract RecordingIntake {
    mapping(bytes32 => bytes) public bodyOf;
    uint256 public nonce;

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.4 ether;
    }

    function request(bytes32, bytes calldata body, IIntake.Callback calldata, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(++nonce));
        bodyOf[id] = body;
    }
}

/// @notice OracleAsker pins each feed's request body by hash for its whole life, and a request body
/// pins the question's block window (oracle/nhi-composite-quote.json: "window":{"fromBlock":26099000,
/// "toBlock":26100000}; the attester "signs windows the buyer pins", docs/AUDIT-ORACLE-2026-10-05.md).
/// A bound feed accepts a window only if toBlock advances and (F1) closed within maxAge/12 blocks. So
/// every Treasury-paid `ask` after the first buys an attestation the feed must refuse, and F4's
/// try/catch swallows the refusal: the keep-alive feed stays near-stale and is re-asked (and paid for)
/// every ASK_MIN_INTERVAL until the daily budget is gone.
contract AskerPinnedWindowTest is Test {
    uint256 private constant KEY = 0xA11CE;
    bytes private constant BODY = '{"q":"network health","window":{"fromBlock":26099000,"toBlock":26100000}}';
    MockIMD private imd;
    BoundNhiFeed private feed;
    OracleAsker private asker;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_100_050);
        vm.warp(1_791_000_000);
        vm.etch(ATTESTATION_RELAYER, address(new SwarmRelay()).code);
        vm.etch(INTAKE, address(new RecordingIntake()).code);
        imd = new MockIMD();
        feed = new BoundNhiFeed(vm.addr(KEY));
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(BODY);
        bool[] memory tracks = new bool[](1);
        bool[] memory keepAlive = new bool[](1);
        keepAlive[0] = true; // NHI: the Treasury keeps it alive
        asker = new OracleAsker(IERC20(address(imd)), feeds, hashes, tracks, keepAlive);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(asker), 10 ether); // one day's budget, as fundOracle tops it up
    }

    /// @dev The swarm answers the window written in the body it was sold.
    function _answer(bytes32 id, uint256 figure) private {
        bytes memory body = RecordingIntake(INTAKE).bodyOf(id);
        uint64 from = _number(body, '"fromBlock":');
        uint64 to = _number(body, '"toBlock":');
        SwarmFeed.OracleAttestation memory a = SwarmFeed.OracleAttestation({
            requestId: id,
            chainId: 1,
            questionHash: feed.expectedQuestionHash(from, to),
            answerType: 3,
            answer: abi.encode(figure),
            figure: figure,
            fromBlock: from,
            toBlock: to,
            blockHash: bytes32(0),
            panelJobId: bytes32(0),
            panelSize: 25,
            quorum: 15,
            agreed: 25,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    feed.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType,
                    keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", feed.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(INTAKE);
        asker.onOracleResult(id, a, abi.encodePacked(r, s, v));
    }

    function _number(bytes memory body, bytes memory key) private pure returns (uint64 n) {
        for (uint256 i; i + key.length <= body.length; ++i) {
            bool hit = true;
            for (uint256 j; j < key.length; ++j) {
                if (body[i + j] != key[j]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;
            for (uint256 k = i + key.length; k < body.length && body[k] >= "0" && body[k] <= "9"; ++k) {
                n = n * 10 + uint8(body[k]) - 48;
            }
            return n;
        }
    }

    function test_theTreasuryPaidAskerKeepsAKeepAliveFeedAlive() public {
        bytes32 first = asker.ask(address(feed), BODY);
        _answer(first, 0.9 ether);
        (uint256 value,) = feed.latestValue();
        assertEq(value, 0.9 ether, "the first purchase lands");

        // 20 hours later the feed is near stale (75% of maxAge) and the Treasury buys its next update.
        vm.warp(block.timestamp + 20 hours);
        vm.roll(block.number + 6_000);
        uint256 spentBefore = imd.balanceOf(address(asker));
        bytes32 second = asker.ask(address(feed), BODY);
        _answer(second, 0.88 ether);
        assertLt(imd.balanceOf(address(asker)), spentBefore, "the Treasury paid for it");
        (value,) = feed.latestValue();
        assertEq(value, 0.88 ether, "and the paid-for update reached the feed");
    }
}
```

## 3. [low] D1 lag warms up exponentially, not linearly: any checkpoint re-bases the warm-up, so capital held a full BACKING_WARMUP is credited ~64%, not 100%

`src/CDPVault.sol:812`

CDPVault documents the D1 lag as 'An increase is credited linearly over BACKING_WARMUP ... Full credit costs real capital held, and paying the stability fee, for the whole warm-up' (CDPVault.sol:283-289, repeated in ParameterizedVault.backedDebt and _securedCollateralValue). `_approach` closes elapsed/BACKING_WARMUP of the REMAINING gap and `_advanceLag` re-bases `laggedAt` at every checkpoint, and every lock/lockIMD/free/draw/wipe/bite/cash/cover by ANY account is a checkpoint (via `_resecure`/`draw`). With activity the credit follows 1-(1-dt/1d)^(1d/dt) -> 1-1/e: a step increase held for a full day is credited 63-64%, ~86% after two days, ~95% after three. Live consequences once the wage is raised: earnLine and backingPerUnit stay understated for days after any honest inflow, so `cash` pays redeemers below par (payoutScale = backingPerUnit*(1-fee)) while the candidate's debt is cancelled at face value; and anyone can hold the credit down for one wei of collateral per poke (lock(1)). Direction is conservative (no over-credit found), so low; but the stated property is false and the test suite only checks the undisturbed case (test_heldCapitalWarmsUpOverADay never touches the vault in between).

**Reproduction**

ParameterizedVault with MockIMD at $1, NHI 0.85, wage raised to 0.01e18 through Parameters.proposeWage + 48h + applyPending. WORKER lock(2000e18), draw(1000e18). Then for 24 iterations: warp +1h, an unrelated account calls lock(1). Expected (documented linear warm-up, and LaggedBacking.t.sol's undisturbed case): laggedNow().debt == 1000e18 and earnLine() == 250e18. Actual: laggedNow().debt == 639.92e18 and earnLine() ~= 160e18. Fix: keep the warm-up linear per checkpoint by tracking the un-warmed increment and its start time (e.g. store `pending` and `pendingSince`, credit pending*min(now-pendingSince,1d)/1d and merge new increments by amount-weighted start time, as draw() already does for mintedAt), or correct the NatSpec to state the exponential approach.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {Parameters} from "src/Parameters.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract WFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;

    constructor(uint256 v) {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract WMirror is ISwarmFeed {
    ISwarmFeed private immutable p;

    constructor(ISwarmFeed p_) {
        p = p_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return p.latestValue();
    }

    function isStale() external view returns (bool) {
        return p.isStale();
    }

    function maxAge() external view returns (uint256) {
        return p.maxAge();
    }
}

contract WAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice BACKING_WARMUP is documented as a LINEAR one-day warm-up ("an increase is credited linearly
/// over BACKING_WARMUP"; "Full credit costs real capital held ... for the whole warm-up"). `_approach`
/// instead closes elapsed/WARMUP of the REMAINING gap at every checkpoint, and every lock/draw/wipe by
/// anyone is a checkpoint. With any activity the credit is exponential (time constant one day): after a
/// full day held, 1000 imdUSD of debt is credited as ~640, not 1000.
contract LagWarmupTest is Test {
    address private constant WORKER = address(0xCA);
    address private constant POKER = address(0x90CE);
    MockIMD private imd;
    ParameterizedVault private vault;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new WAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        WFeed primary = new WFeed(uint256(1 ether) * 1e18 / 2000 ether); // $1 per IMD
        WFeed health = new WFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new WMirror(primary))
        );
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(WORKER, 2_000 ether);
        imd.mint(POKER, 1 ether);
        vm.stopPrank();
        vm.prank(WORKER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(POKER);
        imd.approve(address(vault), type(uint256).max);
        // Minting from work switched on through governance, as the runbook describes.
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0.01 ether);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
    }

    function test_debtHeldForTheWholeWarmupIsCreditedInFullDespiteOtherActivity() public {
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        // An unrelated account locks one wei every hour for the day (any lock/draw/wipe/bite/cash does the same).
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(POKER);
            vault.lock(1);
        }
        (uint256 lagDebt,) = vault.laggedNow();
        // Documented: held one full BACKING_WARMUP, the debt counts in full (earnLine 250, as in
        // test/LaggedBacking.t.sol's undisturbed case). Actual: ~1000 * (1 - (23/24)^24) = ~640.
        assertApproxEqAbs(lagDebt, 1_000 ether, 1 ether, "a day held is full credit");
        assertApproxEqAbs(vault.earnLine(), 250 ether, 0.5 ether, "a day held earns full credit");
    }
}
```

## 4. [low] F9 fix incomplete: a listed reserve value that fits in 256 bits but is near the top still reverts earnLine, backingPerUnit and cash

`src/ParameterizedVault.sol:259`

F9 promised a listed source answering an extreme value 'counts for nothing' instead of taking earnLine, backingPerUnit and cash down. Treasury.reserveValueOf (Treasury.sol:231) only refuses the case where balance*price/10**decimals itself overflows; reserveValueUsd then saturates the sum at type(uint256).max. Both near-max results are returned to consumers that add to them with checked arithmetic: ParameterizedVault.earnLine (`reserveValue() + ...`, line 259), ParameterizedVault._redemptionReserveBacking (`others + Math.mulDiv(gem balance, price, 1e18)`, line 158) and CDPVault._backingPerUnit (`backing += _securedCollateralValue(price)`, CDPVault.sol:643). So the one listed source that F9 was about still bricks redemption (the peg defence), the work ceiling and the public backing view until a delisting matures 48h later. Same premise as F9 (governance-listed source misbehaving), hence low.

**Reproduction**

ParameterizedVault (MockIMD $1), list an 18-decimal token through proposeReserveAsset(asset, feed, 10000) + 48h + applyPending; mint 1e18 of it to the Treasury (balance == unit, so the new overflow guard is skipped); a borrower lock(2000e18), draw(1000e18). The feed then answers type(uint256).max. Expected (F9): the asset counts for nothing and earnLine/backingPerUnit/cash work. Actual: reserveValueOf(asset) == type(uint256).max; earnLine(), backingPerUnit() and cash(10e18, 0, borrower) all revert with Panic(0x11). Same with a 2-asset register whose saturating sum hits max. Fix: cap what reserveValueOf/reserveValueUsd may return (e.g. treat any per-asset value above a sane bound such as type(uint128).max as unpriced), or use saturating adds in earnLine, _redemptionReserveBacking and _backingPerUnit.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {Treasury} from "src/Treasury.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {Parameters} from "src/Parameters.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract SFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 public value;

    constructor(uint256 v) {
        value = v;
    }

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract SMirror is ISwarmFeed {
    ISwarmFeed private immutable p;

    constructor(ISwarmFeed p_) {
        p = p_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return p.latestValue();
    }

    function isStale() external view returns (bool) {
        return p.isStale();
    }

    function maxAge() external view returns (uint256) {
        return p.maxAge();
    }
}

contract SAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract SToken is ERC20 {
    constructor() ERC20("R", "R") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice F9 promised that a listed source answering an extreme value "counts for nothing" instead of
/// taking earnLine, backingPerUnit and cash down. The fix only guards the single product's overflow; a
/// value that FITS in 256 bits but sits near the top is still returned and then overflows the checked
/// additions that consume it (earnLine's `reserveValue() + ...`, `_redemptionReserveBacking`'s
/// `others + ...`, `_backingPerUnit`'s `backing += ...`).
contract ReserveSaturationTest is Test {
    address private constant BORROWER = address(0xBA);
    MockIMD private imd;
    ParameterizedVault private vault;
    SFeed private assetPrice;
    SToken private asset;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new SAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        SFeed primary = new SFeed(uint256(1 ether) * 1e18 / 2000 ether); // $1 per IMD
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(new SFeed(0.85 ether)), address(new SMirror(primary))
        );
        asset = new SToken();
        assetPrice = new SFeed(1 ether);
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeReserveAsset(IERC20(address(asset)), ISwarmFeed(address(assetPrice)), 10_000);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        asset.mint(address(vault.treasury()), 1 ether); // one whole token in the reserve
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 2_000 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function test_cashAlone() public {
        assetPrice.set(type(uint256).max);
        vm.prank(BORROWER);
        vault.cash(10 ether, 0, BORROWER);
    }

    function test_backingAlone() public {
        assetPrice.set(type(uint256).max);
        vault.backingPerUnit();
    }

    function test_anExtremeListedPriceStillRevertsTheConsumers() public {
        // The listed source starts answering an absurd but representable figure.
        assetPrice.set(type(uint256).max);
        Treasury treasury = vault.treasury();
        assertEq(treasury.reserveValueOf(IERC20(address(asset))), type(uint256).max, "returned, not treated as unpriced");
        // F9's promise: none of these revert because of a bad listed source.
        vault.earnLine();
        vault.backingPerUnit();
        vm.prank(BORROWER);
        vault.cash(10 ether, 0, BORROWER);
    }
}
```

## 5. [low] F6 incomplete: stability fees cover remints to the Treasury after burning from it never reach totalReceived; the regression test passes only because its fees are zero

`src/CDPVault.sol:535`

`cover` now syncs the Treasury before burning (F6), setting lastSynced = B. It then burns `amount` (fees first, then principal) from the Treasury and mints `feePaid` back to it (feeRecipient() == treasury). The Treasury's balance ends at B - amount + feePaid < lastSynced, so the next `sync` takes the `balance <= counted` branch, lowers the baseline and credits 0: the reminted fees are never added to totalReceived, though `totalFeesMinted` counts them. test/Cover.t.sol::test_coverKeepsTheTreasurysReceiptsWhole asserts exactly this property (`receivedBefore + unsynced + reminted`, 'including what cover then burned') but calls cover in the same second as the drain, so `reminted == 0` and the assertion is vacuous. Bookkeeping only (no funds move wrongly), but it is the class F6 was meant to close and the Treasury's one figure.

**Reproduction**

Cover.t.sol's fixture: _drain(); warp +90 days (refresh ETH/USD, price back to 1); bad = debtOf(BORROWER) (now includes ~0.32e18 fees); _fundTreasury(bad + 7e18); cover(BORROWER, bad); reserve.sync(imdUSD). Expected (the test's own assertion): totalReceived == receivedBefore + unsynced + reminted = 36.8114e18. Actual: 36.4921e18 (reminted 0.3193e18 missing). Smallest fix: sync the surplus account a second time between the burn and the fee mint (sync -> burn -> sync -> mint), so the baseline drops to the post-burn balance and the reminted fee arrives as unsynced revenue; and make the regression test accrue fees before covering.

## 6. [info] NatSpec/comments that claim properties the code does not have (left after F11)

`src/DeploymentConfig.sol:199`

Each item states the claim, then the code that contradicts it. (1) DeploymentConfig.sol:199, WORK_ORACLE_MAX_AGE: 'A stale tally grants nothing NEW' — SwarmWorkOracle.claim checks only acceptedRoots[root], the wage, the controller and the proof, never isStale(), so a root accepted months ago still credits new rights (D7 says maxAge gates nothing and F11 corrected SwarmWorkOracle/WorkOracleFactory, but not this line). (2) CDPVault.sol:283-289 'An increase is credited linearly over BACKING_WARMUP' — exponential under any activity (see the separate low finding). (3) CDPVault.sol:503-508 cover: 'only ever cancels debt that has no collateral left behind it ... Reverts on a position that still holds collateral' — since F2 it sweeps collateral below the one-wei seizure to the Treasury and proceeds. (4) ParameterizedVault.sol:257 'Parameters caps the ratio at half that cliff' — the cliff is mat-1 = 7000 bps at mat 170 and MAX_EARN_MAT_BPS is 2500, not 3500. (5) UsdPriceFeed.sol:10 'It is what the Treasury prices its IMD reserve with' — the Treasury's collateral reserve is sIMD, which F7 now forbids listing against usdPriceFeed (collateralPriceFeed only). (6) OracleAsker.sol:51 'the Treasury's daily budget, which is all this contract can ever hold' — anyone can transfer IMD to it, and a governance cut to oracleBudget leaves more than a day's budget in it with no way out. (7) SwarmRelay.sol:74 relayAndBite 'so nobody can act on the fresh price in between' — the attestations are public in the mempool; anyone can relay a copy and bite first, making the bundle revert (ReplayedAttestation/WindowNotAdvancing).

**Reproduction**

(1) Record a root at t0, warp 30 days (feed isStale() == true), raise the wage, claim(agentId, ..., root): rights are credited. (3) Cover.t.sol::test_reLockedDustNoLongerBlocksCover: cover succeeds on a position holding 1 raw unit. (4) 7000/2 = 3500 != 2500. (6) imd.transfer(asker, 50e18): asker holds 5x the budget. (7) Copy the attestations from a pending relayAndBite and call relayAndBite (or relay + bite) first: the original reverts. Fix: correct the text.
