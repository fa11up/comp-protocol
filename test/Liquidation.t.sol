// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev The fixed-price model never creates an unhealthy position. Only this test fixture injects
/// a collateral loss, keeping the token balance aligned with recorded collateral. No production setter exists.
contract LiquidationTest is ProtocolFixture {
    using stdStorage for StdStorage;

    function test_withdrawalCannotCreateLiquidatablePosition() public {
        _open(alice, 200 ether, 100 ether);
        vm.startPrank(alice);
        comp.transfer(bob, 100 ether);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(70 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 50 ether);
        _assertPosition(alice, 200 ether, 100 ether);
        assertEq(imd.balanceOf(address(vault)), 200 ether);
        assertEq(imd.balanceOf(alice), 800 ether);
        assertEq(imd.balanceOf(bob), 1000 ether);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function _injectCollateralLoss(uint256 remaining) internal {
        (uint256 original,) = vault.positions(alice);
        stdstore.target(address(vault)).sig("positions(address)").with_key(alice).depth(0).checked_write(remaining);
        vm.prank(address(vault));
        imd.transfer(address(0xDEAD), original - remaining);
    }

    function _unhealthy(uint256 remaining) internal {
        _open(alice, 150 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        _injectCollateralLoss(remaining);
    }

    function test_partialLiquidationPaysBonusAndStopsAtHealthyBoundary() public {
        _unhealthy(130 ether);
        assertEq(vault.collateralRatio(alice), 130);
        vm.startPrank(bob);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CDPVault.Liquidated(alice, bob, 50 ether, 55 ether);
        vault.liquidate(alice, 50 ether);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.stopPrank();
        _assertPosition(alice, 75 ether, 50 ether);
        _assertPosition(bob, 0, 0);
        assertEq(vault.collateralRatio(alice), 150);
        assertEq(comp.totalSupply(), 50 ether);
        assertEq(comp.balanceOf(bob), 50 ether);
        assertEq(imd.balanceOf(bob), 1055 ether);
        assertEq(imd.balanceOf(address(vault)), 75 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
    }

    function test_fullLiquidationLeavesOwnerRemainderWithdrawable() public {
        _unhealthy(140 ether);
        vm.prank(bob);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        assertEq(imd.balanceOf(bob), 1110 ether);
        assertEq(comp.totalSupply(), 0);
        vm.prank(alice);
        vault.withdrawCollateral(30 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    function test_liquidationInsufficientCOMPAndExcessDebtRevertAtomically() public {
        _unhealthy(140 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1 ether)
        );
        vault.liquidate(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.liquidate(alice, 100 ether + 1);
        _assertPosition(alice, 140 ether, 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 140 ether);
    }

    function test_liquidationCannotTakeAnotherUsersCollateral() public {
        _unhealthy(100 ether);
        _open(bob, 200 ether, 0);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 100 ether, 100 ether);
        _assertPosition(bob, 200 ether, 0);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 300 ether);
    }

    function test_liquidationBelowPrincipalCollateralReverts() public {
        _unhealthy(1 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(alice, 2 ether);
        _assertPosition(alice, 1 ether, 100 ether);
    }

    function test_selfLiquidationUsesCallerBalance() public {
        _open(alice, 150 ether, 100 ether);
        _injectCollateralLoss(140 ether);
        vm.prank(alice);
        vault.liquidate(alice, 100 ether);
        _assertPosition(alice, 30 ether, 0);
        assertEq(comp.balanceOf(alice), 0);
        assertEq(imd.balanceOf(alice), 960 ether);
    }

    function testFuzz_fullLiquidationMathAndRounding(uint256 debt, uint256 remaining) public {
        debt = bound(debt, 10, 1e36);
        uint256 deposit = debt + (debt + 1) / 2;
        uint256 payout = debt * 110 / 100;
        remaining = bound(remaining, payout, deposit - 1);
        imd.mint(alice, deposit);
        oracle.grantRights(alice, debt);
        _open(alice, deposit, debt);
        vm.prank(alice);
        comp.transfer(bob, debt);
        _injectCollateralLoss(remaining);
        assertLt(vault.collateralRatio(alice), 150);
        vm.prank(bob);
        vault.liquidate(alice, debt);
        _assertPosition(alice, remaining - payout, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(comp.balanceOf(bob), 0);
        assertEq(imd.balanceOf(bob), 1000 ether + payout);
        assertEq(imd.balanceOf(address(vault)), remaining - payout);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialLiquidationUint128(uint128 rawDebt, uint128 rawRepayment, uint128 rawCollateral) public {
        _checkPartialLiquidation(rawDebt, rawRepayment, rawCollateral);
    }

    function test_liquidationOfOneMinorUnitRoundsBonusDown() public {
        _checkPartialLiquidation(1, 1, 1);
    }

    function test_partialLiquidationAtFirstNonzeroBonus() public {
        _checkPartialLiquidation(11, 10, 11);
    }

    function _checkPartialLiquidation(uint128 rawDebt, uint128 rawRepayment, uint128 rawCollateral) private {
        uint256 debt = bound(uint256(rawDebt), 1, type(uint128).max);
        uint256 repayment = bound(uint256(rawRepayment), 1, debt);
        uint256 deposit = (debt * 150 + 99) / 100;
        uint256 payout = repayment * 110 / 100;
        uint256 collateral = bound(uint256(rawCollateral), payout, deposit - 1);
        imd.mint(alice, deposit);
        oracle.grantRights(alice, debt);
        _open(alice, deposit, debt);
        // The liquidator also has a debt position, which must remain untouched.
        _open(bob, 300 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, debt);
        _injectCollateralLoss(collateral);
        assertLt(vault.collateralRatio(alice), 150);
        uint256 ownerBalance = imd.balanceOf(alice);
        uint256 liquidatorBalance = imd.balanceOf(bob);
        uint256 liquidatorCOMP = comp.balanceOf(bob);
        uint256 rights = oracle.mintingRights(alice);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CDPVault.Liquidated(alice, bob, repayment, payout);
        vault.liquidate(alice, repayment);

        _assertPosition(alice, collateral - payout, debt - repayment);
        _assertPosition(bob, 300 ether, 100 ether);
        assertEq(imd.balanceOf(bob) - liquidatorBalance, repayment * 110 / 100, "exact liquidation payout");
        assertEq(imd.balanceOf(alice), ownerBalance);
        assertEq(imd.balanceOf(address(vault)), collateral - payout + 300 ether);
        assertEq(comp.balanceOf(bob), liquidatorCOMP - repayment);
        assertEq(comp.balanceOf(alice), 0);
        assertEq(comp.totalSupply(), debt - repayment + 100 ether);
        assertEq(comp.allowance(bob, address(vault)), 0);
        assertEq(oracle.mintingRights(alice), rights);
        assertEq(oracle.mintingRights(bob), 900 ether);
    }

    function test_repeatedPartialLiquidationsStopWhenHealthIsRestored() public {
        _unhealthy(120 ether);
        vm.startPrank(bob);
        for (uint256 i = 1; i <= 3; ++i) {
            vault.liquidate(alice, 25 ether);
            uint256 repaid = i * 25 ether;
            uint256 seized = repaid * 110 / 100;
            _assertPosition(alice, 120 ether - seized, 100 ether - repaid);
            assertEq(imd.balanceOf(bob), 1000 ether + seized);
            assertEq(comp.totalSupply(), 100 ether - repaid);
        }
        assertEq(vault.collateralRatio(alice), 150);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.stopPrank();
    }
}
