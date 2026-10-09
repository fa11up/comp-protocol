// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-09 (job a69e204e, pinned a3aa9e4): a proof the panel attached, kept as a regression
// test. On a3aa9e4 it failed as reported.

// A redemption is paid IMD at the feed's price with the backing capped at par, so a one-step feed fall within
// the committed per-epoch allowance (20% on a fresh feed, 40% after two hours of silence) lets a redeemer take
// 1 / (1 - step) IMD per imdUSD from the reserve and from any candidate, while the redemption fee is capped at
// 5%. On a par book the paced backing does not bind (B = 1), so pacing does not slow it. The property asserted:
// after a 20% feed fall, one redemption does not pay more IMD, valued at the pre-fall price, than the imdUSD it
// burned. Fails on a3aa9e4: 50,000 imdUSD takes 59,375 IMD (worth $59,375 at the pre-fall price) out of the
// candidate's collateral, and the candidate's debt falls by only 50,000.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract OsFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 hours;
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

    function isStale() external view returns (bool) {
        return block.timestamp - updatedAt > maxAge;
    }
}

contract OsAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract OneStepFallRedemptionTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant HOLDER = address(0x401D);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    OsFeed private primary;
    OsFeed private health;
    OsFeed private spot;
    uint256 private imdEth = DOLLAR;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new OsAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new OsFeed(DOLLAR);
        health = new OsFeed(0.85 ether); // mat 170, gap 50: a position at 200% is a candidate
        spot = new OsFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(HOLDER, 300_000 ether);
        vm.stopPrank();
        vm.startPrank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether); // 200%: the candidate
        vm.stopPrank();
        vm.startPrank(HOLDER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(300_000 ether);
        vault.draw(100_000 ether); // the redeemer's imdUSD, held for a day
        vm.stopPrank();
        for (uint256 i; i < 24; ++i) _hour();
        assertEq(vault.backingPerUnit(), 1e18, "a par book");
    }

    function _next(uint256 seconds_) private {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1 + seconds_ / 12);
        primary.set(imdEth);
        spot.set(imdEth);
        health.set(0.85 ether);
    }

    function _hour() private {
        _next(1 hours);
        vault.pace();
    }

    /// @dev One step the feeds accept on a fresh epoch (SwarmFeed.maxDeviationBps 2000): primary and spot both
    /// 20% below the price of a moment ago, within SKEW_BPS of each other. The next block, a holder redeems.
    function test_oneStepFallDoesNotPayMoreThanTheImdUSDBurnedAtThePreFallPrice() public {
        uint256 preFall = DOLLAR;
        imdEth = DOLLAR * 80 / 100;
        _next(12);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        assertEq(price, 0.8 ether, "the vault prices at the attested low");
        assertEq(vault.backingPerUnit(), 1e18, "the par book stays at par through a 20% fall: pacing does not bind");
        uint256 collateralBefore = vault.securedCollateral();
        (uint256 bookCollateralBefore, uint256 bookDebtBefore) = vault.positions(BOOK);
        vm.prank(HOLDER);
        uint256 gemOut = vault.cash(50_000 ether, 0, BOOK);
        (uint256 bookCollateralAfter, uint256 bookDebtAfter) = vault.positions(BOOK);
        // The candidate funded all of it (no reserve), and its debt fell by exactly what was burned.
        assertEq(bookCollateralBefore - bookCollateralAfter, gemOut, "paid from the candidate");
        assertEq(bookDebtBefore - bookDebtAfter, 50_000 ether, "fifty thousand of debt cancelled");
        collateralBefore; // silence
        // EXPECTED: 50,000 imdUSD takes at most 50,000 IMD at the pre-fall price (the fee is a brake, not a
        // premium). ACTUAL on a3aa9e4: 50,000 x 0.95 / 0.80 = 59,375 IMD, worth 59,375 at the pre-fall price.
        uint256 valueAtPreFall = Math.mulDiv(gemOut, preFall * 2000, 1e18); // DOLLAR x 2000 = $1 per IMD
        assertLe(valueAtPreFall, 50_000 ether, "a one-step feed fall pays the redeemer more than it burned");
    }
}