// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {CDPVault} from "src/CDPVault.sol";

contract ProtocolSequencesTest is ProtocolFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_uint128DepositMintRepayWithdraw(uint128 c, uint128 d, uint128 r, uint128 w) public {
        // Another user's debt must survive both complete lifecycles unchanged.
        _open(bob, 300 ether, 100 ether);
        _sequence(c, d, r, w);
        _sequence(c, d, r, w);
        _assertPosition(bob, 300 ether, 100 ether);
    }

    function test_uint128MaximumSequence() public {
        _sequence(type(uint128).max, type(uint128).max, type(uint128).max, type(uint128).max);
    }

    function test_zeroSeedsProduceValidSmallestSequence() public {
        _sequence(0, 0, 0, 0);
    }

    function _sequence(uint128 c, uint128 d, uint128 r, uint128 w) private {
        uint256 collateral = bound(uint256(c), 3, type(uint128).max);
        uint256 debt = bound(uint256(d), 1, collateral * 100 / 170);
        uint256 repayment = bound(uint256(r), 1, debt);
        uint256 remainingDebt = debt - repayment;
        uint256 minimumCollateral = (remainingDebt * 170 + 99) / 100;
        uint256 withdrawal = bound(uint256(w), 1, collateral - minimumCollateral);
        uint256 previousSupply = comp.totalSupply();
        uint256 previousCustody = imd.balanceOf(address(vault));
        uint256 previousWallet = imd.balanceOf(alice);
        uint256 previousRights = oracle.mintingRights(alice);
        vm.startPrank(OPERATOR);
        imd.mint(alice, collateral);
        vm.stopPrank();

        vm.startPrank(alice);
        // Exercise finite allowances as well as the fixture's infinite approvals.
        imd.approve(address(vault), collateral);
        vault.lock(collateral);
        _assertPosition(alice, collateral, 0);
        assertEq(imd.allowance(alice, address(vault)), 0);
        assertEq(imd.balanceOf(address(vault)), previousCustody + collateral);

        vault.draw(debt);
        _assertPosition(alice, collateral, debt);
        assertEq(comp.totalSupply(), previousSupply + debt);
        assertEq(comp.balanceOf(alice), debt);
        assertEq(oracle.mintingRights(alice), previousRights);
        assertEq(vault.collateralRatio(alice), collateral * 100 / debt);

        vault.wipe(repayment);
        _assertPosition(alice, collateral, remainingDebt);
        assertEq(comp.totalSupply(), previousSupply + remainingDebt);
        assertEq(comp.balanceOf(alice), remainingDebt);
        assertEq(comp.allowance(alice, address(vault)), 0);
        assertEq(oracle.mintingRights(alice), previousRights);

        vault.free(withdrawal);
        _assertPosition(alice, collateral - withdrawal, remainingDebt);
        assertGe((collateral - withdrawal) * 100, remainingDebt * 170);
        assertGe(vault.collateralRatio(alice), 170);
        assertEq(imd.balanceOf(alice), previousWallet + withdrawal);
        assertEq(imd.balanceOf(address(vault)), previousCustody + collateral - withdrawal);

        if (remainingDebt != 0) vault.wipe(remainingDebt);
        if (withdrawal != collateral) vault.free(collateral - withdrawal);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), previousSupply);
        assertEq(comp.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(vault)), previousCustody);
        assertEq(imd.balanceOf(alice), previousWallet + collateral);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_oneWeiBeyondBorrowAndWithdrawalLimitsReverts(uint128 rawDebt) public {
        uint256 debt = bound(uint256(rawDebt), 1, type(uint128).max);
        uint256 collateral = (debt * 170 + 99) / 100;
        vm.startPrank(OPERATOR);
        imd.mint(alice, collateral);
        oracle.grantRights(alice, debt + 1);
        vm.stopPrank();
        _open(alice, collateral, debt);
        uint256 rights = oracle.mintingRights(alice);
        uint256 balance = imd.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.draw(1);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.free(1);
        vm.stopPrank();
        _assertPosition(alice, collateral, debt);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(imd.balanceOf(address(vault)), collateral);
        assertEq(comp.totalSupply(), debt);
        assertEq(comp.balanceOf(alice), debt);
        assertEq(oracle.mintingRights(alice), rights);

        // A rejected withdrawal cannot make a position eligible for liquidation.
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.bite(alice, 1);
    }
}
