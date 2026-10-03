// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Parameters} from "src/Parameters.sol";
import {Governed} from "src/Governed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

contract WorkCeilingTest is WorkBackingFixture {
    function test_emptyReserveAndNoDebtRefusesEvenOneWeiAndPreservesRights() public {
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(backedVault.workCeiling(), 0);
        _assertRejected(WORKER, 1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        assertEq(stable.totalSupply(), 0);
    }

    function test_ceilingAddsBothTermsAndAllowsLastWeiButRefusesFirstWeiPast() public {
        _fundReserve(71 ether + 1);
        _openDebt(100 ether + 3);
        uint256 ceiling = 96 ether + 1;
        assertEq(backedVault.workCeiling(), ceiling, "sum, with ratio rounded down");
        _assertRejected(WORKER, ceiling + 1);
        _mintWork(WORKER, ceiling - 1);
        assertEq(backedVault.totalWorkMinted(), ceiling - 1);
        _assertRejected(OTHER_WORKER, 2);
        _mintWork(OTHER_WORKER, 1);
        assertEq(backedVault.totalWorkMinted(), ceiling);
        _assertRejected(WORKER, 1);
        assertEq(stable.totalSupply(), backedVault.totalDebt() + ceiling);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - ceiling + 1);
        assertEq(workOracle.mintingRights(OTHER_WORKER), type(uint128).max - 1);
    }

    function test_largeDebtRatioUsesFullPrecisionMultiplication() public {
        uint256 debt = uint256(1) << 250;
        _openDebt(debt);
        uint256 ceiling = debt / 4;
        assertEq(backedVault.workCeiling(), ceiling);
        vm.prank(APPROVED_OPERATOR);
        workOracle.grantRights(WORKER, ceiling);
        _mintWork(WORKER, ceiling);
        _assertRejected(WORKER, 1);
        assertEq(stable.totalSupply(), debt + ceiling);
    }

    function test_reserveAloneSupportsWorkAndDoesNotCreateWorkerDebt() public {
        _fundReserve(10 ether);
        _mintWork(WORKER, 10 ether);
        _assertRejected(WORKER, 1);
        assertEq(backedVault.totalDebt(), 0);
        (uint256 c, uint256 d) = backedVault.positions(WORKER);
        assertEq(c, 0);
        assertEq(d, 0);
        assertEq(stable.balanceOf(WORKER), 10 ether);
    }

    function test_debtDustIsRoundedDownBeforeAddingReserve() public {
        _fundReserve(1);
        _openDebt(3);
        assertEq(backedVault.workCeiling(), 1);
        _mintWork(WORKER, 1);
        _assertRejected(WORKER, 1);
        vm.prank(BORROWER);
        backedVault.mintCOMP(1);
        assertEq(backedVault.workCeiling(), 2);
        _mintWork(OTHER_WORKER, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ceilingArithmeticAndAtomicBoundary(uint96 rawDebt, uint96 rawReserve, uint16 rawRatio) public {
        uint256 debt = bound(rawDebt, 1, 1e28);
        uint256 value = bound(rawReserve, 0, 1e28);
        uint256 ratio = bound(rawRatio, 0, 2500);
        _setRatio(ratio);
        _fundReserve(value);
        _openDebt(debt);
        uint256 expected = value + debt * ratio / 10_000;
        assertEq(backedVault.workCeiling(), expected);
        _assertRejected(WORKER, expected + 1);
        if (expected != 0) _mintWork(WORKER, expected);
        _assertRejected(OTHER_WORKER, 1);
        assertEq(stable.totalSupply(), debt + expected);
    }

    /// @dev D > 0 is essential: when D = 0, reserve-only backing is exactly one; 0/0 is undefined.
    /// Compare cross-products instead of a rounded fixed-point ratio, which can hide a tiny surplus.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_worstCaseBackingExceedsOneForEveryReserveSize(
        uint128 rawDebt,
        uint128 rawReserve,
        uint16 rawRatio,
        uint64 rawNhi
    ) public {
        uint256 debt = bound(rawDebt, 1, type(uint128).max);
        uint256 value = rawReserve;
        uint256 ratio = bound(rawRatio, 0, 2500);
        _setRatio(ratio);
        health.setValue(bound(rawNhi, 0.5 ether, 0.95 ether));
        uint256 minCR = backedVault.minCR();
        assertGe(minCR, 150);
        // Exact rational worst-case C = minCR * D / 100, W = R + rD (before rounding).
        uint256 backingScaled = minCR * debt * 100 + value * 10_000;
        uint256 liabilitiesScaled = debt * 10_000 + value * 10_000 + debt * backedVault.workRatioBps();
        assertGt(backingScaled, liabilitiesScaled);
        assertGe(backingScaled - liabilitiesScaled, debt * 2500);
        // The reserve cancels, proving the bound also for R beyond the fuzz range.
        assertEq(backingScaled - liabilitiesScaled, (minCR * 100 - 10_000 - ratio) * debt);
    }

    function test_bindingMinimumRatioGives120PercentAtEmptyReserveAnd5000IsTheCliff() public view {
        uint256 debt = 100 ether;
        uint256 assets = backedVault.minCR() * debt / 100;
        assertEq(backedVault.workRatioBps(), 2500);
        assertEq(assets * 10_000 / (debt + debt * backedVault.workRatioBps() / 10_000), 12_000);
        for (uint256 i; i < 5; ++i) {
            uint256[5] memory reserves = [uint256(0), 1, 50 ether, 200 ether, uint256(type(uint128).max)];
            uint256 r = reserves[i];
            assertGt(assets + r, debt + r + debt / 4);
            assertEq(assets + r, debt + r + debt / 2, "5000 bps has no surplus for any R");
        }
    }

    function test_ratioHardCapDelayAndPermissionlessApplication() public {
        assertEq(parameters.MAX_WORK_RATIO_BPS(), 2500);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeWorkRatio(1);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.WorkRatioTooHigh.selector, 2501));
        parameters.proposeWorkRatio(2501);
        assertEq(parameters.pendingEta(), 0);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeWorkRatio(0);
        uint256 eta = parameters.pendingEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        assertEq(backedVault.workRatioBps(), 2500);
        _apply();
        assertEq(backedVault.workRatioBps(), 0);
        _openDebt(100 ether);
        assertEq(backedVault.workCeiling(), 0);
        _assertRejected(WORKER, 1);
        _setRatio(2500);
        _mintWork(WORKER, 25 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ratioAboveHardCapCannotBeQueued(uint256 rawRatio) public {
        uint256 ratio = bound(rawRatio, 2501, type(uint256).max);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.WorkRatioTooHigh.selector, ratio));
        parameters.proposeWorkRatio(ratio);
        assertEq(parameters.pendingEta(), 0);
    }

    function test_repaymentTightensCeilingAndDoesNotRestoreWorkRights() public {
        _openDebt(100 ether);
        _mintWork(WORKER, 25 ether);
        vm.prank(BORROWER);
        backedVault.repayCOMP(100 ether);
        assertEq(backedVault.workCeiling(), 0);
        assertEq(backedVault.totalWorkMinted(), 25 ether);
        _assertRejected(WORKER, 1);
        _openDebt(104 ether);
        _mintWork(WORKER, 1 ether);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - 26 ether);
    }

    function test_accruedUnpaidFeesDoNotIncreaseRatioHeadroom() public {
        _openDebt(100 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertGt(backedVault.stabilityFeeOf(BORROWER), 0);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.workCeiling(), 25 ether);
    }

    function test_withdrawalAndRatioReductionBlockFurtherWorkWithoutBurningExistingSupply() public {
        _fundReserve(20 ether);
        _openDebt(100 ether);
        _mintWork(WORKER, 45 ether);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(asset, address(0xBEEF), 2 ether);
        assertEq(backedVault.workCeiling(), 44 ether);
        _assertRejected(OTHER_WORKER, 1);
        _setRatio(0);
        assertEq(backedVault.workCeiling(), 19 ether);
        _assertRejected(WORKER, 1);
        assertEq(stable.balanceOf(WORKER), 45 ether);
    }

    function _assertRejected(address worker, uint256 amount) internal {
        uint256 rights = workOracle.mintingRights(worker);
        uint256 supply = stable.totalSupply();
        uint256 minted = backedVault.totalWorkMinted();
        uint256 balance = stable.balanceOf(worker);
        vm.prank(worker);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.mintFromWork(amount);
        assertEq(workOracle.mintingRights(worker), rights);
        assertEq(stable.totalSupply(), supply);
        assertEq(backedVault.totalWorkMinted(), minted);
        assertEq(stable.balanceOf(worker), balance);
    }
}
