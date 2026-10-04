// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Parameters} from "src/Parameters.sol";
import {Governed} from "src/Governed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice The shipped vault's run fee and automatic work-mint contraction, using real minted COMP.
contract RedemptionEconomicsTest is WorkBackingFixture {
    uint256 private constant FLOOR = 50;
    uint256 private constant CAP = 500;
    uint256 private constant BASE_CAP = 0.045 ether;

    function setUp() public override {
        super.setUp();
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        _openDebt(1000 ether);
        vm.prank(BORROWER);
        backedVault.withdrawCollateral(200 ether); // 180%, inside the healthy 150..200 band.
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), 1000 ether);
    }

    function _redeem(uint256 amount) private returns (uint256 payout) {
        vm.prank(BORROWER);
        payout = backedVault.redeem(amount, 0, BORROWER);
    }

    function _advance(uint256 elapsed) private {
        vm.warp(vm.getBlockTimestamp() + elapsed);
        _refreshEthUsd();
    }

    function test_tenPercentBurnUsesQuarterSupplyFractionAndRetainsTheFee() public {
        assertEq(backedVault.REDEMPTION_FEE_FLOOR_BPS(), FLOOR);
        assertEq(backedVault.REDEMPTION_FEE_CAP_BPS(), CAP);
        assertEq(backedVault.redemptionFeeBps(0), FLOOR);
        assertEq(backedVault.redemptionFeeBps(100 ether), 300);
        uint256 wallet = collateral.balanceOf(BORROWER);
        uint256 payout = _redeem(100 ether);
        assertEq(payout, 97 ether);
        assertEq(backedVault.redemptionBaseRate(), 0.025 ether);
        assertEq(stable.totalSupply(), 900 ether);
        assertEq(collateral.balanceOf(BORROWER), wallet + payout);
        assertEq(collateral.balanceOf(address(reserve)), 903 ether);
        assertEq(collateral.balanceOf(address(backedVault)), 1800 ether);
        assertEq(stable.balanceOf(address(reserve)), 0, "fee never reminted to Treasury");
        assertEq(collateral.balanceOf(APPROVED_OPERATOR), 0, "no fee distribution");
        assertEq(backedVault.totalDebt(), 1000 ether);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 100 ether);
    }

    function test_repeatedRunFollowsCurveReachesCapAndStaysCapped() public {
        uint256 expectedBase;
        uint256 previousFee = FLOOR;
        uint256 cappedCalls;
        for (uint256 i; i < 24; ++i) {
            uint256 supplyBefore = stable.totalSupply();
            uint256 backingBefore = collateral.balanceOf(address(backedVault)) + collateral.balanceOf(address(reserve));
            expectedBase += (25 ether * 1e18 / supplyBefore) / 4;
            if (expectedBase > BASE_CAP) expectedBase = BASE_CAP;
            uint256 fee = FLOOR + expectedBase / 1e14;
            assertEq(backedVault.redemptionFeeBps(25 ether), fee, "quote uses pre-burn supply");
            if (fee < CAP) assertGt(fee, previousFee, "run raises the fee before saturation");
            else ++cappedCalls;
            assertLe(fee, CAP);
            uint256 payout = _redeem(25 ether);
            assertEq(payout, 25 ether * (10_000 - fee) / 10_000);
            assertEq(backedVault.redemptionBaseRate(), expectedBase);
            assertEq(stable.totalSupply(), supplyBefore - 25 ether);
            uint256 backingAfter = collateral.balanceOf(address(backedVault)) + collateral.balanceOf(address(reserve));
            assertEq(backingAfter, backingBefore - payout);
            assertGe(backingAfter * supplyBefore, backingBefore * stable.totalSupply(), "backing ratio improves");
            previousFee = fee;
        }
        assertGt(cappedCalls, 10, "sustained redemptions exercise the cap repeatedly");
        assertEq(backedVault.redemptionFeeBps(0), CAP);
    }

    function test_runDrainsReserveThenPositionsUntilTheCandidateLeavesTheBand() public {
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(collateral, APPROVED_OPERATOR, 900 ether);
        uint256 reserveOnlyCalls;
        uint256 mixedCalls;
        uint256 positionOnlyCalls;
        uint256 burns;
        for (uint256 i; i < 30 && backedVault.collateralRatio(BORROWER) < backedVault.redemptionCeilingCR(); ++i) {
            uint256 beforeReserve = backedVault.redemptionReserve();
            (uint256 beforeCollateral, uint256 beforeDebt) = backedVault.positions(BORROWER);
            uint256 beforeSupply = stable.totalSupply();
            uint256 beforeCeiling = backedVault.workCeiling();
            uint256 payout = _redeem(25 ether);
            (uint256 afterCollateral, uint256 afterDebt) = backedVault.positions(BORROWER);
            if (beforeReserve >= payout) {
                ++reserveOnlyCalls;
                assertEq(beforeCollateral, afterCollateral);
                assertEq(beforeDebt, afterDebt);
            } else {
                if (beforeReserve == 0) ++positionOnlyCalls;
                else ++mixedCalls;
                assertEq(backedVault.redemptionReserve(), 0);
                assertEq(beforeCollateral - afterCollateral, payout - beforeReserve);
                assertLt(afterDebt, beforeDebt);
                assertGe(afterCollateral * beforeDebt, beforeCollateral * afterDebt);
            }
            burns += 25 ether;
            assertEq(stable.totalSupply(), 1000 ether - burns);
            assertGe(
                (afterCollateral + backedVault.redemptionReserve()) * beforeSupply,
                (beforeCollateral + beforeReserve) * stable.totalSupply()
            );
            assertLt(backedVault.workCeiling(), beforeCeiling);
        }
        assertGt(reserveOnlyCalls, 1);
        assertEq(mixedCalls, 1);
        assertGt(positionOnlyCalls, 1);
        assertEq(backedVault.redemptionFeeBps(0), CAP);
        assertGe(backedVault.collateralRatio(BORROWER), backedVault.redemptionCeilingCR());
        uint256 debt = backedVault.totalDebt();
        uint256 collateralBefore = collateral.balanceOf(address(backedVault));
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.IneligibleRedemptionPosition.selector);
        backedVault.redeem(25 ether, 0, BORROWER);
        assertEq(backedVault.totalDebt(), debt);
        assertEq(stable.totalSupply(), 1000 ether - burns);
        assertEq(collateral.balanceOf(address(backedVault)), collateralBefore);
    }

    function test_baseHalvesEveryTwelveHoursAndEventuallyReturnsToFloor() public {
        _redeem(100 ether);
        uint256 storedBase = backedVault.redemptionBaseRate();
        uint256 last = backedVault.lastRedemptionAt();
        _advance(12 hours);
        assertApproxEqAbs(backedVault.decayedRedemptionBaseRate(), storedBase / 2, 1_000_000);
        _advance(12 hours);
        assertApproxEqAbs(backedVault.decayedRedemptionBaseRate(), storedBase / 4, 1_000_000);
        assertEq(backedVault.redemptionBaseRate(), storedBase, "views do not checkpoint decay");
        assertEq(backedVault.lastRedemptionAt(), last);
        _advance(365 days);
        assertEq(backedVault.decayedRedemptionBaseRate(), 0);
        assertEq(backedVault.redemptionFeeBps(0), FLOOR);
        assertEq(backedVault.redemptionFeeBps(9 ether), 75, "next redemption adds its own fraction");
        _redeem(9 ether);
        assertEq(backedVault.redemptionBaseRate(), 0.0025 ether);
        assertEq(backedVault.lastRedemptionAt(), vm.getBlockTimestamp());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_decayIsMonotonicAndNewBurnAddsToDecayedBase(uint32 secondsSeed, uint96 amountSeed) public {
        _redeem(100 ether);
        uint256 elapsed = bound(secondsSeed, 1, 30 days);
        _advance(elapsed);
        uint256 first = backedVault.decayedRedemptionBaseRate();
        assertLt(first, 0.025 ether);
        _advance(12 hours);
        uint256 decayed = backedVault.decayedRedemptionBaseRate();
        assertApproxEqAbs(decayed, first / 2, 1_000_000);
        uint256 amount = bound(amountSeed, 1 ether, 500 ether);
        uint256 expected = decayed + (amount * 1e18 / stable.totalSupply()) / 4;
        if (expected > BASE_CAP) expected = BASE_CAP;
        uint256 fee = FLOOR + expected / 1e14;
        assertEq(backedVault.redemptionFeeBps(amount), fee);
        assertGe(fee, FLOOR);
        assertLe(fee, CAP);
        assertEq(_redeem(amount), amount * (10_000 - fee) / 10_000);
        assertEq(backedVault.redemptionBaseRate(), expected);
    }

    function test_failedMinimumOutDoesNotChargeFeeOrRestartDecay() public {
        _redeem(100 ether);
        _advance(6 hours);
        uint256 rate = backedVault.redemptionBaseRate();
        uint256 decayed = backedVault.decayedRedemptionBaseRate();
        uint256 last = backedVault.lastRedemptionAt();
        uint256 quoted = 10 ether * (10_000 - backedVault.redemptionFeeBps(10 ether)) / 10_000;
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.MinimumOutNotMet.selector);
        backedVault.redeem(10 ether, quoted + 1, BORROWER);
        assertEq(backedVault.redemptionBaseRate(), rate);
        assertEq(backedVault.decayedRedemptionBaseRate(), decayed);
        assertEq(backedVault.lastRedemptionAt(), last);
        assertEq(stable.totalSupply(), 900 ether);
        assertEq(collateral.balanceOf(address(reserve)), 903 ether);
        assertEq(_redeem(10 ether), quoted);
    }

    function test_entireSupplyCanBeBurnedAgainstReserveAndZeroSupplyQuoteIsDefined() public {
        assertEq(_redeem(1000 ether), 950 ether);
        assertEq(stable.totalSupply(), 0);
        assertEq(backedVault.redemptionFeeBps(0), CAP);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        backedVault.redemptionFeeBps(1);
        assertEq(backedVault.totalDebt(), 1000 ether, "reserve burns do not retire a borrower's debt");
        assertEq(backedVault.totalNonPrincipalRedeemed(), 1000 ether);
        _advance(365 days);
        assertEq(backedVault.redemptionFeeBps(0), FLOOR);
    }

    function test_reserveBurnTightensWorkMintingWithoutGovernanceAndDoesNotRestoreRights() public {
        assertEq(backedVault.workCeiling(), 1250 ether);
        _mintWork(WORKER, 1250 ether);
        uint256 rights = workOracle.mintingRights(WORKER);
        uint256 payout = _redeem(100 ether);
        assertEq(backedVault.reserveValue(), 1000 ether - payout);
        assertEq(backedVault.totalDebt(), 1000 ether);
        assertEq(backedVault.workCeiling(), 1250 ether - payout);
        _assertWorkBlocked(rights);
    }

    function test_mixedBurnContractsReserveAndDebtTermsInTheSameCall() public {
        // Consume reserve naturally, then the next redemption has to cross into the position.
        uint256 first = _redeem(900 ether);
        assertEq(first, 855 ether);
        assertEq(backedVault.redemptionReserve(), 145 ether);
        _mintWork(WORKER, backedVault.workCeiling());
        vm.prank(WORKER);
        stable.transfer(BORROWER, 200 ether);
        uint256 rights = workOracle.mintingRights(WORKER);
        uint256 ceilingBefore = backedVault.workCeiling();
        uint256 debtBefore = backedVault.totalDebt();
        uint256 amount = 200 ether;
        uint256 fee = backedVault.redemptionFeeBps(amount);
        uint256 debtRetired = amount - 145 ether * 10_000 / (10_000 - fee);
        assertEq(_redeem(amount), 190 ether);
        assertEq(backedVault.redemptionReserve(), 0);
        assertEq(backedVault.totalDebt(), debtBefore - debtRetired);
        assertEq(backedVault.workCeiling(), (debtBefore - debtRetired) / 4);
        assertLt(backedVault.workCeiling(), ceilingBefore - 145 ether, "both terms contract");
        _assertWorkBlocked(rights);
    }

    function test_positionBurnAloneTightensDebtTerm() public {
        // Reserve exits through its authorized owner before this scenario starts.
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(collateral, APPROVED_OPERATOR, 1000 ether);
        _mintWork(WORKER, 250 ether);
        uint256 rights = workOracle.mintingRights(WORKER);
        _redeem(100 ether);
        assertEq(backedVault.totalDebt(), 900 ether);
        assertEq(backedVault.workCeiling(), 225 ether);
        assertEq(backedVault.reserveValue(), 0);
        _assertWorkBlocked(rights);
    }

    function _assertWorkBlocked(uint256 rights) private {
        uint256 issued = backedVault.totalWorkMinted();
        assertGt(issued, backedVault.workCeiling());
        assertEq(workOracle.mintingRights(WORKER), rights, "redemption never restores consumed work rights");
        assertEq(parameters.pendingEta(), 0, "no pending governance action");
        assertEq(backedVault.workRatioBps(), 2500);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.mintFromWork(1);
        assertEq(backedVault.totalWorkMinted(), issued);
        assertEq(workOracle.mintingRights(WORKER), rights);
    }

    function test_spreadRequiresGovernorAndFortyEightHoursAndTracksLiveMinCR() public {
        assertEq(backedVault.redemptionSpread(), 50);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeRedemptionSpread(25);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(25);
        uint256 eta = parameters.pendingEta();
        assertEq(eta, vm.getBlockTimestamp() + 48 hours);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        assertEq(backedVault.redemptionCeilingCR(), 200);
        _apply();
        assertEq(backedVault.redemptionCeilingCR(), 175);
        health.setValue(0.6 ether);
        assertEq(backedVault.redemptionCeilingCR(), 225);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(100);
        _apply();
        assertEq(backedVault.redemptionCeilingCR(), 300);
        assertEq(backedVault.REDEMPTION_FEE_FLOOR_BPS(), FLOOR);
        assertEq(backedVault.REDEMPTION_FEE_CAP_BPS(), CAP);
    }

    function test_spreadBoundsRejectOnePointOutsideEitherLimit() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.RedemptionSpreadOutOfRange.selector, 24));
        parameters.proposeRedemptionSpread(24);
        vm.expectRevert(abi.encodeWithSelector(Parameters.RedemptionSpreadOutOfRange.selector, 101));
        parameters.proposeRedemptionSpread(101);
        vm.stopPrank();
        assertEq(parameters.pendingEta(), 0);
        assertGt(backedVault.redemptionCeilingCR(), backedVault.minCR());
    }
}
