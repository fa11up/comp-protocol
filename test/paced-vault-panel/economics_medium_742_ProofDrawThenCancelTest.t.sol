// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Paced vault panel audit 2026-10-08 (job dc27aade, pinned d3861ac): a proof the panel attached, kept as a regression
// test. On d3861ac it failed as reported (the paced debt was clamped after a draw only); it passes with the clamp
// after every cancellation (CDPVault._clampPacedDebt).

// The paced debt is clamped only after `draw` (CDPVault._clampPacedDebt). A draw FOLLOWED by a cancellation of
// another position's debt in the same transaction (cash here; bite and cover take the same path) leaves
// `_debtPaced` where the transaction found it, so in the next transaction the zero-second debt that replaced
// the cancelled one counts in full for the work ceiling (ParameterizedVault.backedDebt). The mirror order
// (cash, then draw) is clamped, as the sweep-panel fix intended.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract PFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        set(v);
    }

    function set(uint256 v) public {
        value = v;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract PAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev One transaction: lock, draw, then redeem the drawn imdUSD against the book (draw FIRST).
contract DrawThenCash {
    function run(ParameterizedVault vault, MockIMD imd, uint256 collateral, uint256 debt, address candidate) external {
        imd.approve(address(vault), type(uint256).max);
        vault.lock(collateral);
        vault.draw(debt);
        vault.cash(debt, 0, candidate);
    }
}

/// @dev The same three steps with the redemption BEFORE the draw (the order the committed clamp covers).
contract CashThenDraw {
    function run(ParameterizedVault vault, MockIMD imd, uint256 collateral, uint256 debt, address candidate) external {
        imd.approve(address(vault), type(uint256).max);
        vault.lock(collateral);
        vault.cash(debt, 0, candidate);
        vault.draw(debt);
    }
}

contract ProofDrawThenCancelTest is Test {
    address private constant BOOK = address(0xB00C);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    PFeed private primary;
    PFeed private health;
    PFeed private spot;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new PAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new PFeed(DOLLAR);
        health = new PFeed(0.85 ether); // mat 170, gap 50: the book at 200% is a candidate
        spot = new PFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        vm.startPrank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether); // 200%: eligible for redemption, and the only debt on the book
        vm.stopPrank();
        // A day of hourly pacing: the paced debt catches up with the book.
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 300);
            primary.set(DOLLAR);
            spot.set(DOLLAR);
            health.set(0.85 ether);
            vault.pace();
        }
        assertEq(vault.backedDebt(), 99_500 ether, "the book counts in full after a day");
    }

    function _next() private {
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
    }

    /// @dev The order the committed clamp covers: cancelling 20,000 of the book then drawing 20,000 leaves the
    /// paced debt at the book without the cancelled part, so the new debt backs nothing until it has been held.
    function test_cashThenDrawIsClamped() public {
        CashThenDraw churner = new CashThenDraw();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(churner), 40_000 ether);
        // The churner needs imdUSD to redeem before it draws: the book lends it 20,000.
        vm.prank(BOOK);
        stable.transfer(address(churner), 20_000 ether);
        churner.run(vault, imd, 40_000 ether, 20_000 ether, BOOK);
        _next();
        uint256 counted = vault.backedDebt();
        emit log_named_uint("backedDebt after cash-then-draw", counted);
        assertLe(counted, 79_600 ether, "the redrawn 20,000 does not count until it has been held");
    }

    /// @dev The same capital, the same cancellation, the draw first: the paced debt is never clamped, and the
    /// 20,000 drawn seconds ago counts for the work ceiling in the next transaction.
    function test_drawThenCashCountsZeroSecondDebt() public {
        DrawThenCash churner = new DrawThenCash();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(churner), 40_000 ether);
        uint256 debtBefore = vault.totalDebt();
        churner.run(vault, imd, 40_000 ether, 20_000 ether, BOOK);
        _next();
        // The book's 20,000 was cancelled and the churner's 20,000 replaced it: the same total.
        assertApproxEqAbs(vault.totalDebt(), debtBefore, 20 ether, "the total is unchanged");
        (, uint256 bookDebt) = vault.positions(BOOK);
        assertLt(bookDebt, 80_000 ether, "the book's debt was cancelled");
        uint256 counted = vault.backedDebt();
        emit log_named_uint("backedDebt after draw-then-cash", counted);
        // EXPECTED (the paced debt's stated property, CDPVault BACKING_RISE_PER_HOUR NatSpec and
        // ParameterizedVault.backedDebt): at most the book less what was cancelled, about 79,500.
        // ACTUAL: about 99,500, the whole total including 20,000 of debt drawn seconds ago.
        assertLe(counted, 79_600 ether, "debt cancelled by a redemption and drawn again backs nothing until held");
    }
}