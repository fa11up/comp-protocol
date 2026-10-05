// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LegacyWorkBacking} from "./helpers/LegacyWorkBacking.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

abstract contract ProtocolFixture is LegacyWorkBacking {
    address internal constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    MockIMD internal imd;
    ImdUSD internal comp;
    MockWorkOracle internal oracle;
    CDPVault internal vault;
    TestSwarmFeed internal priceFeed;
    TestSwarmFeed internal nhiFeed;
    MirroredSwarmFeed internal spotFeed;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public virtual {
        imd = new MockIMD();
        comp = new ImdUSD(address(0));
        priceFeed = new TestSwarmFeed(1 ether);
        nhiFeed = new TestSwarmFeed(0.85 ether);
        spotFeed = new MirroredSwarmFeed(address(priceFeed));
        vault = new BaselineVault(
            address(imd), address(comp), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
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
        vault.lock(collateral);
        if (debt != 0) vault.draw(debt);
        vm.stopPrank();
    }

    function _assertPosition(address user, uint256 collateral, uint256 debt) internal view {
        (uint256 actualCollateral, uint256 actualDebt) = vault.positions(user);
        assertEq(actualCollateral, collateral, "collateral");
        assertEq(actualDebt, debt, "debt");
    }
}
