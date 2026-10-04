// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {SwarmWorkOracle} from "src/SwarmWorkOracle.sol";
import {WorkOracleFactory} from "src/WorkOracleFactory.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Parameters} from "src/Parameters.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {
    APPROVED_OPERATOR,
    FEED_REPORTER_0,
    WORK_AGENT_ID,
    WORK_CLAIMANT,
    WORK_ORACLE_FACTORY,
    WORK_ORACLE_SENTINEL,
    WORK_ORACLE_MAX_AGE,
    COMP_PER_TASK_WAD
} from "src/DeploymentConfig.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";

/// @notice The attested work oracle that replaces the grantRights faucet.
/// @dev The figure it accepts comes from the daily oracle receipts the control plane publishes and
/// pins to IPFS — the second Merkle root of upstream PR #332, which this protocol is the first
/// consumer of. The question document in oracle/work-tally-quote.json is what these tests stand in
/// for: they drive the reporter fallback rather than buying an attestation, because the figure is not
/// answerable yet (no receipt carries an agent tally for this seat so far).
contract SwarmWorkOracleTest is WorkBackingFixture {
    SwarmWorkOracle internal work;
    CDPVault internal attestedVault;
    /// @dev Hoisted, and that is not tidiness. `vm.expectRevert` applies to the NEXT call, and
    /// `backedVault.spotFeed()` inside an argument list IS a call, so reading it there silently eats
    /// the expectation and the test passes for the wrong reason.
    address internal spot;

    function setUp() public override {
        super.setUp();
        spot = address(backedVault.spotFeed());
        WorkOracleFactory factory = new WorkOracleFactory();
        vm.etch(WORK_ORACLE_FACTORY, address(factory).code);
        attestedVault = new CDPVault(
            address(collateral),
            address(0),
            WORK_ORACLE_SENTINEL,
            address(primary),
            address(health),
            spot
        );
        work = SwarmWorkOracle(address(attestedVault.oracle()));
    }

    // --- wiring ---------------------------------------------------------------------------------

    function test_theSentinelYieldsARealOracleLinkedToItsVault() public view {
        assertEq(work.vault(), address(attestedVault), "the oracle names the vault that asked for it");
        assertEq(address(attestedVault.oracle()), address(work), "and the vault holds that oracle");
        assertEq(work.AGENT_ID(), WORK_AGENT_ID, "pinned agent");
        assertEq(work.CLAIMANT(), WORK_CLAIMANT, "pinned claimant");
        assertEq(work.maxAge(), WORK_ORACLE_MAX_AGE, "a day, matching the receipts' cadence");
    }

    /// @dev The whole reason the sentinel is explicit rather than zero: no silent downgrade to the
    /// faucet if the factory is not there. This is the shape of the $owner bug that bricked launch 519.
    function test_anAbsentFactoryRevertsRatherThanFallingBackToTheFaucet() public {
        vm.etch(WORK_ORACLE_FACTORY, "");
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new CDPVault(
            address(collateral),
            address(0),
            WORK_ORACLE_SENTINEL,
            address(primary),
            address(health),
            spot
        );
    }

    /// @dev A zero oracle still means the faucet, which every existing suite and the testnet manifest
    /// depend on. The two paths must stay distinguishable.
    function test_zeroStillMeansTheFaucetAndTheSentinelDoesNot() public view {
        assertTrue(address(backedVault.oracle()) != address(work), "different vaults, different oracles");
        assertEq(SwarmWorkOracle(address(work)).vault(), address(attestedVault));
    }

    /// @dev An oracle the factory made for somebody else is useless to a vault, and refused by it.
    function test_anOracleBoundToAnotherVaultIsRefused() public {
        SwarmWorkOracle other = WorkOracleFactory(WORK_ORACLE_FACTORY).create(WORK_ORACLE_MAX_AGE);
        assertEq(other.vault(), address(this), "created for its caller");
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new CDPVault(
            address(collateral),
            address(0),
            address(other),
            address(primary),
            address(health),
            spot
        );
    }

    // --- rights accounting ----------------------------------------------------------------------

    function test_rightsAreTheAttestedCountTimesTheRate() public {
        _tally(1000);
        assertEq(work.attestedTasks(), 1000);
        assertEq(work.compPerTaskWad(), COMP_PER_TASK_WAD, "no parameters on a plain vault");
        assertEq(work.mintingRights(WORK_CLAIMANT), 1000 * COMP_PER_TASK_WAD);
    }

    function test_nobodyButTheClaimantHasRights() public {
        _tally(1000);
        assertEq(work.mintingRights(address(0xBEEF)), 0);
        assertEq(work.mintingRights(address(0)), 0);
        assertEq(work.mintingRights(address(attestedVault)), 0);
    }

    function test_onlyTheVaultMayConsume() public {
        _tally(1000);
        vm.expectRevert(SwarmWorkOracle.Unauthorized.selector);
        vm.prank(WORK_CLAIMANT);
        work.consumeRights(WORK_CLAIMANT, 1);
    }

    function test_consumingMoreThanEarnedIsRefused() public {
        _tally(10);
        uint256 earned = 10 * COMP_PER_TASK_WAD;
        vm.prank(address(attestedVault));
        vm.expectRevert(SwarmWorkOracle.InsufficientRights.selector);
        work.consumeRights(WORK_CLAIMANT, earned + 1);
    }

    function test_consumingForSomeoneElseIsRefused() public {
        _tally(10);
        vm.prank(address(attestedVault));
        vm.expectRevert(SwarmWorkOracle.InvalidAccount.selector);
        work.consumeRights(address(0xBEEF), 1);
    }

    /// @dev THE ACCOUNTING THAT MATTERS. The figure is read under no tolerance but it can still move
    /// down for ordinary reasons — the feed can go stale and re-anchor, and a daily receipt only lists
    /// agents who worked that day. A lower later figure must not claw back what was already consumed.
    function test_aLowerLaterFigureNeverClawsBackConsumedRights() public {
        _tally(1000);
        uint256 spend = 500 * COMP_PER_TASK_WAD;
        vm.prank(address(attestedVault));
        work.consumeRights(WORK_CLAIMANT, spend);
        assertEq(work.mintingRights(WORK_CLAIMANT), 500 * COMP_PER_TASK_WAD, "half left");
        assertEq(work.creditedTasks(), 1000, "the high-water mark is pinned at consumption");

        _retally(600); // a later, lower reading
        assertEq(work.attestedTasks(), 1000, "never below what rights were computed against");
        assertEq(work.mintingRights(WORK_CLAIMANT), 500 * COMP_PER_TASK_WAD, "and the remainder stands");
    }

    /// @dev A stale tally grants nothing NEW and retracts nothing already consumed.
    function test_aStaleTallyGrantsNothingNewAndRetractsNothing() public {
        _tally(1000);
        vm.prank(address(attestedVault));
        work.consumeRights(WORK_CLAIMANT, 400 * COMP_PER_TASK_WAD);

        vm.warp(vm.getBlockTimestamp() + WORK_ORACLE_MAX_AGE + 1);
        assertTrue(work.isStale(), "past a day");
        assertEq(work.attestedTasks(), 1000, "the credited count survives staleness");
        assertEq(work.mintingRights(WORK_CLAIMANT), 600 * COMP_PER_TASK_WAD, "earned minus consumed");
    }

    /// @dev Before any attestation there is nothing to claim. The faucet's defining property was that
    /// one key could change that; here no key can.
    function test_withNoAttestationThereAreNoRightsAndNoKeyCanGrantThem() public view {
        assertTrue(work.isStale(), "a feed with no value is stale");
        assertEq(work.attestedTasks(), 0);
        assertEq(work.mintingRights(WORK_CLAIMANT), 0);
    }

    function test_thereIsNoGrantRightsFunction() public {
        (bool ok,) = address(work).call(abi.encodeWithSignature("grantRights(address,uint256)", WORK_CLAIMANT, 1e18));
        assertFalse(ok, "the faucet's entry point does not exist here");
    }

    // --- the governed rate ----------------------------------------------------------------------

    /// @dev The rate is PROBED, not required, so one oracle serves a plain vault and a governed one.
    /// A governed vault's oracle reads the parameters; a plain vault's falls back to the constant and
    /// cannot be changed by anyone at all.
    function test_theRateIsReadFromTheVaultsParametersWhenItHasThem() public {
        ParameterizedVault governed = new ParameterizedVault(
            address(collateral),
            address(0),
            WORK_ORACLE_SENTINEL,
            address(primary),
            address(health),
            spot
        );
        SwarmWorkOracle governedWork = SwarmWorkOracle(address(governed.oracle()));
        assertEq(governedWork.compPerTaskWad(), COMP_PER_TASK_WAD, "seeded from the shipped constant");

        // vm.prank applies to the NEXT call, and `governed.parameters()` IS a call, so the view has
        // to be hoisted out or it eats the prank.
        Parameters governedParams = governed.parameters();
        vm.prank(APPROVED_OPERATOR);
        governedParams.proposeCompPerTask(0.25 ether);
        vm.warp(governedParams.pendingEta());
        vm.prank(address(0xA990));
        governedParams.applyPending();

        assertEq(governedWork.compPerTaskWad(), 0.25 ether, "the oracle follows the governed rate");
        assertEq(work.compPerTaskWad(), COMP_PER_TASK_WAD, "the plain vault's oracle does not move");
    }

    function test_aGovernedRateChangeTakesEffectAfterTheDelay() public {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeCompPerTask(0.5 ether);
        assertEq(parameters.compPerTaskWad(), COMP_PER_TASK_WAD, "not yet");
        _apply();
        assertEq(parameters.compPerTaskWad(), 0.5 ether, "after 48 hours");
    }

    function test_aRateAboveOneCompPerTaskIsRefusedAtProposal() public {
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.CompPerTaskTooHigh.selector, 1 ether + 1));
        parameters.proposeCompPerTask(1 ether + 1);
    }

    function test_theRateCapIsOneCompPerTask() public view {
        assertEq(parameters.MAX_COMP_PER_TASK_WAD(), 1 ether);
    }

    // --- minting against attested work ----------------------------------------------------------

    /// @dev End to end on a plain vault, whose base `workCeiling` is unbounded: attested work alone
    /// mints COMP, with no key involved anywhere.
    function test_attestedWorkMintsComp() public {
        _tally(1000);
        uint256 rights = work.mintingRights(WORK_CLAIMANT);
        assertEq(rights, 1000 * COMP_PER_TASK_WAD, "rights exist");

        vm.prank(WORK_CLAIMANT);
        attestedVault.mintFromWork(rights);
        assertEq(attestedVault.compToken().balanceOf(WORK_CLAIMANT), rights, "minted from work");
        assertEq(work.mintingRights(WORK_CLAIMANT), 0, "and spent");
        assertEq(work.consumedRights(), rights);
    }

    /// @dev And on a GOVERNED vault the ceiling binds on top: the work is just as attested, but a
    /// stack with no reserve and no debt backs nothing, so the claim is refused. Backing bounds the
    /// amount; work only bounds who may ask.
    function test_onAGovernedVaultTheCeilingStillBinds() public {
        ParameterizedVault governed = new ParameterizedVault(
            address(collateral),
            address(0),
            WORK_ORACLE_SENTINEL,
            address(primary),
            address(health),
            spot
        );
        SwarmWorkOracle governedWork = SwarmWorkOracle(address(governed.oracle()));
        vm.prank(FEED_REPORTER_0);
        governedWork.report(1000);
        assertGt(governedWork.mintingRights(WORK_CLAIMANT), 0, "rights exist");
        assertEq(governed.workCeiling(), 0, "but nothing backs them");

        vm.prank(WORK_CLAIMANT);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        governed.mintFromWork(1);
    }

    // --- the governed rate cannot reach backwards ---

    /// @dev THE REGRESSION. Round 5's audit_judge: "a compPerTask change reprices work that was
    /// already credited and consumed, in both directions." Entitlement was
    /// `attestedTasks() * compPerTaskWad()` — recomputed from a fixed origin at the current rate — so
    /// doubling the rate re-granted rights for work already minted against. Free COMP for a governance
    /// action that was only supposed to price FUTURE work.
    function test_regression_aRateRiseDoesNotRepriceWorkAlreadyConsumed() public {
        ParameterizedVault governed = _governedVault();
        SwarmWorkOracle w = SwarmWorkOracle(address(governed.oracle()));
        Parameters params = governed.parameters();

        vm.prank(FEED_REPORTER_0);
        w.report(1000);
        uint256 all = w.mintingRights(WORK_CLAIMANT);
        assertEq(all, 1000 * COMP_PER_TASK_WAD, "1000 tasks at the shipped rate");

        // Spend every right the attested work earns.
        vm.prank(address(governed));
        w.consumeRights(WORK_CLAIMANT, all);
        assertEq(w.mintingRights(WORK_CLAIMANT), 0, "nothing left");

        // Now double the rate. The old behaviour handed out another `all` for the SAME 1000 tasks.
        _setRate(params, COMP_PER_TASK_WAD * 2);
        assertEq(w.mintingRights(WORK_CLAIMANT), 0, "a rate rise must not re-grant consumed work");
        assertEq(w.creditedRights(), all, "the price of credited work is locked");
    }

    /// @dev The other direction. A cut used to make the recomputed total fall below what had been
    /// consumed, so rights the claimant had already earned simply vanished.
    function test_regression_aRateCutDoesNotTakeBackRightsAlreadyEarned() public {
        ParameterizedVault governed = _governedVault();
        SwarmWorkOracle w = SwarmWorkOracle(address(governed.oracle()));
        Parameters params = governed.parameters();

        vm.prank(FEED_REPORTER_0);
        w.report(1000);
        uint256 half = (1000 * COMP_PER_TASK_WAD) / 2;
        vm.prank(address(governed));
        w.consumeRights(WORK_CLAIMANT, half);
        assertEq(w.mintingRights(WORK_CLAIMANT), half, "half spent, half left");

        _setRate(params, COMP_PER_TASK_WAD / 4);
        assertEq(w.mintingRights(WORK_CLAIMANT), half, "a cut cannot reach work already credited");
        assertGe(w.creditedRights(), w.consumedRights(), "credited never falls below consumed");
    }

    /// @dev And the change does apply where it should: to work that arrives after it.
    function test_newWorkIsPricedAtTheRateInForceWhenItIsCredited() public {
        ParameterizedVault governed = _governedVault();
        SwarmWorkOracle w = SwarmWorkOracle(address(governed.oracle()));
        Parameters params = governed.parameters();

        vm.prank(FEED_REPORTER_0);
        w.report(1000);
        uint256 earned = w.mintingRights(WORK_CLAIMANT);
        vm.prank(address(governed));
        w.consumeRights(WORK_CLAIMANT, earned); // credits 1000 tasks at the old rate

        _setRate(params, COMP_PER_TASK_WAD * 2);
        // The deviation bound permits at most a doubling while fresh, so 1000 -> 1500 is acceptable.
        vm.prank(FEED_REPORTER_0);
        w.report(1500);
        assertEq(w.mintingRights(WORK_CLAIMANT), 500 * COMP_PER_TASK_WAD * 2, "500 new tasks at the new rate");
    }

    function _governedVault() private returns (ParameterizedVault) {
        return new ParameterizedVault(
            address(collateral), address(0), WORK_ORACLE_SENTINEL, address(primary), address(health), spot
        );
    }

    /// @dev vm.prank applies to the NEXT call, so the view is hoisted out of the pranked one.
    function _setRate(Parameters params, uint256 wad) private {
        vm.prank(APPROVED_OPERATOR);
        params.proposeCompPerTask(wad);
        vm.warp(params.pendingEta());
        vm.prank(address(0xA990));
        params.applyPending();
        _refreshEthUsd();
    }

    // --- question binding ------------------------------------------------------------------------

    /// @dev THE PROOF THAT THE CONTRACT COMPUTES WHAT THE SERVICE SIGNS. These two hashes were
    /// produced in JavaScript by `node oracle/question-prefix.mjs oracle/work-tally-quote.json`,
    /// canonicalising the question document as an RFC 8785 subset and hashing it, then spliced here
    /// from Solidity's own pinned prefix. If the payload changes by one character they diverge and
    /// this fails, which is the whole point: the oracle would refuse every attestation and that must
    /// never be discovered after paying for one.
    function test_theSolidityQuestionHashMatchesTheJavascriptOne() public view {
        assertEq(
            work.expectedQuestionHash(1_000_000, 1_007_200),
            0x7844956985792293c4edfe4b8b5d1e6a940b71fb0c4470d74f8c98b2eddce935,
            "window 1000000..1007200"
        );
        assertEq(
            work.expectedQuestionHash(23_000_000, 23_007_000),
            0xfd16adcd61754f55c8af84a062f8a2987577339c4b753468b3a7ff6c5d8b580b,
            "window 23000000..23007000"
        );
    }

    /// @dev This oracle BINDS a question, which is what makes the agentId and the claimant
    /// unforgeable without a field for either. A feed that pinned nothing would return zero here,
    /// and SwarmFeed's constructor would have required a trusted relayer instead.
    function test_thisOraclePinsAQuestionRatherThanTrustingARelayer() public view {
        bytes32 a = work.expectedQuestionHash(1_000_000, 1_007_200);
        bytes32 b = work.expectedQuestionHash(1_000_001, 1_007_200);
        assertTrue(a != bytes32(0), "a question is pinned");
        assertTrue(a != b, "and the window is part of it");
    }

    // --- helpers --------------------------------------------------------------------------------

    /// @dev The reporter fallback, which SwarmFeed requires to exist and which these tests use in
    /// place of buying an attestation. The real path is submitAttestation under question binding,
    /// covered for this contract's base by test/QuestionBinding.t.sol and test/SwarmFeed.t.sol.
    function _tally(uint256 count) private {
        vm.prank(FEED_REPORTER_0);
        work.report(count);
    }

    /// @dev A second reading. The deviation bound permits at most a doubling while the last value is
    /// fresh, so a fall is always acceptable and a rise may need the value to age first.
    function _retally(uint256 count) private {
        vm.prank(FEED_REPORTER_0);
        work.report(count);
    }
}
