// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {SwarmWorkOracle} from "src/SwarmWorkOracle.sol";
import {WorkOracleFactory} from "src/WorkOracleFactory.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Parameters} from "src/Parameters.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {
    APPROVED_OPERATOR,
    ERC8004_ADAPTER,
    WORK_ORACLE_FACTORY,
    WORK_ORACLE_SENTINEL,
    WORK_ORACLE_MAX_AGE,
    WAGE_WAD
} from "src/DeploymentConfig.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {SeedableWorkOracle, SeedableWorkOracleFactory} from "./helpers/SeedableFeeds.sol";

/// @notice The swarm-wide work oracle: one attested root a day, any agent's controller claims.
/// @dev What is worth testing here is not the attestation path — that is SwarmFeed's and is covered
/// where it lives — but the three things this contract adds: a Merkle proof against a root it has
/// accepted, credit that accumulates per agent and is priced when claimed, and an authorisation
/// answer that comes from the ERC-8004 registry rather than from a constant in our source.
contract SwarmWorkOracleTest is WorkBackingFixture {
    uint256 private constant AGENT_A = 51450;
    uint256 private constant AGENT_B = 51204;
    address private constant CONTROLLER_A = address(0xA11CE);
    address private constant CONTROLLER_B = address(0xB0B);
    address private constant STRANGER = address(0xBAD);

    /// @dev The rate governance would set when minting from work is switched on. WAGE_WAD ships as
    /// zero (minting off at launch, and `claim` refuses while it is), so every test that claims first
    /// raises the wage through the real 48-hour timelock, as governance would.
    uint256 private constant RATE = 0.01 ether;

    SeedableWorkOracle private work;
    CDPVault private attestedVault;
    Parameters private governance;
    address private spot;

    function setUp() public override {
        TreasuryFactoryEtch.etch(vm);
        super.setUp();
        spot = address(backedVault.spotFeed());
        SeedableWorkOracleFactory factory = new SeedableWorkOracleFactory();
        vm.etch(WORK_ORACLE_FACTORY, address(factory).code);
        // A governed vault, because the wage is read from its Parameters: a base CDPVault has none and
        // its oracle stays at WAGE_WAD, which is zero at launch.
        ParameterizedVault governed = new ParameterizedVault(
            address(collateral), address(0), WORK_ORACLE_SENTINEL, address(primary), address(health), spot
        );
        attestedVault = governed;
        governance = governed.parameters();
        work = SeedableWorkOracle(address(attestedVault.oracle()));
        _setWage(governance, RATE);
    }

    function _setWage(Parameters params, uint256 wad) private {
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(wad);
        vm.warp(params.pendingEta());
        vm.prank(address(0xA990));
        params.applyPending();
        _refreshEthUsd();
    }

    // --- the root, and how it gets in ------------------------------------------------------------

    function test_aRootIsOnlyClaimableOnceTheFeedHasAcceptedIt() public {
        (bytes32 root,,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        assertFalse(work.acceptedRoots(root), "nothing is accepted before an attestation");
        vm.expectRevert(SwarmWorkOracle.UnknownRoot.selector);
        work.recordRoot();

        work.seed(uint256(root));
        work.recordRoot();
        assertTrue(work.acceptedRoots(root), "the attested figure is the root");
    }

    /// @dev The reason `_checkValue` is overridden. Two honest roots are unrelated 256-bit numbers,
    /// so the inherited deviation bound — right for a price — would refuse almost every update.
    function test_anUnrelatedSecondRootIsAcceptedWhereAPriceWouldBeRefused() public {
        work.seed(uint256(keccak256("day-1")));
        work.recordRoot();
        work.seed(uint256(keccak256("day-2"))); // wildly different; a price feed would revert here
        work.recordRoot();
        assertTrue(work.acceptedRoots(keccak256("day-1")), "the older root stays claimable");
        assertTrue(work.acceptedRoots(keccak256("day-2")));
    }

    function test_zeroIsStillRefusedBecauseItIsNotATree() public {
        vm.expectRevert(SwarmFeed.ZeroValue.selector);
        work.seed(0);
    }

    // --- claiming ---------------------------------------------------------------------------------

    function test_theControllerOfAnAgentClaimsItsPublishedTally() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);

        vm.prank(CONTROLLER_A);
        uint256 rights = work.claim(AGENT_A, 10, 10, proofA, root);

        assertEq(rights, 10 * RATE, "ten tasks at the shipped rate");
        assertEq(work.mintingRights(CONTROLLER_A), rights);
        assertEq(work.creditedTasks(AGENT_A), 10);
        assertEq(work.mintingRights(STRANGER), 0, "nobody else gained anything");
    }

    /// @dev No address is privileged in source: a second agent's controller claims independently, and
    /// neither can touch the other's tally.
    function test_everyAgentsControllerClaimsIndependently() public {
        (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        _controls(AGENT_B, CONTROLLER_B, true);

        vm.prank(CONTROLLER_A);
        work.claim(AGENT_A, 10, 10, proofA, root);
        vm.prank(CONTROLLER_B);
        work.claim(AGENT_B, 20, 20, proofB, root);

        assertEq(work.mintingRights(CONTROLLER_A), 10 * RATE);
        assertEq(work.mintingRights(CONTROLLER_B), 20 * RATE);
    }

    function test_aStrangerCannotClaimAnotherAgentsTally() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, STRANGER, false);
        vm.prank(STRANGER);
        vm.expectRevert(SwarmWorkOracle.NotTheController.selector);
        work.claim(AGENT_A, 10, 10, proofA, root);
    }

    /// @dev The registry has no testnet deployment, so with no adapter nothing answers and every
    /// claim is refused. The compute channel is inert off mainnet, which is the honest state.
    function test_withNoRegistryDeployedNobodyCanClaim() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        assertEq(ERC8004_ADAPTER.code.length, 0, "no adapter on this chain");
        vm.prank(CONTROLLER_A);
        vm.expectRevert(SwarmWorkOracle.NotTheController.selector);
        work.claim(AGENT_A, 10, 10, proofA, root);
    }

    function test_aProofForTheWrongLeafIsRefused() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        vm.expectRevert(SwarmWorkOracle.BadProof.selector);
        work.claim(AGENT_A, 10, 999, proofA, root); // inflated cumulative, same proof
    }

    function test_aRootTheFeedNeverAcceptedIsRefused() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        vm.expectRevert(SwarmWorkOracle.UnknownRoot.selector);
        work.claim(AGENT_A, 10, 10, proofA, root);
    }

    function test_claimingTheSameTallyTwiceCreditsNothingFurther() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.startPrank(CONTROLLER_A);
        work.claim(AGENT_A, 10, 10, proofA, root);
        vm.expectRevert(SwarmWorkOracle.NothingToClaim.selector);
        work.claim(AGENT_A, 10, 10, proofA, root);
        vm.stopPrank();
    }

    /// @dev Only the INCREMENT is credited, so a later day's larger cumulative pays for the
    /// difference and never for work already claimed.
    function test_aLaterDayCreditsOnlyTheIncrement() public {
        (bytes32 day1, bytes32[] memory p1,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(day1);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        work.claim(AGENT_A, 10, 10, p1, day1);

        (bytes32 day2, bytes32[] memory p2,) = _tree(AGENT_A, 5, 15, AGENT_B, 30, 50);
        _accept(day2);
        vm.prank(CONTROLLER_A);
        uint256 more = work.claim(AGENT_A, 5, 15, p2, day2);
        assertEq(more, 5 * RATE, "only the five new tasks");
        assertEq(work.mintingRights(CONTROLLER_A), 15 * RATE);
    }

    /// @dev An agent idle on a given day is absent from that day's tree, so proving against an OLDER
    /// root must stay possible. It is always safe: cumulative is monotone, so an old root can only
    /// under-credit.
    function test_anOlderRootStaysClaimableForAnAgentAbsentFromTheNewest() public {
        (bytes32 day1, bytes32[] memory p1,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(day1);
        _accept(keccak256("day-2-without-agent-a"));
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        assertEq(work.claim(AGENT_A, 10, 10, p1, day1), 10 * RATE);
    }

    // --- pricing, and the mistake not repeated ---------------------------------------------------

    /// @dev Rights are priced AT CLAIM. Its predecessor recomputed entitlement as `tasks * rate` from
    /// a fixed origin, so raising the rate re-granted work already minted against. Same defect as an
    /// accrual index recomputed from deployment; this is the shape that cannot have it.
    function test_aLaterRateChangeDoesNotRepriceWhatWasAlreadyClaimed() public {
        ParameterizedVault governed = new ParameterizedVault(
            address(collateral), address(0), WORK_ORACLE_SENTINEL, address(primary), address(health), spot
        );
        SeedableWorkOracle w = SeedableWorkOracle(address(governed.oracle()));
        Parameters params = governed.parameters();
        _setWage(params, RATE);

        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        w.seed(uint256(root));
        w.recordRoot();
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        uint256 atOldRate = w.claim(AGENT_A, 10, 10, proofA, root);

        _setWage(params, RATE * 2);

        assertEq(atOldRate, 10 * RATE);
        assertEq(w.mintingRights(CONTROLLER_A), atOldRate, "a rate rise cannot reprice a past claim");
        assertEq(w.wage(), RATE * 2, "but it does apply to the next one");
    }

    /// @dev Final panel audit (governance, info). A superseded oracle kept reading the vault's wage and
    /// accepting claims the vault never reads. It refuses them now. The replacement is built directly for
    /// the vault, the route Parameters documents (WorkOracleFactory.create binds the oracle to its caller).
    function test_aSupersededOracleRefusesClaims() public {
        _setWage(governance, 0);
        SwarmWorkOracle successor = new SwarmWorkOracle(address(attestedVault), 1 days);
        vm.prank(APPROVED_OPERATOR);
        governance.proposeWorkOracle(address(successor));
        vm.warp(governance.pendingEta());
        governance.applyPending();
        _refreshEthUsd();
        assertEq(address(attestedVault.oracle()), address(successor));
        _setWage(governance, RATE);
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        vm.expectRevert(SwarmWorkOracle.NotTheVaultsOracle.selector);
        work.claim(AGENT_A, 10, 10, proofA, root);
    }

    /// @dev Sweep panel audit (governance, low). "Nothing to carry over" was keyed on totalEarned alone, so a
    /// replacement between a claim and its mint stranded rights priced at the old wage. A successor without
    /// predecessor() is refused once anything has been CREDITED.
    function test_aReplacementAfterAClaimMustCarryAPredecessor() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        work.claim(AGENT_A, 10, 10, proofA, root);
        assertEq(work.totalCredited(), 10 * RATE);
        assertEq(attestedVault.totalEarned(), 0, "claimed, not minted");
        _setWage(governance, 0);
        SwarmWorkOracle successor = new SwarmWorkOracle(address(attestedVault), 1 days);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.InvalidWorkOracle.selector);
        governance.proposeWorkOracle(address(successor));
    }

    // --- minting from work is off at launch -------------------------------------------------------

    /// @dev WAGE_WAD ships as zero. A claim then would mark the agent's tasks credited for nothing and
    /// they could never earn once minting is switched on, so it is refused, and the tasks stay whole.
    function test_atTheLaunchWageClaimsAreRefusedAndTheTasksStayClaimable() public {
        assertEq(WAGE_WAD, 0, "minting from work ships switched off");
        ParameterizedVault fresh = new ParameterizedVault(
            address(collateral), address(0), WORK_ORACLE_SENTINEL, address(primary), address(health), spot
        );
        SeedableWorkOracle w = SeedableWorkOracle(address(fresh.oracle()));
        Parameters params = fresh.parameters();
        assertEq(w.wage(), 0);

        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        w.seed(uint256(root));
        w.recordRoot();
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        vm.expectRevert(SwarmWorkOracle.WorkMintingOff.selector);
        w.claim(AGENT_A, 10, 10, proofA, root);
        assertEq(w.creditedTasks(AGENT_A), 0, "nothing was marked as credited");

        _setWage(params, RATE);
        vm.prank(CONTROLLER_A);
        assertEq(w.claim(AGENT_A, 10, 10, proofA, root), 10 * RATE, "every task still earns once switched on");
    }

    // --- consumption ------------------------------------------------------------------------------

    function test_onlyTheVaultMayConsumeAndNotBeyondWhatWasClaimed() public {
        (bytes32 root, bytes32[] memory proofA,) = _tree(AGENT_A, 10, 10, AGENT_B, 20, 20);
        _accept(root);
        _controls(AGENT_A, CONTROLLER_A, true);
        vm.prank(CONTROLLER_A);
        uint256 rights = work.claim(AGENT_A, 10, 10, proofA, root);

        vm.prank(STRANGER);
        vm.expectRevert(SwarmWorkOracle.Unauthorized.selector);
        work.consumeRights(CONTROLLER_A, 1);

        vm.prank(address(attestedVault));
        vm.expectRevert(SwarmWorkOracle.InsufficientRights.selector);
        work.consumeRights(CONTROLLER_A, rights + 1);

        vm.prank(address(attestedVault));
        work.consumeRights(CONTROLLER_A, rights);
        assertEq(work.mintingRights(CONTROLLER_A), 0);
    }

    function test_thereIsNoGrantRightsAndNoPinnedClaimant() public {
        (bool ok,) = address(work).call(abi.encodeWithSignature("grantRights(address,uint256)", CONTROLLER_A, 1e18));
        assertFalse(ok, "the faucet's entry point does not exist");
        (ok,) = address(work).call(abi.encodeWithSignature("CLAIMANT()"));
        assertFalse(ok, "and no address is pinned in source");
    }

    // --- helpers ----------------------------------------------------------------------------------

    /// @dev A two-leaf StandardMerkleTree: double-hashed leaves, sorted-pair parent. Small enough to
    /// compute by hand, which is the point — the encoding has to match the upstream receipt exactly.
    /// @dev `accepted` and `cumulative` are SEPARATE on purpose: the daily count and the all-time
    /// count differ for any agent that worked before, and a helper that conflated them hid a wrong
    /// leaf behind a passing proof.
    function _tree(uint256 idA, uint32 acceptedA, uint64 cumA, uint256 idB, uint32 acceptedB, uint64 cumB)
        private
        pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(idA, acceptedA, cumA))));
        bytes32 b = keccak256(bytes.concat(keccak256(abi.encode(idB, acceptedB, cumB))));
        root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        proofA = new bytes32[](1);
        proofA[0] = b;
        proofB = new bytes32[](1);
        proofB[0] = a;
    }

    function _accept(bytes32 root) private {
        work.seed(uint256(root));
        work.recordRoot();
    }

    function _controls(uint256 agentId, address who, bool answer) private {
        vm.mockCall(
            ERC8004_ADAPTER,
            abi.encodeWithSignature("isController(uint256,address)", agentId, who),
            abi.encode(answer)
        );
    }
}
