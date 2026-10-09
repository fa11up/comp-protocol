// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// A pool held down two feed rungs (0.8, then 0.64 of the honest price: two epochs, an hour apart, both within
// the feeds' fresh allowance) and kept attested through the six-hour grace lets a liquidator seize
// debt x 1.2 / 0.64 = 1.875 x the debt's HONEST value per imdUSD burned. The accepted bound (sweep oracle
// panel 2026-10-07, Q6: "the bonus is 20% of debt repaid, at most $200k on the whole LINE") prices the bonus at
// the honest price; `bite` prices it at the held one. The paced payout price protects `cash` from the same
// hold; `bite` reads only the attested price.
//
// Kept from the final sweep panel 3 (2026-10-09, job ed4f7f6d), judge, high, as the measure of the bound now
// ACCEPTED and stated at CDPVault.bite and on the risks page: 1.2 / (1 - push) of the debt at the real price,
// from the borrower only (backing per imdUSD untouched), and a borrower who tops up inside the grace stops it.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract HlFeed is ISwarmFeed {
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

contract HlAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract HeldDownLiquidationTest is Test {
    address private constant VICTIM = address(0xB00C);
    address private constant ATTACKER = address(0xA77A);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    HlFeed private primary;
    HlFeed private health;
    HlFeed private spot;
    uint256 private imdEth = DOLLAR;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new HlAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new HlFeed(DOLLAR);
        health = new HlFeed(0.85 ether); // mat 170, grace six hours
        spot = new HlFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(VICTIM, 1_000_000 ether);
        imd.mint(ATTACKER, 2_000_000 ether);
        vm.stopPrank();
        // The victim: $480k of debt at 200%, the healthy side of mat 170 (LINE is $1M for the whole book).
        vm.startPrank(VICTIM);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(960_000 ether);
        vault.draw(480_000 ether);
        vm.stopPrank();
        // The attacker holds imdUSD, drawn a day earlier at 400% so the hold cannot reach its own position.
        vm.startPrank(ATTACKER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(2_000_000 ether);
        vault.draw(500_000 ether);
        vm.stopPrank();
        for (uint256 i; i < 24; ++i) {
            _hour();
        }
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

    /// @dev Rung one: 0.8 (the fresh cap). An hour later the epoch has closed and rung two anchors at 0.8: 0.64.
    /// The victim is marked at once (CR 128 < 170) and the pool is held, re-attested hourly, through the six-hour
    /// grace. At the bite the seizure is priced at the held 0.64, so each imdUSD burned takes 1.875 IMD.
    function test_aPoolHeldDownTwoRungsThroughGracePaysTheStatedBound() public {
        uint256 preFall = DOLLAR;
        imdEth = DOLLAR * 80 / 100;
        _hour();
        imdEth = DOLLAR * 64 / 100;
        _hour();
        vm.prank(ATTACKER);
        vault.bark(VICTIM);
        (uint256 markedAt, uint256 grace,,) = vault.liquidationMarks(VICTIM);
        assertEq(grace, 6 hours, "grace at NHI 0.85");
        for (uint256 i; i < 6; ++i) {
            _hour();
        }
        assertGe(block.timestamp, markedAt + grace, "grace has elapsed");
        assertApproxEqRel(vault.payoutPrice(), 0.92 ether, 0.01e18, "cash would still be paid near the pre-fall price");

        (uint256 victimCollateralBefore, uint256 burned) = vault.positions(VICTIM);
        uint256 attackerImdBefore = imd.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        vault.bite(VICTIM, burned);
        (uint256 victimCollateralAfter, uint256 victimDebtAfter) = vault.positions(VICTIM);
        assertEq(victimDebtAfter, 0, "the whole debt is bitten in one call");
        uint256 seized = victimCollateralBefore - victimCollateralAfter;
        uint256 received = imd.balanceOf(ATTACKER) - attackerImdBefore;

        // About 480,078 imdUSD burned (principal plus accrued fees). Seized: burned x 1.2 / 0.64 = 1.875 x burned
        // in IMD, worth 1.875 x the debt at the pre-fall price ($900k of the victim's $960k). The attacker, also the marker, keeps all but the
        // protocol's tenth of the bonus.
        uint256 seizedAtPreFall = Math.mulDiv(seized, preFall * 2000, 1e18);
        uint256 receivedAtPreFall = Math.mulDiv(received, preFall * 2000, 1e18);
        emit log_named_decimal_uint("seized, at the pre-fall price", seizedAtPreFall, 18);
        emit log_named_decimal_uint("liquidator receives, at the pre-fall price", receivedAtPreFall, 18);
        // ACCEPTED, as stated at CDPVault.bite: 1.2 / 0.64 = 1.875 x the debt at the real price, no more.
        assertApproxEqRel(seizedAtPreFall, burned * 1875 / 1000, 0.001e18, "the stated bound: 1.875x for two steps");
        assertEq(vault.totalBadDebt(), 0, "a 200% position covers the seizure: no bad debt, the reserve is untouched");
    }

    /// @dev The same hold; the marked borrower tops up inside the grace to minCR at the held price, which clears
    /// the mark, and the liquidation cannot happen.
    function test_aMarkedBorrowerWhoTopsUpInsideTheGraceIsNotLiquidated() public {
        imdEth = DOLLAR * 80 / 100;
        _hour();
        imdEth = DOLLAR * 64 / 100;
        _hour();
        vm.prank(ATTACKER);
        vault.bark(VICTIM);
        _hour();
        // At 0.64 the victim is at 128%; 170% needs about a third more collateral.
        vm.prank(APPROVED_OPERATOR);
        imd.mint(VICTIM, 400_000 ether);
        vm.startPrank(VICTIM);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(400_000 ether);
        vm.stopPrank();
        (,, bool marked,) = vault.liquidationMarks(VICTIM);
        assertFalse(marked, "topping up above minCR at a fresh price clears the mark");
        for (uint256 i; i < 6; ++i) {
            _hour();
        }
        (, uint256 debt) = vault.positions(VICTIM);
        vm.prank(ATTACKER);
        vm.expectRevert();
        vault.bite(VICTIM, debt);
    }
}
