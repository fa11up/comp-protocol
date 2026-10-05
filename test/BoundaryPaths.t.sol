// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {stdError} from "forge-std/StdError.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract BoundaryPathsTest is ProtocolFixture {
    error TokenUnavailable();

    function test_mintRejectsUnlinkedTokenDespiteConstructorBoundOracle() public {
        ImdUSD token = new ImdUSD(address(0));
        CDPVault fresh = new BaselineVault(
            address(imd), address(token), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        assertEq(MockWorkOracle(address(fresh.oracle())).vault(), address(fresh));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.draw(1);
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintFromWork(1);
        assertEq(token.totalSupply(), 0);
    }

    function test_mintRejectsTokenLinkedToDifferentVault() public {
        ImdUSD token = new ImdUSD(address(0));
        CDPVault fresh = new BaselineVault(
            address(imd), address(token), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        CDPVault registeredVault = new BaselineVault(
            address(imd), address(token), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.startPrank(OPERATOR);
        token.setVault(address(registeredVault));
        vm.stopPrank();
        assertEq(token.vault(), address(registeredVault));
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.draw(1);
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintFromWork(1);
        assertEq(token.totalSupply(), 0);
    }

    function test_collateralCanBeRecoveredBeforeInitialization() public {
        CDPVault fresh = new BaselineVault(
            address(imd), address(comp), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.startPrank(alice);
        imd.approve(address(fresh), 7);
        fresh.lock(7);
        fresh.free(7);
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = fresh.positions(alice);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
        assertEq(imd.balanceOf(address(fresh)), 0);
    }

    function test_exhaustedWorkCreditsCannotBeReusedButDoNotPreventBorrowing() public {
        _establishWorkBacking(vault, 1000 ether);
        vm.startPrank(alice);
        vault.mintFromWork(1000 ether);
        vm.expectRevert(CDPVault.InsufficientRights.selector);
        vault.mintFromWork(1);
        vault.lock(150 ether);
        vault.draw(100 ether);
        vault.wipe(100 ether);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.wipe(1);
        vault.free(150 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.free(1);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(oracle.mintingRights(alice), 0);
        assertEq(vault.totalWorkMinted(), 1000 ether);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)] + 1000 ether);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_borrowMintFailureRollsBackDebt() public {
        _open(alice, 150 ether, 0);
        // Fail only the last external step, after the vault has written debt.
        vm.mockCallRevert(
            address(comp),
            abi.encodeCall(comp.mint, (alice, 100 ether)),
            abi.encodeWithSelector(TokenUnavailable.selector)
        );
        vm.prank(alice);
        vm.expectRevert(TokenUnavailable.selector);
        vault.draw(100 ether);
        _assertPosition(alice, 150 ether, 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(comp.totalSupply(), 0);
        assertEq(comp.balanceOf(alice), 0);
        vm.clearMockedCalls();
        vm.prank(alice);
        vault.draw(100 ether);
        _assertPosition(alice, 150 ether, 100 ether);
    }

    function test_workMintFailureRollsBackConsumedRightsAndWorkAccounting() public {
        _establishWorkBacking(vault, 100 ether);
        vm.mockCallRevert(
            address(comp),
            abi.encodeCall(comp.mint, (alice, 100 ether)),
            abi.encodeWithSelector(TokenUnavailable.selector)
        );
        vm.prank(alice);
        vm.expectRevert(TokenUnavailable.selector);
        vault.mintFromWork(100 ether);
        _assertPosition(alice, 0, 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(vault.totalWorkMinted(), 0);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)]);
        vm.clearMockedCalls();
        vm.prank(alice);
        vault.mintFromWork(100 ether);
        assertEq(vault.totalWorkMinted(), 100 ether);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)] + 100 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
    }

    function test_rightsQueryFailureOnlyBlocksWorkMint() public {
        _open(alice, 200 ether, 100 ether);
        vm.mockCallRevert(
            address(oracle),
            abi.encodeCall(oracle.mintingRights, (alice)),
            abi.encodeWithSelector(TokenUnavailable.selector)
        );
        vm.startPrank(alice);
        vm.expectRevert(TokenUnavailable.selector);
        vault.mintFromWork(1);
        vault.draw(1);
        vault.wipe(100 ether + 1);
        vault.free(200 ether);
        vm.stopPrank();
        vm.clearMockedCalls();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }

    function test_oracleRightsOverflowRevertsWithoutErasingRights() public {
        vm.startPrank(OPERATOR);
        oracle.grantRights(alice, type(uint256).max - 1000 ether);
        vm.expectRevert(stdError.arithmeticError);
        oracle.grantRights(alice, 1);
        vm.stopPrank();
        assertEq(oracle.mintingRights(alice), type(uint256).max);
        vm.prank(address(vault));
        oracle.consumeRights(alice, type(uint256).max);
        assertEq(oracle.mintingRights(alice), 0);
    }

    function test_debtAdditionOverflowRevertsAtomically() public {
        _open(alice, 2, 1);
        uint256 remainingRights = oracle.mintingRights(alice);
        vm.prank(OPERATOR);
        oracle.grantRights(alice, type(uint256).max - remainingRights);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.draw(type(uint256).max);
        _assertPosition(alice, 2, 1);
        assertEq(comp.totalSupply(), 1);
        assertEq(oracle.mintingRights(alice), type(uint256).max);
    }

    function test_tokenSupplyOverflowRevertsAtomically() public {
        MockIMD freshIMD = new MockIMD();
        vm.startPrank(OPERATOR);
        freshIMD.mint(alice, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        freshIMD.mint(bob, 1);
        vm.stopPrank();
        assertEq(freshIMD.totalSupply(), type(uint256).max);
        assertEq(freshIMD.balanceOf(alice), type(uint256).max);
        assertEq(freshIMD.balanceOf(bob), 0);

        ImdUSD freshCOMP = new ImdUSD(address(0));
        CDPVault tokenVault = new BaselineVault(
            address(imd), address(freshCOMP), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.prank(OPERATOR);
        freshCOMP.setVault(address(tokenVault));
        // Isolate ERC-20 supply arithmetic using the registered vault as caller.
        vm.startPrank(address(tokenVault));
        freshCOMP.mint(alice, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        freshCOMP.mint(bob, 1);
        vm.stopPrank();
        assertEq(freshCOMP.totalSupply(), type(uint256).max);
        assertEq(freshCOMP.balanceOf(alice), type(uint256).max);
        assertEq(freshCOMP.balanceOf(bob), 0);
    }

    function test_zeroTokenMintAndBurnRemainStandardERC20Operations() public {
        uint256 imdSupply = imd.totalSupply();
        vm.prank(OPERATOR);
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
