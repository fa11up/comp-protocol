// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";
import {IERC20 as IERC20Like} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice `cover`: the protocol's surplus imdUSD (its Treasury's) retires realized bad debt.
/// @dev A realized bad debt is made the way the vault makes one: a crash, a mark, and a liquidation
/// that drains the position's collateral while debt remains.
contract CoverTest is WorkBackingFixture {
    address private constant KEEPER = address(0xBEEF);
    address private constant STRANGER = address(0x5757);

    event Cover(address indexed owner, uint256 amount, address indexed payer);

    function _open(address who, uint256 amount, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(backedVault), amount);
        backedVault.lock(amount);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    /// @dev BORROWER at exactly mat (170 / 100) is crashed to half price, marked, and liquidated for all
    /// its collateral can cover; the remainder of its debt is realized bad debt. KEEPER, a second
    /// borrower, supplies the imdUSD that liquidates it and keeps what is left.
    function _drain() private returns (uint256 bad) {
        _open(BORROWER, 170 ether, 100 ether);
        _open(KEEPER, 450 ether, 250 ether);
        _setVaultPrice(0.5 ether);
        backedVault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _refreshEthUsd();
        uint256 repayable = uint256(170 ether) * 0.5 ether / ((100 + backedVault.CHOP_PERCENT()) * 1e16);
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, repayable);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "drained");
        bad = backedVault.totalBadDebt();
        assertGt(bad, 0, "realized");
        assertEq(backedVault.debtOf(BORROWER), bad, "the whole remaining debt is the realized loss");
        _setVaultPrice(1 ether);
    }

    /// @dev imdUSD reaches the Treasury as stability fees; a transfer of real tokens stands in for them.
    function _fundTreasury(uint256 amount) private {
        vm.prank(KEEPER);
        stable.transfer(address(reserve), amount);
    }

    function test_coverRetiresRealizedBadDebtWithTheTreasurysImdUSD() public {
        uint256 bad = _drain();
        _fundTreasury(bad);
        uint256 treasuryBefore = stable.balanceOf(address(reserve));
        uint256 supplyBefore = stable.totalSupply();
        uint256 debtBefore = backedVault.totalDebt();

        vm.expectEmit(address(backedVault));
        emit Cover(BORROWER, bad, address(reserve));
        vm.prank(STRANGER); // anyone may call it
        backedVault.cover(BORROWER, bad);

        assertEq(backedVault.totalBadDebt(), 0, "the loss is retired");
        assertEq(backedVault.debtOf(BORROWER), 0);
        assertEq(backedVault.badDebtOf(BORROWER), 0);
        assertEq(backedVault.totalDebt(), debtBefore - bad, "principal leaves totalDebt");
        assertEq(stable.balanceOf(address(reserve)), treasuryBefore - bad, "paid from the Treasury");
        assertEq(stable.totalSupply(), supplyBefore - bad, "and burned, not moved");
        assertEq(stable.balanceOf(STRANGER), 0, "the caller spends and receives nothing");
    }

    /// @dev Fees accrued after the drain are retired first and reminted to the Treasury, exactly as in
    /// `wipe`, so covering only the fees moves no principal and costs the Treasury nothing net.
    function test_coverRetiresFeesBeforePrincipal() public {
        uint256 bad = _drain();
        vm.warp(vm.getBlockTimestamp() + 90 days);
        _refreshEthUsd();
        uint256 fees = backedVault.stabilityFeeOf(BORROWER);
        assertGt(fees, 0, "fees keep accruing on a drained position");
        _fundTreasury(fees);
        uint256 treasuryBefore = stable.balanceOf(address(reserve));
        uint256 debtBefore = backedVault.totalDebt();
        uint256 feesMintedBefore = backedVault.totalFeesMinted();

        backedVault.cover(BORROWER, fees);

        assertEq(backedVault.stabilityFeeOf(BORROWER), 0, "fees first");
        assertEq(backedVault.totalDebt(), debtBefore, "no principal yet");
        assertEq(backedVault.debtOf(BORROWER), bad, "the principal loss is still owed");
        assertEq(backedVault.totalBadDebt(), bad);
        assertEq(stable.balanceOf(address(reserve)), treasuryBefore, "burned and reminted to the Treasury");
        assertEq(backedVault.totalFeesMinted(), feesMintedBefore + fees);

        _fundTreasury(bad);
        backedVault.cover(BORROWER, bad);
        assertEq(backedVault.totalBadDebt(), 0);
    }

    function test_partialCoverKeepsTheRecordConsistent() public {
        uint256 bad = _drain();
        _fundTreasury(bad);
        uint256 half = bad / 2;
        backedVault.cover(BORROWER, half);
        assertEq(backedVault.totalBadDebt(), bad - half);
        assertEq(backedVault.debtOf(BORROWER), bad - half);
        assertEq(backedVault.badDebtOf(BORROWER), bad - half);
        backedVault.cover(BORROWER, bad - half);
        assertEq(backedVault.totalBadDebt(), 0);
        assertEq(backedVault.debtOf(BORROWER), 0);
    }

    function test_coverLeavesBackingNoWorse() public {
        uint256 bad = _drain();
        _fundTreasury(bad);
        uint256 before = backedVault.backingPerUnit();
        backedVault.cover(BORROWER, bad);
        assertGe(backedVault.backingPerUnit(), before, "retiring a loss never lowers backing per imdUSD");
    }

    // --- refusals ---------------------------------------------------------------------------------

    function test_aPositionThatStillHoldsCollateralIsNotRealizedBadDebt() public {
        _drain();
        _fundTreasury(1 ether);
        vm.expectRevert(CDPVault.NoRealizedBadDebt.selector);
        backedVault.cover(KEEPER, 1 ether);
    }

    function test_anAccountWithNoPositionHasNothingToCover() public {
        _drain();
        _fundTreasury(1 ether);
        vm.expectRevert(CDPVault.NoRealizedBadDebt.selector);
        backedVault.cover(STRANGER, 1 ether);
    }

    function test_coverCannotRetireMoreThanIsOwed() public {
        uint256 bad = _drain();
        _fundTreasury(bad + 1 ether);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        backedVault.cover(BORROWER, bad + 1);
    }

    function test_coverCannotSpendMoreThanTheTreasuryHolds() public {
        uint256 bad = _drain();
        uint256 held = stable.balanceOf(address(reserve)); // the liquidation's fees, if any
        assertLt(held, bad);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(reserve), held, bad)
        );
        backedVault.cover(BORROWER, bad);
    }

    function test_coverRefusesZero() public {
        _drain();
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        backedVault.cover(BORROWER, 0);
    }
    // --- dust (launch audit, vault panel + governance panel, medium) ------------------------------
    // At sIMD's scale (about 8.7e13 USD per 1e18 raw units) one wei of debt seizes ~13,800 raw units,
    // so a smaller collateral could never be bitten, and `cover` refused any non-zero collateral. A
    // drained borrower re-locking one raw unit froze the bad debt. These tests price the collateral at
    // that scale (1e12 per 1e18 raw), where one wei of debt seizes 1.2e6 raw units.

    uint256 private constant SIMD_SCALE_PRICE = 1e12;

    function _relockDust() private returns (uint256 bad) {
        bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, 1);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), 1);
        backedVault.lock(1);
        vm.stopPrank();
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 1, "one raw unit re-locked onto the drained position");
    }

    function test_reLockedDustNoLongerBlocksCover() public {
        uint256 bad = _relockDust();
        _fundTreasury(bad);
        uint256 treasuryGemBefore = collateral.balanceOf(address(reserve));
        vm.prank(STRANGER);
        backedVault.cover(BORROWER, bad);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "the dust was swept");
        assertEq(collateral.balanceOf(address(reserve)), treasuryGemBefore + 1, "to the Treasury");
        assertEq(backedVault.totalBadDebt(), 0, "and the bad debt is retired");
        assertEq(backedVault.debtOf(BORROWER), 0);
    }

    function test_reLockedDustIsTakenWholeByABite() public {
        uint256 bad = _relockDust();
        backedVault.bark(BORROWER); // still marked from the drain: a no-op unless expired
        uint256 keeperGemBefore = collateral.balanceOf(KEEPER);
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, 1);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "a one-wei bite drains dust below the one-wei seizure");
        assertEq(collateral.balanceOf(KEEPER), keeperGemBefore + 1);
        assertEq(backedVault.totalBadDebt(), bad - 1, "drained again, the residual is recorded");
    }

    /// @dev The variant with no owner action: the largest coverable bite leaves a remainder at the
    /// one-wei seizure (not swept), then the price falls and that remainder can no longer be seized.
    function test_dustLeftByAPriceFallIsStillReachable() public {
        _setVaultPrice(3 * SIMD_SCALE_PRICE);
        uint256 locked = 1.2e24 + 1.2e6; // one imdUSD's seizure at 1e12, plus one one-wei seizure
        _open(BORROWER, locked, 2 ether);
        _open(KEEPER, 450 ether * 1e6, 250 ether); // enough collateral at this scale to borrow imdUSD
        _setVaultPrice(SIMD_SCALE_PRICE);
        backedVault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _refreshEthUsd();
        _setVaultPrice(SIMD_SCALE_PRICE);
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, 1 ether);
        (uint256 remainder,) = backedVault.positions(BORROWER);
        assertEq(remainder, 1.2e6, "left exactly one one-wei seizure, which the sweep does not take");
        assertGt(backedVault.debtOf(BORROWER), 0, "with debt still owed");

        _setVaultPrice(SIMD_SCALE_PRICE / 2); // a further fall: the remainder is now below one wei's seizure
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, 1);
        (remainder,) = backedVault.positions(BORROWER);
        assertEq(remainder, 0, "taken whole instead of reverting InsufficientCollateral");
        assertGt(backedVault.totalBadDebt(), 0, "the shortfall is realized and coverable");
    }

    /// @dev The seizure, at `price`, for `debt` wei of imdUSD: what a bite would take for it.
    function _seizureFor(uint256 debt, uint256 price) private view returns (uint256) {
        return debt * (100 + backedVault.CHOP_PERCENT()) * 1e16 / price;
    }

    /// @dev The debt `cover` treats as dust: a millionth of it, or one imdUSD (a hundredth, under 100 imdUSD).
    function _dustSlice(uint256 debt) private pure returns (uint256) {
        uint256 floor_ = debt / 100 < 1e18 ? debt / 100 : 1e18;
        return debt / 1_000_000 > floor_ ? debt / 1_000_000 : floor_;
    }

    function test_coverStillRefusesAPositionWithRealCollateral() public {
        _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        // More than the dust floor AND worth more than the realized bad debt (twice it): that collateral
        // could make the debt good, so a bite reaches it and cover must not. Anything worth LESS than the
        // bad debt is swept (test_coverSweepsCollateralWorthLessThanTheBadDebt).
        uint256 bad = backedVault.badDebtOf(BORROWER);
        uint256 real = 2 * _seizureFor(_dustSlice(backedVault.debtOf(BORROWER)), SIMD_SCALE_PRICE);
        uint256 worthBad = 2 * bad * 1e18 / SIMD_SCALE_PRICE;
        if (worthBad > real) real = worthBad;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, real);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), real);
        backedVault.lock(real);
        vm.stopPrank();
        vm.expectRevert(CDPVault.NoRealizedBadDebt.selector);
        backedVault.cover(BORROWER, 1);
    }

    /// @dev Final review 2026-10-07, low. The dust floor used to be the seizure for ONE wei of debt, so a
    /// drained borrower could re-lock that seizure plus one raw unit (about 1e-20 sIMD, worth nothing)
    /// for free after every bite: cover refused it as "collateral a bite could reach", a bite needed a
    /// fresh mark and the full grace, and the Treasury's imdUSD stayed reserved behind the bad debt for
    /// a cycle at a time. Anything worth under a millionth of the debt is now swept as dust.
    function test_coverSweepsDustJustAboveTheOneWeiSeizure() public {
        uint256 bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        uint256 griefing = _seizureFor(1, SIMD_SCALE_PRICE) + 1; // the reviewer's exact amount
        assertLt(griefing, _seizureFor(bad / 1_000_000, SIMD_SCALE_PRICE), "worth under a millionth of the debt");
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, griefing);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), griefing);
        backedVault.lock(griefing);
        vm.stopPrank();
        _fundTreasury(bad);
        uint256 treasuryGem = collateral.balanceOf(address(reserve));
        backedVault.cover(BORROWER, bad);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "the dust was swept");
        assertEq(collateral.balanceOf(address(reserve)), treasuryGem + griefing, "to the surplus account");
        assertEq(backedVault.badDebtOf(BORROWER), 0, "and the bad debt covered in the same call");
    }

    /// @dev Second-half review 2026-10-07, low. A millionth of the debt was still free in capital (about
    /// $0.001 on a $1,000 debt), so the re-lock griefing kept its cadence at the price of gas. The floor
    /// is now at least the seizure for one imdUSD of debt (a hundredth of a smaller debt): what used to be
    /// "real collateral" at twice the millionth is swept, and blocking cover costs real money every cycle.
    function test_coverSweepsAReLockWorthUnderOneImdUSD() public {
        uint256 bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        uint256 debt = backedVault.debtOf(BORROWER);
        uint256 griefing = 2 * _seizureFor(debt / 1_000_000, SIMD_SCALE_PRICE);
        assertLt(griefing, _seizureFor(_dustSlice(debt), SIMD_SCALE_PRICE), "under the new floor");
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, griefing);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), griefing);
        backedVault.lock(griefing);
        vm.stopPrank();
        _fundTreasury(bad);
        uint256 treasuryGem = collateral.balanceOf(address(reserve));
        backedVault.cover(BORROWER, bad);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "swept");
        assertEq(collateral.balanceOf(address(reserve)), treasuryGem + griefing, "to the surplus account");
        assertEq(backedVault.badDebtOf(BORROWER), 0);
    }

    /// @dev Final panel audit (vault, low). One raw unit re-locked onto a drained position moved cover onto
    /// the feed-gated path, so between purchased attestations it reverted StaleFeed. Collateral below the
    /// one-wei seizure at the last price is swept with no fresh feed.
    function test_aOneUnitRelockIsSweptWithoutAFreshFeed() public {
        uint256 bad = _relockDust();
        primary.setStale(true);
        _fundTreasury(bad);
        backedVault.cover(BORROWER, bad);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "swept with a stale feed");
        assertEq(backedVault.badDebtOf(BORROWER), 0);
    }

    /// @dev Final panel audit (vault, low) and sweep panel audit (vault, medium). A re-lock worth more than
    /// the dust floor used to hold cover off until someone paid a mark, six hours of grace and an exactly
    /// sized bite; a sweep of anything worth less than the bad debt (8756817) then took a re-collateralised
    /// borrower's whole collateral for one wei of cover. Now cover refuses it and a drained position is
    /// bitten with no mark and no grace, so the re-lock is seized at once and cover follows.
    function test_aReLockOnADrainedPositionIsBittenAtOnceOrTakenByCoverAtItsValue() public {
        uint256 bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        uint256 half = bad / 2 * 1e18 / SIMD_SCALE_PRICE; // worth half the bad debt: real collateral
        assertGt(half, _seizureFor(_dustSlice(backedVault.debtOf(BORROWER)), SIMD_SCALE_PRICE), "far above the dust floor");
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, half);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), half);
        backedVault.lock(half);
        vm.stopPrank();
        _fundTreasury(bad);
        // Never swept for less than it is worth: cover must burn the re-lock's value to take it (below).
        vm.expectRevert(CDPVault.CoverBelowCollateralValue.selector);
        backedVault.cover(BORROWER, 1);
        // The drain's own mark is still inside its window, so a keeper may bite the re-lock and is paid like any
        // liquidator. Once that mark lapses a re-lock needs a new mark and grace (the test below).
        uint256 keeperGem = collateral.balanceOf(KEEPER);
        uint256 repay = half * SIMD_SCALE_PRICE / 1.2e18; // the debt the seizure of `half` repays
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, repay);
        assertGt(collateral.balanceOf(KEEPER), keeperGem, "the liquidator took the re-lock");
        (uint256 held,) = backedVault.positions(BORROWER);
        assertLt(held, _seizureFor(1, SIMD_SCALE_PRICE), "nothing a bite could reach is left");
        backedVault.cover(BORROWER, backedVault.badDebtOf(BORROWER));
        assertEq(backedVault.badDebtOf(BORROWER), 0);
    }

    /// @dev Retry panel audit 2026-10-07, vault, low. A drained borrower held cover off with a $1.20
    /// re-lock, and the only bite that cleared it paid the liquidator $0.18 before gas. Cover now takes a
    /// re-lock worth less than the realized bad debt at its value: the surplus burns at least that much of
    /// the position's debt, so holding cover off costs the whole re-lock and needs no liquidator.
    function test_coverTakesAReLockWorthLessThanTheBadDebtAtItsValue() public {
        uint256 bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        uint256 relock = bad / 4 * 1e18 / SIMD_SCALE_PRICE;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, relock);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), relock);
        backedVault.lock(relock);
        vm.stopPrank();
        _fundTreasury(bad);
        uint256 value = Math.mulDiv(relock, SIMD_SCALE_PRICE, 1e18, Math.Rounding.Ceil);
        vm.expectRevert(CDPVault.CoverBelowCollateralValue.selector);
        backedVault.cover(BORROWER, value - 1);
        address treasury = address(backedVault.treasury());
        uint256 treasuryGem = collateral.balanceOf(treasury);
        uint256 debtBefore = backedVault.debtOf(BORROWER);
        backedVault.cover(BORROWER, value);
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "the re-lock is taken");
        assertEq(collateral.balanceOf(treasury), treasuryGem + relock, "by the surplus account that paid for it");
        assertEq(backedVault.debtOf(BORROWER), debtBefore - value, "and the debt falls by its full value");
        backedVault.cover(BORROWER, backedVault.debtOf(BORROWER));
        assertEq(backedVault.badDebtOf(BORROWER), 0);
    }

    /// @dev Retry panel audit 2026-10-07, vault, low. A once-drained borrower who rebuilt past its recorded
    /// loss was bitten with no mark and no grace on any later dip below mat. Only a re-lock worth less than
    /// the realized bad debt skips them now; a rebuilt position is marked and given grace like any other.
    function test_aDrainedBorrowerWhoRebuiltPastItsLossIsMarkedAndGivenGrace() public {
        uint256 bad = _drain();
        _setVaultPrice(SIMD_SCALE_PRICE);
        // Collateral worth twice the debt: 200%, and far past the recorded loss.
        uint256 rebuilt = backedVault.debtOf(BORROWER) * 2 * 1e18 / SIMD_SCALE_PRICE;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, rebuilt);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), rebuilt);
        backedVault.lock(rebuilt);
        vm.stopPrank();
        assertEq(backedVault.totalBadDebt(), bad, "the record stands until repaid");
        // A 20% fall: 160%, below mat, but the collateral is still worth more than the recorded loss.
        _setVaultPrice(SIMD_SCALE_PRICE * 8 / 10);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.PositionNotMarked.selector);
        backedVault.bite(BORROWER, 1 ether);
        backedVault.bark(BORROWER);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.GracePeriodNotElapsed.selector);
        backedVault.bite(BORROWER, 1 ether);
    }

    /// @dev Retry2 panel audit 2026-10-08, vault, low. The no-mark bite of a re-lock worth less than the recorded
    /// loss also caught a borrower rebuilding in tranches, at the 20% penalty with no grace. The shortcut is
    /// gone: once the drain's mark has lapsed, a re-lock is marked and given grace like any position, and the
    /// griefing it was there for is answered by cover, which takes such a re-lock at its value.
    function test_aReLockAfterTheDrainsMarkLapsedNeedsANewMarkAndGrace() public {
        uint256 bad = _drain();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refreshEthUsd();
        _setVaultPrice(SIMD_SCALE_PRICE);
        uint256 relock = bad / 4 * 1e18 / SIMD_SCALE_PRICE;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, relock);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), relock);
        backedVault.lock(relock);
        vm.stopPrank();
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.MarkExpired.selector);
        backedVault.bite(BORROWER, 1 ether);
        _fundTreasury(bad);
        backedVault.cover(BORROWER, Math.mulDiv(relock, SIMD_SCALE_PRICE, 1e18, Math.Rounding.Ceil));
        (uint256 held,) = backedVault.positions(BORROWER);
        assertEq(held, 0, "cover took the re-lock at its value instead");
    }

    // --- bookkeeping (launch audit, governance panel, low) ----------------------------------------

    /// @dev cover burned Treasury imdUSD outside its receipt accounting, so imdUSD that arrived since the
    /// last sync vanished from totalReceived. It now syncs the Treasury first.
    function test_coverKeepsTheTreasurysReceiptsWhole() public {
        uint256 bad = _drain();
        uint256 extra = 7 ether;
        IERC20Like stableToken = IERC20Like(address(stable));
        uint256 receivedBefore = reserve.totalReceived(stableToken);
        _fundTreasury(bad + extra); // arrives, never synced
        // Everything that arrived since the last sync: this funding plus fees reminted earlier.
        uint256 unsynced = stable.balanceOf(address(reserve)) - reserve.lastSynced(stableToken);
        assertGe(unsynced, bad + extra);
        uint256 remintedBefore = backedVault.totalFeesMinted();
        backedVault.cover(BORROWER, bad);
        uint256 reminted = backedVault.totalFeesMinted() - remintedBefore;
        reserve.sync(stableToken);
        assertEq(
            reserve.totalReceived(stableToken),
            receivedBefore + unsynced + reminted,
            "every imdUSD that arrived is on the books, including what cover then burned"
        );
    }

    /// @dev Adversarial review 2026-10-05, finding 5 (low): the test above passes with ZERO fees, which
    /// hid that the fees `cover` remints to the Treasury landed below the pre-burn baseline and were
    /// never credited. With a quarter of fees outstanding they must reach totalReceived too.
    function test_coverCreditsTheFeesItRemintsToTheTreasury() public {
        uint256 bad = _drain();
        vm.warp(vm.getBlockTimestamp() + 90 days);
        _refreshEthUsd();
        uint256 owed = backedVault.debtOf(BORROWER);
        uint256 fees = owed - bad;
        assertGt(fees, 0, "fees accrued on the drained position");
        IERC20Like stableToken = IERC20Like(address(stable));
        _fundTreasury(owed);
        reserve.sync(stableToken);
        uint256 receivedBefore = reserve.totalReceived(stableToken);
        uint256 held = stable.balanceOf(address(reserve));

        backedVault.cover(BORROWER, owed);
        assertEq(backedVault.debtOf(BORROWER), 0);
        assertEq(stable.balanceOf(address(reserve)), held - owed + fees, "the fee part came back to the Treasury");
        reserve.sync(stableToken);
        assertEq(reserve.totalReceived(stableToken), receivedBefore + fees, "and it is booked as revenue");
    }

}

/// @notice The base vault has no surplus account: its fee recipient is a wallet that never agreed to
/// have its imdUSD burned, so `cover` refuses rather than spend it. Uses the Sepolia freeze replay
/// from BadDebtSweep to reach a realized bad debt on a base vault.
contract CoverBaseVaultTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);
    uint256 private constant COLLATERAL = 1531680210045556243504;
    uint256 private constant DEBT = 1800000000000000000;
    uint256 private constant CRASH_PRICE = 1179684498206226;
    uint256 private constant MAX_REPAYABLE = 1505749499999999047;

    function test_theBaseVaultHasNoSurplusToSpend() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        MockIMD imd = new MockIMD();
        TestSwarmFeed priceFeed = new TestSwarmFeed(1e18);
        TestSwarmFeed spotFeed = new TestSwarmFeed(1e18);
        TestSwarmFeed nhiFeed = new TestSwarmFeed(0.6e18);
        CDPVault vault = new BaselineVault(
            address(imd), address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        ImdUSD stable = vault.stablecoin();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, COLLATERAL);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(COLLATERAL);
        vault.draw(DEBT);
        stable.transfer(KEEPER, DEBT);
        vm.stopPrank();
        priceFeed.setValue(CRASH_PRICE);
        spotFeed.setValue(CRASH_PRICE);
        vm.startPrank(KEEPER);
        vault.bark(BORROWER);
        vault.bite(BORROWER, MAX_REPAYABLE);
        vm.stopPrank();
        assertGt(vault.totalBadDebt(), 0, "realized on the base vault too");

        vm.expectRevert(CDPVault.NoSurplus.selector);
        vault.cover(BORROWER, 1);
    }

}
