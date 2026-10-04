// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "src/CDPVault.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";

/// @dev Exercises the shipped USD-denominated vault, its Treasury and its nonzero stability fee.
/// IMD stays at $1: changes in backing below measure redemption, not an unrelated oracle loss.
contract RedemptionSequenceHandler is WorkBackingFixture {
    address[4] public actors = [address(0xED01), address(0xED02), address(0xED03), address(0xED04)];
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public collateralRedeemed;
    mapping(address => uint256) public principal;
    uint256 public collateralIssued;
    uint256 public debtIssued;
    uint256 public workIssued;
    uint256 public repaymentBurns;
    uint256 public feesReminted;
    uint256 public redemptionBurns;
    uint256 public nonPrincipalBurns;
    uint256 public reserveFunded;
    uint256 public reserveSpent;
    uint256 public reserveOnlyCalls;
    uint256 public mixedCalls;
    uint256 public positionOnlyCalls;
    uint256 public rejectedCalls;
    uint256 public debtMintCalls;
    uint256 public workMintCalls;

    struct BeforeRedemption {
        uint256 supply;
        uint256 reserveIMD;
        uint256 redeemerIMD;
        uint256 backing;
        uint256 ceiling;
        uint256 base;
        uint256 lastAt;
        uint256[4] collateral;
        uint256[4] debt;
    }

    struct RedemptionAmounts {
        uint256 burned;
        uint256 payout;
        uint256 reserveOut;
        uint256 cancelled;
        uint256 principalCancelled;
    }

    constructor() {
        WorkBackingFixture.setUp();
        _register(collateral, backedVault.usdPriceFeed(), 10_000);
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            vm.prank(APPROVED_OPERATOR);
            workOracle.grantRights(actor, type(uint128).max);
            _deposit(actor, 180 ether);
            vm.prank(actor);
            backedVault.mintCOMP(100 ether);
            principal[actor] = 100 ether;
            debtIssued += 100 ether;
        }
        _fundIMD(20 ether);
        vm.prank(actors[3]);
        backedVault.mintFromWork(10 ether);
        workIssued = 10 ether;

        // Every random sequence starts with actual reserve, mixed, and position redemptions.
        // This also prevents an all-reverting handler from making the invariant vacuous.
        _redeem(0, 1, 5 ether, false);
        _redeem(0, 1, 20 ether, false);
        _redeem(0, 2, 1 ether, false);
    }

    function fundReserve(uint256 rawAmount) external {
        _fundIMD(bound(rawAmount, 1, 100 ether));
    }

    function deposit(uint256 seed, uint256 rawAmount) external {
        _deposit(actors[seed % 4], bound(rawAmount, 1, 100 ether));
    }

    function borrow(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % 4];
        (uint256 amountCollateral, uint256 debt) = backedVault.positions(actor);
        uint256 maximumDebt = Math.mulDiv(amountCollateral, 100, backedVault.minCR());
        if (maximumDebt <= debt) return;
        uint256 amount = bound(rawAmount, 1, Math.min(maximumDebt - debt, 100 ether));
        vm.prank(actor);
        backedVault.mintCOMP(amount);
        debtIssued += amount;
        principal[actor] += amount;
        ++debtMintCalls;
    }

    function mintWork(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % 4];
        uint256 ceiling = backedVault.workCeiling();
        if (ceiling <= workIssued) return;
        uint256 amount = bound(rawAmount, 1, Math.min(ceiling - workIssued, 100 ether));
        uint256 rights = workOracle.mintingRights(actor);
        vm.prank(actor);
        backedVault.mintFromWork(amount);
        workIssued += amount;
        assertEq(workOracle.mintingRights(actor), rights - amount, "work consumes rights exactly once");
        assertLe(workIssued, ceiling, "only backed work may be newly minted");
        ++workMintCalls;
    }

    function repay(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % 4];
        uint256 available = Math.min(stable.balanceOf(actor), backedVault.debtOf(actor));
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        uint256 fee = Math.min(amount, backedVault.stabilityFeeOf(actor));
        vm.prank(actor);
        backedVault.repayCOMP(amount);
        principal[actor] -= amount - fee;
        repaymentBurns += amount;
        feesReminted += fee;
    }

    function withdraw(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % 4];
        (uint256 amountCollateral, uint256 debt) = backedVault.positions(actor);
        uint256 required = Math.mulDiv(debt, backedVault.minCR(), 100, Math.Rounding.Ceil);
        if (amountCollateral <= required) return;
        uint256 amount = bound(rawAmount, 1, amountCollateral - required);
        vm.prank(actor);
        backedVault.withdrawCollateral(amount);
        withdrawn[actor] += amount;
    }

    function transferCOMP(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % 4];
        uint256 amount = bound(rawAmount, 0, stable.balanceOf(from));
        vm.prank(from);
        stable.transfer(actors[toSeed % 4], amount);
    }

    function advanceTime(uint256 rawElapsed) external {
        uint256 oldRate = backedVault.decayedRedemptionBaseRate();
        vm.warp(block.timestamp + bound(rawElapsed, 1, 12 hours));
        _refreshEthUsd();
        assertLe(backedVault.decayedRedemptionBaseRate(), oldRate, "time cannot raise the base fee");
    }

    function setHealth(uint256 rawNhi) external {
        health.setValue(bound(rawNhi, 0.6 ether, 0.85 ether));
    }

    function redeem(uint256 redeemerSeed, uint256 candidateSeed, uint256 rawAmount) external {
        uint256 available = stable.balanceOf(actors[redeemerSeed % 4]);
        if (available < 2) return;
        _redeem(redeemerSeed % 4, candidateSeed % 4, bound(rawAmount, 2, Math.min(available, 100 ether)), false);
    }

    function rejectSlippage(uint256 redeemerSeed, uint256 candidateSeed, uint256 rawAmount) external {
        uint256 available = stable.balanceOf(actors[redeemerSeed % 4]);
        if (available < 2) return;
        _redeem(redeemerSeed % 4, candidateSeed % 4, bound(rawAmount, 2, Math.min(available, 100 ether)), true);
    }

    function _redeem(uint256 redeemerIndex, uint256 candidateIndex, uint256 amount, bool forceSlippage) private {
        address redeemer = actors[redeemerIndex];
        address candidate = actors[candidateIndex];
        BeforeRedemption memory beforeState = _snapshot(redeemer);
        uint256 feeBps = backedVault.redemptionFeeBps(amount);
        assertGe(feeBps, 50, "fee floor is preserved");
        assertLe(feeBps, 500, "fee never exceeds the source cap");
        RedemptionAmounts memory amounts;
        amounts.burned = amount;
        amounts.payout = Math.mulDiv(amount, 10_000 - feeBps, 10_000);
        amounts.reserveOut = Math.min(amounts.payout, beforeState.reserveIMD);
        amounts.cancelled = amounts.reserveOut == amounts.payout
            ? 0
            : amount - Math.mulDiv(amounts.reserveOut, 10_000, 10_000 - feeBps);
        bytes4 failure;
        if (forceSlippage) {
            failure = CDPVault.MinimumOutNotMet.selector;
        } else if (amounts.cancelled != 0) {
            uint256 debt = beforeState.debt[candidateIndex];
            if (debt == 0 || backedVault.collateralRatio(candidate) >= backedVault.redemptionCeilingCR()) {
                failure = CDPVault.IneligibleRedemptionPosition.selector;
            } else if (amounts.cancelled > debt) {
                failure = CDPVault.ExcessRepayment.selector;
            } else if (
                amounts.payout - amounts.reserveOut
                    > Math.mulDiv(beforeState.collateral[candidateIndex], amounts.cancelled, debt)
            ) {
                failure = CDPVault.RedemptionWorsensRatio.selector;
            }
        }
        // IMD is $1 and the registered reserve retains 100% in this fixture. Compare
        // exact fractions independently: payout / burn must not exceed backing / supply.
        // Debt exits can break that bound even when the candidate's own ratio improves.
        if (failure == bytes4(0) && amounts.payout * beforeState.supply > beforeState.backing * amount) {
            failure = CDPVault.RedemptionWorsensBacking.selector;
        }
        if (failure != bytes4(0)) {
            vm.expectRevert(failure);
            vm.prank(redeemer);
            backedVault.redeem(amount, forceSlippage ? amounts.payout + 1 : amounts.payout, candidate);
            _assertUnchanged(beforeState, redeemer);
            ++rejectedCalls;
            return;
        }
        amounts.principalCancelled =
            amounts.cancelled - Math.min(amounts.cancelled, backedVault.stabilityFeeOf(candidate));
        vm.prank(redeemer);
        uint256 paid = backedVault.redeem(amount, amounts.payout, candidate);
        assertEq(paid, amounts.payout, "exact feed-priced discounted payout");
        _assertRedeemed(beforeState, amounts, redeemer, candidateIndex);
        principal[candidate] -= amounts.principalCancelled;
        collateralRedeemed[candidate] += amounts.payout - amounts.reserveOut;
        reserveSpent += amounts.reserveOut;
        redemptionBurns += amount;
        nonPrincipalBurns += amount - amounts.principalCancelled;
        if (amounts.reserveOut == amounts.payout) ++reserveOnlyCalls;
        else if (amounts.reserveOut == 0) ++positionOnlyCalls;
        else ++mixedCalls;
    }

    function _assertRedeemed(
        BeforeRedemption memory beforeState,
        RedemptionAmounts memory amounts,
        address redeemer,
        uint256 candidateIndex
    ) private view {
        assertEq(
            stable.totalSupply(), beforeState.supply - amounts.burned, "one burn reduces supply by its entire amount"
        );
        assertEq(collateral.balanceOf(redeemer), beforeState.redeemerIMD + amounts.payout, "one payout per burn");
        assertEq(
            collateral.balanceOf(address(reserve)), beforeState.reserveIMD - amounts.reserveOut, "reserve spent first"
        );
        assertLe(backedVault.workCeiling(), beforeState.ceiling, "redemption cannot loosen new work minting");
        uint256 backingAfter = collateral.balanceOf(address(backedVault)) + collateral.balanceOf(address(reserve));
        assertGe(
            backingAfter * beforeState.supply,
            beforeState.backing * stable.totalSupply(),
            "backing ratio cannot fall, including after debt unwinds"
        );
        for (uint256 i; i < actors.length; ++i) {
            (uint256 afterCollateral, uint256 afterDebt) = backedVault.positions(actors[i]);
            if (i == candidateIndex && amounts.cancelled != 0) {
                assertEq(afterCollateral, beforeState.collateral[i] - (amounts.payout - amounts.reserveOut));
                assertEq(
                    afterDebt, beforeState.debt[i] - amounts.cancelled, "collateral only falls against retired debt"
                );
                assertGe(
                    afterCollateral * beforeState.debt[i], beforeState.collateral[i] * afterDebt, "exact CR cannot fall"
                );
            } else {
                assertEq(afterCollateral, beforeState.collateral[i], "unselected positions keep collateral");
                assertEq(afterDebt, beforeState.debt[i], "reserve-only redemption touches no position");
            }
        }
    }

    function _snapshot(address redeemer) private view returns (BeforeRedemption memory state) {
        state.supply = stable.totalSupply();
        state.reserveIMD = collateral.balanceOf(address(reserve));
        state.redeemerIMD = collateral.balanceOf(redeemer);
        state.backing = state.reserveIMD + collateral.balanceOf(address(backedVault));
        state.ceiling = backedVault.workCeiling();
        state.base = backedVault.redemptionBaseRate();
        state.lastAt = backedVault.lastRedemptionAt();
        for (uint256 i; i < actors.length; ++i) {
            (state.collateral[i], state.debt[i]) = backedVault.positions(actors[i]);
        }
    }

    function _assertUnchanged(BeforeRedemption memory state, address redeemer) private view {
        assertEq(stable.totalSupply(), state.supply, "rejected redemption burns nothing");
        assertEq(collateral.balanceOf(address(reserve)), state.reserveIMD, "rejection retains reserve");
        assertEq(collateral.balanceOf(redeemer), state.redeemerIMD, "rejection pays nothing");
        assertEq(backedVault.redemptionBaseRate(), state.base, "rejection does not raise the fee");
        assertEq(backedVault.lastRedemptionAt(), state.lastAt, "rejection does not restart decay");
        for (uint256 i; i < actors.length; ++i) {
            (uint256 actualCollateral, uint256 actualDebt) = backedVault.positions(actors[i]);
            assertEq(actualCollateral, state.collateral[i], "rejected redemption leaves collateral");
            assertEq(actualDebt, state.debt[i], "rejected redemption leaves debt");
        }
    }

    function _deposit(address actor, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(actor, amount);
        collateralIssued += amount;
        vm.startPrank(actor);
        collateral.approve(address(backedVault), amount);
        backedVault.depositCollateral(amount);
        vm.stopPrank();
        deposited[actor] += amount;
    }

    function _fundIMD(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), amount);
        collateralIssued += amount;
        reserveFunded += amount;
    }

    function assertAccounting() external view {
        uint256 positionCollateral;
        uint256 positionPrincipal;
        uint256 userIMD;
        uint256 userCOMP;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            (uint256 amountCollateral, uint256 debt) = backedVault.positions(actor);
            assertEq(
                amountCollateral, deposited[actor] - withdrawn[actor] - collateralRedeemed[actor], "collateral history"
            );
            assertEq(
                debt - backedVault.stabilityFeeOf(actor), principal[actor], "principal history excludes unminted fees"
            );
            positionCollateral += amountCollateral;
            positionPrincipal += principal[actor];
            userIMD += collateral.balanceOf(actor);
            userCOMP += stable.balanceOf(actor);
        }
        assertEq(backedVault.totalDebt(), positionPrincipal, "total minted principal matches positions");
        assertEq(backedVault.totalWorkMinted(), workIssued, "redemption never restores consumed work rights");
        assertEq(backedVault.totalFeesMinted(), feesReminted, "redemption fees are never paid to a recipient");
        assertEq(
            backedVault.totalNonPrincipalRedeemed(), nonPrincipalBurns, "reserve and accrued-fee burns accounted once"
        );
        assertEq(
            stable.totalSupply(),
            debtIssued + workIssued + feesReminted - repaymentBurns - redemptionBurns,
            "independent supply history"
        );
        assertEq(
            stable.totalSupply(),
            positionPrincipal + workIssued - nonPrincipalBurns,
            "supply identity after redemptions"
        );
        assertEq(stable.balanceOf(address(reserve)), feesReminted, "only paid stability fees reach treasury COMP");
        assertEq(userCOMP + stable.balanceOf(address(reserve)), stable.totalSupply(), "all COMP is accounted for");
        assertEq(collateral.balanceOf(address(backedVault)), positionCollateral, "vault custody matches positions");
        assertEq(
            collateral.balanceOf(address(reserve)), reserveFunded - reserveSpent, "reserve custody matches cash flow"
        );
        assertEq(collateral.totalSupply(), collateralIssued, "no collateral is created by redemption");
        assertEq(
            userIMD + positionCollateral + reserveFunded - reserveSpent, collateralIssued, "all IMD is accounted for"
        );
        assertLe(backedVault.redemptionBaseRate(), 0.045 ether, "stored base respects cap");
        assertGe(backedVault.redemptionFeeBps(0), 50);
        assertLe(backedVault.redemptionFeeBps(0), 500);
        assertGt(reserveOnlyCalls, 0, "reserve route actually executed");
        assertGt(mixedCalls, 0, "same-call reserve exhaustion actually executed");
        assertGt(positionOnlyCalls, 0, "position route actually executed");
    }
}

contract RedemptionInvariantTest is StdInvariant, Test {
    RedemptionSequenceHandler private handler;

    function setUp() public {
        handler = new RedemptionSequenceHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.fundReserve.selector;
        selectors[1] = handler.deposit.selector;
        selectors[2] = handler.borrow.selector;
        selectors[3] = handler.mintWork.selector;
        selectors[4] = handler.repay.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.transferCOMP.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.setHealth.selector;
        selectors[9] = handler.redeem.selector;
        selectors[10] = handler.rejectSlippage.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_redemptionPreservesSupplyDebtBackingAndCustody() public view {
        handler.assertAccounting();
    }

    function test_handlerExecutesMixedRoutesAndRejectsWithoutMutating() public {
        handler.assertAccounting();
        handler.advanceTime(12 hours);
        handler.redeem(1, 3, 1 ether);
        handler.fundReserve(10 ether);
        handler.redeem(2, 2, 1 ether);
        handler.rejectSlippage(0, 0, 2 ether);
        handler.redeem(0, 2, 20 ether);
        handler.deposit(0, 30 ether);
        handler.borrow(0, 10 ether);
        handler.mintWork(3, 1 ether);
        handler.transferCOMP(3, 1, 1 ether);
        handler.repay(1, 2 ether);
        handler.withdraw(0, 1 ether);
        handler.setHealth(0.6 ether);
        handler.redeem(3, 0, 1 ether);
        handler.assertAccounting();
        assertGe(handler.reserveOnlyCalls(), 2);
        assertGe(handler.mixedCalls(), 2);
        assertGe(handler.positionOnlyCalls(), 3);
        assertGe(handler.rejectedCalls(), 1);
        assertEq(handler.debtMintCalls(), 1);
        assertEq(handler.workMintCalls(), 1);
    }

    function test_handlerChecksBackingAfterBorrowersRepayAndWithdraw() public {
        // Work remains outstanding after borrowers use their COMP to close debt and exit.
        // None of these actions require a price change or a governance intervention.
        handler.mintWork(3, 80 ether);
        handler.repay(0, 74 ether);
        handler.repay(1, 95 ether);
        handler.repay(2, 99 ether);
        handler.repay(3, 100 ether);
        handler.withdraw(0, 141 ether);
        handler.withdraw(1, 174 ether);
        handler.withdraw(2, 179 ether);
        handler.withdraw(3, 180 ether);
        handler.fundReserve(10 ether);
        uint256 rejected = handler.rejectedCalls();
        handler.redeem(3, 0, 1 ether);
        assertEq(handler.rejectedCalls(), rejected + 1, "unsafe payout must be rejected");
        handler.assertAccounting();
    }
}
