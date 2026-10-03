// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ZeroFeeVault} from "./helpers/ZeroFeeVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT, MAX_DIVERGENCE_BPS} from "src/DeploymentConfig.sol";
import {TestSwarmFeed} from "test/helpers/TestSwarmFeed.sol";

/// @notice Independent primary and spot feeds exercise the guard without an RPC or attestation signer.
contract DivergenceGuardTest is Test {
    enum Action {
        Mint,
        Mark,
        Liquidate,
        WithdrawWithDebt,
        ClearRecoveredMark
    }

    address private constant BORROWER = address(0xD100);
    address private constant MARKER = address(0xD200);
    address private constant LIQUIDATOR = address(0xD300);
    address private constant DEBT_FREE = address(0xD400);

    CDPVault private vault;
    CompToken private comp;
    MockIMD private imd;
    TestSwarmFeed private primary;
    TestSwarmFeed private spot;
    TestSwarmFeed private nhi;

    function setUp() public {
        vm.warp(10 days);
        imd = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.85 ether);
        vault = new ZeroFeeVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.compToken();

        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 300 ether);
        imd.mint(DEBT_FREE, 300 ether);
        MockWorkOracle(address(vault.oracle())).grantRights(LIQUIDATOR, 1000 ether);
        vm.stopPrank();

        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(300 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        vm.startPrank(DEBT_FREE);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(300 ether);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        vault.mintFromWork(1000 ether);
    }

    function testFuzz_MintAcceptsExactlyMaximumDivergence(bool spotAbove) public {
        _setBoundary(1 ether, spotAbove, false);
        vm.prank(BORROWER);
        vault.mintCOMP(50 ether);
        assertEq(vault.debtOf(BORROWER), 150 ether);
        assertEq(comp.balanceOf(BORROWER), 150 ether);
    }

    function testFuzz_MarkAcceptsExactlyMaximumDivergence(bool spotAbove) public {
        _prepare(Action.Mark);
        _setBoundary(0.4 ether, spotAbove, false);
        vm.prank(MARKER);
        vault.markUnderwater(BORROWER);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        assertTrue(marked);
        assertEq(markedAt, block.timestamp);
        assertEq(grace, 6 hours);
        assertEq(marker, MARKER);
    }

    function testFuzz_LiquidationAcceptsExactlyMaximumDivergence(bool spotAbove) public {
        _prepare(Action.Liquidate);
        _setBoundary(0.4 ether, spotAbove, false);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 10 ether);
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 272.5 ether);
        assertEq(debt, 90 ether);
        assertEq(comp.balanceOf(LIQUIDATOR), 990 ether);
        assertEq(imd.balanceOf(LIQUIDATOR) + imd.balanceOf(MARKER), 27.5 ether);
    }

    function testFuzz_MintRejectsOneWeiBeyondMaximumDivergence(bool spotAbove) public {
        _setBoundary(1 ether, spotAbove, true);
        _expectAtomicFailure(Action.Mint, CDPVault.PriceDivergence.selector);
    }

    function testFuzz_MarkRejectsOneWeiBeyondMaximumDivergence(bool spotAbove) public {
        _prepare(Action.Mark);
        _setBoundary(0.4 ether, spotAbove, true);
        _expectAtomicFailure(Action.Mark, CDPVault.PriceDivergence.selector);
    }

    function testFuzz_LiquidationRejectsOneWeiBeyondMaximumDivergence(bool spotAbove) public {
        _prepare(Action.Liquidate);
        _setBoundary(0.4 ether, spotAbove, true);
        _expectAtomicFailure(Action.Liquidate, CDPVault.PriceDivergence.selector);
    }

    /// @dev At very small prices, even one wei can exceed the bound; nonmultiples of 20 expose BPS truncation.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PrimaryDenominatorAndIntegerBoundary(uint256 priceSeed, bool spotAbove) public {
        uint256 price = bound(priceSeed, 20, type(uint256).max / 2);
        assertEq(MAX_DIVERGENCE_BPS, 500);
        primary.setValue(price);
        // The approved 500 BPS bound is exactly 1/20 of the primary, independent of the spot price.
        uint256 allowedDifference = price / 20;
        spot.setValue(spotAbove ? price + allowedDifference : price - allowedDifference);
        vm.prank(DEBT_FREE);
        vault.mintCOMP(1);
        assertEq(vault.debtOf(DEBT_FREE), 1);

        spot.setValue(spotAbove ? price + allowedDifference + 1 : price - allowedDifference - 1);
        bytes32 beforeState = _state();
        vm.prank(DEBT_FREE);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.mintCOMP(1);
        assertEq(_state(), beforeState, "rejected mint changed state");
        assertEq(vault.debtOf(DEBT_FREE), 1);
        assertEq(comp.balanceOf(DEBT_FREE), 1);
    }

    function test_PricesBelowTwentyRejectAOneWeiDifference() public {
        for (uint256 price = 1; price < 20; ++price) {
            primary.setValue(price);
            spot.setValue(price);
            vm.prank(DEBT_FREE);
            vault.mintCOMP(1);
            spot.setValue(price + 1);
            vm.prank(DEBT_FREE);
            vm.expectRevert(CDPVault.PriceDivergence.selector);
            vault.mintCOMP(1);
        }
        assertEq(vault.debtOf(DEBT_FREE), 19);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PriceDependentActionsRejectEitherStaleFeed(uint8 actionSeed, bool staleSpot) public {
        Action action = Action(bound(actionSeed, 0, uint256(Action.ClearRecoveredMark)));
        _prepare(action);
        if (staleSpot) spot.setStale(true);
        else primary.setStale(true);
        _expectAtomicFailure(action, CDPVault.StaleFeed.selector);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PriceDependentActionsRejectZeroPrice(uint8 actionSeed, bool zeroSpot) public {
        Action action = Action(bound(actionSeed, 0, uint256(Action.ClearRecoveredMark)));
        _prepare(action);
        if (zeroSpot) spot.setValue(0);
        else primary.setValue(0);
        _expectAtomicFailure(action, CDPVault.InvalidPrice.selector);
    }

    function testFuzz_DebtBearingWithdrawalRejectsDivergenceAtomically(bool spotAbove) public {
        _setBoundary(1 ether, spotAbove, true);
        _expectAtomicFailure(Action.WithdrawWithDebt, CDPVault.PriceDivergence.selector);
    }

    function testFuzz_ExplicitRecoveryAcceptsExactlyMaximumDivergence(bool spotAbove) public {
        _prepare(Action.ClearRecoveredMark);
        _setBoundary(1 ether, spotAbove, false);
        vm.prank(DEBT_FREE);
        vault.clearRecoveredMark(BORROWER);
        _assertMarkCleared();
        assertEq(vault.debtOf(BORROWER), 100 ether);
    }

    function testFuzz_ExplicitRecoveryRejectsOneWeiBeyondMaximumDivergence(bool spotAbove) public {
        _prepare(Action.ClearRecoveredMark);
        _setBoundary(1 ether, spotAbove, true);
        _expectAtomicFailure(Action.ClearRecoveredMark, CDPVault.PriceDivergence.selector);
    }

    function testFuzz_AutomaticRecoveryAcceptsExactlyMaximumDivergence(bool spotAbove, bool repay) public {
        _prepare(Action.ClearRecoveredMark);
        _setBoundary(1 ether, spotAbove, false);
        _dustRecoveryAction(repay);
        _assertMarkCleared();
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 300 ether + (repay ? 0 : 1));
        assertEq(debt, 100 ether - (repay ? 1 : 0));
    }

    /// @dev A primary-only recovery cannot erase an already mature keeper snapshot.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InvalidAutomaticRecoveryPreservesMatureMarkAndKeeper(uint8 observationSeed, bool repay) public {
        _prepare(Action.ClearRecoveredMark);
        bytes32 matureMark = _markState();
        uint256 observation = bound(observationSeed, 0, 3);
        if (observation < 2) _setBoundary(1 ether, observation == 0, true);
        else if (observation == 2) spot.setStale(true);
        else spot.setValue(0);

        _dustRecoveryAction(repay);
        assertEq(_markState(), matureMark, "invalid recovery changed the mature snapshot");
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 300 ether + (repay ? 0 : 1));
        assertEq(debt, 100 ether - (repay ? 1 : 0));

        primary.setValue(0.4 ether);
        spot.setValue(0.4 ether);
        spot.setStale(false);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 10 ether);
        assertEq(_markState(), matureMark, "liquidation must retain the original keeper snapshot");
        assertEq(imd.balanceOf(MARKER), 0.25 ether);
        assertEq(imd.balanceOf(LIQUIDATOR), 27.25 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0);
        (uint256 remainingCollateral, uint256 remainingDebt) = vault.positions(BORROWER);
        assertEq(remainingCollateral, collateral - 27.5 ether);
        assertEq(remainingDebt, debt - 10 ether);
    }

    function testFuzz_RepaymentAndFullExitSucceedWhilePricesDiverge(bool spotAbove) public {
        _prepare(Action.Liquidate);
        _setBoundary(0.4 ether, spotAbove, true);
        vm.startPrank(BORROWER);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(300 ether);
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(imd.balanceOf(BORROWER), 300 ether);
        assertEq(comp.balanceOf(BORROWER), 0);
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
        (,, bool marked,) = vault.liquidationMarks(BORROWER);
        assertFalse(marked, "full repayment must clear the liquidation mark");
    }

    function test_PartialRepaymentSucceedsWhilePricesDiverge() public {
        _prepare(Action.Liquidate);
        spot.setValue(2 ether);
        vm.prank(BORROWER);
        vault.repayCOMP(10 ether);
        assertEq(vault.debtOf(BORROWER), 90 ether);
        assertEq(comp.balanceOf(BORROWER), 90 ether);
        assertEq(vault.totalDebt(), 90 ether);
        (,, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        assertTrue(marked, "still-underwater position preserves its mark");
        assertEq(marker, MARKER);
    }

    function test_DebtFreeWithdrawalSucceedsWithoutTouchingTheDivergentFeeds() public {
        spot.setValue(100 ether);
        vm.prank(DEBT_FREE);
        vault.withdrawCollateral(300 ether);
        assertEq(imd.balanceOf(DEBT_FREE), 300 ether);
        (uint256 collateral, uint256 debt) = vault.positions(DEBT_FREE);
        assertEq(collateral, 0);
        assertEq(debt, 0);
    }

    function test_RepaymentAndDebtFreeExitSucceedWithZeroAndStaleFeeds() public {
        _prepare(Action.Liquidate);
        primary.setValue(0);
        spot.setValue(0);
        primary.setStale(true);
        spot.setStale(true);
        nhi.setStale(true);
        vm.startPrank(BORROWER);
        vault.repayCOMP(1 ether);
        vault.repayCOMP(99 ether);
        vault.withdrawCollateral(300 ether);
        vm.stopPrank();
        assertEq(vault.debtOf(BORROWER), 0);
        assertEq(imd.balanceOf(BORROWER), 300 ether);
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
    }

    function _prepare(Action action) private {
        if (action == Action.Mark || action == Action.Liquidate || action == Action.ClearRecoveredMark) {
            primary.setValue(0.4 ether);
            spot.setValue(0.4 ether);
        }
        if (action == Action.Liquidate || action == Action.ClearRecoveredMark) {
            vm.prank(MARKER);
            vault.markUnderwater(BORROWER);
            vm.warp(block.timestamp + 6 hours);
        }
        if (action == Action.ClearRecoveredMark) {
            primary.setValue(1 ether);
            spot.setValue(1 ether);
        }
    }

    function _setBoundary(uint256 price, bool spotAbove, bool beyond) private {
        assertEq(MAX_DIVERGENCE_BPS, 500);
        uint256 difference = price / 20 + (beyond ? 1 : 0);
        spot.setValue(spotAbove ? price + difference : price - difference);
    }

    function _expectAtomicFailure(Action action, bytes4 selector) private {
        bytes32 beforeState = _state();
        address caller = action == Action.Mark ? MARKER : action == Action.Liquidate ? LIQUIDATOR : BORROWER;
        vm.prank(caller);
        vm.expectRevert(selector);
        if (action == Action.Mint) vault.mintCOMP(1 ether);
        else if (action == Action.Mark) vault.markUnderwater(BORROWER);
        else if (action == Action.Liquidate) vault.liquidate(BORROWER, 10 ether);
        else if (action == Action.ClearRecoveredMark) vault.clearRecoveredMark(BORROWER);
        else vault.withdrawCollateral(1 ether);
        assertEq(_state(), beforeState, "failed price check changed debt, mark, collateral or balances");
    }

    function _dustRecoveryAction(bool repay) private {
        if (!repay) {
            vm.prank(APPROVED_OPERATOR);
            imd.mint(BORROWER, 1);
        }
        vm.prank(BORROWER);
        if (repay) vault.repayCOMP(1);
        else vault.depositCollateral(1);
    }

    function _markState() private view returns (bytes32) {
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        return keccak256(abi.encode(markedAt, grace, marked, marker));
    }

    function _assertMarkCleared() private view {
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        assertEq(markedAt, 0);
        assertEq(grace, 0);
        assertFalse(marked);
        assertEq(marker, address(0));
    }

    function _state() private view returns (bytes32) {
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        bytes32 positionState =
            keccak256(abi.encode(collateral, debt, markedAt, grace, marked, marker, vault.debtIndexOf(BORROWER)));
        bytes32 accountingState = keccak256(
            abi.encode(
                comp.totalSupply(),
                vault.totalDebt(),
                vault.totalWorkMinted(),
                vault.totalFeesMinted(),
                vault.totalBadDebt()
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                comp.balanceOf(BORROWER),
                comp.balanceOf(LIQUIDATOR),
                comp.balanceOf(FEE_RECIPIENT),
                imd.balanceOf(address(vault)),
                imd.balanceOf(BORROWER),
                imd.balanceOf(LIQUIDATOR),
                imd.balanceOf(MARKER),
                imd.balanceOf(FEE_RECIPIENT)
            )
        );
        return keccak256(abi.encode(positionState, accountingState, balances));
    }
}
