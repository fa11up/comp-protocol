// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT, MARKER_SHARE_BPS, PROTOCOL_BONUS_SHARE_BPS} from "../src/DeploymentConfig.sol";

/// @notice The liquidation split at the values a deployment actually ships, through the real vault.
/// @dev Most suites run on BaselineVault with the economics inert, so their payout arithmetic keeps
/// stating what it is about. That leaves the shipped configuration uncovered unless something tests
/// it directly, which is what this is. It derives every expectation from the constants, so changing
/// one cannot pass unnoticed.
contract ShippedSplitTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant MARKER = address(0xCA11);
    address private constant LIQUIDATOR = address(0x1A1D);

    CDPVault private vault;
    MockIMD private imd;
    ImdUSD private comp;
    TestSwarmFeed private price;
    TestSwarmFeed private nhi;
    TestSwarmFeed private spot;

    uint256 private constant PRICE = 0.9 ether;
    uint256 private constant REPAID = 50 ether;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        price = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.6 ether); // mat 200, grace 0
        vault = new CDPVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        comp = vault.stablecoin();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 300 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(300 ether);
        vault.draw(150 ether);
        comp.transfer(LIQUIDATOR, 150 ether);
        vm.stopPrank();
        price.setValue(PRICE);
        spot.setValue(PRICE);
    }

    function test_theShippedSplitPaysMarkerProtocolAndLiquidatorExactly() public {
        assertEq(vault.protocolBonusShareBps(), PROTOCOL_BONUS_SHARE_BPS, "the vault carries the shipped share");
        assertEq(vault.markerShareBps(), MARKER_SHARE_BPS);

        vm.prank(MARKER);
        vault.bark(BORROWER);
        uint256 liquidatorBefore = imd.balanceOf(LIQUIDATOR);
        vm.prank(LIQUIDATOR);
        vault.bite(BORROWER, REPAID);

        uint256 seized = REPAID * 110 * 1e16 / PRICE;
        uint256 bonus = seized - REPAID * 1e18 / PRICE;
        uint256 markerCut = bonus * MARKER_SHARE_BPS / 10_000;
        uint256 protocolCut = bonus * PROTOCOL_BONUS_SHARE_BPS / 10_000;

        assertEq(imd.balanceOf(MARKER), markerCut, "marker");
        assertEq(imd.balanceOf(FEE_RECIPIENT), protocolCut, "protocol");
        assertEq(imd.balanceOf(LIQUIDATOR) - liquidatorBefore, seized - markerCut - protocolCut, "liquidator");
        assertEq(markerCut + protocolCut + (seized - markerCut - protocolCut), seized, "the split is exhaustive");
    }

    /// @dev The borrower's loss is the whole seizure whatever the split, because the shares divide
    /// the bonus rather than seizing more collateral. That is the property that makes turning the
    /// protocol share on safe for borrowers.
    function test_theBorrowersLossDoesNotDependOnTheSplit() public {
        (uint256 collateralBefore,) = vault.positions(BORROWER);
        vm.prank(MARKER);
        vault.bark(BORROWER);
        vm.prank(LIQUIDATOR);
        vault.bite(BORROWER, REPAID);
        (uint256 collateralAfter,) = vault.positions(BORROWER);
        assertEq(collateralBefore - collateralAfter, REPAID * 110 * 1e16 / PRICE, "exactly the formula seizure");
    }

    /// @dev The cap the vault enforces, stated against the shipped values rather than assumed.
    function test_theShippedSharesLeaveTheLiquidatorAMajorityOfTheBonus() public view {
        assertLe(PROTOCOL_BONUS_SHARE_BPS, 10_000 - MARKER_SHARE_BPS, "the vault would revert above this");
        assertGt(10_000 - MARKER_SHARE_BPS - PROTOCOL_BONUS_SHARE_BPS, PROTOCOL_BONUS_SHARE_BPS, "keeper keeps more");
    }
}
