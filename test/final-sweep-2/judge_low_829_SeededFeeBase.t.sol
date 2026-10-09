// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-09 (job a69e204e, pinned a3aa9e4): a proof the panel attached, kept as a regression
// test. On a3aa9e4 it failed as reported.

// CDPVault._pacedSupply seeds a zero paced supply with the whole live supply at once. At launch the first borrower
// draws (the pacing at the start of its own transaction sees zero), and the NEXT capital-moving transaction by anyone
// writes that draw into the fee base in full. Repaid a block later, it keeps the fee base inflated for about a day,
// falling only at FOLLOW_BPS_PER_HOUR: principal drawn for a block dilutes every redemption fee in that window.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract SeedFeed is ISwarmFeed {
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

contract SeedAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract SeededFeeBaseTest is Test {
    address private constant WHALE = address(0xA11CE);
    address private constant BOOK = address(0xB00C);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    SeedFeed private primary;
    SeedFeed private health;
    SeedFeed private spot;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new SeedAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new SeedFeed(DOLLAR);
        health = new SeedFeed(0.85 ether);
        spot = new SeedFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(WHALE, 2_000_000 ether);
        imd.mint(BOOK, 220_000 ether);
        vm.stopPrank();
        vm.prank(WHALE);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(BOOK);
        imd.approve(address(vault), type(uint256).max);
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        primary.set(DOLLAR);
        spot.set(DOLLAR);
        health.set(0.85 ether);
    }

    function _bookBorrows() private {
        // An honest book of 100,000 imdUSD at 200%: inside the redeemable band (mat 170 + gap 50).
        vm.startPrank(BOOK);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
    }

    /// Control: the same honest book with no block-long draw in front of it. 50,000 burned against a 100,000 base
    /// (the floor) stores the cap: 50 + 450 = 500 bps.
    function test_controlFeeAtLaunch() public {
        _bookBorrows();
        _next();
        vault.pace();
        _next();
        assertEq(vault.redemptionFeeBps(50_000 ether), 500);
    }

    function test_blockLongDrawAtLaunchDilutesTheFeeBase() public {
        // Block 1: the first borrower draws 900,000 (LINE is 1,000,000). Its own pacing sees a zero supply.
        vm.startPrank(WHALE);
        vault.lock(1_600_000 ether);
        vault.draw(900_000 ether);
        vm.stopPrank();
        // Block 2: the honest book borrows; its pacing seeds the paced supply with the whole 900,000.
        _next();
        _bookBorrows();
        // Block 3: the whale repays its principal and leaves. Live supply is 100,000 again.
        _next();
        vm.startPrank(WHALE);
        vault.wipe(900_000 ether);
        vault.free(1_500_000 ether); // a few cents of accrued fee stay owed; the collateral comes out
        vm.stopPrank();
        _next();
        (, uint256 pacedSupply,,,,) = vault.paced();
        emit log_named_uint("paced supply (fee base)", pacedSupply);
        emit log_named_uint("live supply", stable.totalSupply());
        uint256 fee = vault.redemptionFeeBps(50_000 ether);
        emit log_named_uint("fee for 50,000, bps", fee);
        // EXPECTED (the paced figures' NatSpec: principal drawn for a block cannot dilute the fee): 500 bps, as in
        // the control. ACTUAL: 328 bps, the 900,000 drawn for two blocks counting in the fee base in full.
        assertEq(fee, 500, "a block-long draw diluted the redemption fee");
        // And it lasts: twelve hours later the base is still about 300,000 against a live supply of 100,000.
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 300);
            primary.set(DOLLAR);
            spot.set(DOLLAR);
            health.set(0.85 ether);
            vault.pace();
        }
        assertEq(vault.redemptionFeeBps(50_000 ether), 500, "still diluted twelve hours later");
    }
}