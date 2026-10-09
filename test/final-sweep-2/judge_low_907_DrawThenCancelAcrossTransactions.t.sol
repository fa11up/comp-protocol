// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-09 (job a69e204e, pinned a3aa9e4): a proof the panel attached, kept as a regression
// test. On a3aa9e4 it failed as reported.

// The paced debt's clamp after a cancellation (CDPVault._clampPacedDebt, added in c1ecb05 for the paced vault
// panel's medium #1) measures "the debt this transaction began with less what it has cancelled" from totalDebt
// and the transaction's own transient tallies. A draw in ONE transaction and the cancellation of another
// position's seasoned debt in the NEXT (same block or the next) leaves the paced debt at the book's total: the
// cancelled seasoned debt is replaced, in the counted figure, by debt drawn a transaction earlier, which the
// NatSpec (CDPVault 310-313, ParameterizedVault 237-240, 261-264) says backs nothing until it has been held.
// Fails on a3aa9e4: after lock+draw(20,000) and, in the next block, cash(20,000, 0, BOOK), backedDebt() reads
// 99,500 where the seasoned book is 79,500 and the churner's 20,000 is twelve seconds old.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract DcFeed is ISwarmFeed {
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

contract DcAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract DrawThenCancelAcrossTransactionsTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant CHURNER = address(0xC4A1);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    DcFeed private primary;
    DcFeed private health;
    DcFeed private spot;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new DcAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new DcFeed(DOLLAR);
        health = new DcFeed(0.85 ether); // mat 170, gap 50: the book at 200% is a candidate
        spot = new DcFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(CHURNER, 40_000 ether);
        vm.stopPrank();
        vm.startPrank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether); // 200%: eligible for redemption, and the only debt on the book
        vm.stopPrank();
        vm.prank(CHURNER);
        imd.approve(address(vault), type(uint256).max);
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

    function test_drawThenCancelInTheNextTransactionCountsZeroSecondDebt() public {
        // Transaction 1: the churner locks and draws 20,000 (its debt is not yet counted: paced stays 99,500).
        vm.startPrank(CHURNER);
        vault.lock(40_000 ether);
        vault.draw(20_000 ether);
        vm.stopPrank();
        (,, uint256 pacedAfterDraw,,,) = vault.paced();
        assertEq(pacedAfterDraw, 99_500 ether, "the fresh draw is not counted");
        // Transaction 2, the next block: redeem the drawn 20,000 against the seasoned book.
        _next();
        vm.prank(CHURNER);
        vault.cash(20_000 ether, 0, BOOK);
        // The next block: the book's total is back at 99,500, of which 20,000 is twelve seconds old.
        _next();
        // A day's stability fees (about 12 imdUSD) were cancelled first, so the principal is a few imdUSD above.
        assertApproxEqAbs(vault.totalDebt(), 99_500 ether, 20 ether);
        (, uint256 bookDebt) = vault.positions(BOOK);
        assertApproxEqAbs(bookDebt, 79_500 ether, 20 ether, "the book lost 20,000 of seasoned debt");
        // EXPECTED per the NatSpec: at most the seasoned 79,500 plus two blocks of the follow step (about 67).
        // ACTUAL on a3aa9e4: 99,500: the churner's zero-second debt counts in full for the work ceiling.
        assertLe(vault.backedDebt(), 79_600 ether, "cancelled seasoned debt replaced by zero-second debt counts in full");
    }
}