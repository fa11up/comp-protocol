// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "../../src/CDPVault.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {MockWorkOracle} from "../../src/MockWorkOracle.sol";
import {ISwarmFeed} from "../../src/interfaces/ISwarmFeed.sol";
import {
    APPROVED_OPERATOR,
    FEE_RECIPIENT,
    SKEW_BPS,
    CHIP_BPS,
    DUTY_BPS
} from "../../src/DeploymentConfig.sol";

/// @dev Independent fixture: these tests exercise the vault's checks, not feed aggregation.
contract IncrementFeed is ISwarmFeed {
    uint256 private value;
    bool public stale;
    uint256 public constant maxAge = 1 days;

    constructor(uint256 value_) {
        value = value_;
    }

    function set(uint256 value_) external {
        value = value_;
    }

    function setStale(bool stale_) external {
        stale = stale_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return stale;
    }
}

contract IncrementShareVault is CDPVault {
    uint256 private immutable share;

    constructor(address collateral, address primary, address nhi, address spot, uint256 share_)
        CDPVault(collateral, address(0), address(0), primary, nhi, spot)
    {
        share = share_;
    }

    function cut() public view override returns (uint256) {
        return share;
    }
}

contract IncrementCeilingVault is IncrementShareVault {
    constructor(address collateral, address primary, address nhi, address spot)
        IncrementShareVault(collateral, primary, nhi, spot, 0)
    {}

    function line() public pure override returns (uint256) {
        return 100 ether;
    }
}

/// @notice Run independently of legacy constructor fixtures with:
/// FOUNDRY_TEST=script/checks FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
/// forge test --match-path script/checks/CDPVaultIncrement.t.sol
/// The fee cases also support a scratch source copy with a nonzero DUTY_BPS.
contract CDPVaultIncrementTest is Test {
    MockIMD private imd;
    CDPVault private vault;
    ImdUSD private comp;
    IncrementFeed private primary;
    IncrementFeed private spot;
    IncrementFeed private nhi;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant MARKER = address(0xCA11);
    address private constant OTHER_MARKER = address(0xCA12);

    function setUp() public {
        imd = new MockIMD();
        primary = new IncrementFeed(1 ether);
        spot = new IncrementFeed(1 ether);
        nhi = new IncrementFeed(0.85 ether);
        vault = new CDPVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(ALICE, 10_000 ether);
        imd.mint(BOB, 10_000 ether);
        MockWorkOracle(address(vault.oracle())).grantRights(BOB, 10_000 ether);
        vm.stopPrank();
        vm.prank(ALICE);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(vault), type(uint256).max);
    }

    function test_constructorPinsOnlyTheNewSpotFeedAndConfigScalars() public view {
        assertEq(address(vault.priceFeed()), address(primary));
        assertEq(address(vault.spotFeed()), address(spot));
        assertEq(vault.skew(), SKEW_BPS);
        assertEq(vault.chip(), CHIP_BPS);
        assertEq(vault.duty(), DUTY_BPS);
        assertEq(comp.vault(), address(vault));
        assertEq(MockWorkOracle(address(vault.oracle())).vault(), address(vault));
    }

    function test_constructorRejectsUndeployedSpot() public {
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new CDPVault(address(imd), address(0), address(0), address(primary), address(nhi), address(0));
    }

    function test_divergenceBoundaryUsesPrimaryDenominatorOnBothSides() public {
        _open(300 ether, 0);
        uint256 tolerance = 1 ether * SKEW_BPS / 10_000;
        spot.set(1 ether + tolerance);
        vm.prank(ALICE);
        vault.draw(1 ether);
        spot.set(1 ether + tolerance + 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.draw(1 ether);
        spot.set(1 ether - tolerance);
        vm.prank(ALICE);
        vault.draw(1 ether);
        spot.set(1 ether - tolerance - 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.draw(1 ether);
        assertEq(vault.debtOf(ALICE), 2 ether);
    }

    function test_divergenceComparisonHandlesFullWidthPrices() public {
        _open(300 ether, 0);
        uint256 price = type(uint256).max;
        uint256 tolerance = Math.mulDiv(price, SKEW_BPS, 10_000);
        primary.set(price);
        spot.set(price - tolerance);
        vm.prank(ALICE);
        vault.draw(1 ether);
        spot.set(price - tolerance - 1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.draw(1 ether);
    }

    function test_divergenceBlocksAllThreeActionsButAllowsRepaymentAndDebtFreeExit() public {
        _open(300 ether, 100 ether);
        _price(0.4 ether);
        nhi.set(0.6 ether);
        vm.prank(MARKER);
        vault.bark(ALICE);
        spot.set(1 ether);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vm.prank(ALICE);
        vault.draw(1);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.bark(ALICE);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.bite(ALICE, 1);
        vm.startPrank(ALICE);
        vault.wipe(100 ether);
        vault.free(300 ether);
        vm.stopPrank();
        _position(vault, 0, 0);
        assertEq(imd.balanceOf(ALICE), 10_000 ether);
    }

    function test_spotStalenessAndZeroBlockPriceDependentActions() public {
        _open(300 ether, 100 ether);
        _price(0.4 ether);
        nhi.set(0.6 ether);
        vault.bark(ALICE);
        spot.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.draw(1);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.bark(ALICE);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.bite(ALICE, 1);
        spot.setStale(false);
        spot.set(0);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vm.prank(ALICE);
        vault.draw(1);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.bark(ALICE);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.bite(ALICE, 1);
        vm.startPrank(ALICE);
        vault.wipe(100 ether);
        primary.setStale(true);
        nhi.setStale(true);
        spot.setStale(true);
        vault.free(300 ether);
        vm.stopPrank();
        _position(vault, 0, 0);
    }

    function test_spotGuardLeavesWorkMintAvailableAndProtectsDebtBearingWithdrawal() public {
        _open(300 ether, 100 ether);
        spot.set(0);
        spot.setStale(true);
        vm.prank(BOB);
        vault.earn(5 ether);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.free(1 ether);
        assertEq(comp.balanceOf(BOB), 5 ether);
        _position(vault, 300 ether, 100 ether);
    }

    function test_existingPrimaryAndNhiFreshnessGuardsRemain() public {
        _open(300 ether, 100 ether);
        primary.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.free(1);
        primary.setStale(false);
        nhi.setStale(true);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vm.prank(ALICE);
        vault.draw(1);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.bark(ALICE);
    }

    function test_repeatedMarkPreservesMarkerAndGraceSnapshot() public {
        _open(300 ether, 100 ether);
        _price(0.4 ether);
        vm.prank(MARKER);
        vault.bark(ALICE);
        (uint256 markedAt, uint256 grace, bool marked, address marker) = vault.liquidationMarks(ALICE);
        assertTrue(marked);
        assertEq(grace, 6 hours);
        assertEq(marker, MARKER);
        nhi.set(0.6 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(OTHER_MARKER);
        vault.bark(ALICE);
        (uint256 againAt, uint256 againGrace,, address againMarker) = vault.liquidationMarks(ALICE);
        assertEq(againAt, markedAt);
        assertEq(againGrace, grace);
        assertEq(againMarker, MARKER);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        vault.bite(ALICE, 1);
        vm.warp(markedAt + grace + vault.tail() + 1);
        vm.expectRevert(CDPVault.MarkExpired.selector);
        vault.bite(ALICE, 1);
        vm.prank(OTHER_MARKER);
        vault.bark(ALICE);
        (againAt, againGrace,, againMarker) = vault.liquidationMarks(ALICE);
        assertEq(againAt, block.timestamp);
        assertEq(againGrace, 0);
        assertEq(againMarker, OTHER_MARKER);
    }

    function test_successfulLiquidationPaysRecordedMarkerFromExistingBonus() public {
        _open(300 ether, 100 ether);
        _fundLiquidator(100 ether);
        _price(0.4 ether);
        nhi.set(0.6 ether);
        vm.prank(MARKER);
        vault.bark(ALICE);
        uint256 beforeBalance = imd.balanceOf(BOB);
        vm.prank(BOB);
        vault.bite(ALICE, 20 ether);
        uint256 payout = 55 ether;
        uint256 markerCut = 5 ether * CHIP_BPS / 10_000;
        assertEq(imd.balanceOf(MARKER), markerCut);
        assertEq(imd.balanceOf(BOB) - beforeBalance, payout - markerCut);
        _position(vault, 245 ether, 80 ether);
        assertEq(imd.balanceOf(address(vault)), 245 ether);
    }

    function test_markerEqualsLiquidatorReceivesOneCombinedTransfer() public {
        _open(300 ether, 100 ether);
        _fundLiquidator(100 ether);
        _price(0.4 ether);
        nhi.set(0.6 ether);
        vm.prank(BOB);
        vault.bark(ALICE);
        uint256 beforeBalance = imd.balanceOf(BOB);
        vm.recordLogs();
        vm.prank(BOB);
        vault.bite(ALICE, 20 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 collateralTransfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(imd) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)"))
            {
                ++collateralTransfers;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), BOB);
                assertEq(abi.decode(logs[i].data, (uint256)), 55 ether);
            }
        }
        assertEq(collateralTransfers, 1);
        assertEq(imd.balanceOf(BOB) - beforeBalance, 55 ether);
    }

    function test_protocolAndMarkerSharesLeaveBorrowerLossUnchanged() public {
        IncrementShareVault shared =
            new IncrementShareVault(address(imd), address(primary), address(nhi), address(spot), 2_000);
        vm.startPrank(ALICE);
        imd.approve(address(shared), type(uint256).max);
        shared.lock(300 ether);
        shared.draw(100 ether);
        shared.stablecoin().transfer(BOB, 100 ether);
        vm.stopPrank();
        _open(300 ether, 100 ether);
        _fundLiquidator(100 ether);
        _price(0.4 ether);
        nhi.set(0.6 ether);
        vm.startPrank(MARKER);
        vault.bark(ALICE);
        shared.bark(ALICE);
        vm.stopPrank();
        uint256 protocolBalance = imd.balanceOf(FEE_RECIPIENT);
        uint256 liquidatorBalance = imd.balanceOf(BOB);
        vm.prank(BOB);
        shared.bite(ALICE, 20 ether);
        uint256 markerCut = 10 ether * CHIP_BPS / 10_000;
        assertEq(imd.balanceOf(FEE_RECIPIENT) - protocolBalance, 2 ether);
        assertEq(imd.balanceOf(MARKER), markerCut);
        assertEq(imd.balanceOf(BOB) - liquidatorBalance, 58 ether - markerCut);
        vm.prank(BOB);
        vault.bite(ALICE, 20 ether);
        (uint256 defaultCollateral, uint256 defaultDebt) = vault.positions(ALICE);
        _position(shared, defaultCollateral, defaultDebt);
        assertEq(defaultCollateral, 240 ether, "same 120 percent payout regardless of recipients");
    }

    function test_bonusSharesCannotConsumeLiquidatorPrincipal() public {
        IncrementShareVault invalid = new IncrementShareVault(
            address(imd), address(primary), address(nhi), address(spot), 10_001 - CHIP_BPS
        );
        vm.startPrank(ALICE);
        imd.approve(address(invalid), type(uint256).max);
        invalid.lock(300 ether);
        invalid.draw(100 ether);
        vm.stopPrank();
        _price(0.4 ether);
        nhi.set(0.6 ether);
        invalid.bark(ALICE);
        vm.expectRevert(CDPVault.InvalidBonusShares.selector);
        invalid.bite(ALICE, 20 ether);
        _position(invalid, 300 ether, 100 ether);
    }

    function test_badDebtIsVisibleBeforeLiquidationAndTrackedWithoutForgiveness() public {
        // 171% to open; at 0.55 it covers 120 x 0.55 / 1.2 = 55 of its 70.
        _open(120 ether, 70 ether);
        _fundLiquidator(70 ether);
        _price(0.55 ether);
        nhi.set(0.6 ether);
        assertEq(vault.badDebtOf(ALICE), 15 ether);
        assertEq(vault.totalBadDebt(), 0, "not yet realized by collateral exhaustion");
        vault.bark(ALICE);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.bite(ALICE, 70 ether);
        _position(vault, 120 ether, 70 ether);
        vm.prank(BOB);
        vault.bite(ALICE, 55 ether);
        _position(vault, 0, 15 ether);
        assertEq(vault.badDebtOf(ALICE), 15 ether);
        assertEq(vault.totalBadDebt(), 15 ether);
        assertEq(vault.totalDebt(), 15 ether);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vm.prank(BOB);
        vault.bite(ALICE, 1 ether);
        assertEq(vault.totalBadDebt(), 15 ether);
        vm.prank(BOB);
        comp.transfer(ALICE, 15 ether);
        vm.prank(ALICE);
        vault.wipe(5 ether);
        _position(vault, 0, 10 ether);
        assertEq(vault.totalBadDebt(), 10 ether);
        vm.prank(ALICE);
        vault.wipe(10 ether);
        _position(vault, 0, 0);
        assertEq(vault.totalBadDebt(), 0);
        assertEq(comp.totalSupply(), 0);
    }

    function test_recollateralizationCannotHideRecordedBadDebt() public {
        _open(120 ether, 70 ether);
        _fundLiquidator(70 ether);
        _price(0.55 ether);
        nhi.set(0.6 ether);
        vault.bark(ALICE);
        vm.prank(BOB);
        vault.bite(ALICE, 55 ether);
        vm.prank(ALICE);
        vault.lock(12 ether); // covers 12 x 0.55 / 1.2 = 5.5 of the 15
        _position(vault, 12 ether, 15 ether);
        assertEq(vault.badDebtOf(ALICE), 9.5 ether);
        assertEq(vault.totalBadDebt(), 15 ether);
        assertEq(vault.totalDebt(), 15 ether);
    }

    function test_badDebtMatchesExistingRoundedPayoutForOneWeiDebt() public {
        _price(2 ether);
        _open(1, 1);
        _fundLiquidator(1);
        _price(1 ether);
        nhi.set(0.6 ether);
        assertEq(vault.badDebtOf(ALICE), 0, "one collateral wei covers the rounded one-wei payout");
        vault.bark(ALICE);
        vm.prank(BOB);
        vault.bite(ALICE, 1);
        _position(vault, 0, 0);
        assertEq(vault.totalBadDebt(), 0);
    }

    function testFuzz_badDebtSeparatesCoveredFromUncoveredRoundedPayout(
        uint16 collateralSeed,
        uint16 debtSeed,
        uint64 priceSeed
    ) public {
        uint256 collateral = bound(uint256(collateralSeed), 1, 1_000);
        uint256 debt = bound(uint256(debtSeed), 1, 2_000);
        uint256 price = bound(uint256(priceSeed), 1, 10 ether);
        _price(10_000 ether);
        _open(collateral, debt);
        _price(price);
        uint256 badDebt = vault.badDebtOf(ALICE);
        assertLe(badDebt, debt);
        uint256 covered = debt - badDebt;
        uint256 bonusScale = (100 + vault.CHOP_PERCENT()) * 1e16;
        assertLe(covered * bonusScale / price, collateral);
        if (badDebt != 0) assertGt((covered + 1) * bonusScale / price, collateral);
    }

    function test_feeIsLinearAndReadsDoNotCompoundOrCheckpoint() public {
        _open(1_000 ether, 100 ether);
        uint256 originalIndex = vault.chiOf(ALICE);
        uint256 started = block.timestamp;
        vm.warp(started + 365 days);
        uint256 yearFee = 100 ether * DUTY_BPS / 10_000;
        assertEq(vault.debtOf(ALICE), 100 ether + yearFee);
        assertEq(vault.stabilityFeeOf(ALICE), yearFee);
        _position(vault, 1_000 ether, 100 ether + yearFee);
        assertEq(vault.collateralRatio(ALICE), 1_000 ether * 100 / (100 ether + yearFee));
        vm.prank(ALICE);
        vault.lock(1 ether);
        assertEq(vault.chiOf(ALICE), originalIndex, "collateral changes do not capitalize interest");
        vm.warp(started + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 100 ether + 2 * yearFee);
        assertEq(vault.totalDebt(), 100 ether, "ceiling remains an outstanding principal limit");
        assertEq(comp.totalSupply(), 100 ether, "unpaid fees are not minted");
    }

    function test_feePaymentMintsOnlyCollectedFeeAndLeavesPrincipalUntilFeePaid() public {
        _open(1_000 ether, 100 ether);
        uint256 started = block.timestamp;
        vm.warp(started + 365 days);
        uint256 fee = 100 ether * DUTY_BPS / 10_000;
        uint256 recipientBalance = comp.balanceOf(FEE_RECIPIENT);
        if (fee != 0) {
            vm.prank(ALICE);
            vault.wipe(fee / 2);
            assertEq(vault.totalDebt(), 100 ether);
            assertEq(vault.stabilityFeeOf(ALICE), fee - fee / 2);
            assertEq(comp.balanceOf(FEE_RECIPIENT) - recipientBalance, fee / 2);
            assertEq(vault.totalFeesMinted(), fee / 2);
        }
        uint256 remainingFee = vault.stabilityFeeOf(ALICE);
        vm.prank(ALICE);
        vault.wipe(remainingFee + 10 ether);
        assertEq(vault.totalDebt(), 90 ether);
        assertEq(vault.debtOf(ALICE), 90 ether);
        assertEq(vault.stabilityFeeOf(ALICE), 0);
        assertEq(vault.totalFeesMinted(), fee);
        assertEq(comp.balanceOf(FEE_RECIPIENT) - recipientBalance, fee);
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalEarned());
        vm.warp(started + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 90 ether + 90 ether * DUTY_BPS / 10_000);
    }

    function test_borrowCheckpointPreservesUnpaidFeeWithoutChargingFeeOnFee() public {
        _open(1_000 ether, 100 ether);
        uint256 started = block.timestamp;
        vm.warp(started + 365 days);
        uint256 firstYearFee = 100 ether * DUTY_BPS / 10_000;
        vm.prank(ALICE);
        vault.draw(50 ether);
        assertEq(vault.debtOf(ALICE), 150 ether + firstYearFee);
        assertEq(vault.chiOf(ALICE), vault.chi());
        vm.warp(started + 2 * 365 days);
        assertEq(vault.debtOf(ALICE), 150 ether + 250 ether * DUTY_BPS / 10_000);
        assertEq(vault.totalDebt(), 150 ether);
        assertEq(vault.totalFeesMinted(), 0);
    }

    function test_feeAccrualLeavesDebtCeilingHookAndPrincipalHeadroomUnchanged() public {
        IncrementCeilingVault capped =
            new IncrementCeilingVault(address(imd), address(primary), address(nhi), address(spot));
        vm.startPrank(ALICE);
        imd.approve(address(capped), type(uint256).max);
        capped.lock(1_000 ether);
        capped.draw(100 ether);
        vm.warp(block.timestamp + 365 days);
        uint256 fee = capped.stabilityFeeOf(ALICE);
        assertEq(capped.totalDebt(), capped.line());
        assertEq(capped.debtOf(ALICE), 100 ether + fee);
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        capped.draw(1);
        capped.wipe(fee + 10 ether);
        assertEq(capped.totalDebt(), 90 ether);
        capped.draw(10 ether);
        assertEq(capped.totalDebt(), 100 ether);
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        capped.draw(1);
        vm.stopPrank();
    }

    function test_nonzeroFeeAffectsHealthAndLiquidationRepayment() public {
        if (DUTY_BPS == 0) {
            vm.skip(true);
            return;
        }
        _open(170 ether, 100 ether);
        uint256 started = block.timestamp;
        vm.warp(started + 365 days);
        uint256 fee = 100 ether * DUTY_BPS / 10_000;
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vm.prank(ALICE);
        vault.free(1);
        vm.prank(MARKER);
        vault.bark(ALICE);
        (, uint256 grace,,) = vault.liquidationMarks(ALICE);
        vm.warp(block.timestamp + grace);
        uint256 debt = vault.debtOf(ALICE);
        assertGt(debt, 100 ether);
        assertGe(vault.stabilityFeeOf(ALICE), fee);
        vm.prank(BOB);
        vault.earn(debt);
        uint256 recipientBalance = comp.balanceOf(FEE_RECIPIENT);
        uint256 owedFee = vault.stabilityFeeOf(ALICE);
        vm.prank(BOB);
        vault.bite(ALICE, debt);
        assertEq(vault.debtOf(ALICE), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalFeesMinted(), owedFee);
        assertEq(comp.balanceOf(FEE_RECIPIENT) - recipientBalance, owedFee);
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalEarned());
    }

    function test_nonzeroFeeOnlyRepaymentCannotEraseRecordedPrincipalShortfall() public {
        if (DUTY_BPS == 0) {
            vm.skip(true);
            return;
        }
        _open(120 ether, 70 ether);
        _fundLiquidator(70 ether);
        _price(0.55 ether);
        nhi.set(0.6 ether);
        vault.bark(ALICE);
        vm.prank(BOB);
        vault.bite(ALICE, 55 ether);
        vm.warp(block.timestamp + 365 days);
        uint256 fee = vault.stabilityFeeOf(ALICE);
        vm.startPrank(BOB);
        vault.earn(fee);
        comp.transfer(ALICE, fee);
        vm.stopPrank();
        vm.prank(ALICE);
        vault.wipe(fee);
        _position(vault, 0, 15 ether);
        assertEq(vault.totalDebt(), 15 ether);
        assertEq(vault.totalBadDebt(), 15 ether);
        assertEq(vault.badDebtOf(ALICE), 15 ether);
        assertEq(vault.totalFeesMinted(), fee);
    }

    function _open(uint256 collateral, uint256 debt) private {
        vm.startPrank(ALICE);
        vault.lock(collateral);
        if (debt != 0) vault.draw(debt);
        vm.stopPrank();
    }

    function _fundLiquidator(uint256 amount) private {
        vm.prank(ALICE);
        comp.transfer(BOB, amount);
    }

    function _price(uint256 value) private {
        primary.set(value);
        spot.set(value);
    }

    function _position(CDPVault target, uint256 collateral, uint256 debt) private view {
        (uint256 actualCollateral, uint256 actualDebt) = target.positions(ALICE);
        assertEq(actualCollateral, collateral, "collateral");
        assertEq(actualDebt, debt, "debt");
    }
}
