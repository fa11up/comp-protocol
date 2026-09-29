// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {IWorkOracle} from "../src/interfaces/IWorkOracle.sol";

contract MockWorkOracleTest is ProtocolFixture {
    function test_constructorAndInterface() public view {
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.deployer(), address(this));
        assertEq(IWorkOracle(address(oracle)).mintingRights(address(0xF00)), 0);
    }

    function test_constructorRejectsInvalidVault() public {
        vm.expectRevert(MockWorkOracle.InvalidVault.selector);
        new MockWorkOracle(address(0));
        vm.expectRevert(MockWorkOracle.InvalidVault.selector);
        new MockWorkOracle(alice);
    }

    function test_grantIsAdditiveAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit MockWorkOracle.RightsGranted(alice, 42);
        oracle.grantRights(alice, 42);
        oracle.grantRights(alice, 7);
        assertEq(oracle.mintingRights(alice), 1000 ether + 49);
    }

    function test_grantRejectsUnauthorizedZeroAccountAndZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.grantRights(alice, 1);
        vm.expectRevert(MockWorkOracle.InvalidAccount.selector);
        oracle.grantRights(address(0), 1);
        vm.expectRevert(MockWorkOracle.ZeroAmount.selector);
        oracle.grantRights(alice, 0);
    }

    function test_consumeOnlyVaultAndInsufficientRightsReverts() public {
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.consumeRights(alice, 1);
        vm.prank(alice);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.consumeRights(alice, 1);
        vm.startPrank(address(vault));
        vm.expectRevert(MockWorkOracle.InsufficientRights.selector);
        oracle.consumeRights(alice, 1000 ether + 1);
        vm.expectRevert(MockWorkOracle.ZeroAmount.selector);
        oracle.consumeRights(alice, 0);
        vm.expectRevert(MockWorkOracle.InvalidAccount.selector);
        oracle.consumeRights(address(0), 1);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit MockWorkOracle.RightsConsumed(alice, 1000 ether);
        oracle.consumeRights(alice, 1000 ether);
        vm.expectRevert(MockWorkOracle.InsufficientRights.selector);
        oracle.consumeRights(alice, 1);
        vm.stopPrank();
        assertEq(oracle.mintingRights(alice), 0);
        assertEq(oracle.mintingRights(bob), 1000 ether);
    }
}
