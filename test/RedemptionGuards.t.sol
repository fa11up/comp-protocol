// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @dev Does several vault calls inside ONE transaction. `isolate = true` makes every call a test
/// makes directly its own transaction, which is what the vault's transient tallies are designed
/// around; the only way to put a deposit or a mint in the same transaction as a redemption is to
/// route them through a contract, which is also exactly what an attacker would do.
contract AtomicActor {
    ParameterizedVault private immutable vault;
    IERC20 private immutable imd;

    constructor(ParameterizedVault vault_, IERC20 imd_) {
        vault = vault_;
        imd = imd_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        vault.depositCollateral(amount);
    }

    function depositAndRedeem(uint256 depositAmount, uint256 burn, address candidate) external returns (uint256) {
        vault.depositCollateral(depositAmount);
        return vault.redeem(burn, 0, candidate);
    }

    function depositAndMint(uint256 depositAmount, uint256 mint) external {
        vault.depositCollateral(depositAmount);
        vault.mintCOMP(mint);
    }

    function depositMintAndRedeem(uint256 depositAmount, uint256 mint, uint256 burn, address candidate)
        external
        returns (uint256)
    {
        vault.depositCollateral(depositAmount);
        vault.mintCOMP(mint);
        return vault.redeem(burn, 0, candidate);
    }

    function redeem(uint256 burn, address candidate) external returns (uint256) {
        return vault.redeem(burn, 0, candidate);
    }
}

/// @notice The revised guards: whole-basis-point rounding, what the backing guard may count, and
/// what a single transaction can and cannot do to the figures redemption is measured against.
contract RedemptionGuardsTest is WorkBackingFixture {
    address private constant REDEEMER = address(0xDEED);
    address private constant SECOND_BORROWER = address(0xBEE);
    AtomicActor private actor;

    function setUp() public override {
        super.setUp();
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        actor = new AtomicActor(backedVault, IERC20(address(collateral)));
    }

    // --- fee rounding -------------------------------------------------------------------------

    function test_subBasisPointRemainderIsChargedToTheRedeemerAndKeptInTheBase() public {
        _open(BORROWER, 1800 ether, 1000 ether);
        _reserveIMD(10 ether);
        // 0.39 of a 1000 supply is 0.975 of a basis point: charged as one, stored exactly.
        _giveCOMP(0.39 ether);
        assertEq(backedVault.redemptionFeeBps(0.39 ether), 51);
        vm.prank(REDEEMER);
        assertEq(backedVault.redeem(0.39 ether, 0, address(0)), 0.39 ether * (10_000 - 51) / 10_000);
        assertEq(backedVault.redemptionBaseRate(), 0.0000975 ether, "the fraction survives in the stored base");
        assertEq(backedVault.redemptionFeeBps(0), 51, "a zero quote rounds the decayed fraction up too");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteEventAndPayoutAgreeOnTheRoundedUpFee(uint256 amountSeed) public {
        _open(BORROWER, 1800 ether, 1000 ether);
        _reserveIMD(1000 ether);
        uint256 amount = bound(amountSeed, 10_000, 500 ether);
        _giveCOMP(amount);
        uint256 increase = Math.min(amount * 1e18 / 1000 ether / 4, 0.045 ether);
        uint256 fee = 50 + Math.ceilDiv(increase, 1e14);
        assertEq(backedVault.redemptionFeeBps(amount), fee);
        assertGe(fee * 1e14, 50 * 1e14 + increase, "whole basis points never undercharge");
        assertLt(fee * 1e14, 50 * 1e14 + increase + 1e14, "and never overcharge by a whole one");
        vm.recordLogs();
        vm.prank(REDEEMER);
        uint256 out = backedVault.redeem(amount, 0, address(0));
        assertEq(out, Math.mulDiv(amount, (10_000 - fee) * 1e14, 1e18));
        assertEq(_emittedFee(), fee, "the event reports the fee that was charged");
        assertEq(backedVault.redemptionBaseRate(), increase, "the stored base keeps the exact fraction");
    }

    // --- what the backing guard may count ------------------------------------------------------

    /// @dev Collateral above minCR times the debt behind it is withdrawable with no feed read and
    /// backs no COMP. Counting it would let a position's surplus bless a payout to work-issued
    /// supply that nothing stands behind.
    function test_surplusCollateralAboveMinCRDoesNotBackWorkMintedComp() public {
        _open(BORROWER, 1000 ether, 100 ether);
        _mintWork(WORKER, 25 ether);
        vm.startPrank(BORROWER);
        backedVault.repayCOMP(90 ether);
        backedVault.withdrawCollateral(850 ether);
        vm.stopPrank();
        _reserveIMD(10 ether);
        // Whole balance: 160 of backing for 35 of supply. Secured: 10 + min(150, 150% x 10) = 25.
        assertEq(collateral.balanceOf(address(backedVault)), 150 ether);
        assertEq(stable.totalSupply(), 35 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 1500);
        uint256 out = _quote(10 ether);
        assertLe(out * 35 ether, 160 ether * 10 ether, "the whole balance would allow this burn");
        assertGt(out * 35 ether, 25 ether * 10 ether, "the secured figure refuses it");
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        backedVault.redeem(10 ether, 0, BORROWER);
        // The same burn is accepted once enough principal stands behind the collateral again.
        vm.prank(BORROWER);
        backedVault.mintCOMP(90 ether);
        out = _quote(10 ether);
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);
    }

    /// @dev The cap is minCR percent of principal, so it rises with stress: a surplus that is
    /// withdrawable at NHI .85 is held in place at NHI .60, and then it backs COMP.
    function test_stressedMinCRRaisesWhatSecuredCollateralMayCount() public {
        _open(BORROWER, 200 ether, 100 ether);
        _open(SECOND_BORROWER, 150 ether, 100 ether);
        _reserveIMD(100 ether);
        _mintWork(WORKER, 120 ether); // ceiling: 100 reserve + a quarter of 200 debt
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(collateral, APPROVED_OPERATOR, 100 ether);
        assertEq(stable.totalSupply(), 320 ether);
        uint256 out = _quote(10 ether);
        // 350 held. At minCR 150 only 300 counts, which is short of a 99.2% payout on 320 of supply.
        assertGt(out * 320 ether, 300 ether * 10 ether);
        assertLe(out * 320 ether, 350 ether * 10 ether);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        backedVault.redeem(10 ether, 0, SECOND_BORROWER);
        // At minCR 200 up to 400 counts, so all 350 does. Same burn, same candidate, same price.
        health.setValue(0.6 ether);
        assertEq(backedVault.minCR(), 200);
        assertEq(_quote(10 ether), out);
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, SECOND_BORROWER), out);
    }

    /// @dev After a liquidation drains a position, its residual principal is still in totalDebt
    /// with nothing behind it. Counting 150% of that residual would bless a payout from the
    /// remaining borrower's surplus. Numbers are chosen so that subtraction alone decides.
    function test_realizedBadDebtIsRemovedFromTheSecuredPrincipal() public {
        _open(BORROWER, 150 ether, 100 ether);
        _open(SECOND_BORROWER, 400 ether, 250 ether);
        _reserveIMD(50 ether);
        _mintWork(WORKER, 110 ether); // ceiling: 50 reserve + a quarter of 350 debt
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(collateral, APPROVED_OPERATOR, 50 ether);
        // Drain the first position through a liquidation that exhausts its collateral.
        _setVaultPrice(0.5 ether);
        backedVault.markUnderwater(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _refreshEthUsd();
        uint256 repayable = uint256(150 ether) * 0.5 ether / 1.1 ether;
        vm.prank(SECOND_BORROWER);
        backedVault.liquidate(BORROWER, repayable);
        (uint256 c,) = backedVault.positions(BORROWER);
        assertEq(c, 0);
        uint256 bad = backedVault.totalBadDebt();
        assertGt(bad, 31 ether);
        _setVaultPrice(1 ether);

        uint256 held = collateral.balanceOf(address(backedVault));
        uint256 supply = stable.totalSupply();
        uint256 out = _quote(10 ether);
        uint256 withResidual = Math.min(held, Math.mulDiv(backedVault.totalDebt(), 150, 100));
        uint256 withoutResidual = Math.min(held, Math.mulDiv(backedVault.totalDebt() - bad, 150, 100));
        assertLe(out, Math.mulDiv(withResidual, 10 ether, supply), "counting the residual would allow this burn");
        assertGt(out, Math.mulDiv(withoutResidual, 10 ether, supply), "the realized loss refuses it");
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        backedVault.redeem(10 ether, 0, SECOND_BORROWER);
        assertEq(collateral.balanceOf(address(backedVault)), held);
        assertEq(stable.totalSupply(), supply);
    }

    // --- one transaction -------------------------------------------------------------------------

    function test_debtFreeDepositInTheSameTransactionDoesNotCountAsBacking() public {
        _open(BORROWER, 150 ether, 100 ether);
        _mintWork(WORKER, 25 ether);
        vm.prank(WORKER);
        stable.transfer(address(actor), 25 ether);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(actor), 100 ether);
        _setVaultPrice(0.8 ether);
        // 120 of value, capped at 150, for 125 of supply: short of a 97.5% payout.
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        actor.redeem(10 ether, BORROWER);
        // A debt-free deposit in the same call is not counted, however large.
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        actor.depositAndRedeem(100 ether, 10 ether, BORROWER);
        assertEq(collateral.balanceOf(address(actor)), 100 ether, "the whole call rolled back");
        assertEq(stable.balanceOf(address(actor)), 25 ether);
        // The slow version is the accepted design: collateral left across a transaction counts
        // up to the cap, and costs real capital exposed in the vault for that time.
        actor.deposit(100 ether);
        uint256 out = _quote(10 ether);
        assertEq(actor.redeem(10 ether, BORROWER), out);
        assertEq(collateral.balanceOf(address(actor)), out);
    }

    function test_principalMintedInTheSameTransactionDoesNotDiluteTheFee() public {
        _open(BORROWER, 2000 ether, 1000 ether);
        _reserveIMD(1000 ether);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(actor), 3000 ether);
        // Measured against the instantaneous supply of 2000 this would be a 175-bps burn.
        // Against the 1000 that existed before the call it is 300, which is what it costs.
        uint256 out = actor.depositMintAndRedeem(3000 ether, 1000 ether, 100 ether, address(0));
        assertEq(out, 97 ether);
        assertEq(backedVault.redemptionBaseRate(), 0.025 ether);
        assertEq(backedVault.redemptionFeeBps(0), 300);
        assertEq(stable.balanceOf(address(actor)), 900 ether);
        assertEq(stable.totalSupply(), 1900 ether);
    }

    function test_aBurnWithNoSupplyBeforeTheTransactionSaturatesTheFee() public {
        _reserveIMD(100 ether);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(actor), 300 ether);
        assertEq(stable.totalSupply(), 0);
        uint256 out = actor.depositMintAndRedeem(300 ether, 100 ether, 10 ether, address(0));
        assertEq(out, 9.5 ether, "the first burn of a supply that did not exist pays the cap");
        assertEq(backedVault.redemptionBaseRate(), 0.045 ether);
        assertEq(backedVault.redemptionFeeBps(0), 500);
        assertEq(collateral.balanceOf(address(reserve)), 90.5 ether);
    }

    function test_sameTransactionMintCannotMakeAnUnbackedRedemptionPass() public {
        // Work-issued COMP with nothing behind it after the borrower leaves.
        _open(BORROWER, 1000 ether, 100 ether);
        _mintWork(WORKER, 25 ether);
        vm.startPrank(BORROWER);
        backedVault.repayCOMP(100 ether);
        backedVault.withdrawCollateral(1000 ether);
        vm.stopPrank();
        _reserveIMD(5 ether);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(actor), 1800 ether);
        // An eligible position opened in the same call: its collateral counts for nothing, its
        // principal counts for nothing, and the burn is refused on backing with everything rolled back.
        vm.expectRevert(CDPVault.RedemptionWorsensBacking.selector);
        actor.depositMintAndRedeem(1800 ether, 1000 ether, 10 ether, address(actor));
        assertEq(stable.totalSupply(), 25 ether);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(collateral.balanceOf(address(actor)), 1800 ether);
        // The same position held across a transaction is the accepted slow path: its principal
        // then stands behind 150% of its collateral, and its surplus is exposed in the meantime.
        actor.depositAndMint(1800 ether, 1000 ether);
        uint256 out = _quote(10 ether);
        assertEq(actor.redeem(10 ether, address(actor)), out);
        assertEq(stable.totalSupply(), 1015 ether);
    }

    // --- helpers ---------------------------------------------------------------------------------

    function _emittedFee() private returns (uint256 fee) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Redeemed(address,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(backedVault) || logs[i].topics[0] != topic) continue;
            (,,,, fee) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            return fee;
        }
        revert("Redeemed not emitted");
    }

    function _open(address who, uint256 c, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(who, c);
        vm.startPrank(who);
        collateral.approve(address(backedVault), c);
        backedVault.depositCollateral(c);
        backedVault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _giveCOMP(uint256 amount) private {
        vm.prank(BORROWER);
        stable.transfer(REDEEMER, amount);
    }

    function _reserveIMD(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), amount);
    }

    function _quote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        return Math.mulDiv(amount, (10_000 - backedVault.redemptionFeeBps(amount)) * 1e14, price);
    }
}
