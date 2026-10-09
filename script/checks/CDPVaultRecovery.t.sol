// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "../../src/CDPVault.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {APPROVED_OPERATOR, SKEW_BPS} from "../../src/DeploymentConfig.sol";
import {IncrementFeed} from "./CDPVaultIncrement.t.sol";

/// @notice FOUNDRY_TEST=script/checks forge test --offline --out test/scratch/recovery-out \
/// --cache-path test/scratch/recovery-cache --match-path script/checks/CDPVaultRecovery.t.sol
contract CDPVaultRecoveryTest is Test {
    enum InvalidObservation {
        Divergence,
        StaleSpot,
        ZeroSpot,
        StalePrimary,
        ZeroPrimary,
        StaleNhi
    }

    MockIMD private imd;
    ImdUSD private comp;
    CDPVault private vault;
    IncrementFeed private primary;
    IncrementFeed private spot;
    IncrementFeed private nhi;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant MARKER = address(0xCA11);
    uint256 private markedAt;
    uint256 private grace;
    /// The recovered price. The stability fee (DUTY_BPS) accrues through the grace period, so at exactly 1 the
    /// 170 of collateral sits a hair under mat against 100 of debt plus fee; 1.01 leaves the injected fault as
    /// the only thing that can stop a recovery.
    uint256 private constant RECOVERED = 1.01 ether;

    function setUp() public {
        vm.warp(2 days);
        imd = new MockIMD();
        primary = new IncrementFeed(1 ether);
        spot = new IncrementFeed(1 ether);
        nhi = new IncrementFeed(0.85 ether);
        vault = new CDPVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(ALICE, 171 ether);
        imd.mint(BOB, 20 ether);
        vm.stopPrank();
        // BOB borrows a little of his own, so he can lend ALICE the stability fee her debt accrues.
        vm.startPrank(BOB);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(20 ether);
        vault.draw(1 ether);
        vm.stopPrank();
        vm.startPrank(ALICE);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(170 ether);
        vault.draw(100 ether);
        comp.transfer(BOB, 10 ether);
        vm.stopPrank();
        primary.set(0.9 ether);
        spot.set(0.9 ether);
        vm.prank(MARKER);
        vault.bark(ALICE);
        (markedAt, grace,,) = vault.liquidationMarks(ALICE);
        assertEq(grace, 6 hours);
        vm.warp(markedAt + grace);
    }

    function test_divergentRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.Divergence);
    }

    function test_staleSpotRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.StaleSpot);
    }

    function test_zeroSpotRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.ZeroSpot);
    }

    function test_stalePrimaryRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.StalePrimary);
    }

    function test_zeroPrimaryRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.ZeroPrimary);
    }

    function test_staleNhiRecoveryPreservesMatureMarkOnAllRoutes() public {
        _checkInvalidRecovery(InvalidObservation.StaleNhi);
    }

    function test_fullRepaymentAndDebtFreeExitRemainFeedIndependent() public {
        primary.set(0);
        primary.setStale(true);
        spot.set(0);
        spot.setStale(true);
        nhi.setStale(true);
        vm.prank(BOB);
        comp.transfer(ALICE, 11 ether);
        uint256 owed = vault.debtOf(ALICE); // principal plus the fee accrued through the grace period
        assertGt(owed, 100 ether);
        vm.startPrank(ALICE);
        vault.wipe(owed);
        _assertCleared();
        vault.free(170 ether);
        vm.stopPrank();
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(imd.balanceOf(ALICE), 171 ether);
        assertEq(comp.balanceOf(ALICE), 101 ether - owed, "90 kept + 11 from BOB, less everything owed");
    }

    function test_freshAgreedRecoveryClearsOnAllRoutes() public {
        _checkValidRecovery(RECOVERED);
    }

    function test_recoveryAcceptsExactUpperPrimaryRelativeBoundary() public {
        _checkValidRecovery(RECOVERED + RECOVERED * SKEW_BPS / 10_000);
    }

    function test_recoveryAcceptsExactLowerPrimaryRelativeBoundary() public {
        _checkValidRecovery(RECOVERED - RECOVERED * SKEW_BPS / 10_000);
    }

    function _checkInvalidRecovery(InvalidObservation observation) private {
        for (uint256 route; route < 3; ++route) {
            uint256 snapshot = vm.snapshotState();
            primary.set(RECOVERED);
            spot.set(RECOVERED);
            bytes4 expectedError = CDPVault.StaleFeed.selector;
            if (observation == InvalidObservation.Divergence) {
                spot.set(0.9 ether);
                expectedError = CDPVault.PriceDivergence.selector;
            } else if (observation == InvalidObservation.StaleSpot) {
                spot.setStale(true);
            } else if (observation == InvalidObservation.ZeroSpot) {
                spot.set(0);
                expectedError = CDPVault.InvalidPrice.selector;
            } else if (observation == InvalidObservation.StalePrimary) {
                primary.setStale(true);
            } else if (observation == InvalidObservation.ZeroPrimary) {
                primary.set(0);
                expectedError = CDPVault.InvalidPrice.selector;
            } else {
                nhi.setStale(true);
            }
            if (route == 0) {
                // Explicit clear may reject the observation or leave the mark alone.
                (bool accepted, bytes memory reason) =
                    address(vault).call(abi.encodeCall(vault.heel, (ALICE)));
                if (!accepted) assertEq(reason, abi.encodeWithSelector(expectedError));
            } else {
                uint256 owedBefore = vault.debtOf(ALICE); // principal plus the fee accrued so far
                _recover(route);
                (uint256 collateral,) = vault.positions(ALICE);
                assertEq(collateral, 170 ether + (route == 1 ? 1 : 0));
                assertEq(vault.debtOf(ALICE), owedBefore - (route == 2 ? 1 : 0));
            }
            _assertOriginalMark();
            primary.set(0.9 ether);
            spot.set(0.9 ether);
            primary.setStale(false);
            spot.setStale(false);
            nhi.setStale(false);
            vm.prank(BOB);
            vault.bark(ALICE);
            _assertOriginalMark();
            uint256 owed = vault.debtOf(ALICE); // principal plus the fee accrued through the grace period
            vm.prank(BOB);
            vault.bite(ALICE, 10 ether);
            assertEq(vault.debtOf(ALICE), owed - 10 ether);
            assertGt(imd.balanceOf(MARKER), 0, "original marker receives its bonus share");
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function _checkValidRecovery(uint256 spotPrice) private {
        for (uint256 route; route < 3; ++route) {
            uint256 snapshot = vm.snapshotState();
            primary.set(RECOVERED);
            spot.set(spotPrice);
            _recover(route);
            _assertCleared();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function _recover(uint256 route) private {
        vm.startPrank(ALICE);
        if (route == 0) vault.heel(ALICE);
        else if (route == 1) vault.lock(1);
        else vault.wipe(1);
        vm.stopPrank();
    }

    function _assertOriginalMark() private view {
        (uint256 currentAt, uint256 currentGrace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked, "invalid recovery must preserve mature mark");
        assertEq(currentAt, markedAt);
        assertEq(currentGrace, grace);
        assertEq(marker, MARKER);
    }

    function _assertCleared() private view {
        (uint256 currentAt, uint256 currentGrace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertFalse(marked);
        assertEq(currentAt, 0);
        assertEq(currentGrace, 0);
        assertEq(marker, address(0));
    }
}
