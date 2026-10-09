// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The paced figures (CDPVault._pace, 2026-10-08), which replaced the per-position lag after the launch vault
// panel (job 5383ced0). The guarantees, each tested below on the production vault:
//   a redemption is paid no more than the paced backing, which rises by at most BACKING_RISE_PER_HOUR, however much
//   capital arrives and however long it is held;
//   with no readable price the paced backing does not rise;
//   the fee base follows the supply by at most FOLLOW_BPS_PER_HOUR an hour, so principal held for a block or
//   an hour cannot dilute the fee;
//   the work ceiling counts debt only up to the paced debt, under the same limit.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";
import {RsFeed, RsAggregator} from "test/final-sweep-panel/ReserveShare.t.sol";

contract PacedFiguresTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant WHALE = address(0x3A1E);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    RsFeed private primary;
    RsFeed private health;
    RsFeed private spot;
    uint256 private imdEth = DOLLAR;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new RsAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new RsFeed(DOLLAR);
        health = new RsFeed(0.85 ether);
        spot = new RsFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(WHALE, 100_000_000 ether);
        imd.mint(address(vault.treasury()), 20_000 ether); // a reserve, so the payout has a route at any figure
        vm.stopPrank();
        vm.prank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(WHALE);
        imd.approve(address(vault), type(uint256).max);
    }

    function _next(uint256 seconds_) private {
        vm.roll(block.number + 1 + seconds_ / 12);
        vm.warp(block.timestamp + seconds_);
        primary.set(imdEth); // keep the feeds fresh across the warp
        spot.set(imdEth);
        health.set(0.85 ether);
    }

    /// @dev Hours passing with the vault paced every hour.
    function _hours(uint256 n) private {
        for (uint256 i; i < n; ++i) {
            _next(1 hours);
            vault.pace();
        }
    }

    /// @dev A thin book below par, paced there.
    function _belowPar() private returns (uint256 honest) {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        _next(2 days);
        imdEth = DOLLAR * 40 / 100; // the book at 0.8 plus the reserve's share
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vm.prank(BOOK);
        vault.lock(1); // a touch marks the fall
        honest = vault.backingPerUnit();
        assertLt(honest, 1e18, "below par");
    }

    function test_aLiftOfAnySizeIsHeldToTheRiseLimitForHours() public {
        uint256 honest = _belowPar();
        uint256 at = block.timestamp;
        // A loan eight times the book (the debt ceiling's room), held for hours: the live figure is at par from the
        // first block.
        vm.startPrank(WHALE);
        vault.lock(100_000_000 ether);
        vault.draw(800_000 ether);
        vm.stopPrank();
        for (uint256 i; i < 6; ++i) {
            _next(30 minutes);
            uint256 allowed = honest + Math.mulDiv(vault.BACKING_RISE_PER_HOUR(), block.timestamp - at, 1 hours);
            assertLe(vault.backingPerUnit(), Math.min(allowed, 1e18), "no faster than the rise limit");
        }
        // What a redemption is paid follows the same figure.
        uint256 figure = vault.backingPerUnit();
        assertLt(figure, 1e18, "three hours in, still below par");
        uint256 feeBps = vault.redemptionFeeBps(1_000 ether);
        uint256 payPrice = vault.payoutPrice(); // the paced payout price, still above the attested $0.40
        vm.prank(WHALE);
        uint256 paid = vault.cash(1_000 ether, 0, address(0));
        assertEq(paid, Math.mulDiv(1_000 ether, Math.mulDiv(figure, 10_000 - feeBps, 10_000), payPrice));
    }

    function test_withNoReadablePriceTheMarkDoesNotRise() public {
        uint256 honest = _belowPar();
        vm.mockCallRevert(CHAINLINK_ETH_USD, abi.encodeWithSignature("latestRoundData()"), "dead");
        _next(6 hours);
        vm.prank(BOOK);
        vault.lock(1); // ungated, and paces with no usable price: the paced backing holds
        vm.clearMockedCalls();
        imdEth = DOLLAR;
        primary.set(imdEth); // the price recovers in the same block
        spot.set(imdEth);
        (uint256 mark,,,,,) = vault.paced();
        assertEq(mark, honest, "six dead hours did not write the paced backing");
        // The backing keeps its own clock (paced vault panel 2026-10-08, low F4): a pacing through the dead window
        // held it without consuming its interval, so one interval's rise is available now, not six hours' worth.
        assertEq(vault.backingPerUnit(), honest + vault.BACKING_RISE_PER_HOUR(), "one interval's rise, no more");
    }

    function test_principalHeldForAnHourCannotDiluteTheFee() public {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        _next(2 days);
        uint256 honestBps = vault.redemptionFeeBps(1_000 ether);
        // A whale draws eight times the supply and holds it an hour before redeeming.
        vm.startPrank(WHALE);
        vault.lock(100_000_000 ether);
        vault.draw(800_000 ether);
        vm.stopPrank();
        _next(1 hours);
        uint256 dilutedBps = vault.redemptionFeeBps(1_000 ether);
        // The fee base may have moved 10% in the hour: 1,000 of about 110,000 rather than of 100,000.
        assertGe(dilutedBps + 1, honestBps - (honestBps - 50) / 10, "the base moved at most its hourly step");
        assertGt(dilutedBps, 50 + (honestBps - 50) / 2, "nowhere near the ninefold dilution");
    }

    function test_theWorkCeilingCountsDebtOnlyUpToThePacedDebt() public {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        _hours(24);
        assertEq(vault.backedDebt(), 99_500 ether, "the book counts in full");
        vm.startPrank(WHALE);
        vault.lock(100_000_000 ether);
        vault.draw(800_000 ether);
        vm.stopPrank();
        _next(1 hours);
        // An hour of 10% of the 100,000 floor (the paced debt is below it): 10,000 more, not 800,000.
        assertEq(vault.backedDebt(), 109_500 ether, "debt held for an hour counts only one step");
    }

    /// @dev The accepted dip (CDPVault, the paced figures' NatSpec) needs a book below par: on a par book the
    /// aggregate cap has slack, so a position's exit and return across two transactions leaves par.
    function test_onAParBookAnExitAndReturnAcrossTransactionsLeavesPar() public {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        vm.startPrank(WHALE);
        vault.lock(1_000_000 ether);
        vault.draw(500_000 ether);
        vm.stopPrank();
        _hours(24);
        assertEq(vault.backingPerUnit(), 1e18);
        vm.prank(WHALE);
        vault.wipe(500_000 ether); // the dominant position leaves ...
        _next(12);
        vm.prank(WHALE);
        vault.draw(500_000 ether); // ... and is back a block later: the dip was paced
        _next(12);
        assertEq(vault.backingPerUnit(), 1e18, "on a par book there is no dip to pace");
    }

    /// @dev The same exit and return on a book below par: the figure dips to what the book is backed at without
    /// the position, is paced there, and climbs back at the rise limit. The griefer must be healthy at the crashed
    /// price, which in a book below par means small next to the underwater part (here 10,000 of debt at 500%
    /// against 99,500 at 200%), so the dip is about twice its debt over the supply: bounded, crisis-only, and it
    /// only ever underpays.
    function test_belowParAnExitAndReturnDipsToTheRestOfTheBookAndClimbsBack() public {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        vm.startPrank(WHALE);
        vault.lock(50_000 ether);
        vault.draw(10_000 ether);
        vm.stopPrank();
        _hours(24);
        // IMD to $0.40: BOOK at 80%, WHALE at 200%; backing (8,000 + 79,600 + 20,000) / 109,500 = 0.98.
        imdEth = DOLLAR * 40 / 100;
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vm.prank(BOOK);
        vault.lock(1); // re-prices BOOK's term at the new price
        vm.prank(WHALE);
        vault.lock(1);
        // The first pacing after the fall read the stale terms (0.87); six paced hours climb back to the honest 0.98.
        _hours(6);
        uint256 before = vault.backingPerUnit();
        assertApproxEqAbs(before, 0.9826e18, 1e15, "the honest figure, (8,000 + 79,600 + 20,000) / 109,500");
        uint256 restOfBook = Math.mulDiv(8_000 ether + 79_600 ether, 1e18, 99_500 ether); // BOOK alone, with the reserve
        vm.prank(WHALE);
        vault.wipe(10_000 ether);
        _next(12);
        vm.prank(WHALE);
        vault.draw(10_000 ether);
        _next(12);
        uint256 dipped = vault.backingPerUnit();
        assertLt(dipped, before, "the dip was paced");
        assertGe(dipped + 1e15, restOfBook, "but never below what the rest of the book is backed at");
        _hours(1);
        assertGe(vault.backingPerUnit(), dipped + 0.019e18, "and it climbs back at the rise limit");
    }

    /// @dev A quiet day banks no rise: elapsed time counts at most PACE_INTERVAL toward a move (a lift after a
    /// quiet day is paid the paced value plus one interval, not plus a day).
    function test_aQuietDayBanksNoRise() public {
        uint256 honest = _belowPar();
        vm.warp(block.timestamp + 1 days); // nobody paces
        primary.set(imdEth);
        spot.set(imdEth);
        health.set(0.85 ether);
        vm.startPrank(WHALE);
        vault.lock(100_000_000 ether);
        vault.draw(800_000 ether);
        vm.stopPrank();
        _next(12);
        assertLe(vault.backingPerUnit(), honest + vault.BACKING_RISE_PER_HOUR() + 1e14, "one interval, not a day");
    }

    /// @dev While the spot disagrees with the primary the backing is not paced in either direction, so a diverged
    /// primary (bounded by the feed's allowance, but wrong) cannot write it.
    function test_aDivergedPrimaryDoesNotPaceTheBacking() public {
        uint256 honest = _belowPar();
        (uint256 pacedBefore,,,,,) = vault.paced();
        // The primary alone jumps 15% (within its epoch allowance); the spot stays. Ungated calls still pace.
        primary.set(imdEth * 115 / 100);
        _next(12);
        vm.prank(BOOK);
        vault.lock(1);
        (uint256 pacedAfter,,,,,) = vault.paced();
        assertEq(pacedAfter, pacedBefore, "held while the feeds disagree");
        primary.set(imdEth);
        _next(12);
        assertLe(vault.backingPerUnit(), honest + vault.BACKING_RISE_PER_HOUR() * 36 / 3600 + 1, "and nothing was banked");
    }

    // --- paced vault panel 2026-10-08 (job dc27aade) -----------------------------------------------------------

    /// @dev Medium F2: the dip is not "below par only". A par book whose par reading is carried by one dominant
    /// healthy position (here 500% against an underwater tail) dips to the rest-of-book figure when that position
    /// wipes and redraws across two blocks. Kept as the statement of the accepted cost, with its bound and recovery.
    function test_aParBookDipsWhenThePositionCarryingTheCapLeavesAndReturns() public {
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        vm.startPrank(WHALE);
        vault.lock(2_500_000 ether);
        vault.draw(500_000 ether);
        vm.stopPrank();
        _hours(24);
        imdEth = DOLLAR * 40 / 100; // BOOK at 80%, WHALE at 200%: the book reads par on WHALE's surplus
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vm.prank(BOOK);
        vault.lock(1);
        vm.prank(WHALE);
        vault.lock(1);
        _hours(12);
        assertEq(vault.backingPerUnit(), 1e18, "par, carried by the dominant position");
        vm.prank(WHALE);
        vault.wipe(500_000 ether);
        _next(12);
        vm.prank(WHALE);
        vault.draw(500_000 ether);
        _next(12);
        uint256 restOfBook = Math.mulDiv(8_000 ether + 79_600 ether, 1e18, 99_500 ether); // BOOK and the reserve
        uint256 dipped = vault.backingPerUnit();
        assertLt(dipped, 0.9e18, "dipped to the rest of the book");
        assertGe(dipped + 1e15, restOfBook, "and no lower");
        _hours(10);
        assertEq(vault.backingPerUnit(), 1e18, "ten paced hours later, par");
    }

    /// @dev Medium F3, the under-read: after a fall an idle position's debt-bound term reads low until re-priced.
    /// `resecure` lets anyone re-price it; the payout then climbs at the rise rate.
    function test_anyoneCanRepriceAnIdlePositionAfterAFall() public {
        vm.startPrank(WHALE);
        vault.lock(600_000 ether);
        vault.draw(100_000 ether); // 600%, debt-bound: the term is 200,000 IMD at $1
        vm.stopPrank();
        _hours(24);
        assertEq(vault.backingPerUnit(), 1e18);
        imdEth = DOLLAR * 40 / 100;
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vault.pace(); // the stale term, 200,000 IMD at $0.40, reads 80,000 (plus the reserve's 8,000) against 100,000
        assertEq(vault.backingPerUnit(), 0.88e18, "the stale term under-reads");
        vault.resecure(WHALE); // the honest term is min(600,000, 2 x 100,000 / 0.40) = 500,000 IMD: par
        _hours(10);
        assertEq(vault.backingPerUnit(), 1e18, "re-priced by a third party, the payout climbs back to par");
    }

    /// @dev Medium F3, the over-read: a term an owner fixed at a crash low reads high after the recovery, and the
    /// payout climbs toward the inflated figure. `resecure` corrects it (a fall is paced at once).
    function test_anyoneCanRepriceATermFixedAtACrashLow() public {
        address X = address(0x5EC);
        address Y = address(0x5ED);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(X, 300_001 ether);
        imd.mint(Y, 425_001 ether);
        vm.stopPrank();
        vm.prank(X);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(Y);
        imd.approve(address(vault), type(uint256).max);
        vm.startPrank(X);
        vault.lock(300_000 ether);
        vault.draw(25_000 ether); // 1200%
        vm.stopPrank();
        vm.startPrank(Y);
        vault.lock(425_000 ether);
        vault.draw(250_000 ether); // 170%
        vm.stopPrank();
        _hours(24);
        imdEth = DOLLAR * 20 / 100; // the crash: X fixes its term at the low, 2 x 25,000 / 0.20 = 250,000 IMD
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vm.prank(X);
        vault.lock(1);
        vm.prank(Y);
        vault.lock(1);
        _hours(2);
        imdEth = DOLLAR * 40 / 100; // the recovery: X's stale 250,000 IMD reads $100,000 against an honest $50,000
        primary.set(imdEth);
        spot.set(imdEth);
        _next(12);
        vm.prank(Y);
        vault.lock(1);
        // Honest: reserve 20,000 IMD, X min(300,000, 125,000) IMD, Y 425,000 IMD, all at $0.40, over 275,000.
        uint256 honest = Math.mulDiv((20_000 ether + 125_000 ether + 425_000 ether) * 40 / 100, 1e18, 275_000 ether);
        uint256 snap = vm.snapshotState();
        _hours(40);
        assertEq(vault.backingPerUnit(), 1e18, "unrepriced, the stale term carries the payout to par");
        vm.revertToState(snap);
        vault.resecure(X);
        _hours(40);
        assertApproxEqRel(vault.backingPerUnit(), honest, 1e15, "re-priced by a third party, it settles at the honest figure");
    }

    /// @dev Low F4: a pacing through a stale window holds the backing without consuming its interval.
    function test_aPacingAtAnUnusablePriceDoesNotForfeitTheRise() public {
        uint256 honest = _belowPar();
        imdEth = DOLLAR;
        primary.set(imdEth);
        spot.set(imdEth); // the price recovers: the live figure is par, the paced backing climbs
        vm.warp(block.timestamp + 50 minutes);
        spot.set(imdEth); // the spot stays fresh ...
        vm.mockCallRevert(CHAINLINK_ETH_USD, abi.encodeWithSignature("latestRoundData()"), "dead"); // ... the USD leg dies
        vm.prank(BOOK);
        vault.lock(1); // paces the supply and debt; the backing holds
        vm.clearMockedCalls();
        vm.warp(block.timestamp + 10 minutes);
        primary.set(imdEth);
        spot.set(imdEth);
        vault.pace();
        (uint256 paced,,,,,) = vault.paced();
        assertEq(paced, honest + vault.BACKING_RISE_PER_HOUR(), "the whole hour's rise, not ten minutes of it");
    }

    /// @dev Paced vault panel low F5, restated by the final sweep panel (low F3): the paced supply starts at the
    /// live supply but no higher than the fee-base floor, so whoever draws first cannot set the launch fee base;
    /// the first day's redemptions are measured against the floor until the paced supply has followed the book up.
    function test_launchDayFeeBaseIsSeededNoHigherThanTheFloor() public {
        vm.startPrank(WHALE);
        vault.lock(1_500_000 ether);
        vault.draw(500_000 ether);
        vm.stopPrank();
        _next(1 hours);
        vault.pace();
        (, uint256 supply,,,,) = vault.paced();
        assertEq(supply, 100_000 ether, "seeded at the floor at the first pacing after the draw");
        assertEq(vault.redemptionFeeBps(5_000 ether), 300, "measured against the floor, not the live 500,000");
        _hours(17);
        assertEq(vault.redemptionFeeBps(5_000 ether), 100, "a day on, against the live supply");
    }
}
