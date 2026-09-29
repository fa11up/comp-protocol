// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";

abstract contract ProtocolFixture is Test {
    address internal constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    MockIMD internal imd;
    CompToken internal comp;
    MockWorkOracle internal oracle;
    CDPVault internal vault;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public virtual {
        imd = new MockIMD();
        comp = new CompToken(address(0));
        vault = new CDPVault(address(imd), address(comp), address(0));
        oracle = new MockWorkOracle(address(vault));
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        imd.mint(alice, 1000 ether);
        imd.mint(bob, 1000 ether);
        oracle.grantRights(alice, 1000 ether);
        oracle.grantRights(bob, 1000 ether);
        vm.stopPrank();
        vm.prank(alice);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(vault), type(uint256).max);
    }

    function _open(address user, uint256 collateral, uint256 debt) internal {
        vm.startPrank(user);
        vault.depositCollateral(collateral);
        if (debt != 0) vault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _assertPosition(address user, uint256 collateral, uint256 debt) internal view {
        (uint256 actualCollateral, uint256 actualDebt) = vault.positions(user);
        assertEq(actualCollateral, collateral, "collateral");
        assertEq(actualDebt, debt, "debt");
    }
}
