// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CDPVaultTest is ProtocolFixture {
    function test_configuration() public view {
        assertEq(address(vault.imdToken()), address(imd));
        assertEq(address(vault.compToken()), address(comp));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.MIN_COLLATERAL_RATIO(), 150);
        assertEq(vault.LIQUIDATION_BONUS_PERCENT(), 10);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    function test_invalidConstructorTokens() public {
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new CDPVault(address(0), address(comp), address(0));
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new CDPVault(address(imd), alice, address(0));
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new CDPVault(address(imd), address(imd), address(0));
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new CDPVault(address(imd), address(comp), alice);
    }

    function test_oracleInitializationOnlyDeployerOnce() public {
        CDPVault fresh = new CDPVault(address(imd), address(comp), address(0));
        vm.prank(alice);
        vm.expectRevert(CDPVault.Unauthorized.selector);
        fresh.setOracle(address(oracle));
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        fresh.setOracle(address(0));
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        fresh.setOracle(alice);
        vm.expectEmit(true, false, false, true, address(fresh));
        emit CDPVault.OracleSet(address(oracle));
        fresh.setOracle(address(oracle));
        assertEq(address(fresh.oracle()), address(oracle));
        vm.expectRevert(CDPVault.AlreadyInitialized.selector);
        fresh.setOracle(address(oracle));
        vm.prank(alice);
        vm.expectRevert(CDPVault.AlreadyInitialized.selector);
        fresh.setOracle(address(0));
    }

    function test_constructorOracleLocksInitialization() public {
        CDPVault fresh = new CDPVault(address(imd), address(comp), address(oracle));
        assertEq(address(fresh.oracle()), address(oracle));
        vm.expectRevert(CDPVault.AlreadyInitialized.selector);
        fresh.setOracle(address(oracle));
    }

    function test_mintRequiresBothLinksInitialized() public {
        CompToken freshComp = new CompToken();
        CDPVault fresh = new CDPVault(address(imd), address(freshComp), address(0));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintCOMP(1);
        fresh.setOracle(address(oracle));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintCOMP(1);
    }

    function test_depositAndWithdrawWithoutDebt() public {
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.CollateralDeposited(alice, 25 ether);
        vault.depositCollateral(25 ether);
        _assertPosition(alice, 25 ether, 0);
        assertEq(imd.balanceOf(address(vault)), 25 ether);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.CollateralWithdrawn(alice, 25 ether);
        vault.withdrawCollateral(25 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_depositFailureRollsBackPosition() public {
        vm.startPrank(alice);
        imd.approve(address(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.depositCollateral(1);
        imd.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 ether, 1001 ether)
        );
        vault.depositCollateral(1001 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_allActionsRejectZero() public {
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.depositCollateral(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.withdrawCollateral(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.mintCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.repayCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.liquidate(alice, 0);
    }

    function test_mintAt150PercentConsumesRightsAndEmitsEvent() public {
        _open(alice, 150 ether, 0);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.COMPMinted(alice, 100 ether);
        vault.mintCOMP(100 ether);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(comp.balanceOf(alice), 100 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
        assertEq(vault.collateralRatio(alice), 150);
    }

    function test_mintRejectsInsufficientRightsWithNoStateChange() public {
        imd.mint(alice, 2000 ether);
        _open(alice, 3000 ether, 0);
        vm.prank(alice);
        vm.expectRevert(CDPVault.InsufficientRights.selector);
        vault.mintCOMP(1000 ether + 1);
        _assertPosition(alice, 3000 ether, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }

    function test_mintRejectsInsufficientCollateralIncludingExistingDebt() public {
        vm.prank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        _open(alice, 150 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_roundingCannotUndercollateralizeOneWeiDebt() public {
        _open(alice, 1, 0);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        vault.depositCollateral(1);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(1);
        vm.stopPrank();
        assertEq(vault.collateralRatio(alice), 200);
    }

    function test_withdrawChecksPositionAndResultingRatio() public {
        _open(alice, 200 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(201 ether);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(50 ether + 1);
        vault.withdrawCollateral(50 ether);
        vm.stopPrank();
        _assertPosition(alice, 150 ether, 100 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
    }

    function test_partialAndFullRepaymentWithoutApprovalDoesNotRestoreRights() public {
        _open(alice, 150 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.COMPRepaid(alice, 40 ether);
        vault.repayCOMP(40 ether);
        _assertPosition(alice, 150 ether, 60 ether);
        assertEq(comp.totalSupply(), 60 ether);
        assertEq(comp.allowance(alice, address(vault)), 0);
        vault.repayCOMP(60 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(oracle.mintingRights(alice), 900 ether);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_repaymentRejectsExcessDebtAndInsufficientBalanceAtomically() public {
        _open(alice, 150 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(100 ether + 1);
        comp.transfer(bob, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vault.repayCOMP(1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(1);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_liquidationRejectsDebtFreeExactly150AndAbove150() public {
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        _open(alice, 150 ether, 100 ether);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.prank(alice);
        vault.depositCollateral(1 ether);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        _assertPosition(alice, 151 ether, 100 ether);
    }

    function test_directDonationDoesNotCreateWithdrawableCollateral() public {
        vm.prank(alice);
        imd.transfer(address(vault), 50 ether);
        _assertPosition(alice, 0, 0);
        vm.prank(alice);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
    }

    function testFuzz_depositMintRepayWithdrawSequence(uint256 c, uint256 d, uint256 r, uint256 w) public {
        c = bound(c, 2, 1e36);
        d = bound(d, 1, c * 2 / 3);
        r = bound(r, 0, d);
        imd.mint(alice, c);
        oracle.grantRights(alice, d);
        _open(alice, c, d);
        vm.startPrank(alice);
        if (r != 0) vault.repayCOMP(r);
        uint256 remainingDebt = d - r;
        uint256 requiredCollateral = remainingDebt + remainingDebt / 2 + remainingDebt % 2;
        w = bound(w, 0, c - requiredCollateral);
        if (w != 0) vault.withdrawCollateral(w);
        _assertPosition(alice, c - w, remainingDebt);
        assertEq(comp.totalSupply(), remainingDebt);
        assertGe(vault.collateralRatio(alice), 150);
        if (remainingDebt != 0) vault.repayCOMP(remainingDebt);
        if (c != w) vault.withdrawCollateral(c - w);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(alice), 1000 ether + c);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }
}
