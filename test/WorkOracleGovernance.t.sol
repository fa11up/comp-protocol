// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {Parameters} from "src/Parameters.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @dev A replacement oracle that carries over its predecessor's history, which is what governance must
/// supply once anything has been minted from work.
contract SuccessorOracle {
    address public immutable vault;
    address public immutable predecessor;
    mapping(address => uint256) public mintingRights;

    constructor(address vault_, address predecessor_) {
        (vault, predecessor) = (vault_, predecessor_);
    }

    function grant(address account, uint256 amount) external {
        mintingRights[account] += amount;
    }

    function consumeRights(address account, uint256 amount) external {
        require(msg.sender == vault, "only the vault");
        mintingRights[account] -= amount;
    }
}

/// @notice The governed work-oracle slot (2026-10-05): integrating minting from work upstream must never
/// force a new vault, because the created oracle pins the WorkRegistry, the receipt schema and its leaf
/// encoding in bytecode. Replaceable behind the 48-hour delay, ONLY while the wage is zero, and — once
/// anything has been minted from work — only by an oracle naming the current one as its predecessor.
contract WorkOracleGovernanceTest is WorkBackingFixture {
    function _proposeOracle(address next) private {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeWorkOracle(next);
    }

    function test_opensOnTheOracleTheVaultCreated() public view {
        assertEq(parameters.workOracle(), address(0));
        assertEq(address(backedVault.oracle()), address(workOracle));
    }

    function test_aReplacementTakesOverEarnAfterTheDelay() public {
        _openDebt(1_000 ether);
        _warmBacking();
        MockWorkOracle next = new MockWorkOracle(address(backedVault));
        _proposeOracle(address(next));
        assertEq(address(backedVault.oracle()), address(workOracle), "nothing changes before the delay");
        _apply();
        assertEq(address(backedVault.oracle()), address(next));

        // Rights in the old oracle no longer count; rights in the new one do.
        vm.prank(WORKER);
        vm.expectRevert();
        backedVault.earn(1 ether);
        vm.prank(APPROVED_OPERATOR);
        next.grantRights(WORKER, 1 ether);
        _mintWork(WORKER, 1 ether);
        assertEq(next.mintingRights(WORKER), 0, "consumed in the replacement");
    }

    function test_refusedWhileMintingFromWorkIsOn() public {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeWage(0.5 ether);
        _apply();
        MockWorkOracle next = new MockWorkOracle(address(backedVault));
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.WorkMintingOn.selector);
        parameters.proposeWorkOracle(address(next));
    }

    function test_theReplacementMustServeThisVault() public {
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.InvalidWorkOracle.selector);
        parameters.proposeWorkOracle(address(0xC0DE1E55)); // no code
        MockWorkOracle elsewhere = new MockWorkOracle(address(this));
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.InvalidWorkOracle.selector);
        parameters.proposeWorkOracle(address(elsewhere));
    }

    function test_onlyTheGovernorProposes() public {
        MockWorkOracle next = new MockWorkOracle(address(backedVault));
        vm.expectRevert();
        parameters.proposeWorkOracle(address(next));
    }

    /// @dev Once work has been minted, the old oracle holds credited history; a fresh oracle would credit
    /// the same cumulative tallies again. Only a successor naming the current oracle is accepted, and
    /// going back to the created oracle (zero) is refused.
    function test_afterAnyMintingTheReplacementMustNameItsPredecessor() public {
        _openDebt(1_000 ether);
        _warmBacking();
        _mintWork(WORKER, 1 ether);
        assertGt(backedVault.totalEarned(), 0);

        MockWorkOracle fresh = new MockWorkOracle(address(backedVault)); // has no predecessor()
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert();
        parameters.proposeWorkOracle(address(fresh));

        SuccessorOracle stranger = new SuccessorOracle(address(backedVault), address(0xBEEF));
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.InvalidWorkOracle.selector);
        parameters.proposeWorkOracle(address(stranger));

        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Parameters.InvalidWorkOracle.selector);
        parameters.proposeWorkOracle(address(0));

        SuccessorOracle heir = new SuccessorOracle(address(backedVault), address(workOracle));
        _proposeOracle(address(heir));
        _apply();
        assertEq(address(backedVault.oracle()), address(heir));
    }

    /// @dev The rules are checked again when the change is applied: minting that started during the
    /// delay turns a fresh replacement into one that would double-credit, and it is refused.
    function test_applyRechecksTheRules() public {
        _openDebt(1_000 ether);
        _warmBacking();
        MockWorkOracle fresh = new MockWorkOracle(address(backedVault));
        _proposeOracle(address(fresh));
        _mintWork(WORKER, 1 ether); // minting begins inside the delay
        vm.warp(parameters.pendingEta());
        _refreshEthUsd();
        vm.expectRevert();
        parameters.applyPending();
    }
}
