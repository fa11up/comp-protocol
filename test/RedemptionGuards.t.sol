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
        vault.lock(amount);
    }

    function mint(uint256 amount) external {
        vault.draw(amount);
    }

    function depositAndRedeem(uint256 depositAmount, uint256 burn, address candidate) external returns (uint256) {
        vault.lock(depositAmount);
        return vault.redeem(burn, 0, candidate);
    }

    function depositAndMint(uint256 depositAmount, uint256 mint) external {
        vault.lock(depositAmount);
        vault.draw(mint);
    }

    function depositMintAndRedeem(uint256 depositAmount, uint256 mint, uint256 burn, address candidate)
        external
        returns (uint256)
    {
        vault.lock(depositAmount);
        vault.draw(mint);
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
        _giveStable(0.39 ether);
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
        _giveStable(amount);
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

    /// @dev Collateral above mat times the debt behind it is withdrawable with no feed read and
    /// backs no COMP. Counting it would let a position's surplus bless a payout to work-issued
    /// supply that nothing stands behind.
    function test_surplusCollateralAboveMinCRDoesNotBackWorkMintedComp() public {
        _open(BORROWER, 1000 ether, 100 ether);
        _mintWork(WORKER, 25 ether);
        vm.startPrank(BORROWER);
        backedVault.wipe(90 ether);
        backedVault.free(850 ether);
        vm.stopPrank();
        _reserveIMD(10 ether);
        // Whole balance: 160 of backing for 35 of supply. Secured: 10 + min(150, 150% x 10) = 25.
        assertEq(collateral.balanceOf(address(backedVault)), 150 ether);
        assertEq(stable.totalSupply(), 35 ether);
        assertEq(backedVault.collateralRatio(BORROWER), 1500);
        // WAS a RedemptionWorsensBacking halt. The surplus is excluded from the figure the payout is
        // capped at instead, which is the same defence stated as a number rather than a refusal:
        // the 160 of balance would put a COMP at par, the 25 actually secured puts it at 25/35.
        assertEq(
            backedVault.backingPerUnit(),
            Math.mulDiv(25 ether, 1e18, 35 ether),
            "the secured figure, not the whole balance"
        );
        uint256 out = _quote(10 ether);
        assertLt(out, _parQuote(10 ether), "so the burn is paid below par minus the fee");
        assertEq(out, Math.mulDiv(10 ether, Math.mulDiv(Math.mulDiv(25 ether, 1e18, 35 ether), 9500, 10_000), 1e18));
        uint256 backingBefore1 = _econBacking();
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);
        assertGt(_econBacking(), backingBefore1, "and the fee leaves backing strictly better");
        // Once principal stands behind the collateral again a COMP is fully backed and the same burn
        // is paid par minus the fee: the cap stops binding, rather than a closed channel reopening.
        vm.prank(BORROWER);
        backedVault.draw(90 ether);
        assertEq(backedVault.backingPerUnit(), 1e18, "principal behind the collateral restores par");
        out = _quote(10 ether);
        assertEq(out, _parQuote(10 ether), "an unbound cap pays exactly par minus the fee");
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, BORROWER), out);
    }

    /// @dev The cap is mat percent of principal, so it rises with stress: a surplus that is
    /// withdrawable at NHI .85 is held in place at NHI .60, and then it backs COMP.
    function test_stressedMinCRRaisesWhatSecuredCollateralMayCount() public {
        _open(BORROWER, 200 ether, 100 ether);
        _open(SECOND_BORROWER, 150 ether, 100 ether);
        _reserveIMD(100 ether);
        _mintWork(WORKER, 120 ether); // ceiling: 100 reserve + a quarter of 200 debt
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(collateral, APPROVED_OPERATOR, 100 ether);
        assertEq(stable.totalSupply(), 320 ether);
        assertEq(collateral.balanceOf(address(backedVault)), 350 ether);
        // 350 is held against 320 of supply, so the balance alone would put a COMP at par. What may
        // COUNT is bounded by mat times the principal behind it, and at mat 150 that bound bites
        // at 300 — so a COMP is backed at 300/320 and the payout is capped there, not at par.
        assertEq(backedVault.mat(), 150);
        assertEq(
            backedVault.backingPerUnit(), Math.mulDiv(300 ether, 1e18, 320 ether), "mat 150 bounds it to 300"
        );
        uint256 out = _quote(10 ether);
        assertLt(out, _parQuote(10 ether), "below par minus the fee, by exactly the shortfall in backing");

        // Stressing NHI raises mat, so the SAME collateral may count for more: at mat 200 the
        // bound is 400, the whole 350 counts, and a COMP is backed to par. That is this test's
        // subject, and it now reads as a figure instead of as which burns happen to revert.
        health.setValue(0.6 ether);
        assertEq(backedVault.mat(), 200);
        assertEq(backedVault.backingPerUnit(), 1e18, "at mat 200 the whole balance counts");
        assertEq(_quote(10 ether), _parQuote(10 ether), "and the cap no longer binds");

        // Back at the base mat the capped burn goes through and cannot worsen economic backing.
        health.setValue(0.85 ether);
        assertEq(backedVault.mat(), 150);
        uint256 backingBefore2 = _econBacking();
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, SECOND_BORROWER), out);
        assertGt(_econBacking(), backingBefore2, "a redemption must not worsen backing");

        // And the stressed reading reaches par again from the state the redemption left, so the
        // next burn of the same size is paid par minus the fee rather than the capped amount.
        health.setValue(0.6 ether);
        assertEq(backedVault.mat(), 200);
        assertEq(backedVault.backingPerUnit(), 1e18);
        uint256 atPar = _quote(10 ether);
        assertEq(atPar, _parQuote(10 ether));
        assertGt(atPar, out, "the same burn is paid more once the bound stops biting");
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, atPar, SECOND_BORROWER), atPar);
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
        backedVault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _refreshEthUsd();
        uint256 repayable = uint256(150 ether) * 0.5 ether / 1.1 ether;
        vm.prank(SECOND_BORROWER);
        backedVault.bite(BORROWER, repayable);
        (uint256 c,) = backedVault.positions(BORROWER);
        assertEq(c, 0);
        uint256 bad = backedVault.totalBadDebt();
        assertGt(bad, 31 ether);
        _setVaultPrice(1 ether);

        uint256 held = collateral.balanceOf(address(backedVault));
        uint256 supply = stable.totalSupply();
        assertEq(backedVault.mat(), 150);
        uint256 secured = backedVault.securedCollateral(); // price is back to 1, so value == amount
        uint256 withResidual = Math.min(secured, Math.mulDiv(backedVault.totalDebt(), 150, 100));
        uint256 withoutResidual = Math.min(secured, Math.mulDiv(backedVault.totalDebt() - bad, 150, 100));
        assertLt(withoutResidual, withResidual, "the realized loss shrinks the secured principal");
        // WAS a RedemptionWorsensBacking halt. The loss is removed from the principal the backing
        // figure is bounded by instead, so it CAPS the payout rather than refusing the burn — and
        // the subtraction is now readable as a figure instead of inferred from which burns revert.
        uint256 reserveTerm = _reserveBacking(1e18); // the liquidation's protocol cut, not zero
        assertEq(
            backedVault.backingPerUnit(),
            Math.mulDiv(reserveTerm + withoutResidual, 1e18, supply),
            "backing is bounded by the loss-adjusted principal"
        );
        uint256 out = _quote(10 ether);
        assertLt(out, _parQuote(10 ether), "so the burn is paid below par minus the fee");
        assertLt(
            out,
            Math.mulDiv(10 ether, Math.min(1e18, Math.mulDiv(reserveTerm + withResidual, 1e18, supply)), 1e18),
            "counting the residual would have paid more"
        );
        uint256 backingBefore3 = _econBacking();
        vm.prank(WORKER);
        assertEq(backedVault.redeem(10 ether, out, SECOND_BORROWER), out);
        assertGt(_econBacking(), backingBefore3, "a redemption must not worsen backing");
        // The reserve pays first and the candidate covers the rest, so what left in total is `out`.
        assertEq(
            collateral.balanceOf(address(backedVault)) + collateral.balanceOf(address(reserve)),
            held + reserveTerm - out,
            "the reserve paid first, the candidate covered the rest"
        );
        assertEq(stable.totalSupply(), supply - 10 ether);
    }

    // --- one transaction -------------------------------------------------------------------------

    function test_debtFreeDepositInTheSameTransactionDoesNotCountAsBacking() public {
        _open(BORROWER, 150 ether, 100 ether);
        _mintWork(WORKER, 25 ether); // the ceiling exactly: no reserve, a quarter of 100 of debt
        vm.prank(WORKER);
        stable.transfer(address(actor), 25 ether);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(actor), 400 ether);
        _setVaultPrice(0.8 ether);
        // 150 IMD at 0.8 is 120 of value, under the 150 that 100 of principal would allow, for 125
        // of supply. WAS a RedemptionWorsensBacking halt; the payout is capped at 120/125 instead,
        // so what a deposit does to backing is now a figure rather than a question of which burns
        // revert. The whole point of this test is that the answer is "nothing".
        uint256 capped = Math.mulDiv(120 ether, 1e18, 125 ether);
        assertEq(backedVault.backingPerUnit(), capped, "120 of value against 125 of supply");

        // A debt-free deposit in the SAME call buys the depositor nothing: the figure the payout is
        // capped at is the one the call found, so 100 extra IMD does not raise what it is paid.
        uint256 econBefore = _econBacking();
        uint256 withDeposit = actor.depositAndRedeem(100 ether, 10 ether, BORROWER);
        assertGt(_econBacking(), econBefore, "an in-call deposit cannot worsen backing either");
        assertEq(
            withDeposit,
            Math.mulDiv(10 ether, Math.mulDiv(capped, 10_000 - 250, 10_000), 0.8 ether),
            "paid against the backing the call found, not the backing it brought"
        );

        // Source revision for finding 7cd5035c: the secured term is counted per position and bounded
        // by that position's own principal, so a debt-free deposit counts for nothing ACROSS a
        // transaction boundary too. It used to fill the gap the aggregate cap left open when the
        // indebted position held less than mat (as here, at 120%), for the cost of gas.
        // The burn above took its payout out of the candidate, so the secured term is no longer the
        // 150 it started at. What matters is that the deposit does not move it.
        uint256 securedAfterBurn = backedVault.securedCollateral();
        assertEq(securedAfterBurn, 150 ether - withDeposit, "only the payout left the secured term");
        uint256 beforeDeposit = backedVault.backingPerUnit();
        actor.deposit(100 ether);
        assertEq(backedVault.securedCollateral(), securedAfterBurn, "no principal, no secured term");
        assertEq(backedVault.backingPerUnit(), beforeDeposit, "200 idle IMD in the vault changes nothing");

        // The slow version with debt against the collateral is the accepted design, and it is the
        // only thing that moves the cap: 50 of principal at 0.8 secures 125 of the actor's 200, and
        // it costs real capital exposed in an open position rather than one transaction of gas.
        actor.mint(50 ether);
        assertEq(
            backedVault.securedCollateral(), securedAfterBurn + 125 ether, "bounded by twice its own principal"
        );
        assertGt(backedVault.backingPerUnit(), beforeDeposit, "principal behind collateral is what counts");
        uint256 out = _quote(10 ether);
        assertGt(out, withDeposit, "so the same burn is now paid more");
        assertEq(actor.redeem(10 ether, BORROWER), out);
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
        backedVault.wipe(100 ether);
        backedVault.free(1000 ether);
        vm.stopPrank();
        _reserveIMD(5 ether);
        vm.prank(APPROVED_OPERATOR);
        // Twice what the old version minted: the in-call redemption used to revert and give the
        // collateral back, and now it goes through, so the second deposit needs its own.
        collateral.mint(address(actor), 3600 ether);
        // 5 IMD of reserve stands behind 25 of work-issued supply and nothing else does.
        uint256 capped = Math.mulDiv(5 ether, 1e18, 25 ether);
        assertEq(backedVault.backingPerUnit(), capped, "a fifth of par, and that is the honest figure");
        // An eligible position opened in the same call: its collateral and principal both count for
        // nothing, so the burn is priced against the backing that existed before the call. It is no
        // longer refused — the payout is capped at a fifth of par instead, which is the same
        // defence without the halt, and the attacker's 1800 IMD buys them nothing.
        uint256 backingBeforeOpen = _econBacking();
        uint256 inCall = actor.depositMintAndRedeem(1800 ether, 1000 ether, 10 ether, address(actor));
        assertGt(_econBacking(), backingBeforeOpen, "an in-call position cannot worsen backing");
        assertLt(inCall, 10 ether / 4, "capped near a fifth of par, not paid at par");
        // The same position held across a transaction is the accepted slow path: its principal
        // then stands behind 150% of its collateral, and its surplus is exposed in the meantime.
        actor.depositAndMint(1800 ether, 1000 ether);
        assertEq(backedVault.backingPerUnit(), 1e18, "capital held across a transaction does count");
        uint256 out = _quote(10 ether);
        assertEq(out, _parQuote(10 ether), "so the burn is paid par minus the fee");
        assertGt(out, inCall * 4, "four times what the same burn got inside one transaction");
        assertEq(actor.redeem(10 ether, address(actor)), out);
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
        backedVault.lock(c);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    function _giveStable(uint256 amount) private {
        vm.prank(BORROWER);
        stable.transfer(REDEEMER, amount);
    }

    function _reserveIMD(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), amount);
    }

    /// @dev Mirrors the vault: par minus the fee, then capped at what actually backs a COMP.
    function _quote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        uint256 scale = Math.mulDiv(backedVault.backingPerUnit(), 10_000 - backedVault.redemptionFeeBps(amount), 10_000);
        return Math.mulDiv(amount, scale, price);
    }

    /// @notice Collateral plus reserve, per COMP, in the vault's unit — the ECONOMIC backing figure.
    /// @dev Distinct from `backingPerUnit()` on purpose, and the difference is the point. That one is
    /// deliberately conservative: it counts only collateral with mat times its value in principal
    /// behind it, so cancelling a borrower's debt DISQUALIFIES mat worth of collateral while
    /// retiring only one COMP of supply, and the measure falls. Measured: four successive 10 COMP
    /// redemptions walk it 0.9375 -> 0.9194 -> 0.9000 -> 0.8793 -> 0.8571 while the economic figure
    /// below rises 1.0938 -> 1.1219 every step. The conservative measure is not monotone and must
    /// not be asserted as if it were; THIS figure is the one the pro-rata payout makes monotone, and
    /// it is computed here from balances rather than from the vault, so it can disagree with it.
    function _econBacking() private view returns (uint256) {
        uint256 supply = stable.totalSupply();
        if (supply == 0) return type(uint256).max;
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        uint256 backing = _reserveBacking(price) + Math.mulDiv(collateral.balanceOf(address(backedVault)), price, 1e18);
        return Math.mulDiv(backing, 1e18, supply);
    }

    /// @dev The reserve's contribution, composed exactly as ParameterizedVault composes it: IMD at
    /// this vault's own price whether or not governance listed it, every other asset at its
    /// registered value. Liquidations pay a protocol cut into the Treasury, so this is rarely zero
    /// even in a test that drained it.
    function _reserveBacking(uint256 price) private view returns (uint256) {
        uint256 others = backedVault.reserveValue() - reserve.reserveValueOf(IERC20(address(collateral)));
        return others + Math.mulDiv(backedVault.redemptionReserve(), price, 1e18);
    }

    /// @dev What the payout would be with no backing cap: par minus the fee.
    function _parQuote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        return Math.mulDiv(amount, (10_000 - backedVault.redemptionFeeBps(amount)) * 1e14, price);
    }
}
