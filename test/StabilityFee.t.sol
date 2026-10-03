// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ZeroFeeVault, TenPercentFeeVault} from "./helpers/ZeroFeeVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT, STABILITY_FEE_BPS} from "src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

abstract contract StabilityFeeFixture is Test {
    CDPVault internal vault;
    MockIMD internal collateral;
    CompToken internal comp;
    MockWorkOracle internal oracle;
    TestSwarmFeed internal primary;
    TestSwarmFeed internal spot;
    TestSwarmFeed internal nhi;
    address internal constant BORROWER = address(0xA11CE);
    address internal constant SECOND_BORROWER = address(0xB0B);
    address internal constant LIQUIDATOR = address(0x1A1D);
    address internal constant MARKER = address(0xCA11);

    /// @dev Which rate this suite runs at. The fixture funds and approves whatever this returns, so a
    /// suite cannot end up approving one vault and exercising another.
    function _deployVault() internal virtual returns (CDPVault) {
        return new ZeroFeeVault(
            address(collateral), address(0), address(0), address(primary), address(nhi), address(spot)
        );
    }

    function setUp() public virtual {
        vm.warp(1_000_000);
        collateral = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.85 ether);
        vault = _deployVault();
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, 1_000_000 ether);
        collateral.mint(SECOND_BORROWER, 1_000_000 ether);
        oracle.grantRights(SECOND_BORROWER, 1_000 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        collateral.approve(address(vault), type(uint256).max);
        vm.prank(SECOND_BORROWER);
        collateral.approve(address(vault), type(uint256).max);
    }

    function _open(address account, uint256 amount) internal {
        vm.startPrank(account);
        vault.depositCollateral(amount * 3);
        vault.mintCOMP(amount);
        vm.stopPrank();
    }

    function _assertZeroFeeAccounting(uint256 expectedDebt, uint256 expectedWork) internal view {
        assertEq(vault.totalDebt(), expectedDebt, "outstanding principal");
        assertEq(vault.totalWorkMinted(), expectedWork, "work minting is independent of debt");
        assertEq(vault.totalFeesMinted(), 0, "zero annual rate never mints fees");
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0, "no stablecoin fee reaches the recipient");
        assertEq(comp.totalSupply(), expectedDebt + expectedWork, "original supply invariant");
        assertEq(vault.debtOf(BORROWER) + vault.debtOf(SECOND_BORROWER), expectedDebt, "summed position debt");
        assertEq(vault.stabilityFeeOf(BORROWER), 0);
        assertEq(vault.stabilityFeeOf(SECOND_BORROWER), 0);
    }
}

/// @notice Exercises the ZERO-rate configuration through actual vault entry points. The shipped rate is
/// non-zero; NonzeroStabilityFeeTest below covers that, and these cases hold the rate at zero so each one
/// keeps asserting what it is about rather than restating it in terms of accrual.
contract StabilityFeeTest is StabilityFeeFixture {
    function test_zeroRateUntouchedPositionAcrossKnownElapsedTimes() public {
        assertEq(vault.stabilityFeeBps(), 0, "this suite pins the zero-rate configuration");
        uint256 principal = 100 ether + 7;
        _open(BORROWER, principal);
        uint256 initialIndex = vault.debtIndexOf(BORROWER);
        uint256[5] memory elapsed = [uint256(1), 365 days - 1, 365 days, 365 days + 1, 100 * 365 days];
        for (uint256 i; i < elapsed.length; ++i) {
            vm.warp(vault.deployedAt() + elapsed[i]);
            assertEq(vault.debtIndex(), 1 ether, "zero slope at every elapsed time");
            assertEq(vault.debtOf(BORROWER), principal, "untouched debt remains exact");
            (uint256 held, uint256 debt) = vault.positions(BORROWER);
            assertEq(held, principal * 3);
            assertEq(debt, principal, "position and debt views agree");
            assertEq(vault.collateralRatio(BORROWER), 300);
            assertEq(vault.badDebtOf(BORROWER), 0);
            assertEq(vault.debtIndexOf(BORROWER), initialIndex, "views never change the debt checkpoint");
            _assertZeroFeeAccounting(principal, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_zeroRateLateOpeningAndPartialRepayment(uint256 principal, uint256 elapsed, uint256 amount)
        public
    {
        principal = bound(principal, 1, 100_000 ether);
        elapsed = bound(elapsed, 1, 100 * 365 days);
        amount = bound(amount, 1, principal);
        vm.warp(vault.deployedAt() + elapsed);
        _open(BORROWER, principal);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        assertEq(vault.debtOf(BORROWER), principal, "no retroactive or elapsed-time fee at zero rate");
        vm.prank(BORROWER);
        vault.repayCOMP(amount);
        assertEq(vault.debtIndexOf(BORROWER), 1 ether);
        assertEq(vault.debtOf(BORROWER), principal - amount);
        _assertZeroFeeAccounting(principal - amount, 0);
    }

    function test_zeroRateTouchedAndUntouchedDebtPreserveSupplyWithWorkMinting() public {
        _open(BORROWER, 100 ether);
        _open(SECOND_BORROWER, 40 ether);
        vm.prank(SECOND_BORROWER);
        vault.mintFromWork(7 ether);
        _assertZeroFeeAccounting(140 ether, 7 ether);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(BORROWER);
        vault.mintCOMP(10 ether);
        _assertZeroFeeAccounting(150 ether, 7 ether);

        vm.warp(vm.getBlockTimestamp() + 182 days + 123);
        vm.prank(BORROWER);
        vault.repayCOMP(35 ether);
        assertEq(vault.debtOf(SECOND_BORROWER), 40 ether, "inactive borrower remains accounted for");
        _assertZeroFeeAccounting(115 ether, 7 ether);

        vm.warp(vm.getBlockTimestamp() + 3 * 365 days);
        vm.prank(BORROWER);
        vault.repayCOMP(75 ether);
        vm.prank(SECOND_BORROWER);
        vault.repayCOMP(40 ether);
        _assertZeroFeeAccounting(0, 7 ether);
        assertEq(comp.balanceOf(SECOND_BORROWER), 7 ether, "debt retirement preserves work-backed supply");
    }

    function test_zeroRateRepaymentFailuresRollBackDebtAndFeeAccounting() public {
        _open(BORROWER, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 checkpoint = vault.debtIndexOf(BORROWER);
        vm.startPrank(BORROWER);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.repayCOMP(0);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(100 ether + 1);
        comp.transfer(SECOND_BORROWER, 1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", BORROWER, 100 ether - 1, 100 ether
            )
        );
        vault.repayCOMP(100 ether);
        vm.stopPrank();
        assertEq(vault.debtIndexOf(BORROWER), checkpoint, "a failed burn cannot commit accrual");
        assertEq(vault.debtOf(BORROWER), 100 ether);
        assertEq(comp.balanceOf(BORROWER), 100 ether - 1);
        assertEq(comp.balanceOf(SECOND_BORROWER), 1);
        _assertZeroFeeAccounting(100 ether, 0);
    }

    function test_zeroRateLiquidationAfterLongIdlePeriodMintsNoFee() public {
        _open(BORROWER, 100 ether);
        vm.prank(BORROWER);
        comp.transfer(LIQUIDATOR, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 * 365 days);
        primary.setValue(0.5 ether);
        spot.setValue(0.5 ether);
        nhi.setValue(0.6 ether);
        vm.prank(MARKER);
        vault.markUnderwater(BORROWER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 10 ether);
        assertEq(comp.balanceOf(LIQUIDATOR), 0, "liquidation burns the full repayment");
        assertEq(comp.balanceOf(MARKER), 0, "marker bonus is collateral, never a stability mint");
        _assertZeroFeeAccounting(90 ether, 0);
    }
}

/// @notice Exact linear-accrual arithmetic at a fixed 10% rate.
/// @dev This used to be reachable only through check_stability_fee.py, which copied the source and
/// rewrote the constant outside the build, because the rate was a nonvirtual constant. It is virtual
/// now, so a subclass reaches it inside the build and that script is no longer needed.
contract NonzeroStabilityFeeTest is StabilityFeeFixture {
    uint256 internal rate;

    function setUp() public override {
        super.setUp();
        rate = vault.stabilityFeeBps();
        assertEq(rate, 1_000, "these cases state their arithmetic longhand at a 10% rate");
    }

    function _deployVault() internal override returns (CDPVault) {
        return new TenPercentFeeVault(
            address(collateral), address(0), address(0), address(primary), address(nhi), address(spot)
        );
    }

    function test_nonzeroUntouchedDebtAccruesLinearlyAcrossYears() public {
        _open(BORROWER, 100 ether);
        uint256 started = vm.getBlockTimestamp();
        uint256 checkpoint = vault.debtIndexOf(BORROWER);
        for (uint256 yearsElapsed = 1; yearsElapsed <= 3; ++yearsElapsed) {
            vm.warp(started + yearsElapsed * 365 days);
            uint256 expectedFee = yearsElapsed * 10 ether;
            assertEq(vault.debtIndex(), 1 ether + yearsElapsed * 0.1 ether);
            assertEq(vault.debtOf(BORROWER), 100 ether + expectedFee, "idle debt must accrue without a transaction");
            assertEq(vault.stabilityFeeOf(BORROWER), expectedFee, "linear rate never compounds unpaid fees");
            (uint256 held, uint256 debt) = vault.positions(BORROWER);
            assertEq(held, 300 ether);
            assertEq(debt, 100 ether + expectedFee);
            assertEq(vault.collateralRatio(BORROWER), 30_000 ether / debt);
            assertEq(vault.debtIndexOf(BORROWER), checkpoint, "reading debt cannot advance its checkpoint");
            assertEq(vault.totalDebt(), 100 ether, "accrual leaves minted principal unchanged");
            assertEq(comp.totalSupply(), 100 ether, "unpaid fees are not minted");
            assertEq(vault.totalFeesMinted(), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nonzeroElapsedSecondsHaveExactLinearIndex(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 5 * 365 days);
        _open(BORROWER, 1 ether);
        vm.warp(vault.deployedAt() + elapsed);
        // One token of principal makes the fee equal to the index delta, with one floor operation.
        uint256 expectedFee = elapsed * 1 ether / (10 * 365 days);
        assertEq(vault.debtIndex(), 1 ether + expectedFee);
        assertEq(vault.debtOf(BORROWER), 1 ether + expectedFee);
        assertEq(vault.stabilityFeeOf(BORROWER), expectedFee);
        assertEq(comp.totalSupply(), 1 ether);
        assertEq(vault.totalFeesMinted(), 0);
    }

    function test_nonzeroDebtOpenedLaterDoesNotPayForTimeBeforeBorrowing() public {
        vm.warp(vault.deployedAt() + 2 * 365 days);
        _open(BORROWER, 100 ether);
        assertEq(vault.debtIndexOf(BORROWER), 1.2 ether);
        assertEq(vault.stabilityFeeOf(BORROWER), 0);
        vm.warp(vault.deployedAt() + 3 * 365 days);
        assertEq(vault.debtOf(BORROWER), 110 ether);
        vm.prank(BORROWER);
        vault.depositCollateral(1 ether);
        assertEq(vault.debtIndexOf(BORROWER), 1.2 ether, "collateral changes do not capitalize fees");
        vm.warp(vault.deployedAt() + 4 * 365 days);
        assertEq(vault.debtOf(BORROWER), 120 ether);
    }

    function test_nonzeroDebtChangesUseNewPrincipalWithoutCompoundingFees() public {
        _open(BORROWER, 100 ether);
        vm.warp(vault.deployedAt() + 365 days / 2);
        vm.prank(BORROWER);
        vault.mintCOMP(50 ether);
        assertEq(vault.debtIndexOf(BORROWER), 1.05 ether);
        assertEq(vault.debtOf(BORROWER), 155 ether);
        assertEq(vault.stabilityFeeOf(BORROWER), 5 ether);

        vm.warp(vault.deployedAt() + 3 * 365 days / 2);
        assertEq(vault.debtOf(BORROWER), 170 ether, "100 for half a year, then 150 for one year");
        vm.prank(BORROWER);
        vault.repayCOMP(7 ether);
        assertEq(vault.totalDebt(), 150 ether, "fees are paid before principal");
        assertEq(vault.stabilityFeeOf(BORROWER), 13 ether);
        assertEq(vault.totalFeesMinted(), 7 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 7 ether);
        assertEq(comp.totalSupply(), 150 ether, "fee payment burns then remints the same amount");

        vm.warp(vault.deployedAt() + 2 * 365 days);
        assertEq(vault.debtOf(BORROWER), 170.5 ether, "unpaid fees do not earn interest");
        vm.prank(BORROWER);
        vault.repayCOMP(30.5 ether);
        assertEq(vault.totalDebt(), 140 ether, "20.5 fees and 10 principal were repaid");
        assertEq(vault.stabilityFeeOf(BORROWER), 0);
        assertEq(vault.totalFeesMinted(), 27.5 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 27.5 ether);
        assertEq(comp.totalSupply(), 140 ether);
        vm.warp(vault.deployedAt() + 3 * 365 days);
        assertEq(vault.debtOf(BORROWER), 154 ether, "principal reduction changes the next linear accrual");
    }

    function test_nonzeroAccruedDebtControlsMintWithdrawalMarkAndLiquidation() public {
        nhi.setValue(0.6 ether);
        vm.startPrank(BORROWER);
        vault.depositCollateral(200 ether);
        vault.mintCOMP(100 ether);
        comp.transfer(LIQUIDATOR, 10 ether);
        vm.stopPrank();
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.markUnderwater(BORROWER);
        vm.warp(vault.deployedAt() + 365 days);
        assertEq(vault.debtOf(BORROWER), 110 ether);
        vm.startPrank(BORROWER);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(1);
        vm.stopPrank();
        vm.prank(MARKER);
        vault.markUnderwater(BORROWER);
        vm.prank(LIQUIDATOR);
        vault.liquidate(BORROWER, 10 ether);
        (uint256 held, uint256 debt) = vault.positions(BORROWER);
        assertEq(held, 189 ether);
        assertEq(debt, 100 ether);
        assertEq(vault.totalDebt(), 100 ether, "liquidation also pays accrued fees first");
        assertEq(vault.stabilityFeeOf(BORROWER), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);
        assertEq(vault.totalFeesMinted(), 10 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_nonzeroFailedBurnRollsBackAccrualThenFullRepaymentMintsOnlyFees() public {
        _open(BORROWER, 100 ether);
        vm.warp(vault.deployedAt() + 365 days);
        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", BORROWER, 100 ether, 110 ether)
        );
        vault.repayCOMP(110 ether);
        assertEq(vault.debtIndexOf(BORROWER), 1 ether, "failed repayment restores the old checkpoint");
        assertEq(vault.debtOf(BORROWER), 110 ether, "failed repayment cannot erase fee debt");
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(vault.totalFeesMinted(), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0);

        vm.startPrank(SECOND_BORROWER);
        vault.mintFromWork(10 ether);
        comp.transfer(BORROWER, 10 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        vault.repayCOMP(110 ether);
        assertEq(vault.debtOf(BORROWER), 0);
        assertEq(vault.stabilityFeeOf(BORROWER), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalFeesMinted(), 10 ether);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 10 ether);
        assertEq(comp.totalSupply(), 10 ether, "all principal retired; independently minted work supply survives");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(vault.debtOf(BORROWER), 0, "closed positions cannot accrue new fees");
    }
}

/// @notice Whatever rate the deployment actually ships, accruing through the real vault.
/// @dev The suites above pin zero and ten percent because their arithmetic is written out longhand.
/// This one derives its expectations from the shipped constant, so the configuration that will
/// actually be deployed is covered whatever it is set to, and a change to it cannot pass unnoticed.
contract ShippedRateStabilityFeeTest is StabilityFeeFixture {
    uint256 internal rate;

    function setUp() public override {
        super.setUp();
        rate = vault.stabilityFeeBps();
        assertEq(rate, STABILITY_FEE_BPS, "the deployed vault must carry the shipped rate");
    }

    function _deployVault() internal override returns (CDPVault) {
        return new CDPVault(
            address(collateral), address(0), address(0), address(primary), address(nhi), address(spot)
        );
    }

    function test_shippedRateAccruesLinearlyAndMintsNothingUntilRepayment() public {
        if (rate == 0) return; // a deployment may ship inert; the zero suite covers that case
        uint256 principal = 100 ether;
        _open(BORROWER, principal);
        uint256 started = vm.getBlockTimestamp();
        vm.warp(started + 365 days);

        uint256 expectedFee = principal * rate / 10_000;
        assertEq(vault.stabilityFeeOf(BORROWER), expectedFee, "one year accrues exactly the annual rate");
        assertEq(vault.debtOf(BORROWER), principal + expectedFee);
        assertEq(vault.totalDebt(), principal, "accrual leaves minted principal alone");
        assertEq(comp.totalSupply(), principal, "an unpaid fee is not minted");
        assertEq(vault.totalFeesMinted(), 0);

        vm.warp(started + 2 * 365 days);
        assertEq(vault.stabilityFeeOf(BORROWER), 2 * expectedFee, "linear, never compounding");
    }

    function test_shippedRateIsASaneAnnualRate() public view {
        assertLt(rate, 10_000, "an annual rate at or above 100% is a misconfiguration");
    }
}
