// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev All unhealthy positions arise through feed changes after a successful collateralized borrow.
/// The local feeds model accepted values and freshness; no vault or token storage is patched.
contract LiquidationTest is ProtocolFixture {
    function _priceDrivenPosition(uint256 collateral) internal {
        priceFeed.setValue(2 ether);
        _open(alice, collateral, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        priceFeed.setValue(1 ether);
        assertLt(vault.collateralRatio(alice), vault.minCR());
    }

    function _markAndWait(address owner) internal returns (uint256 markedAt, uint256 grace) {
        vault.markUnderwater(owner);
        bool marked;
        (markedAt, grace, marked) = vault.liquidationMarks(owner);
        assertTrue(marked);
        vm.warp(markedAt + grace);
    }

    function _assertMark(address owner, uint256 markedAt, uint256 grace, bool marked) internal view {
        (uint256 actualTime, uint256 actualGrace, bool actualMarked) = vault.liquidationMarks(owner);
        assertEq(actualTime, markedAt, "mark timestamp");
        assertEq(actualGrace, grace, "snapshotted grace");
        assertEq(actualMarked, marked, "mark state");
    }

    function test_partialLiquidationPaysExactBonusAndClearsRecoveredMark() public {
        _priceDrivenPosition(130 ether);
        _markAndWait(alice);
        uint256 liquidatorBalance = imd.balanceOf(bob);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CDPVault.Liquidated(alice, bob, 50 ether, 55 ether);
        vault.liquidate(alice, 50 ether);

        _assertPosition(alice, 75 ether, 50 ether);
        _assertPosition(bob, 0, 0);
        _assertMark(alice, 0, 0, false);
        assertEq(vault.collateralRatio(alice), 150);
        assertEq(imd.balanceOf(bob) - liquidatorBalance, 50 ether * 110 / 100);
        assertEq(imd.balanceOf(address(vault)), 75 ether);
        assertEq(comp.balanceOf(bob), 50 ether);
        assertEq(comp.totalSupply(), 50 ether + vault.totalWorkMinted());
        assertEq(oracle.mintingRights(alice), 1000 ether, "borrowing and liquidation do not consume work rights");
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
    }

    function test_fullLiquidationExecutesAtExactGraceBoundaryAndOwnerWithdrawsRemainder() public {
        _priceDrivenPosition(140 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        assertEq(block.timestamp, markedAt + grace);
        assertEq(grace, 6 hours);
        uint256 liquidatorBalance = imd.balanceOf(bob);

        vm.prank(bob);
        vault.liquidate(alice, 100 ether);

        _assertPosition(alice, 30 ether, 0);
        _assertMark(alice, 0, 0, false);
        assertEq(imd.balanceOf(bob) - liquidatorBalance, 100 ether * 110 / 100);
        assertEq(comp.balanceOf(bob), 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(comp.allowance(bob, address(vault)), 0, "liquidation burns caller COMP without approval");
        vm.prank(alice);
        vault.withdrawCollateral(30 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(alice), 890 ether);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    function test_partialLiquidationAtHalfUnitPricePaysExactCollateralAndRoundsDown() public {
        uint256 payout = _checkPartialLiquidation(100 ether + 7, 50 ether + 3, 250 ether, 0.5 ether);
        assertEq(payout, 110 ether + 6, "fractional 0.6 wei of collateral is rounded down");
    }

    function test_partialLiquidationAtDoubleUnitPricePaysExactCollateralAndRoundsDown() public {
        uint256 payout = _checkPartialLiquidation(100 ether + 7, 50 ether + 3, 65 ether, 2 ether);
        assertEq(payout, 27.5 ether + 1, "fractional 0.65 wei of collateral is rounded down");
    }

    function test_fullLiquidationAtHalfUnitPricePaysExactCollateralAndClearsMark() public {
        uint256 payout = _checkPartialLiquidation(100 ether + 3, 100 ether + 3, 250 ether, 0.5 ether);
        assertEq(payout, 220 ether + 6);
        _assertMark(alice, 0, 0, false);
    }

    function test_fullLiquidationAtDoubleUnitPricePaysExactCollateralAndClearsMark() public {
        uint256 payout = _checkPartialLiquidation(100 ether + 3, 100 ether + 3, 65 ether, 2 ether);
        assertEq(payout, 55 ether + 1);
        _assertMark(alice, 0, 0, false);
    }

    function test_halfUnitPriceLiquidationRejectsPayoutAboveOwnerCollateralAtomically() public {
        _priceDrivenPosition(140 ether);
        _open(bob, 200 ether, 0);
        priceFeed.setValue(0.5 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);

        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(alice, 100 ether);

        _assertPosition(alice, 140 ether, 100 ether);
        _assertPosition(bob, 200 ether, 0);
        _assertMark(alice, markedAt, grace, true);
        assertEq(imd.balanceOf(address(vault)), 340 ether);
        assertEq(imd.balanceOf(bob), 800 ether);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(comp.totalSupply(), 100 ether + vault.totalWorkMinted());
    }

    function test_liquidationRequiresMarkAndElapsedGrace() public {
        _priceDrivenPosition(140 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.PositionNotMarked.selector);
        vault.liquidate(alice, 100 ether);
        vault.markUnderwater(alice);
        uint256 markedAt = block.timestamp;
        _assertMark(alice, markedAt, 6 hours, true);

        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 6 hours - 1);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 140 ether, 100 ether);
        _assertMark(alice, markedAt, 6 hours, true);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
        vm.warp(markedAt + 6 hours);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
    }

    function test_liquidationExecutesAtExactEndOfMarkWindow() public {
        _priceDrivenPosition(140 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        vm.warp(markedAt + grace + vault.liquidationWindow());
        // A mark remains actionable at equality, including after repeated marking.
        vault.markUnderwater(alice);
        _assertMark(alice, markedAt, grace, true);
        uint256 beforeCollateral = imd.balanceOf(bob);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        assertEq(imd.balanceOf(bob) - beforeCollateral, 100 ether * 110 / 100);
        _assertPosition(alice, 30 ether, 0);
        _assertMark(alice, 0, 0, false);
        assertEq(comp.totalSupply(), 0);
    }

    function test_expiredMarkRevertsAtomicallyAndRemarkTakesNewGraceSnapshot() public {
        _priceDrivenPosition(140 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        vm.warp(markedAt + grace + vault.liquidationWindow() + 1);
        vm.prank(bob);
        vm.expectRevert(CDPVault.MarkExpired.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 140 ether, 100 ether);
        _assertMark(alice, markedAt, grace, true);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
        assertEq(imd.balanceOf(address(vault)), 140 ether);

        nhiFeed.setValue(0.7 ether);
        vault.markUnderwater(alice);
        uint256 newMark = block.timestamp;
        _assertMark(alice, newMark, 8640, true);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(newMark + 8639);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(newMark + 8640);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        _assertMark(alice, 0, 0, false);
        assertEq(imd.balanceOf(bob), 1110 ether);
        assertEq(comp.totalSupply(), 0);
    }

    function test_depositRecoveryDuringGraceClearsMarkAndNewDeclineNeedsNewWindow() public {
        _priceDrivenPosition(130 ether);
        vault.markUnderwater(alice);
        uint256 firstMark = block.timestamp;
        vm.warp(firstMark + 1 hours);
        vm.prank(alice);
        vault.depositCollateral(20 ether);
        _assertMark(alice, 0, 0, false);
        assertEq(vault.collateralRatio(alice), vault.minCR());
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 100 ether);

        priceFeed.setValue(0.9 ether);
        vm.warp(firstMark + 6 hours);
        vm.prank(bob);
        vm.expectRevert(CDPVault.PositionNotMarked.selector);
        vault.liquidate(alice, 100 ether);
        vault.markUnderwater(alice);
        _assertMark(alice, block.timestamp, 6 hours, true);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
    }

    function test_repaymentRecoveryDuringGraceClearsMark() public {
        _priceDrivenPosition(130 ether);
        vault.markUnderwater(alice);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        comp.transfer(alice, 25 ether);
        vm.prank(alice);
        vault.repayCOMP(25 ether);
        _assertMark(alice, 0, 0, false);
        _assertPosition(alice, 130 ether, 75 ether);
        assertGe(vault.collateralRatio(alice), vault.minCR());
        vm.warp(block.timestamp + 6 hours);
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 75 ether);
    }

    function test_priceRecoveryCanBeObservedAndClearedByAnyoneDuringGrace() public {
        _priceDrivenPosition(140 ether);
        vault.markUnderwater(alice);
        vm.warp(block.timestamp + 1 hours);
        priceFeed.setValue(2 ether);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.UnderwaterMarkCleared(alice);
        vault.clearRecoveredMark(alice);
        _assertMark(alice, 0, 0, false);
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 100 ether);
        priceFeed.setValue(1 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(bob);
        vm.expectRevert(CDPVault.PositionNotMarked.selector);
        vault.liquidate(alice, 100 ether);
    }

    function test_underwaterMarkCannotBeClearedBeforeRecovery() public {
        _priceDrivenPosition(140 ether);
        vault.markUnderwater(alice);
        uint256 markedAt = block.timestamp;
        vm.prank(bob);
        vm.expectRevert(CDPVault.UnderwaterPosition.selector);
        vault.clearRecoveredMark(alice);
        _assertMark(alice, markedAt, 6 hours, true);
    }

    function test_nhiDeclineAloneMakesPositionLiquidatableWithoutPriceMovement() public {
        _open(alice, 170 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        uint256 ratioBefore = vault.collateralRatio(alice);
        (uint256 priceBefore,) = priceFeed.latestValue();
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.markUnderwater(alice);

        nhiFeed.setValue(0.7 ether);
        assertEq(vault.collateralRatio(alice), ratioBefore);
        assertEq(vault.minCR(), 180);
        assertEq(vault.gracePeriod(), 8640);
        vault.markUnderwater(alice);
        uint256 markedAt = block.timestamp;
        _assertMark(alice, markedAt, 8640, true);
        vm.warp(markedAt + 8639);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 8640);
        uint256 beforeBalance = imd.balanceOf(bob);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        (uint256 priceAfter,) = priceFeed.latestValue();
        assertEq(priceAfter, priceBefore, "only NHI moved");
        assertEq(imd.balanceOf(bob) - beforeBalance, 100 ether * 110 / 100);
        _assertPosition(alice, 60 ether, 0);
        _assertMark(alice, 0, 0, false);
    }

    function test_nhiAtLowerBoundaryAllowsImmediateLiquidationAfterMark() public {
        _open(alice, 170 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        nhiFeed.setValue(0.6 ether);
        vault.markUnderwater(alice);
        _assertMark(alice, block.timestamp, 0, true);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 60 ether, 0);
        assertEq(imd.balanceOf(bob), 1110 ether);
    }

    function test_oneWeiNhiDeclineAcrossFractionalThresholdKeepsGraceSnapshot() public {
        _open(alice, 170 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        nhiFeed.setValue(0.75 ether);
        assertEq(vault.minCR(), 170);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.markUnderwater(alice);

        nhiFeed.setValue(0.75 ether - 1);
        assertEq(vault.minCR(), 171, "fractional threshold rounds up");
        assertEq(vault.collateralRatio(alice), 170, "collateral value has not changed");
        vault.markUnderwater(alice);
        (uint256 markedAt,,) = vault.liquidationMarks(alice);
        _assertMark(alice, markedAt, 12959, true);

        vm.warp(markedAt + 1 hours);
        nhiFeed.setValue(0.7 ether);
        vault.markUnderwater(alice);
        _assertMark(alice, markedAt, 12959, true);
        vm.warp(markedAt + 12958);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 12959);
        uint256 beforeBalance = imd.balanceOf(bob);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);

        assertEq(imd.balanceOf(bob) - beforeBalance, 100 ether * 110 / 100);
        (uint256 price,) = priceFeed.latestValue();
        assertEq(price, 1 ether, "only NHI moved");
        _assertPosition(alice, 60 ether, 0);
        _assertMark(alice, 0, 0, false);
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
    }

    function test_nhiRecoveryDuringGraceClearsMarkWithoutPriceMovement() public {
        _open(alice, 170 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        nhiFeed.setValue(0.7 ether);
        vault.markUnderwater(alice);
        vm.warp(block.timestamp + 1 hours);
        nhiFeed.setValue(0.85 ether);
        vault.clearRecoveredMark(alice);
        _assertMark(alice, 0, 0, false);
        assertEq(vault.collateralRatio(alice), 170);
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 100 ether);
    }

    function test_nhiDeclineAndRepeatedMarksCannotShortenOrRestartGraceSnapshot() public {
        _priceDrivenPosition(140 ether);
        vault.markUnderwater(alice);
        uint256 markedAt = block.timestamp;
        vm.warp(markedAt + 1 hours);
        nhiFeed.setValue(0.6 ether);
        assertEq(vault.gracePeriod(), 0);
        vm.prank(bob);
        vault.markUnderwater(alice);
        _assertMark(alice, markedAt, 6 hours, true);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 6 hours - 1);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 6 hours);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
    }

    function test_nhiRiseAndRepeatedMarksCannotExtendGraceSnapshot() public {
        _priceDrivenPosition(140 ether);
        nhiFeed.setValue(0.7 ether);
        vault.markUnderwater(alice);
        uint256 markedAt = block.timestamp;
        _assertMark(alice, markedAt, 8640, true);
        vm.warp(markedAt + 1 hours);
        nhiFeed.setValue(0.85 ether);
        assertEq(vault.gracePeriod(), 6 hours);
        assertLt(vault.collateralRatio(alice), vault.minCR());
        vault.markUnderwater(alice);
        _assertMark(alice, markedAt, 8640, true);
        vm.warp(markedAt + 8639);
        vm.prank(bob);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(alice, 100 ether);
        vm.warp(markedAt + 8640);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
    }

    function test_onePriceMoveLiquidatesMultiplePositionsWithoutCrossAccountSeizure() public {
        priceFeed.setValue(2 ether);
        _open(alice, 140 ether, 100 ether);
        _open(bob, 240 ether, 200 ether);
        address liquidator = address(0xCAFE);
        vm.prank(alice);
        comp.transfer(liquidator, 100 ether);
        vm.prank(bob);
        comp.transfer(liquidator, 200 ether);
        priceFeed.setValue(1 ether);
        vault.markUnderwater(alice);
        vault.markUnderwater(bob);
        vm.warp(block.timestamp + 6 hours);

        vm.startPrank(liquidator);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        _assertPosition(bob, 240 ether, 200 ether);
        assertEq(imd.balanceOf(liquidator), 100 ether * 110 / 100);
        vault.liquidate(bob, 200 ether);
        vm.stopPrank();
        _assertPosition(bob, 20 ether, 0);
        _assertPosition(liquidator, 0, 0);
        _assertMark(alice, 0, 0, false);
        _assertMark(bob, 0, 0, false);
        assertEq(imd.balanceOf(liquidator), 300 ether * 110 / 100);
        assertEq(imd.balanceOf(address(vault)), 50 ether);
        assertEq(comp.balanceOf(liquidator), 0);
        assertEq(comp.totalSupply(), 0);
    }

    function test_liquidationInsufficientCOMPAndExcessDebtRevertAtomically() public {
        _priceDrivenPosition(140 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 100 ether)
        );
        vault.liquidate(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.liquidate(alice, 100 ether + 1);
        _assertPosition(alice, 140 ether, 100 ether);
        _assertMark(alice, markedAt, grace, true);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 140 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
    }

    function test_liquidationCannotTakeAnotherUsersCollateral() public {
        _priceDrivenPosition(100 ether);
        _open(bob, 200 ether, 0);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 100 ether, 100 ether);
        _assertPosition(bob, 200 ether, 0);
        _assertMark(alice, markedAt, grace, true);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 300 ether);
    }

    function test_zeroRepaymentAndHealthyOrDebtFreePositionsCannotBeLiquidated() public {
        _open(alice, 200 ether, 100 ether);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.liquidate(alice, 0);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.markUnderwater(alice);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.markUnderwater(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(bob, 1);
    }

    function test_eitherStaleFeedBlocksMarkAndExecutionWithoutConsumingTheMark() public {
        _priceDrivenPosition(140 ether);
        priceFeed.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.markUnderwater(alice);
        priceFeed.setStale(false);
        nhiFeed.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.markUnderwater(alice);
        nhiFeed.setStale(false);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        priceFeed.setStale(true);
        vm.prank(bob);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(alice, 100 ether);
        priceFeed.setStale(false);
        nhiFeed.setStale(true);
        vm.prank(bob);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 140 ether, 100 ether);
        _assertMark(alice, markedAt, grace, true);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
        nhiFeed.setStale(false);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
    }

    function test_zeroPriceBlocksLiquidationWithoutChangingBalances() public {
        _priceDrivenPosition(140 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        priceFeed.setValue(0);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 140 ether, 100 ether);
        _assertMark(alice, markedAt, grace, true);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 140 ether);
    }

    function test_workMintedCOMPCanFundLiquidationWithoutReducingWorkMintedCounter() public {
        priceFeed.setValue(2 ether);
        _open(alice, 140 ether, 100 ether);
        vm.prank(bob);
        vault.mintFromWork(100 ether);
        priceFeed.setValue(1 ether);
        _markAndWait(alice);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        _assertPosition(bob, 0, 0);
        assertEq(comp.balanceOf(alice), 100 ether);
        assertEq(comp.balanceOf(bob), 0);
        assertEq(imd.balanceOf(bob), 1110 ether);
        assertEq(vault.totalWorkMinted(), 100 ether);
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
        assertEq(oracle.mintingRights(bob), 900 ether);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }

    function test_selfLiquidationBurnsOnlyCallerCOMPAndPaysTheCaller() public {
        priceFeed.setValue(2 ether);
        _open(alice, 140 ether, 100 ether);
        priceFeed.setValue(1 ether);
        _markAndWait(alice);
        vm.prank(alice);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        assertEq(comp.balanceOf(alice), 0);
        assertEq(imd.balanceOf(alice), 970 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
    }

    function test_repeatedPartialLiquidationsKeepOriginalGraceUntilRecovery() public {
        _priceDrivenPosition(120 ether);
        (uint256 markedAt, uint256 grace) = _markAndWait(alice);
        vm.startPrank(bob);
        for (uint256 i = 1; i <= 3; ++i) {
            vault.liquidate(alice, 25 ether);
            uint256 repaid = i * 25 ether;
            uint256 seized = repaid * 110 / 100;
            _assertPosition(alice, 120 ether - seized, 100 ether - repaid);
            assertEq(imd.balanceOf(bob), 1000 ether + seized);
            assertEq(comp.totalSupply(), 100 ether - repaid);
            if (i < 3) _assertMark(alice, markedAt, grace, true);
        }
        assertEq(vault.collateralRatio(alice), 150);
        _assertMark(alice, 0, 0, false);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialLiquidationConservesBalancesAndRoundsDown(
        uint128 rawDebt,
        uint128 rawRepayment,
        uint128 rawCollateral
    ) public {
        _checkPartialLiquidation(rawDebt, rawRepayment, rawCollateral, 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialLiquidationAtNonUnitPricesConservesBalancesAndRoundsDown(
        uint128 rawDebt,
        uint128 rawRepayment,
        uint128 rawCollateral,
        bool halfUnitPrice
    ) public {
        // A minimum of 20 debt units permits integral collateral at both prices, even for full repayment.
        uint128 debt = uint128(bound(uint256(rawDebt), 20, type(uint128).max));
        _checkPartialLiquidation(debt, rawRepayment, rawCollateral, halfUnitPrice ? 0.5 ether : 2 ether);
    }

    function test_liquidationOfOneMinorUnitRoundsBonusDown() public {
        _checkPartialLiquidation(1, 1, 1, 1 ether);
    }

    function test_partialLiquidationAtFirstNonzeroBonus() public {
        _checkPartialLiquidation(11, 10, 11, 1 ether);
    }

    function _checkPartialLiquidation(
        uint128 rawDebt,
        uint128 rawRepayment,
        uint128 rawCollateral,
        uint256 liquidationPrice
    ) private returns (uint256 actualPayout) {
        uint256 debt = bound(uint256(rawDebt), 1, type(uint128).max);
        uint256 repayment = bound(uint256(rawRepayment), 1, debt);
        uint256 payout = repayment * 1.1 ether / liquidationPrice;
        uint256 openingPrice = liquidationPrice * 2;
        uint256 openingMinimum = (debt * 1.5 ether + openingPrice - 1) / openingPrice;
        // The highest collateral below 150% at the execution price, including integer-rounding edges.
        uint256 unhealthyMaximum = (debt * 150 ether + liquidationPrice * 100 - 1) / (liquidationPrice * 100) - 1;
        uint256 collateral =
            bound(uint256(rawCollateral), payout > openingMinimum ? payout : openingMinimum, unhealthyMaximum);
        vm.prank(OPERATOR);
        imd.mint(alice, collateral);
        priceFeed.setValue(openingPrice);
        _open(alice, collateral, debt);
        // The liquidator's own collateral and debt must remain untouched.
        _open(bob, 300 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, debt);
        priceFeed.setValue(liquidationPrice);
        _markAndWait(alice);
        uint256 liquidatorBalance = imd.balanceOf(bob);
        uint256 ownerBalance = imd.balanceOf(alice);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CDPVault.Liquidated(alice, bob, repayment, payout);
        vault.liquidate(alice, repayment);

        _assertPosition(alice, collateral - payout, debt - repayment);
        _assertPosition(bob, 300 ether, 100 ether);
        actualPayout = imd.balanceOf(bob) - liquidatorBalance;
        assertEq(actualPayout, payout, "exact price-divided liquidation payout");
        assertLe(actualPayout * liquidationPrice, repayment * 1.1 ether, "payout does not round up");
        assertLt(repayment * 1.1 ether, (actualPayout + 1) * liquidationPrice, "no extra collateral is withheld");
        assertEq(imd.balanceOf(alice), ownerBalance);
        assertEq(imd.balanceOf(address(vault)), collateral - payout + 300 ether);
        assertEq(comp.balanceOf(bob), debt + 100 ether - repayment);
        assertEq(comp.balanceOf(alice), 0);
        assertEq(comp.totalSupply(), debt - repayment + 100 ether + vault.totalWorkMinted());
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(oracle.mintingRights(bob), 1000 ether);
    }
}
