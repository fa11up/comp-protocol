// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ArithmeticTest is ProtocolFixture {
    function setUp() public override {
        imd = new MockIMD();
        comp = new CompToken(address(0));
        vault = new CDPVault(address(imd), address(comp), address(0));
        oracle = new MockWorkOracle(address(vault));
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        vm.stopPrank();
        vm.prank(alice);
        imd.approve(address(vault), type(uint256).max);
    }

    function test_maxUintCollateralSupportsBorrowingWithoutProductOverflow() public {
        uint256 collateral = type(uint256).max;
        uint256 debt = Math.mulDiv(collateral, 2, 3);
        vm.startPrank(OPERATOR);
        imd.mint(alice, collateral);
        oracle.grantRights(alice, type(uint256).max);
        vm.stopPrank();
        _open(alice, collateral, debt);
        assertEq(vault.collateralRatio(alice), 150);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        vault.repayCOMP(debt);
        vault.withdrawCollateral(collateral);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), type(uint256).max);
        assertEq(comp.totalSupply(), 0);
    }

    function test_unrepresentableRatioSaturates() public {
        vm.startPrank(OPERATOR);
        imd.mint(alice, type(uint256).max);
        oracle.grantRights(alice, 1);
        vm.stopPrank();
        _open(alice, type(uint256).max, 1);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    function testFuzz_ratioMatchesWideMultiplication(uint256 collateral, uint256 debt) public {
        collateral = bound(collateral, 2, type(uint256).max / 100);
        debt = bound(debt, 1, collateral * 2 / 3);
        vm.startPrank(OPERATOR);
        imd.mint(alice, collateral);
        oracle.grantRights(alice, debt);
        vm.stopPrank();
        _open(alice, collateral, debt);
        assertEq(vault.collateralRatio(alice), collateral * 100 / debt);
    }
}
