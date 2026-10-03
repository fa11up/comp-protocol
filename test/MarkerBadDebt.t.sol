// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT, MARKER_SHARE_BPS} from "src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

/// @dev Exercises the existing immutable deployment hook without changing the marker policy.
contract MarkerProtocolShareVault is CDPVault {
    uint256 private immutable share;

    constructor(address collateral, address primary, address nhi, address spot, uint256 share_)
        CDPVault(collateral, address(0), address(0), primary, nhi, spot)
    {
        share = share_;
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return share;
    }
    /// @dev Held at zero so this suite keeps asserting what it is about. The shipped rate is
    /// non-zero and ShippedRateStabilityFeeTest covers it.
    function stabilityFeeBps() public pure override returns (uint256) {
        return 0;
    }

}

contract MarkerBadDebtTest is Test {
    error TransferUnavailable();

    address private constant BORROWER = address(0xB0110);
    address private constant SECOND_BORROWER = address(0xB0220);
    address private constant MARKER = address(0xA11CE);
    address private constant NEXT_MARKER = address(0xCA11);
    address private constant LIQUIDATOR = address(0x11C);
    bytes32 private constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    MockIMD private imd;
    CDPVault private vault;
    CompToken private comp;
    TestSwarmFeed private primary;
    TestSwarmFeed private spot;
    TestSwarmFeed private nhi;

    function setUp() public {
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new TestSwarmFeed(4 ether);
        spot = new TestSwarmFeed(4 ether);
        nhi = new TestSwarmFeed(0.6 ether);
        _deploy(2500);
    }

    function test_distinctMarkerLiquidatorAndProtocolReceiveExactShares() public {
        assertTrue(MARKER != LIQUIDATOR && MARKER != FEE_RECIPIENT && LIQUIDATOR != FEE_RECIPIENT);
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        assertEq(imd.balanceOf(MARKER), 0, "marking alone earns nothing");
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        assertEq(imd.balanceOf(MARKER), 1 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 2.5 ether);
        assertEq(imd.balanceOf(LIQUIDATOR), 106.5 ether);
        _assertPosition(BORROWER, 30 ether, 0);
        assertEq(imd.balanceOf(BORROWER), 0);
        assertEq(imd.balanceOf(address(vault)), 30 ether);
        assertEq(comp.totalSupply(), 0);
        (,, bool marked, address marker) = vault.liquidationMarks(BORROWER);
        assertFalse(marked);
        assertEq(marker, address(0));
    }

    function test_defaultProtocolShareStillPaysMarkerFromBonus() public {
        vault = new BaselineVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.compToken();
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        assertEq(imd.balanceOf(MARKER), 1 ether);
        assertEq(imd.balanceOf(LIQUIDATOR), 109 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0);
        _assertPosition(BORROWER, 30 ether, 0);
    }

    function test_sameMarkerAndLiquidatorReceiveOneCombinedCollateralTransfer() public {
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, LIQUIDATOR);
        vm.recordLogs();
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 collateralTransfers;
        uint256 transfersToLiquidator;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(imd) || logs[i].topics[0] != TRANSFER) continue;
            ++collateralTransfers;
            if (logs[i].topics[2] == bytes32(uint256(uint160(LIQUIDATOR)))) {
                ++transfersToLiquidator;
                assertEq(abi.decode(logs[i].data, (uint256)), 107.5 ether);
            }
        }
        assertEq(transfersToLiquidator, 1, "combined marker and liquidator payment");
        assertEq(collateralTransfers, 2, "one combined transfer plus the protocol transfer");
        assertEq(imd.balanceOf(LIQUIDATOR), 107.5 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 2.5 ether);
        _assertPosition(BORROWER, 30 ether, 0);
    }

    function test_maximumCombinedBonusSharesPreserveLiquidatorPrincipal() public {
        _deploy(10_000 - MARKER_SHARE_BPS);
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        assertEq(imd.balanceOf(LIQUIDATOR), 100 ether);
        assertEq(imd.balanceOf(MARKER), 1 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 9 ether);
        _assertPosition(BORROWER, 30 ether, 0);
    }

    function test_oneBpsBeyondCombinedBonusLimitRevertsAtomically() public {
        _deploy(10_001 - MARKER_SHARE_BPS);
        _open(BORROWER, 55 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.InvalidBonusShares.selector);
        vault.liquidate(BORROWER, 50 ether);
        _assertUnpaid(BORROWER, 55 ether, 100 ether);
    }

    function test_oneWeiRepaymentHasNoBonusOrZeroValueMarkerTransfer() public {
        _open(BORROWER, 2, 2);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.recordLogs();
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(imd) && logs[i].topics[0] == TRANSFER) ++transfers;
        }
        assertEq(transfers, 1);
        assertEq(imd.balanceOf(LIQUIDATOR), 1);
        assertEq(imd.balanceOf(MARKER), 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0);
        _assertPosition(BORROWER, 1, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sharesConserveSeizureIncludingPriceAndShareRounding(
        uint128 rawRepayment,
        uint96 rawPrice,
        uint16 rawProtocolShare
    ) public {
        uint256 repayment = bound(rawRepayment, 100, 1e30);
        uint256 price = bound(rawPrice, 1e15, 10 ether);
        uint256 protocolShare = bound(rawProtocolShare, 0, 10_000 - MARKER_SHARE_BPS);
        _deploy(protocolShare);
        uint256 debt = repayment * 2;
        uint256 collateral = (debt * 1 ether + price - 1) / price;
        _setPrice(price * 4);
        _open(BORROWER, collateral, debt);
        _setPrice(price);
        _mark(BORROWER, MARKER);
        uint256 seized = repayment * 1.1 ether / price;
        uint256 principalCollateral = repayment * 1 ether / price;
        uint256 bonus = seized - principalCollateral;
        uint256 markerCut = bonus * MARKER_SHARE_BPS / 10_000;
        uint256 protocolCut = bonus * protocolShare / 10_000;
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, repayment);
        assertEq(imd.balanceOf(MARKER), markerCut);
        assertEq(imd.balanceOf(FEE_RECIPIENT), protocolCut);
        assertEq(imd.balanceOf(LIQUIDATOR), seized - markerCut - protocolCut);
        assertGe(imd.balanceOf(LIQUIDATOR), principalCollateral, "shares never consume principal");
        assertEq(imd.balanceOf(MARKER) + imd.balanceOf(FEE_RECIPIENT) + imd.balanceOf(LIQUIDATOR), seized);
        _assertPosition(BORROWER, collateral - seized, debt - repayment);
        assertEq(imd.balanceOf(address(vault)), collateral - seized);
        assertEq(comp.totalSupply(), debt - repayment);
    }

    function test_repeatedMarkCannotStealMarkerOrRestartGrace() public {
        nhi.setValue(0.85 ether);
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        (uint256 markedAt, uint256 grace,,) = vault.liquidationMarks(BORROWER);
        vm.warp(markedAt + grace - 1);
        _mark(BORROWER, NEXT_MARKER);
        (uint256 repeatedAt, uint256 repeatedGrace,, address marker) = vault.liquidationMarks(BORROWER);
        assertEq(repeatedAt, markedAt);
        assertEq(repeatedGrace, grace);
        assertEq(marker, MARKER);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(BORROWER, 100 ether);
        vm.warp(markedAt + grace);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        assertEq(imd.balanceOf(MARKER), 1 ether);
        assertEq(imd.balanceOf(NEXT_MARKER), 0);
    }

    function test_expiredMarkPaysNobodyAndReplacementMustWaitNewGrace() public {
        nhi.setValue(0.85 ether);
        _open(BORROWER, 140 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        (uint256 markedAt, uint256 grace,,) = vault.liquidationMarks(BORROWER);
        vm.warp(markedAt + grace + vault.liquidationWindow() + 1);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.MarkExpired.selector);
        vault.liquidate(BORROWER, 100 ether);
        _assertUnpaid(BORROWER, 140 ether, 100 ether);
        _mark(BORROWER, NEXT_MARKER);
        (uint256 newMarkedAt, uint256 newGrace,, address marker) = vault.liquidationMarks(BORROWER);
        assertEq(newMarkedAt, block.timestamp);
        assertEq(marker, NEXT_MARKER);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.liquidate(BORROWER, 100 ether);
        vm.warp(newMarkedAt + newGrace);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 100 ether);
        assertEq(imd.balanceOf(MARKER), 0);
        assertEq(imd.balanceOf(NEXT_MARKER), 1 ether);
    }

    function test_markerPaymentFailureRollsBackBurnAndNewBadDebt() public {
        _open(BORROWER, 55 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.mockCallRevert(
            address(imd),
            abi.encodeCall(imd.transfer, (MARKER, 0.5 ether)),
            abi.encodeWithSelector(TransferUnavailable.selector)
        );
        vm.prank(LIQUIDATOR);
        vm.expectRevert(TransferUnavailable.selector);
        vault.liquidate(BORROWER, 50 ether);
        _assertUnpaid(BORROWER, 55 ether, 100 ether);
        assertEq(comp.balanceOf(LIQUIDATOR), 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(vault.totalDebt(), 100 ether);
        vm.clearMockedCalls();
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
    }

    function test_liquidationRecordsExactShortfallWithoutForgivingIt() public {
        _open(BORROWER, 55 ether, 100 ether);
        _setPrice(1 ether);
        assertEq(vault.badDebtOf(BORROWER), 50 ether);
        assertEq(vault.totalBadDebt(), 0, "only realized exhaustion enters the accumulator");
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(BORROWER, 50 ether + 1);
        _assertUnpaid(BORROWER, 55 ether, 100 ether);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 50 ether);
        _assertPosition(BORROWER, 0, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        assertEq(vault.badDebtOf(BORROWER), 50 ether);
        assertEq(vault.totalDebt(), 50 ether);
        assertEq(comp.totalSupply(), 50 ether);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.liquidate(BORROWER, 1);
        assertEq(vault.totalBadDebt(), 50 ether, "failed retries cannot count a loss twice");
    }

    function test_multipleExhaustedPositionsAndRepaymentsUpdateOnlyTheirShortfalls() public {
        _open(BORROWER, 55 ether, 100 ether);
        _open(SECOND_BORROWER, 44 ether, 80 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        _mark(SECOND_BORROWER, NEXT_MARKER);
        vm.startPrank(LIQUIDATOR);
        vault.liquidate(BORROWER, 50 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        vault.liquidate(SECOND_BORROWER, 40 ether);
        assertEq(vault.totalBadDebt(), 90 ether);
        comp.transfer(BORROWER, 20 ether);
        comp.transfer(SECOND_BORROWER, 40 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        vault.repayCOMP(20 ether);
        assertEq(vault.totalBadDebt(), 70 ether);
        assertEq(vault.badDebtOf(BORROWER), 30 ether);
        assertEq(vault.badDebtOf(SECOND_BORROWER), 40 ether);
        vm.prank(SECOND_BORROWER);
        vault.repayCOMP(40 ether);
        assertEq(vault.totalBadDebt(), 30 ether);
        assertEq(vault.badDebtOf(SECOND_BORROWER), 0);
        assertEq(comp.totalSupply(), 30 ether);
        assertEq(vault.totalDebt(), 30 ether);
    }

    function test_recapitalizationCannotEraseHistoricalDebtAndSecondExhaustionDoesNotDoubleCount() public {
        _open(BORROWER, 55 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 50 ether);
        _deposit(BORROWER, 11 ether);
        assertEq(vault.totalBadDebt(), 50 ether);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 10 ether);
        _assertPosition(BORROWER, 0, 40 ether);
        assertEq(vault.totalBadDebt(), 40 ether);
        _deposit(BORROWER, 100 ether);
        assertEq(vault.badDebtOf(BORROWER), 0);
        assertEq(vault.totalBadDebt(), 40 ether, "collateral alone does not erase recorded debt");
        vm.prank(LIQUIDATOR);
        comp.transfer(BORROWER, 40 ether);
        vm.prank(BORROWER);
        vault.repayCOMP(40 ether);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(comp.totalSupply(), 0);
        _assertPosition(BORROWER, 100 ether, 0);
    }

    function test_badDebtCoverageBoundaryAndOneCollateralWeiBelowIt() public {
        _open(BORROWER, 110 ether, 100 ether);
        _open(SECOND_BORROWER, 110 ether - 1, 100 ether);
        _setPrice(1 ether);
        assertEq(vault.badDebtOf(BORROWER), 0);
        assertEq(vault.badDebtOf(SECOND_BORROWER), 1);
        assertEq(vault.badDebtOf(address(0xDEAD)), 0);
        primary.setStale(true);
        assertEq(vault.badDebtOf(SECOND_BORROWER), 1, "documented current-price view permits stale observations");
        primary.setValue(0);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.badDebtOf(SECOND_BORROWER);
        assertEq(vault.badDebtOf(address(0xDEAD)), 0, "debt-free view does not need a price");
    }

    function test_badDebtWithoutCollateralDoesNotNeedAValidPrice() public {
        _open(BORROWER, 55 ether, 100 ether);
        _setPrice(1 ether);
        _mark(BORROWER, MARKER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 50 ether);
        primary.setValue(0);
        primary.setStale(true);
        assertEq(vault.badDebtOf(BORROWER), 50 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_badDebtEqualsDebtBeyondMaximumFloorRoundedLiquidation(
        uint128 rawDebt,
        uint128 rawCollateral,
        uint96 rawPrice
    ) public {
        uint256 debt = bound(rawDebt, 1, 1e30);
        uint256 collateral = bound(rawCollateral, 1, debt * 2);
        uint256 price = bound(rawPrice, 1e15, 100 ether);
        _setPrice((debt * 2 ether + collateral - 1) / collateral);
        _open(BORROWER, collateral, debt);
        _setPrice(price);
        // An independently derived integer inequality: floor(repayment * 1.1e18 / price) <= collateral.
        uint256 capacity = ((collateral + 1) * price - 1) / 1.1 ether;
        uint256 covered = capacity < debt ? capacity : debt;
        assertEq(vault.badDebtOf(BORROWER), debt - covered);
        assertLe(covered * 1.1 ether / price, collateral);
        if (covered < debt) assertGt((covered + 1) * 1.1 ether / price, collateral);
        assertEq(vault.totalBadDebt(), 0, "views do not record unrealized losses");
    }

    function _deploy(uint256 share) private {
        vault = new MarkerProtocolShareVault(address(imd), address(primary), address(nhi), address(spot), share);
        comp = vault.compToken();
    }

    function _setPrice(uint256 price) private {
        primary.setValue(price);
        spot.setValue(price);
    }

    function _open(address owner, uint256 collateral, uint256 debt) private {
        _deposit(owner, collateral);
        vm.startPrank(owner);
        vault.mintCOMP(debt);
        comp.transfer(LIQUIDATOR, debt);
        vm.stopPrank();
    }

    function _deposit(address owner, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(owner, amount);
        vm.startPrank(owner);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(amount);
        vm.stopPrank();
    }

    function _mark(address owner, address marker) private {
        vm.prank(marker);
        vault.markUnderwater(owner);
    }

    function _assertPosition(address owner, uint256 collateral, uint256 debt) private view {
        (uint256 actualCollateral, uint256 actualDebt) = vault.positions(owner);
        assertEq(actualCollateral, collateral);
        assertEq(actualDebt, debt);
    }

    function _assertUnpaid(address owner, uint256 collateral, uint256 debt) private view {
        _assertPosition(owner, collateral, debt);
        assertEq(imd.balanceOf(MARKER), 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0);
        assertEq(imd.balanceOf(LIQUIDATOR), 0);
        assertEq(vault.totalBadDebt(), 0);
        (,, bool marked, address marker) = vault.liquidationMarks(owner);
        assertTrue(marked);
        assertEq(marker, MARKER);
    }
}
