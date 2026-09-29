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
        vm.startPrank(OPERATOR);
        imd.mint(alice, deposit);
        oracle.grantRights(alice, debt);
        vm.stopPrank();
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
}
