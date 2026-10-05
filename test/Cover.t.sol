// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

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
