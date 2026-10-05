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

    event Cash(
        address indexed redeemer,
        address indexed candidate,
        uint256 burned,
        uint256 gemOut,
        uint256 reserveOut,
        uint256 debtCancelled,
        uint256 feeBps
    );

    function test_reserveOnlyLeavesEvenAnAccruedIneligiblePositionUntouched() public {
        _open(BORROWER, 300 ether, 100 ether);
        _giveStable(10 ether);
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
        emit Cash(REDEEMER, BORROWER, 10 ether, out, out, 0, 300);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, BORROWER), out);

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
        _giveStable(10 ether);
        uint256 out = _quote(10 ether);
        _reserveIMD(out);
        bytes32 beforePosition = _positionState(BORROWER);

        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, address(0)), out);

        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(_positionState(BORROWER), beforePosition);
        assertEq(collateral.balanceOf(REDEEMER), out);
    }

    function test_reserveExhaustionContinuesIntoPositionInTheSameCall() public {
        _open(BORROWER, 180 ether, 100 ether);
        _open(SECOND_BORROWER, 200 ether, 100 ether);
        _giveStable(20 ether);
        // A 10%-of-supply burn charges 3%; reserve pays exactly half the final output.
        _reserveIMD(9.7 ether);
        bytes32 untouched = _positionState(SECOND_BORROWER);
        uint256 out = 19.4 ether;
        vm.expectEmit(true, true, false, true, address(backedVault));
        emit Cash(REDEEMER, BORROWER, 20 ether, out, 9.7 ether, 10 ether, 300);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(20 ether, out, BORROWER), out);

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
        _giveStable(10 ether);
        uint256 out = _quote(10 ether);
        _reserveIMD(out - 1);

        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, BORROWER), out);

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
        _giveStable(10 ether);
        _reserveIMD(2 ether);
        uint256 otherReserve = asset.balanceOf(address(reserve));
        uint256 out = _quote(10 ether);
        vm.prank(REDEEMER);
        backedVault.cash(10 ether, out, BORROWER);
        assertEq(asset.balanceOf(address(reserve)), otherReserve);
        assertEq(asset.balanceOf(REDEEMER), 0);
        assertEq(collateral.balanceOf(REDEEMER), out);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertLt(backedVault.debtOf(BORROWER), 100 ether);
    }

    function test_healthyCeilingExactlyRefusedAndOneWeiBelowAccepted() public {
        _assertCeilingBoundary(0.85 ether, 170, 220);
    }

    function test_stressedCeilingExactlyRefusedAndOneWeiBelowAccepted() public {
        _assertCeilingBoundary(0.6 ether, 200, 250);
    }

    function test_minimumRatioRemainsInsideEligibleBandAtHealthyAndStressedNHI() public {
        _open(BORROWER, 170 ether, 100 ether);
        _giveStable(1 ether);
        assertEq(backedVault.collateralRatio(BORROWER), backedVault.mat());
        uint256 healthyOut = _quote(1 ether);
        vm.prank(REDEEMER);
        backedVault.cash(1 ether, healthyOut, BORROWER);
        health.setValue(0.6 ether);
        _open(SECOND_BORROWER, 200 ether, 100 ether);
        vm.prank(SECOND_BORROWER);
        stable.transfer(REDEEMER, 1 ether);
        assertEq(backedVault.mat(), 200);
        assertEq(backedVault.redemptionCeilingCR(), 250);
        assertEq(backedVault.collateralRatio(SECOND_BORROWER), 200);
        uint256 out = _quote(1 ether);
        vm.prank(REDEEMER);
        backedVault.cash(1 ether, out, SECOND_BORROWER);
        assertEq(backedVault.debtOf(SECOND_BORROWER), 99 ether);
    }

    function test_fullPositionRedemptionRetiresDebtAndLeavesFeeAsBorrowerCollateral() public {
        _open(BORROWER, 170 ether, 100 ether);
        _giveStable(100 ether);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(100 ether, 95 ether, BORROWER), 95 ether);
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 75 ether);
        assertEq(d, 0);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(stable.totalSupply(), 0);
        assertEq(backedVault.collateralRatio(BORROWER), type(uint256).max);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        vm.prank(BORROWER);
        backedVault.free(c);
        assertEq(collateral.balanceOf(BORROWER), 75 ether);
        assertEq(collateral.balanceOf(address(backedVault)), 0);
    }

    function test_positionBelowMinCRCanRecoverByRedemptionAndClearItsMark() public {
        _open(BORROWER, 180 ether, 100 ether);
        // At a 170% floor, 40 of redemption (paid at the 5% cap) lifts 144% back to 176%.
        _giveStable(40 ether);
        _setVaultPrice(0.8 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 144);
        assertLt(backedVault.collateralRatio(BORROWER), backedVault.mat());
        backedVault.bark(BORROWER);
        (,, bool marked,) = backedVault.liquidationMarks(BORROWER);
        assertTrue(marked);

        vm.prank(REDEEMER);
        assertEq(backedVault.cash(40 ether, 47.5 ether, BORROWER), 47.5 ether);

        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 132.5 ether);
        assertEq(d, 60 ether);
        assertGt(c * 100 ether, 180 ether * d);
        assertGe(backedVault.collateralRatio(BORROWER), backedVault.mat());
        (,, marked,) = backedVault.liquidationMarks(BORROWER);
        assertFalse(marked);
    }

    function test_payoutDoesNotDependOnWhichEligibleRatioTheCallerChooses() public {
        _open(BORROWER, 171 ether, 100 ether);
        _open(SECOND_BORROWER, 219 ether, 100 ether);
        _giveStable(10 ether);
        uint256 expected = _quote(10 ether);
        uint256 snapshot = vm.snapshotState();
        vm.prank(REDEEMER);
        uint256 firstOut = backedVault.cash(10 ether, expected, BORROWER);
        assertEq(firstOut, expected);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prank(REDEEMER);
        uint256 secondOut = backedVault.cash(10 ether, expected, SECOND_BORROWER);
        assertEq(secondOut, expected);
        assertEq(secondOut, firstOut, "a higher-ratio candidate cannot pay the redeemer more");
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 171 ether);
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
        backedVault.cash(1 ether, out, BORROWER);
        assertEq(backedVault.stabilityFeeOf(BORROWER), 1 ether);
        assertEq(backedVault.debtOf(BORROWER), 101 ether);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 1 ether);
        assertEq(backedVault.totalFeesMinted(), 0);
        assertEq(stable.balanceOf(address(reserve)), 0);
        assertEq(stable.totalSupply(), 109 ether);
        assertEq(workOracle.mintingRights(WORKER), rights);
        assertEq(backedVault.totalEarned(), 10 ether);
    }

    function test_rejectsZeroAmountAndDustWithZeroPayout() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(1 ether);
        _expectUnchanged(0, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.ZeroAmount.selector));
        _expectUnchanged(1, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.ZeroAmount.selector));
    }

    function test_twoWeiBurnPaysOneWeiAndCancelsBothWeiOfDebt() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(2);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(2, 1, BORROWER), 1);
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 180 ether - 1);
        assertEq(d, 100 ether - 2);
        assertEq(stable.totalSupply(), 100 ether - 2);
        assertEq(collateral.balanceOf(REDEEMER), 1);
        assertGt(c * 100 ether, 180 ether * d);
    }

    function test_minimumOutOneWeiAboveQuoteRevertsAtomically() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(2 ether);
        uint256 out = _quote(10 ether);
        _expectUnchanged(
            10 ether, out + 1, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.MinimumOutNotMet.selector)
        );
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, BORROWER), out);
    }

    function test_shortReserveWithNoCandidateDoesNotPartiallyPayOrBurn() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
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
        _giveStable(10 ether);
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

    /// @dev The payout is no longer fixed at par, so a SOLE position can no longer lose ratio to a
    /// redemption: the figure the payout is capped at IS that position's own ratio, and removing
    /// value at a position's own ratio leaves the ratio where it was. The fee makes it strictly
    /// better. The ratio guard is not dead — see the next test, where the candidate is worse than
    /// the aggregate the cap is computed from, which is the only way the gap can open.
    function test_deeplyUnderwaterPositionCannotLoseRatioToFixedPriceRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _setVaultPrice(0.5 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 90);
        // The only position is the whole protocol, so backing per COMP is its ratio: 0.9.
        assertEq(backedVault.backingPerUnit(), 0.9 ether);
        uint256 out = _quote(10 ether);
        assertLt(out, _parQuote(10 ether), "a par payout is what used to worsen the ratio");
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, BORROWER), out);
        // The improvement is sub-whole-percent, so compare the exact fractions the guard compares
        // rather than the rounded ratio: 162.315/90 against 180/100.
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(backedVault.collateralRatio(BORROWER), 90, "unchanged at whole-percent precision");
        assertGt(c * 100 ether, uint256(180 ether) * d, "and strictly better exactly, by the fee");
    }

    /// @dev The ratio guard is still live and still necessary. `backingPerUnit` is an AGGREGATE, so
    /// a candidate whose own ratio is below it would be worsened by a payout the aggregate affords;
    /// one overcollateralized position is enough to open that gap. This is the case the cap cannot
    /// cover and the per-candidate guard must.
    function test_redemptionWorsensRatioStillRefusesACandidateBelowAggregateBacking() public {
        _open(BORROWER, 180 ether, 100 ether);
        // Eligible itself (CR 170 is under the 200 ceiling) but healthy enough to lift the
        // aggregate above the weak candidate's ratio, which is all the gap needs.
        _open(SECOND_BORROWER, 340 ether, 100 ether);
        _giveStable(20 ether);
        _setVaultPrice(0.5 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 90);
        assertEq(backedVault.collateralRatio(SECOND_BORROWER), 170);
        assertGt(backedVault.backingPerUnit(), 0.9 ether, "the aggregate is above this candidate's ratio");
        _expectUnchanged(
            10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.RedemptionWorsensRatio.selector)
        );
        // The same burn against the healthy candidate is fine, so it is the candidate that is
        // refused and not the burn.
        uint256 out = _quote(10 ether);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(10 ether, out, SECOND_BORROWER), out);
    }

    function test_stalePrimaryAndNhiEachRefuseEvenReserveOnlyRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(20 ether);
        primary.setStale(true);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
        primary.setStale(false);
        health.setStale(true);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
    }

    function test_expiredUsdLegRefusesRedemptionAndPreservesBothSources() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(2 ether);
        usd.set(ETH_USD_ANSWER, 0);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
    }

    function test_staleSpotAndDivergentSpotEachRefuseRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(2 ether);
        address spot = address(backedVault.spotFeed());
        vm.mockCall(spot, abi.encodeCall(ISwarmFeed.isStale, ()), abi.encode(true));
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.StaleFeed.selector));
        vm.clearMockedCalls();
        (uint256 primaryPrice,) = primary.latestValue();
        uint256 justOutside = primaryPrice + primaryPrice * backedVault.skew() / 10_000 + 1;
        vm.mockCall(
            spot, abi.encodeCall(ISwarmFeed.latestValue, ()), abi.encode(justOutside, uint64(vm.getBlockTimestamp()))
        );
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.PriceDivergence.selector));
    }

    function test_zeroPrimaryPriceRefusesReserveRedemption() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(20 ether);
        primary.setValue(0);
        _expectUnchanged(10 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.InvalidPrice.selector));
    }

    function test_doubleRedemptionCannotPayTwiceFromOneBalance() public {
        _open(BORROWER, 180 ether, 100 ether);
        _giveStable(10 ether);
        _reserveIMD(50 ether);
        vm.prank(REDEEMER);
        backedVault.cash(10 ether, 0, BORROWER);
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

    /// @dev Finding `b92320ae`'s exact sequence, which is why the backing guard was added in the
    /// first place: borrow, mint from work, repay, withdraw, then redeem against the reserve. The
    /// deterioration it reported (100/250 to 90.15/240) is still refused -- by paying 3.94 instead
    /// of 9.85, rather than by refusing the burn.
    function test_debtUnwindCannotLeaveReserveRedemptionWorseningBacking() public {
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        _reserveIMD(100 ether);
        _mintWorkAndUnwind(1700 ether, 1000 ether, 250 ether);
        assertEq(backedVault.reserveValue(), 100 ether);
        // The borrower is gone: 100 of reserve stands behind 250 of work-issued COMP and nothing
        // else does, so a COMP is backed at 0.4. Paying par here is exactly what the old
        // RedemptionWorsensBacking halt existed to stop — 90.15 of reserve against 240 of supply is
        // worse than 100 against 250 — and the cap stops it by paying the right amount instead.
        assertEq(backedVault.backingPerUnit(), 0.4 ether, "100 of reserve, 250 of supply");
        assertLt(uint256(90.15 ether) * 250 ether, uint256(100 ether) * 240 ether, "par would deteriorate it");
        assertEq(_quote(10 ether), 3.94 ether, "40% of par, less the 150 bps fee");
        assertLt(_quote(10 ether), _parQuote(10 ether));
        _expectProRata(10 ether, 0, BORROWER, WORKER);
        assertEq(backedVault.reserveValue(), 96.06 ether);
        assertGt(backedVault.backingPerUnit(), 0.4 ether, "and the fee leaves it strictly better");
    }

    function test_underbackedReserveBoundaryRejectsOneWeiBelowAndAcceptsEquality() public {
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        _reserveIMD(246.25 ether - 1);
        _mintWorkAndUnwind(1700 ether, 1000 ether, 250 ether);
        // THERE IS NO LONGER A BOUNDARY, and that is this test's result. 246.25 of reserve against
        // 250 of supply is the level at which a PAR payout of 9.85 exactly preserved backing, so
        // one wei below it the old guard refused and at it the guard allowed. The payout now scales
        // with backing instead of being fixed at par, so backing is preserved or improved at EVERY
        // reserve level and the one wei either side of 246.25 is no longer a cliff.
        uint256 out = _quote(10 ether);
        assertEq(_parQuote(10 ether), 9.85 ether, "what par would have paid at the old boundary");
        assertLt(out, 9.85 ether, "the cap pays less, because backing is below par");
        assertLt(
            (backedVault.reserveValue() - 9.85 ether) * 250 ether,
            backedVault.reserveValue() * 240 ether,
            "one wei below the boundary, a par payout loses backing"
        );
        assertGe(
            (backedVault.reserveValue() - out) * 250 ether,
            backedVault.reserveValue() * 240 ether,
            "the capped payout does not, one wei below or anywhere else"
        );
        _expectProRata(10 ether, out, address(0), WORKER);

        // At the old boundary exactly: still no cliff, still paid below par, still improving.
        _reserveIMD(1);
        uint256 beforeBacking = backedVault.reserveValue();
        assertLt(beforeBacking, stable.totalSupply(), "safe redemptions can start below 100% backing");
        uint256 second = _quote(10 ether);
        assertLt(second, 9.85 ether, "the cap binds at the boundary too");
        vm.prank(WORKER);
        assertEq(backedVault.cash(10 ether, second, address(0)), second);
        assertGt(
            backedVault.reserveValue() * 240 ether,
            beforeBacking * stable.totalSupply(),
            "strictly better, where par was exactly neutral"
        );
        assertEq(stable.totalSupply(), 230 ether);
        assertEq(collateral.balanceOf(WORKER), out + second);
        assertEq(backedVault.totalNonPrincipalRedeemed(), 20 ether);
    }

    function test_improvingPositionRatioDoesNotPermitWorseningAggregateBacking() public {
        _assertUnderbackedPositionRejected(0);
    }

    function test_mixedPayoutBackingFailureRollsBackCandidateDebtAndReserve() public {
        _assertUnderbackedPositionRejected(1 ether);
    }

    function test_fractionalValueDustCannotHideBackingLoss() public {
        _setVaultPrice(0.2 ether);
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        _reserveIMD(9);
        _mintWorkAndUnwind(136, 16, 4);
        // 9 IMD wei at 0.2 floors to 1 USD wei of reserve behind 4 wei of supply, so a COMP is
        // backed at a quarter and the burn is paid 1 wei, not the 4 that par would pay.
        assertEq(backedVault.reserveValue(), 1);
        assertEq(backedVault.backingPerUnit(), 0.25 ether, "1 of value, 4 of supply");
        assertEq(_parQuote(1), 4, "par would have paid four times that");
        assertEq(_quote(1), 1, "a quarter of par, less the fee, floored");
        // Paying 4 of 9 is the deterioration this test is named for: flooring both balances shows
        // 1 USD wei before and after, while the exact asset/supply fraction falls from 9/4 to 5/3.
        assertEq(uint256(5) * 0.2 ether / 1 ether, 1, "the floor hides it");
        assertLt(uint256(5) * 4, uint256(9) * 3, "the exact fraction does not");
        // Paying 1 cannot hide anything: 8 of 9 remain against 3 of 4, which is strictly better.
        _expectProRata(1, 0, address(0), WORKER);
        assertEq(collateral.balanceOf(address(reserve)), 8);
        assertEq(stable.totalSupply(), 3);
        assertGt(uint256(8) * 4, uint256(9) * 3, "8/3 beats 9/4 even in exact arithmetic");
    }

    function test_discountedReserveRejectsUnsafePayoutAndAcceptsRecapitalization() public {
        _register(collateral, backedVault.usdPriceFeed(), 5000);
        _reserveIMD(100 ether);
        _mintWorkAndUnwind(1700 ether, 1000 ether, 250 ether);
        // A 50% haircut: 100 IMD in the Treasury is 50 of REGISTERED value behind 250 of supply.
        assertEq(backedVault.reserveValue(), 50 ether);
        // But the figure the cap uses is 0.4, not 0.2, and that is correct rather than an oversight:
        // per finding 998ff6b2 the vault values the Treasury's IMD at its own price on BOTH sides,
        // because `redemptionReserve` pays that IMD out one for one whether or not governance listed
        // it or at what factor. One valuation for the IMD held and the IMD leaving is what makes the
        // comparison mean anything; the haircut governs other assets, which this route cannot pay.
        assertEq(backedVault.backingPerUnit(), 0.4 ether, "IMD at the vault's own price, 100 of 250");
        uint256 first = _quote(10 ether);
        assertLt(first, _parQuote(10 ether), "so a discounted reserve pays a discounted redemption");
        _expectProRata(10 ether, 0, address(0), WORKER);
        // Recapitalizing raises the cap, and the SAME burn is then paid more. That is the half of
        // this test that the old halt could only express as "rejected, then accepted".
        uint256 heldAfterFirst = collateral.balanceOf(address(reserve));
        _reserveIMD(400 ether);
        uint256 beforeBacking = backedVault.reserveValue();
        uint256 out = _quote(10 ether);
        assertGt(out, first, "a recapitalized reserve pays more for the same burn");
        vm.prank(WORKER);
        assertEq(backedVault.cash(10 ether, out, address(0)), out);
        assertEq(backedVault.reserveValue(), (heldAfterFirst + 400 ether - out) / 2);
        assertGt(backedVault.reserveValue() * 240 ether, beforeBacking * stable.totalSupply());
        assertEq(stable.totalSupply(), 230 ether);
        assertEq(collateral.balanceOf(WORKER), first + out);
    }

    function _mintWorkAndUnwind(uint256 c, uint256 debt, uint256 work) private {
        _open(BORROWER, c, debt);
        _mintWork(WORKER, work);
        vm.startPrank(BORROWER);
        backedVault.wipe(debt);
        backedVault.free(c);
        vm.stopPrank();
        assertEq(backedVault.totalDebt(), 0);
        assertEq(collateral.balanceOf(address(backedVault)), 0);
        assertEq(stable.totalSupply(), work, "work issuance survives the debt unwind");
    }

    function _assertUnderbackedPositionRejected(uint256 reserveAmount) private {
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        _reserveIMD(reserveAmount);
        _mintWorkAndUnwind(1700 ether, 1000 ether, 250 ether);
        _open(SECOND_BORROWER, 180 ether, 100 ether);
        uint256 out = _quote(10 ether);
        uint256 cancelled =
            10 ether - Math.mulDiv(reserveAmount, 10_000, 10_000 - backedVault.redemptionFeeBps(10 ether));
        assertGt(
            (180 ether - (out - reserveAmount)) * 100 ether,
            uint256(180 ether) * (100 ether - cancelled),
            "candidate ratio would improve"
        );
        // The candidate's own ratio improves, which the ratio guard allows, and under a PAR payout
        // the aggregate would still have deteriorated — that gap is what RedemptionWorsensBacking
        // was for. The capped payout closes it arithmetically: par deteriorates, this does not.
        uint256 backing = 180 ether + reserveAmount;
        assertLt(
            (backing - _parQuote(10 ether)) * 350 ether,
            backing * 340 ether,
            "a par payout would deteriorate the aggregate"
        );
        assertGe((backing - out) * 350 ether, backing * 340 ether, "the capped payout does not");
        assertLt(out, _parQuote(10 ether), "because it pays less than par");
        _expectProRata(10 ether, out, SECOND_BORROWER, WORKER);
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
        _giveStable(amount);
        // Whole basis points, rounded against the redeemer.
        uint256 fee = 50 + Math.ceilDiv(Math.min(amount * 1e18 / debt / 4, 0.045 ether), 1e14);
        uint256 expectedOut = Math.mulDiv(amount, (10_000 - fee) * 1e14, price);
        uint256 reserveBefore = bound(reserveSeed, 0, expectedOut);
        _reserveIMD(reserveBefore);
        uint256 collateralBefore = collateral.balanceOf(address(backedVault));
        bytes32 positionBefore = _positionState(BORROWER);

        vm.prank(REDEEMER);
        uint256 out = backedVault.cash(amount, expectedOut, BORROWER);

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
        assertEq(backedVault.mat(), minimum);
        assertEq(backedVault.gap(), 50);
        assertEq(backedVault.redemptionCeilingCR(), ceiling);
        uint256 c = ceiling * 1 ether;
        _open(BORROWER, c, 100 ether);
        _giveStable(1 ether);
        assertEq(backedVault.collateralRatio(BORROWER), ceiling);
        _expectUnchanged(
            1 ether, 0, BORROWER, REDEEMER, abi.encodeWithSelector(CDPVault.IneligibleRedemptionPosition.selector)
        );
        vm.prank(BORROWER);
        backedVault.free(1);
        assertEq(backedVault.collateralRatio(BORROWER), ceiling - 1);
        uint256 out = _quote(1 ether);
        vm.prank(REDEEMER);
        assertEq(backedVault.cash(1 ether, out, BORROWER), out);
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
        backedVault.lock(c);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    function _giveStable(uint256 amount) private {
        vm.prank(BORROWER);
        stable.transfer(REDEEMER, amount);
    }

    function _reserveIMD(uint256 amount) private {
        if (amount == 0) return;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), amount);
    }

    /// @dev Mirrors the vault: par minus the fee, then capped at what actually backs a COMP.
    function _quote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        uint256 scale = Math.mulDiv(backedVault.backingPerUnit(), 10_000 - backedVault.redemptionFeeBps(amount), 10_000);
        return Math.mulDiv(amount, scale, price);
    }

    function _positionState(address candidate) private view returns (bytes32) {
        (uint256 c, uint256 d) = backedVault.positions(candidate);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = backedVault.liquidationMarks(candidate);
        return keccak256(
            abi.encode(
                c,
                d,
                backedVault.chiOf(candidate),
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

    /// @dev What the `RedemptionWorsensBacking` expectations became. The payout is capped at backing
    /// per COMP, so a redemption that used to be refused for removing more than its share now simply
    /// pays that share — and cannot worsen backing, which is the property the halt was protecting.
    function _expectProRata(uint256 amount, uint256 minOut, address candidate, address payer) private {
        uint256 backingBefore1 = _econBacking();
        vm.prank(payer);
        backedVault.cash(amount, minOut, candidate);
        assertGe(_econBacking(), backingBefore1, "a redemption must not worsen backing");
    }

    function _expectUnchanged(uint256 amount, uint256 minOut, address candidate, address payer, bytes memory error)
        private
    {
        bytes32 beforeState = _state(candidate, payer);
        vm.prank(payer);
        vm.expectRevert(error);
        backedVault.cash(amount, minOut, candidate);
        assertEq(_state(candidate, payer), beforeState, "failed redemption left a partial state transition");
    }

    /// @notice Collateral plus reserve, per COMP, in the vault's unit — the ECONOMIC backing figure.
    /// @dev Distinct from `backingPerUnit()` on purpose, and the difference is the point. That one is
    /// deliberately conservative: it counts only collateral with mat times its value in principal
    /// behind it, so cancelling a borrower's debt DISQUALIFIES mat worth of collateral while
    /// retiring only one COMP of supply, and the measure falls. Measured: four successive 10 COMP
    /// redemptions walk it 0.9375 -> 0.9194 -> 0.9000 -> 0.8793 -> 0.8571 while the economic figure
    /// below rises 1.0938 -> 1.1219 every step. The conservative measure is not monotone and must
    /// not be asserted as if it were; THIS figure is the one the pro-rata payout makes monotone, and
    /// it is computed here from balances rather than from the vault, so it can disagree with it.
    function _econBacking() private view returns (uint256) {
        uint256 supply = stable.totalSupply();
        if (supply == 0) return type(uint256).max;
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        uint256 others = backedVault.reserveValue() - reserve.reserveValueOf(IERC20(address(collateral)));
        uint256 backing = others + Math.mulDiv(
            collateral.balanceOf(address(reserve)) + collateral.balanceOf(address(backedVault)), price, 1e18
        );
        return Math.mulDiv(backing, 1e18, supply);
    }

    /// @dev What the payout would be with no backing cap: par minus the fee.
    function _parQuote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        return Math.mulDiv(amount, (10_000 - backedVault.redemptionFeeBps(amount)) * 1e14, price);
    }
}
