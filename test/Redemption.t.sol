// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Treasury} from "src/Treasury.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice Exercises redemption through the shipped vault, Treasury and USD price composition.
contract RedemptionTest is WorkBackingFixture {
    address private constant REDEEMER = address(0xDEED);
    address private constant SECOND_BORROWER = address(0xBEE);

    event Redeemed(
        address indexed redeemer,
        address indexed candidate,
        uint256 compBurned,
        uint256 imdOut,
        uint256 reserveOut,
        uint256 debtCancelled,
        uint256 feeBps
    );

    function test_reserveOnlyLeavesEvenAnAccruedIneligiblePositionUntouched() public {
        _open(BORROWER, 300 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(30 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _refreshEthUsd();
        assertGt(backedVault.stabilityFeeOf(BORROWER), 0);
        assertGe(backedVault.collateralRatio(BORROWER), backedVault.redemptionCeilingCR());
        bytes32 beforePosition = _positionState(BORROWER);
        uint256 supply = stable.totalSupply();
        uint256 principal = backedVault.totalDebt();
        uint256 out = _quote(10 ether);

        vm.expectEmit(true, true, false, true, address(backedVault));
        emit Redeemed(REDEEMER, BORROWER, 10 ether, out, out, 0, 300);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);

        assertEq(_positionState(BORROWER), beforePosition, "reserve redemption touched position accounting");
        assertEq(backedVault.totalDebt(), principal);
        assertEq(collateral.balanceOf(address(backedVault)), 300 ether);
        assertEq(collateral.balanceOf(address(reserve)), 30 ether - out);
        assertEq(collateral.balanceOf(REDEEMER), out);
        assertEq(stable.totalSupply(), supply - 10 ether);
        assertEq(stable.balanceOf(REDEEMER), 0);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 10 ether);
        assertEq(stable.balanceOf(address(reserve)), 0, "redemption fee must stay in backing");
    }

    function test_exactReserveCapacityNeedsNoCandidate() public {
        _open(BORROWER, 200 ether, 100 ether);
        _giveCOMP(10 ether);
        uint256 out = _quote(10 ether);
        _reserveIMD(out);
        bytes32 beforePosition = _positionState(BORROWER);

        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(10 ether, out, address(0)), out);

        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(_positionState(BORROWER), beforePosition);
        assertEq(collateral.balanceOf(REDEEMER), out);
    }

    function test_reserveExhaustionContinuesIntoPositionInTheSameCall() public {
        _open(BORROWER, 180 ether, 100 ether);
        _open(SECOND_BORROWER, 200 ether, 100 ether);
        _giveCOMP(20 ether);
        // A 10%-of-supply burn charges 3%; reserve pays exactly half the final output.
        _reserveIMD(9.7 ether);
        bytes32 untouched = _positionState(SECOND_BORROWER);
        uint256 out = 19.4 ether;
        vm.expectEmit(true, true, false, true, address(backedVault));
        emit Redeemed(REDEEMER, BORROWER, 20 ether, out, 9.7 ether, 10 ether, 300);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(20 ether, out, BORROWER), out);

        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 170.3 ether);
        assertEq(d, 90 ether);
        assertGt(c * 100 ether, 180 ether * d, "exact collateral/debt ratio must rise");
        assertEq(_positionState(SECOND_BORROWER), untouched);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(collateral.balanceOf(address(backedVault)), 370.3 ether);
        assertEq(collateral.balanceOf(REDEEMER), out);
        assertEq(stable.totalSupply(), 180 ether);
        assertEq(backedVault.totalDebt(), 190 ether);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 10 ether);
    }

    function test_oneWeiReserveShortfallCancelsEnoughPositionDebtForTheLastWei() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        uint256 out = _quote(10 ether);
        _reserveIMD(out - 1);

        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);

        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 180 ether - 1);
        assertEq(d, 100 ether - 2, "reserve-funded debt rounds down, protecting the borrower");
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(collateral.balanceOf(REDEEMER), out);
        assertEq(stable.totalSupply(), 90 ether);
        assertGt(c * 100 ether, 180 ether * d);
    }

    function test_registeredNonImdReserveIsNeverPaidOutByRedemption() public {
        _fundReserve(100 ether);
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(2 ether);
        uint256 otherReserve = asset.balanceOf(address(reserve));
        uint256 out = _quote(10 ether);
        vm.prank(REDEEMER);
        backedVault.redeem(10 ether, out, BORROWER);
        assertEq(asset.balanceOf(address(reserve)), otherReserve);
        assertEq(asset.balanceOf(REDEEMER), 0);
        assertEq(collateral.balanceOf(REDEEMER), out);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertLt(backedVault.debtOf(BORROWER), 100 ether);
    }

    function test_healthyCeilingExactlyRefusedAndOneWeiBelowAccepted() public {
        _assertCeilingBoundary(0.85 ether, 150, 200);
    }

    function test_stressedCeilingExactlyRefusedAndOneWeiBelowAccepted() public {
        _assertCeilingBoundary(0.6 ether, 200, 250);
    }

    function test_minimumRatioRemainsInsideEligibleBandAtHealthyAndStressedNHI() public {
        _open(BORROWER, 150 ether, 100 ether);
        _giveCOMP(1 ether);
        assertEq(backedVault.collateralRatio(BORROWER), backedVault.minCR());
        uint256 healthyOut = _quote(1 ether);
        vm.prank(REDEEMER);
        backedVault.redeem(1 ether, healthyOut, BORROWER);
        health.setValue(0.6 ether);
        _open(SECOND_BORROWER, 200 ether, 100 ether);
        vm.prank(SECOND_BORROWER);
        stable.transfer(REDEEMER, 1 ether);
        assertEq(backedVault.minCR(), 200);
        assertEq(backedVault.redemptionCeilingCR(), 250);
        assertEq(backedVault.collateralRatio(SECOND_BORROWER), 200);
        uint256 out = _quote(1 ether);
        vm.prank(REDEEMER);
        backedVault.redeem(1 ether, out, SECOND_BORROWER);
        assertEq(backedVault.debtOf(SECOND_BORROWER), 99 ether);
    }

    function test_fullPositionRedemptionRetiresDebtAndLeavesFeeAsBorrowerCollateral() public {
        _open(BORROWER, 150 ether, 100 ether);
        _giveCOMP(100 ether);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(100 ether, 95 ether, BORROWER), 95 ether);
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 55 ether);
        assertEq(d, 0);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(stable.totalSupply(), 0);
        assertEq(backedVault.collateralRatio(BORROWER), type(uint256).max);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        vm.prank(BORROWER);
        backedVault.withdrawCollateral(c);
        assertEq(collateral.balanceOf(BORROWER), 55 ether);
        assertEq(collateral.balanceOf(address(backedVault)), 0);
    }

    function test_positionBelowMinCRCanRecoverByRedemptionAndClearItsMark() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(20 ether);
        _setVaultPrice(0.8 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 144);
        assertLt(backedVault.collateralRatio(BORROWER), backedVault.minCR());
        backedVault.markUnderwater(BORROWER);
        (,, bool marked,) = backedVault.liquidationMarks(BORROWER);
        assertTrue(marked);

        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(20 ether, 23.75 ether, BORROWER), 23.75 ether);

        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 156.25 ether);
        assertEq(d, 80 ether);
        assertGt(c * 100 ether, 180 ether * d);
        assertGe(backedVault.collateralRatio(BORROWER), backedVault.minCR());
        (,, marked,) = backedVault.liquidationMarks(BORROWER);
        assertFalse(marked);
    }

    function test_payoutDoesNotDependOnWhichEligibleRatioTheCallerChooses() public {
        _open(BORROWER, 151 ether, 100 ether);
        _open(SECOND_BORROWER, 199 ether, 100 ether);
        _giveCOMP(10 ether);
        uint256 expected = _quote(10 ether);
        uint256 snapshot = vm.snapshotState();
        vm.prank(REDEEMER);
        uint256 firstOut = backedVault.redeem(10 ether, expected, BORROWER);
        assertEq(firstOut, expected);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prank(REDEEMER);
        uint256 secondOut = backedVault.redeem(10 ether, expected, SECOND_BORROWER);
        assertEq(secondOut, expected);
        assertEq(secondOut, firstOut, "a higher-ratio candidate cannot pay the redeemer more");
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 151 ether);
        assertEq(d, 100 ether);
    }

    function test_feeDebtIsCancelledWithoutMintingFeesOrRestoringWorkRights() public {
        _open(BORROWER, 180 ether, 100 ether);
        _mintWork(WORKER, 10 ether);
        uint256 rights = workOracle.mintingRights(WORKER);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _refreshEthUsd();
        assertEq(backedVault.stabilityFeeOf(BORROWER), 2 ether);
        assertEq(backedVault.debtOf(BORROWER), 102 ether);
        uint256 out = _quote(1 ether);
        vm.prank(WORKER);
        backedVault.redeem(1 ether, out, BORROWER);
        assertEq(backedVault.stabilityFeeOf(BORROWER), 1 ether);
        assertEq(backedVault.debtOf(BORROWER), 101 ether);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 1 ether);
        assertEq(backedVault.totalFeesMinted(), 0);
        assertEq(stable.balanceOf(address(reserve)), 0);
        assertEq(stable.totalSupply(), 109 ether);
        assertEq(workOracle.mintingRights(WORKER), rights);
        assertEq(backedVault.totalWorkMinted(), 10 ether);
    }

    function test_rejectsZeroAmountAndDustWithZeroPayout() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(1 ether);
        _expectUnchanged(0, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.ZeroAmount.selector));
        _expectUnchanged(1, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.ZeroAmount.selector));
    }

    function test_twoWeiBurnPaysOneWeiAndCancelsBothWeiOfDebt() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(2);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(2, 1, BORROWER), 1);
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 180 ether - 1);
        assertEq(d, 100 ether - 2);
        assertEq(stable.totalSupply(), 100 ether - 2);
        assertEq(collateral.balanceOf(REDEEMER), 1);
        assertGt(c * 100 ether, 180 ether * d);
    }

    function test_minimumOutOneWeiAboveQuoteRevertsAtomically() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(2 ether);
        uint256 out = _quote(10 ether);
        _expectUnchanged(
            10 ether, out + 1, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.MinimumOutNotMet.selector)
        );
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);
    }

    function test_shortReserveWithNoCandidateDoesNotPartiallyPayOrBurn() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        uint256 out = _quote(10 ether);
        _reserveIMD(out - 1);
        _expectUnchanged(
            10 ether, 0, address(0), REDEEMER, abi.encodeWithSelector(CDPVault.IneligibleRedemptionPosition.selector)
        );
    }

    function test_candidateWithTooLittleDebtRevertsWithoutPartialFill() public {
        _open(BORROWER, 18 ether, 10 ether);
        _open(SECOND_BORROWER, 180 ether, 100 ether);
        vm.prank(SECOND_BORROWER);
        stable.transfer(REDEEMER, 20 ether);
        _reserveIMD(1 ether);
        _expectUnchanged(20 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.ExcessRepayment.selector));
    }

    function test_amountAboveTotalSupplyIsRefusedBeforeAnyPayout() public {
        _open(BORROWER, 180 ether, 100 ether);
        _reserveIMD(200 ether);
        _expectUnchanged(
            100 ether + 1, 0, BORROWER, BORROWER, abi.encodeWithSelector(CDPVault.ExcessRepayment.selector)
        );
    }

    function test_unfundedCallerRollsBackDebtCollateralFeesAndReserveAccounting() public {
        _open(BORROWER, 180 ether, 100 ether);
        _reserveIMD(2 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _refreshEthUsd();
        _expectUnchanged(
            10 ether,
            0,
            BORROWER,
            REDEEMER,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, REDEEMER, 0, 10 ether)
        );
    }

    function test_failedPositionTransferRollsBackTheEarlierReserveTransferAndBurn() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(2 ether);
        uint256 positionPayout = _quote(10 ether) - 2 ether;
        vm.mockCall(address(collateral), abi.encodeCall(IERC20.transfer, (REDEEMER, positionPayout)), abi.encode(false));
        _expectUnchanged(
            10 ether,
            0,
            BORROWER,
            REDEEMER,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(collateral))
        );
    }

    function test_deeplyUnderwaterPositionCannotLoseRatioToFixedPriceRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _setVaultPrice(0.5 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 90);
        _expectUnchanged(
            10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.RedemptionWorsensRatio.selector)
        );
    }

    function test_stalePrimaryAndNhiEachRefuseEvenReserveOnlyRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(20 ether);
        primary.setStale(true);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
        primary.setStale(false);
        health.setStale(true);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
    }

    function test_expiredUsdLegRefusesRedemptionAndPreservesBothSources() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(2 ether);
        usd.set(ETH_USD_ANSWER, 0);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
    }

    function test_staleSpotAndDivergentSpotEachRefuseRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(2 ether);
        address spot = address(backedVault.spotFeed());
        vm.mockCall(spot, abi.encodeCall(ISwarmFeed.isStale, ()), abi.encode(true));
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
        vm.clearMockedCalls();
        (uint256 primaryPrice,) = primary.latestValue();
        uint256 justOutside = primaryPrice + primaryPrice * backedVault.maxDivergenceBps() / 10_000 + 1;
        vm.mockCall(
            spot, abi.encodeCall(ISwarmFeed.latestValue, ()), abi.encode(justOutside, uint64(vm.getBlockTimestamp()))
        );
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.PriceDivergence.selector));
    }

    function test_zeroPrimaryPriceRefusesReserveRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(20 ether);
        primary.setValue(0);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.InvalidPrice.selector));
    }

    function test_doubleRedemptionCannotPayTwiceFromOneBalance() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveCOMP(10 ether);
        _reserveIMD(50 ether);
        vm.prank(REDEEMER);
        backedVault.redeem(10 ether, 0, BORROWER);
        _expectUnchanged(
            10 ether,
            0,
            BORROWER,
            REDEEMER,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, REDEEMER, 0, 10 ether)
        );
    }

    function test_treasuryRedemptionCannotBeCalledDirectlyEvenByGovernor() public {
        _reserveIMD(100 ether);
        vm.prank(REDEEMER);
        vm.expectRevert(Treasury.Unauthorized.selector);
        reserve.redeemIMD(REDEEMER, 1 ether);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.Unauthorized.selector);
        reserve.redeemIMD(APPROVED_OPERATOR, 1 ether);
        assertEq(collateral.balanceOf(address(reserve)), 100 ether);
        assertEq(collateral.balanceOf(REDEEMER), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_priceRoundingReserveSplitAndExactRatioConservation(
        uint256 debtSeed,
        uint256 amountSeed,
        uint256 priceSeed,
        uint256 reserveSeed
    ) public {
        uint256 debt = bound(debtSeed, 1 ether, 1e27);
        uint256 amount = bound(amountSeed, 10_000, debt / 2);
        // Every generated price is exactly representable through both real USD price legs.
        uint256 price = bound(priceSeed, 1, 1000) * 0.01 ether;
        _setVaultPrice(price);
        uint256 initialCollateral = Math.mulDiv(debt, 1.9 ether, price, Math.Rounding.Ceil);
        _open(BORROWER, initialCollateral, debt);
        _giveCOMP(amount);
        uint256 fee = 50 + Math.min(amount * 1e18 / debt / 4, 0.045 ether) / 1e14;
        uint256 expectedOut = Math.mulDiv(amount, (10_000 - fee) * 1e14, price);
        uint256 reserveBefore = bound(reserveSeed, 0, expectedOut);
        _reserveIMD(reserveBefore);
        uint256 collateralBefore = collateral.balanceOf(address(backedVault));
        bytes32 positionBefore = _positionState(BORROWER);

        vm.prank(REDEEMER);
        uint256 out = backedVault.redeem(amount, expectedOut, BORROWER);

        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(out, expectedOut, "one feed-priced, rounded-down payout");
        assertEq(collateral.balanceOf(REDEEMER), expectedOut);
        assertEq(stable.totalSupply(), debt - amount);
        assertEq(stable.balanceOf(REDEEMER), 0);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(collateralBefore - collateral.balanceOf(address(backedVault)), expectedOut - reserveBefore);
        assertEq(initialCollateral - c, expectedOut - reserveBefore);
        assertGe(c * debt, initialCollateral * d, "exact position ratio fell");
        // Same price before and after: cancel it from the exact backing/supply comparison.
        assertGe(c * debt, (initialCollateral + reserveBefore) * (debt - amount), "aggregate backing ratio fell");
        if (reserveBefore == expectedOut) {
            assertEq(_positionState(BORROWER), positionBefore);
        } else {
            assertLt(d, debt, "collateral must never leave without debt retirement");
            assertGe((debt - d) * (10_000 - fee) * 1e14, (initialCollateral - c) * price);
        }
        assertEq(stable.balanceOf(address(reserve)), 0);
        assertEq(backedVault.totalFeesMinted(), 0);
    }

    function _assertCeilingBoundary(uint256 nhi, uint256 minimum, uint256 ceiling) private {
        health.setValue(nhi);
        assertEq(backedVault.minCR(), minimum);
        assertEq(backedVault.redemptionSpread(), 50);
        assertEq(backedVault.redemptionCeilingCR(), ceiling);
        uint256 c = ceiling * 1 ether;
        _open(BORROWER, c, 100 ether);
        _giveCOMP(1 ether);
        assertEq(backedVault.collateralRatio(BORROWER), ceiling);
        _expectUnchanged(
            1 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.IneligibleRedemptionPosition.selector)
        );
        vm.prank(BORROWER);
        backedVault.withdrawCollateral(1);
        assertEq(backedVault.collateralRatio(BORROWER), ceiling - 1);
        uint256 out = _quote(1 ether);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(1 ether, out, BORROWER), out);
        (uint256 afterCollateral, uint256 afterDebt) = backedVault.positions(BORROWER);
        assertEq(afterCollateral, c - 1 - out);
        assertEq(afterDebt, 99 ether);
        assertGt(afterCollateral * 100 ether, (c - 1) * afterDebt);
    }

    function _open(address who, uint256 c, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(who, c);
        vm.startPrank(who);
        collateral.approve(address(backedVault), c);
        backedVault.depositCollateral(c);
        backedVault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _giveCOMP(uint256 amount) private {
        vm.prank(BORROWER);
        stable.transfer(REDEEMER, amount);
    }

    function _reserveIMD(uint256 amount) private {
        if (amount == 0) return;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), amount);
    }

    function _quote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        return Math.mulDiv(amount, (10_000 - backedVault.redemptionFeeBps(amount)) * 1e14, price);
    }

    function _positionState(address candidate) private view returns (bytes32) {
        (uint256 c, uint256 d) = backedVault.positions(candidate);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = backedVault.liquidationMarks(candidate);
        return keccak256(
            abi.encode(
                c,
                d,
                backedVault.debtIndexOf(candidate),
                backedVault.stabilityFeeOf(candidate),
                markedAt,
                grace,
                marked,
                marker
            )
        );
    }

    function _state(address candidate, address payer) private view returns (bytes32) {
        bytes32 balances = keccak256(
            abi.encode(
                collateral.balanceOf(address(reserve)),
                collateral.balanceOf(address(backedVault)),
                collateral.balanceOf(payer),
                stable.balanceOf(payer),
                stable.balanceOf(address(reserve)),
                stable.totalSupply(),
                reserve.lastSynced(IERC20(address(collateral))),
                reserve.totalReceived(IERC20(address(collateral)))
            )
        );
        return keccak256(
            abi.encode(
                balances,
                _positionState(candidate),
                backedVault.totalDebt(),
                backedVault.totalBadDebt(),
                backedVault.totalNonPrincipalRedeemed(),
                backedVault.totalFeesMinted(),
                backedVault.redemptionBaseRate(),
                backedVault.lastRedemptionAt()
            )
        );
    }

    function _expectUnchanged(uint256 amount, uint256 minOut, address candidate, address payer, bytes memory error)
        private
    {
        bytes32 beforeState = _state(candidate, payer);
        vm.prank(payer);
        vm.expectRevert(error);
        backedVault.redeem(amount, minOut, candidate);
        assertEq(_state(candidate, payer), beforeState, "failed redemption left a partial state transition");
    }
}
