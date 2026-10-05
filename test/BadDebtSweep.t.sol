// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice Regression test for a position that froze on Sepolia, using its exact figures.
/// @dev bite() folds that unreachable remainder into the seizure, as extra incentive for
/// whoever closes the position. It sits outside the bonus, so neither the marker's share nor the
/// protocol's grows with it, and the borrower's loss with both shares at zero is unchanged.
/// @dev On 2026-10-02, vault 0xD8CbC70B9C2dfC75762686dd4795e2aC033452c5 held collateral
/// 1531680210045556243504 against debt 1800000000000000000 at price 1179684498206226. A liquidation
/// of the largest coverable debt, 1642635818181817142, left 887 wei. Seizing even one wei of debt
/// costs 932 wei at that price, so every later bite reverted InsufficientCollateral
/// (0x3a23d825, checked on chain for 1, 100 and 500). The position could never drain, so
/// _recordBadDebt never fired: badDebtOf reported 157364181818182858 while totalBadDebt stayed 0.
/// @dev Those figures were at a 10% bonus. The position is replayed as it was; the bonus is now 20%,
/// so the largest coverable debt is 1505749499999999047, the shortfall 294250500000000953, and the
/// same liquidation strands 717 wei against a 1017-wei seizure for one wei of debt: still frozen
/// without the sweep. (At 10% this arithmetic reproduces the live 887 and 932 exactly.)
contract BadDebtSweepTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);

    uint256 private constant COLLATERAL = 1531680210045556243504;
    uint256 private constant DEBT = 1800000000000000000;
    uint256 private constant CRASH_PRICE = 1179684498206226;
    uint256 private constant MAX_REPAYABLE = 1505749499999999047;
    uint256 private constant SHORTFALL = 294250500000000953;

    MockIMD private imd;
    ImdUSD private comp;
    CDPVault private vault;
    TestSwarmFeed private priceFeed;
    TestSwarmFeed private nhiFeed;
    TestSwarmFeed private spotFeed;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        priceFeed = new TestSwarmFeed(1e18);
        spotFeed = new TestSwarmFeed(1e18);
        // NHI 0.60 pins mat at 200 and lull at zero, so a mark is actionable at once.
        nhiFeed = new TestSwarmFeed(0.6e18);
        vault = new BaselineVault(
            address(imd), address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        comp = vault.stablecoin();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, COLLATERAL);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(COLLATERAL);
        vault.draw(DEBT);
        comp.transfer(KEEPER, DEBT);
        vm.stopPrank();
    }

    function test_theSepoliaFreezeDrainsThePositionAndRealizesTheShortfall() public {
        _crash(CRASH_PRICE);
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        assertEq(vault.badDebtOf(BORROWER), SHORTFALL, "the shortfall the live vault reported");

        vm.prank(KEEPER);
        vault.bite(BORROWER, MAX_REPAYABLE);

        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, 0, "the dust the live vault stranded (717 wei at 20%) must be swept");
        assertEq(vault.debtOf(BORROWER), SHORTFALL, "principal is never forgiven");
        // Before the sweep this read zero, for good: the position could never drain.
        assertEq(vault.totalBadDebt(), SHORTFALL, "draining the position realizes the loss");

        // The dust reached the liquidator on top of the formula payout. Marker and liquidator are
        // the same address here, so the vault pays one combined transfer.
        uint256 formulaPayout = (MAX_REPAYABLE * (100 + vault.CHOP_PERCENT()) * 1e16) / CRASH_PRICE;
        assertEq(imd.balanceOf(KEEPER), formulaPayout + 717, "liquidator receives the formula payout plus the dust");
    }

    /// @dev The sweep must not touch a borrower made whole: clearing the debt leaves them solvent
    /// and the remaining collateral is theirs to withdraw.
    function test_aLiquidationThatClearsTheDebtLeavesTheRemainderWithTheBorrower() public {
        _crash(1.5e15);
        vm.prank(KEEPER);
        vault.bark(BORROWER);

        vm.prank(KEEPER);
        vault.bite(BORROWER, DEBT);

        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(vault.debtOf(BORROWER), 0, "debt cleared");
        assertGt(collateral, 0, "a solvent borrower keeps the remainder");
        assertEq(vault.totalBadDebt(), 0, "no realized loss when the debt is fully repaid");
    }

    /// @dev The invariant the sweep buys, across the whole price range that can strand collateral:
    /// a position left with debt is never left holding collateral no liquidation could ever seize.
    function testFuzz_noLiquidationStrandsUnreachableCollateral(uint96 rawPrice, uint96 rawRepay) public {
        uint256 price = bound(uint256(rawPrice), 1e12, 2e15);
        _crash(price);
        vm.prank(KEEPER);
        vault.bark(BORROWER);

        uint256 coverable = (COLLATERAL * price) / ((100 + vault.CHOP_PERCENT()) * 1e16);
        if (coverable > DEBT) coverable = DEBT;
        vm.assume(coverable >= 1);
        uint256 repay = bound(uint256(rawRepay), 1, coverable);

        vm.prank(KEEPER);
        vault.bite(BORROWER, repay);

        // Nothing is ever left that a further liquidation could not take.
        (uint256 collateral,) = vault.positions(BORROWER);
        if (vault.debtOf(BORROWER) != 0 && collateral != 0) {
            assertGe(collateral, ((100 + vault.CHOP_PERCENT()) * 1e16) / price, "stranded collateral no liquidation can reach");
        }
    }

    function _crash(uint256 price) private {
        priceFeed.setValue(price);
        spotFeed.setValue(price);
    }
}
