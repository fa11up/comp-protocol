// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-09 (job a69e204e, pinned a3aa9e4): a proof the panel attached, kept as a regression
// test. On a3aa9e4 it failed as reported.

// The paced debt does not fall when held debt is cancelled while un-paced new debt is outstanding.
// Sequence: B holds 100k long enough to be fully paced; A draws 100k in one transaction (paced stays
// 100k, the draw is excluded); in the NEXT transaction A redeems 50k against B. B's held debt falls to
// 50k, A's zero-second debt is still 100k, yet the paced debt stays 100k: the cancelled 50k of held
// debt has silently been replaced by 50k of A's one-block-old debt in the work ceiling's figure.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract PdFeed is ISwarmFeed {
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

contract PdAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract PacedDebtDrawThenCancelTest is Test {
    address private constant B = address(0xB0B);
    address private constant A = address(0xA11CE);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    PdFeed private primary;
    PdFeed private health;
    PdFeed private spot;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new PdAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new PdFeed(DOLLAR);
        health = new PdFeed(0.85 ether);
        spot = new PdFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(B, 1_000_000 ether);
        imd.mint(A, 1_000_000 ether);
        vm.stopPrank();
        vm.prank(B);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(A);
        imd.approve(address(vault), type(uint256).max);
    }

    function _next(uint256 seconds_) private {
        vm.roll(block.number + 1 + seconds_ / 12);
        vm.warp(block.timestamp + seconds_);
        primary.set(DOLLAR);
        spot.set(DOLLAR);
        health.set(0.85 ether);
    }

    function test_cancellingHeldDebtAfterAnUnpacedDrawLowersThePacedDebt() public {
        // B: 100k of debt at 200% (eligible for redemption below mat + gap = 220%), held until fully paced.
        vm.startPrank(B);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        for (uint256 i; i < 14; ++i) {
            _next(1 hours);
            vault.pace();
        }
        (,, uint256 pacedDebt,,,) = vault.paced();
        assertEq(pacedDebt, 100_000 ether, "B's debt is fully paced");

        // Transaction 1: A draws 100k. The draw is excluded, so the paced debt stays 100k.
        _next(12);
        vm.startPrank(A);
        vault.lock(300_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        (,, pacedDebt,,,) = vault.paced();
        assertEq(pacedDebt, 100_000 ether, "A's draw does not count yet");

        // Transaction 2, the next block: A redeems 50k against B, cancelling 50k of B's HELD debt.
        _next(12);
        vm.prank(A);
        vault.cash(50_000 ether, 0, B);
        // Fees were paid first, so a few imdUSD of the burn went to B's accrued fee rather than principal.
        assertApproxEqAbs(vault.totalDebt(), 150_000 ether, 50 ether, "B 50k + A 100k");

        // The debt that has been held is now B's 50k. A's 100k is one block old. The work ceiling's debt
        // (backedDebt, read in a fresh transaction) must be no more than B's remainder plus one block's step
        // (10% of 100k per hour, 12 seconds of it: about 33 imdUSD).
        _next(12);
        assertLe(vault.backedDebt(), 50_000 ether + 100 ether, "paced debt should have fallen with the cancellation");
    }
}