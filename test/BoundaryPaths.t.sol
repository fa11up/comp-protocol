// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {stdError} from "forge-std/StdError.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CDPVault} from "src/CDPVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract BoundaryPathsTest is ProtocolFixture {
    error TokenUnavailable();

    function test_mintRejectsMissingOracleEvenWhenTokenIsLinked() public {
        CompToken token = new CompToken();
        CDPVault fresh = new CDPVault(address(imd), address(token), address(0));
        token.setVault(address(fresh));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintCOMP(1);
        assertEq(token.totalSupply(), 0);
    }

    function test_mintRejectsTokenLinkedToDifferentVault() public {
        CompToken token = new CompToken();
        CDPVault fresh = new CDPVault(address(imd), address(token), address(0));
        MockWorkOracle freshOracle = new MockWorkOracle(address(fresh));
        fresh.setOracle(address(freshOracle));
        token.setVault(address(vault));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintCOMP(1);
        assertEq(token.totalSupply(), 0);
    }

    function test_collateralCanBeRecoveredBeforeInitialization() public {
        CDPVault fresh = new CDPVault(address(imd), address(comp), address(0));
        vm.startPrank(alice);
        imd.approve(address(fresh), 7);
        fresh.depositCollateral(7);
        fresh.withdrawCollateral(7);
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = fresh.positions(alice);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
        assertEq(imd.balanceOf(address(fresh)), 0);
    }

    function test_repaidWorkCreditsCannotBeUsedToBorrowAgain() public {
        imd.mint(alice, 500 ether);
        _open(alice, 1500 ether, 1000 ether);
        vm.startPrank(alice);
        vault.repayCOMP(1000 ether);
        vm.expectRevert(CDPVault.InsufficientRights.selector);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(1);
        vault.withdrawCollateral(1500 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(oracle.mintingRights(alice), 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(imd.balanceOf(alice), 1500 ether);
    }

    function test_tokenMintFailureRollsBackConsumedRightsAndDebt() public {
        _open(alice, 150 ether, 0);
        // Fail only the last external step, after the real oracle has consumed rights.
        vm.mockCallRevert(
            address(comp),
            abi.encodeCall(comp.mint, (alice, 100 ether)),
            abi.encodeWithSelector(TokenUnavailable.selector)
        );
        vm.prank(alice);
        vm.expectRevert(TokenUnavailable.selector);
        vault.mintCOMP(100 ether);
        _assertPosition(alice, 150 ether, 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(comp.totalSupply(), 0);
        assertEq(comp.balanceOf(alice), 0);
        vm.clearMockedCalls();
        vm.prank(alice);
        vault.mintCOMP(100 ether);
        _assertPosition(alice, 150 ether, 100 ether);
    }

    function test_rightsQueryFailureDoesNotPreventRepaymentOrWithdrawal() public {
        _open(alice, 150 ether, 100 ether);
        vm.mockCallRevert(
            address(oracle),
            abi.encodeCall(oracle.mintingRights, (alice)),
            abi.encodeWithSelector(TokenUnavailable.selector)
        );
        vm.startPrank(alice);
        vm.expectRevert(TokenUnavailable.selector);
        vault.mintCOMP(1);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        vm.clearMockedCalls();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
    }

    function test_oracleRightsOverflowRevertsWithoutErasingRights() public {
        oracle.grantRights(alice, type(uint256).max - 1000 ether);
        vm.expectRevert(stdError.arithmeticError);
        oracle.grantRights(alice, 1);
        assertEq(oracle.mintingRights(alice), type(uint256).max);
        vm.prank(address(vault));
        oracle.consumeRights(alice, type(uint256).max);
        assertEq(oracle.mintingRights(alice), 0);
    }

    function test_debtAdditionOverflowRevertsAtomically() public {
        _open(alice, 2, 1);
        oracle.grantRights(alice, type(uint256).max - oracle.mintingRights(alice));
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.mintCOMP(type(uint256).max);
        _assertPosition(alice, 2, 1);
        assertEq(comp.totalSupply(), 1);
        assertEq(oracle.mintingRights(alice), type(uint256).max);
    }

    function test_tokenSupplyOverflowRevertsAtomically() public {
        MockIMD freshIMD = new MockIMD();
        freshIMD.mint(alice, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        freshIMD.mint(bob, 1);
        assertEq(freshIMD.totalSupply(), type(uint256).max);
        assertEq(freshIMD.balanceOf(alice), type(uint256).max);
        assertEq(freshIMD.balanceOf(bob), 0);

        CompToken freshCOMP = new CompToken();
        freshCOMP.setVault(address(this));
        freshCOMP.mint(alice, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        freshCOMP.mint(bob, 1);
        assertEq(freshCOMP.totalSupply(), type(uint256).max);
        assertEq(freshCOMP.balanceOf(alice), type(uint256).max);
        assertEq(freshCOMP.balanceOf(bob), 0);
    }

    function test_zeroTokenMintAndBurnRemainStandardERC20Operations() public {
        uint256 imdSupply = imd.totalSupply();
        imd.mint(alice, 0);
        vm.startPrank(address(vault));
        comp.mint(alice, 0);
        comp.burn(alice, 0);
        vm.stopPrank();
        assertEq(imd.totalSupply(), imdSupply);
        assertEq(comp.totalSupply(), 0);
        assertEq(comp.balanceOf(alice), 0);
    }

    function test_transferFromFailuresRestoreAllowanceOnAllTokens() public {
        _open(alice, 150 ether, 100 ether);
        LaunchToken launch = new LaunchToken();
        launch.transfer(alice, 100 ether);
        _assertTransferFromFailures(imd);
        _assertTransferFromFailures(comp);
        _assertTransferFromFailures(launch);
    }

    function _assertTransferFromFailures(ERC20 token) private {
        uint256 balance = token.balanceOf(alice);
        uint256 bobBalance = token.balanceOf(bob);
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        token.approve(bob, balance + 1);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1);
        assertEq(token.allowance(alice, bob), balance + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        token.transferFrom(alice, bob, balance + 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), balance + 1);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.totalSupply(), supply);

        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.startPrank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(bob, 0);
        vm.stopPrank();
    }
}
