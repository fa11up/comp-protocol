// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {Test} from "forge-std/Test.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {Governed} from "../src/Governed.sol";
import {Parameters, ICheckpointedVault} from "../src/Parameters.sol";
import {ParameterizedVault} from "../src/ParameterizedVault.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {FreshUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {
    APPROVED_OPERATOR,
    CHAINLINK_ETH_USD,
    CHIP_BPS,
    SKEW_BPS,
    CUT_BPS,
    DUTY_BPS
} from "../src/DeploymentConfig.sol";

/// @notice The governed parameter path end to end: the seam, the delay, the bounds, and the two
/// defects that made a mutable stability rate unsafe before the index was checkpointed.
contract ParametersTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant STRANGER = address(0x5747);

    Parameters private params;
    ParameterizedVault private vault;
    MockIMD private imd;
    ImdUSD private comp;
    TestSwarmFeed private price;
    TestSwarmFeed private nhi;
    TestSwarmFeed private spot;

    function setUp() public {
        TreasuryFactoryEtch.etch(vm);
        vm.chainId(11155111);
        vm.warp(10 days);
        // ParameterizedVault denominates in USD, so its price has a Chainlink leg. One dollar per ETH
        // keeps every figure in this suite in the unit the feeds already quote — the suite is about
        // governance, not pricing — and an always-fresh leg lets it warp years forward, which several
        // of these tests do, without the vault halting on a stale USD price.
        vm.etch(CHAINLINK_ETH_USD, address(new FreshUsdAggregator()).code);
        FreshUsdAggregator(CHAINLINK_ETH_USD).setDecimals(8);
        FreshUsdAggregator(CHAINLINK_ETH_USD).set(1e8);
        imd = new MockIMD();
        price = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.9 ether);
        vault = new ParameterizedVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        params = vault.parameters();
        comp = vault.stablecoin();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_000 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(1_000 ether);
        vm.stopPrank();
    }

    function _set(uint256 ceiling, uint256 protocolBps, uint256 feeBps, uint256 divergenceBps, uint256 markerBps)
        private
        returns (Parameters.ParamSet memory next)
    {
        next = Parameters.ParamSet(ceiling, protocolBps, feeBps, divergenceBps, markerBps);
    }

    function _govern(Parameters.ParamSet memory next) private {
        vm.prank(APPROVED_OPERATOR);
        params.propose(next);
        vm.warp(block.timestamp + params.TIMELOCK());
        vm.prank(STRANGER);
        params.applyPending();
    }

    /// @dev A second borrower mints COMP against their own collateral and sells it on. The only way
    /// fee-paying COMP exists: the protocol mints principal, never the fee.
    function _fundFeeFromTheMarket(address to, uint256 amount) private {
        address market = address(0x4A4E7);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(market, 1_000 ether);
        vm.startPrank(market);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(1_000 ether);
        vault.draw(amount);
        comp.transfer(to, amount);
        vm.stopPrank();
    }

    // --- the seam -----------------------------------------------------------

    /// @dev A fresh Parameters is the shipped configuration, so binding it changes nothing.
    function test_governanceStartsFromTheShippedConfiguration() public view {
        assertEq(vault.line(), type(uint256).max);
        assertEq(vault.cut(), CUT_BPS);
        assertEq(vault.duty(), DUTY_BPS);
        assertEq(vault.skew(), SKEW_BPS);
        assertEq(vault.chip(), CHIP_BPS);
    }

    function test_everyEconomicKnobCanBeSourcedFromOutsideTheVault() public {
        _govern(_set(250 ether, 2_000, 400, 800, 1_500));
        assertEq(vault.line(), 250 ether, "ceiling follows the parameters contract");
        assertEq(vault.cut(), 2_000);
        assertEq(vault.duty(), 400);
        assertEq(vault.skew(), 800);
        assertEq(vault.chip(), 1_500);
    }

    /// @dev The knobs are not decorative: a tightened ceiling binds on the next mint.
    function test_aTightenedCeilingTakesEffectWithoutRedeployingTheVault() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);
        _govern(_set(100 ether, 0, DUTY_BPS, 500, 1_000));
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        vault.draw(1);
    }

    /// @dev And a tightened divergence bound starts refusing a gap it used to allow.
    function test_aTightenedDivergenceBoundBindsImmediately() public {
        spot.setValue(1.03 ether); // 300 bps apart: inside 500, outside 200
        vm.prank(BORROWER);
        vault.draw(1 ether);
        _govern(_set(type(uint256).max, 0, DUTY_BPS, 200, 1_000));
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.draw(1 ether);
    }

    /// @dev The asymmetry that makes this safe: what prices the collateral is NOT reachable this way.
    /// The feeds are immutables with no setter, and so is the parameters address itself, so a
    /// governor can tune the economics and can never change the price, the signer, or the source.
    function test_parametersCannotReachThePriceSource() public {
        _govern(_set(1 ether, 9_000, 1_000, 2_000, 1_000));
        assertEq(address(vault.priceFeed()), address(price));
        assertEq(address(vault.spotFeed()), address(spot));
        assertEq(address(vault.nhiFeed()), address(nhi));
        assertEq(address(vault.gem()), address(imd));
        assertEq(address(vault.parameters()), address(params));
    }

    // --- the delay ----------------------------------------------------------

    function test_aChangeCannotLandBeforeTheDelayHasRun() public {
        Parameters.ParamSet memory next = _set(type(uint256).max, 0, 1_000, 500, 1_000);
        vm.prank(APPROVED_OPERATOR);
        params.propose(next);
        assertEq(vault.duty(), DUTY_BPS, "the old rate is live for the whole delay");

        vm.warp(block.timestamp + params.TIMELOCK() - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, params.pendingEta()));
        params.applyPending();

        vm.warp(block.timestamp + 1);
        params.applyPending();
        assertEq(vault.duty(), 1_000);
    }

    /// @dev The pending change is readable by anyone for the whole window — that is what makes the
    /// delay worth anything to a borrower.
    function test_thePendingChangeIsPublicWhileItWaits() public {
        vm.prank(APPROVED_OPERATOR);
        params.propose(_set(500 ether, 1_111, 700, 300, 2_000));
        (Parameters.ParamSet memory next, uint256 eta) = params.pendingSet();
        assertEq(next.duty, 700);
        assertEq(next.line, 500 ether);
        assertEq(eta, block.timestamp + params.TIMELOCK());
    }

    function test_onlyTheGovernorMayProposeOrCancel() public {
        Parameters.ParamSet memory next = _set(type(uint256).max, 0, 300, 500, 1_000);
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        params.propose(next);

        vm.prank(APPROVED_OPERATOR);
        params.propose(next);
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        params.cancel();

        vm.prank(APPROVED_OPERATOR);
        params.cancel();
        assertEq(params.pendingEta(), 0);
        vm.expectRevert(Governed.NothingPending.selector);
        params.applyPending();
    }

    /// @dev Applying is permissionless once the delay has run, so the governor cannot hold a
    /// validated change over the protocol and pick its moment.
    function test_anyoneMayApplyOnceTheDelayHasRun() public {
        vm.prank(APPROVED_OPERATOR);
        params.propose(_set(type(uint256).max, 0, 150, 500, 1_000));
        vm.warp(block.timestamp + params.TIMELOCK());
        vm.prank(STRANGER);
        params.applyPending();
        assertEq(vault.duty(), 150);
    }

    function test_oneProposalAtATime() public {
        Parameters.ParamSet memory next = _set(type(uint256).max, 0, 150, 500, 1_000);
        vm.startPrank(APPROVED_OPERATOR);
        params.propose(next);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.propose(next);
        vm.stopPrank();
    }

    // --- the bounds ---------------------------------------------------------

    function test_theGovernorCannotExceedTheHardBounds() public {
        vm.startPrank(APPROVED_OPERATOR);

        vm.expectRevert(abi.encodeWithSelector(Parameters.FeeTooHigh.selector, 1_001));
        params.propose(_set(type(uint256).max, 0, 1_001, 500, 1_000));

        vm.expectRevert(abi.encodeWithSelector(Parameters.DivergenceOutOfRange.selector, 99));
        params.propose(_set(type(uint256).max, 0, 200, 99, 1_000));

        vm.expectRevert(abi.encodeWithSelector(Parameters.DivergenceOutOfRange.selector, 2_001));
        params.propose(_set(type(uint256).max, 0, 200, 2_001, 1_000));

        vm.expectRevert(abi.encodeWithSelector(Parameters.SharesExceedBonus.selector, 5_000, 5_001));
        params.propose(_set(type(uint256).max, 5_001, 200, 500, 5_000));

        vm.expectRevert(Parameters.ZeroCeiling.selector);
        params.propose(_set(0, 0, 200, 500, 1_000));

        vm.stopPrank();
    }

    /// @dev The ceiling is NOT checked against outstanding debt, which an audit showed was a
    /// griefing vector rather than a protection: minting is permissionless up to the current ceiling,
    /// so a borrower could keep totalDebt above any proposed figure and stall the whole payload. A low
    /// ceiling strands nobody — repay, withdraw and bite are not ceiling-gated — so a proposal
    /// that tightens below current debt simply stops further growth.
    function test_aTightCeilingStopsGrowthWithoutStrandingAnyone() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);

        _govern(_set(50 ether, 0, DUTY_BPS, 500, 1_000));
        assertEq(vault.line(), 50 ether, "a ceiling below outstanding debt still applies");

        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        vault.draw(1);

        // The position is fully operable: the borrower is not trapped by a ceiling they are past.
        vm.startPrank(BORROWER);
        comp.approve(address(vault), type(uint256).max);
        vault.wipe(10 ether);
        vault.free(1 ether);
        vm.stopPrank();
        assertGt(vault.debtOf(BORROWER), 0);
    }


    /// @dev AUDIT FIX (two mediums): a vault's Parameters is the one it created, and there is no way
    /// to pass another in or to bind one afterwards. So neither the front-run that bound an impostor
    /// nor the second vault borrowing an already-bound Parameters is expressible any more. The proofs
    /// for both live in audit/proofs/, outside the compiled tree, because they no longer compile.
    function test_everyVaultGovernsThroughItsOwnParametersAndNothingElse() public {
        ParameterizedVault other =
            new ParameterizedVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        Parameters theirs = other.parameters();

        assertTrue(address(theirs) != address(params), "two vaults must not share one Parameters");
        assertEq(address(theirs.vault()), address(other), "each Parameters governs its creator");
        assertEq(address(params.vault()), address(vault));

        // A rate change on one reaches only that one, so the other is never left uncheckpointed.
        vm.prank(APPROVED_OPERATOR);
        theirs.propose(Parameters.ParamSet(type(uint256).max, 0, 400, 500, 1_000));
        vm.warp(block.timestamp + theirs.TIMELOCK());
        theirs.applyPending();
        assertEq(other.duty(), 400);
        assertEq(vault.duty(), DUTY_BPS, "the other vault is untouched");
    }

    // --- what made the rate governable at all --------------------------------

    /// @dev The defect this fixes: the index used to run from `deployedAt` at the CURRENT rate, so
    /// raising the rate repriced every second already elapsed. A year held at 2% cost 2 COMP, and
    /// the instant the rate went to 10% that same year cost 10.
    function test_aRateRiseDoesNotRepriceTimeThatHasAlreadyPassed() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 365 days);

        assertEq(vault.stabilityFeeOf(BORROWER), 2 ether, "100 COMP for a year at 200 bps");

        vm.prank(APPROVED_OPERATOR);
        params.propose(_set(type(uint256).max, 0, 1_000, 500, 1_000));
        vm.warp(block.timestamp + params.TIMELOCK());
        uint256 owedAtTheOldRate = vault.stabilityFeeOf(BORROWER);
        params.applyPending();

        assertEq(vault.stabilityFeeOf(BORROWER), owedAtTheOldRate, "the time that happened is unchanged");
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.stabilityFeeOf(BORROWER), owedAtTheOldRate + 10 ether, "only the new year is at 10%");
    }

    /// @dev The worse half of the same defect: the index was recomputed, so a rate CUT made it fall
    /// below a borrower's stored index, and the subtraction in `stabilityFeeOf` underflowed. That
    /// reverts `_accrue`, which is on every entry point — a rate cut used to freeze every position.
    function test_aRateCutDoesNotFreezePositions() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 180 days);

        vm.prank(APPROVED_OPERATOR);
        params.propose(_set(type(uint256).max, 0, 0, 500, 1_000)); // all the way to zero
        vm.warp(block.timestamp + params.TIMELOCK());
        uint256 owedBefore = vault.stabilityFeeOf(BORROWER);
        assertGt(owedBefore, 0);
        params.applyPending();

        assertEq(vault.stabilityFeeOf(BORROWER), owedBefore, "fees already owed survive the cut");
        vm.warp(block.timestamp + 180 days);
        assertEq(vault.stabilityFeeOf(BORROWER), owedBefore, "and nothing accrues at a zero rate");

        // And the position is still operable, which it was not before: a falling index made the
        // subtraction in `stabilityFeeOf` underflow, so every entry point reverted.
        vm.startPrank(BORROWER);
        vault.draw(1 ether);
        vault.free(1 ether);
        vm.stopPrank();
    }

    /// @dev What the delay buys a borrower: 48 hours at the terms they priced. A fee rise is
    /// proposed, and a borrower who does not want it can be fully out before it applies.
    function test_aBorrowerCanExitAtTheOldTermsDuringTheDelay() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 30 days);

        vm.prank(APPROVED_OPERATOR);
        params.propose(_set(type(uint256).max, 0, 1_000, 500, 1_000));

        vm.warp(block.timestamp + params.TIMELOCK() - 1); // the last moment of the old terms
        uint256 owed = vault.debtOf(BORROWER);
        // The fee is not mintable against the borrower's own collateral — minting adds principal
        // one for one, so a position can never repay its own fee. It comes from the market.
        _fundFeeFromTheMarket(BORROWER, owed - 100 ether);
        vm.startPrank(BORROWER);
        comp.approve(address(vault), type(uint256).max);
        vault.wipe(owed);
        vault.free(1_000 ether);
        vm.stopPrank();

        assertEq(vault.debtOf(BORROWER), 0);
        assertEq(imd.balanceOf(BORROWER), 1_000 ether, "out whole, at the rate they borrowed at");

        vm.warp(block.timestamp + 1);
        params.applyPending();
        assertEq(vault.stabilityFeeOf(BORROWER), 0, "and the new rate finds nothing to charge");
    }

    /// @dev The deployment shape a launch manifest can actually express: it makes no post-deploy
    /// calls and names at most four contracts, so the vault creates its own Parameters and the pair
    /// comes up mutually linked with nothing sent afterwards.
    function test_aSelfContainedVaultComesUpAlreadyLinked() public {
        ParameterizedVault solo =
            new ParameterizedVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        Parameters own = solo.parameters();
        assertTrue(address(own) != address(0), "the vault created its parameters");
        assertEq(address(own.vault()), address(solo), "and they already name it, with no post-deploy call");
        assertEq(address(own), address(solo.parameters()), "in both directions");

        // Governance works immediately, including the rate, which needs the binding to checkpoint.
        vm.prank(APPROVED_OPERATOR);
        own.propose(Parameters.ParamSet(type(uint256).max, 0, 500, 500, 1_000));
        vm.warp(block.timestamp + own.TIMELOCK());
        own.applyPending();
        assertEq(solo.duty(), 500);

        // And it is a DIFFERENT Parameters from this fixture's: one per vault, never shared.
        assertTrue(address(own) != address(params), "a vault does not borrow another vault's parameters");
    }

    /// @dev `drip` is permissionless and can only move the index forward, so calling it
    /// repeatedly is harmless and never changes what anyone owes.
    function test_pokingTheIndexIsIdempotentAndOpenToAnyone() public {
        vm.prank(BORROWER);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 90 days);
        uint256 owed = vault.stabilityFeeOf(BORROWER);
        uint256 index = vault.chi();

        vm.prank(STRANGER);
        vault.drip();
        assertEq(vault.chi(), index);
        assertEq(vault.stabilityFeeOf(BORROWER), owed);

        vm.prank(STRANGER);
        vault.drip();
        assertEq(vault.stabilityFeeOf(BORROWER), owed);
    }
}
