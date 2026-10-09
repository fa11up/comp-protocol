// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Kept proof from the payout vault panel (2026-10-09, job f936eafb), audit_economics, high. Failed on c90e8d9; passes
// on the fix (PAYOUT_PRICE_FALL_BPS_PER_HOUR 100, and the fresh-principal netting in _tallyPrincipalRetired).

// The paced payout price (PAYOUT_PRICE_FALL_BPS_PER_HOUR = 500) slows a manipulated fall of the attested price
// to 5% per paced hour, and pace() is permissionless. So a pool held down on a 5%-an-hour ramp (each step inside
// the feeds' 20% epoch allowance and inside SKEW_BPS) is followed by the paid price in full, and a redemption
// after five paced hours is paid 0.95 / 0.95^5 = 1.23 IMD per imdUSD, valued at the price of five hours earlier.
// The property asserted: after a ramp of five 5% steps, one redemption does not pay more IMD, valued at the
// pre-ramp price, than the imdUSD it burned. Fails on c90e8d9: 50,000 imdUSD takes 61,380 IMD from the candidate.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract RfFeed is ISwarmFeed {
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

contract RfAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract RampedFallRedemptionTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant HOLDER = address(0x401D);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    RfFeed private primary;
    RfFeed private health;
    RfFeed private spot;
    uint256 private imdEth = DOLLAR;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new RfAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new RfFeed(DOLLAR);
        health = new RfFeed(0.85 ether); // mat 170, gap 50: a position at 200% is a candidate
        spot = new RfFeed(DOLLAR);
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
        for (uint256 i; i < 24; ++i) {
            _hour();
        }
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
        vault.pace(); // permissionless: the attacker paces on the hour
    }

    /// @dev Five hourly steps of 5% down, each inside the feeds' per-epoch allowance and inside SKEW_BPS, each
    /// paced on the hour by the attacker. The paid price follows the ramp in full (PAYOUT_PRICE_FALL_BPS_PER_HOUR
    /// is exactly the ramp's rate), so the redemption is paid at 0.774 of the pre-ramp price.
    function test_rampedFallPacedHourlyDoesNotPayMoreThanTheImdUSDBurnedAtThePreRampPrice() public {
        uint256 preRamp = DOLLAR;
        for (uint256 i; i < 5; ++i) {
            imdEth = imdEth * 95 / 100;
            _hour();
        }
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        assertLt(price, 0.78 ether, "the vault prices at the ramped low");
        uint256 payPrice = vault.payoutPrice();
        // On c90e8d9 (5% an hour, the ramp's own rate) the paid price had followed the ramp in full here; at 1% an
        // hour it has fallen 0.99^5 and sits above the ramped low.
        assertGe(payPrice, 0.95 ether, "the paced payout price has fallen at most 5% over the ramp");
        assertEq(vault.backingPerUnit(), 1e18, "the par book stays at par: the paced backing does not bind");
        (uint256 bookCollateralBefore, uint256 bookDebtBefore) = vault.positions(BOOK);
        vm.prank(HOLDER);
        uint256 gemOut = vault.cash(50_000 ether, 0, BOOK);
        (uint256 bookCollateralAfter, uint256 bookDebtAfter) = vault.positions(BOOK);
        assertEq(bookCollateralBefore - bookCollateralAfter, gemOut, "paid from the candidate");
        assertEq(bookDebtBefore - bookDebtAfter, 50_000 ether, "fifty thousand of debt cancelled");
        // EXPECTED: 50,000 imdUSD takes at most 50,000 IMD at the pre-ramp price. ACTUAL on c90e8d9:
        // 50,000 x 0.95 / 0.7738 = 61,380 IMD, worth $61,380 at the pre-ramp price, all from the candidate.
        uint256 valueAtPreRamp = Math.mulDiv(gemOut, preRamp * 2000, 1e18); // DOLLAR x 2000 = $1 per IMD
        assertLe(valueAtPreRamp, 50_000 ether, "a paced ramp pays the redeemer more than it burned");
    }
}
