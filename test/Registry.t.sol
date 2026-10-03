// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Governed} from "../src/Governed.sol";
import {Registry} from "../src/Registry.sol";
import {Treasury} from "../src/Treasury.sol";
import {APPROVED_OPERATOR, ATTESTATION_RELAYER} from "../src/DeploymentConfig.sol";

/// @notice The replaceable counterparties, and the line between them and the ones that are custody.
contract RegistryTest is Test {
    address private constant STRANGER = address(0x5747);
    address private constant WORK_ORACLE = address(0x404AC1E);
    address private constant NEW_RELAYER = address(0x3E14);

    Registry private registry;
    Treasury private treasury;

    function setUp() public {
        vm.warp(10 days);
        treasury = new Treasury();
        registry = new Registry(address(treasury), WORK_ORACLE);
    }

    function _propose(address relayer_, address treasury_, address workOracle_) private {
        vm.prank(APPROVED_OPERATOR);
        registry.propose(Registry.Addresses(relayer_, treasury_, workOracle_));
    }

    /// @dev The registry agrees with the feeds at deployment, so any divergence later is a decision
    /// someone made rather than a mismatch nobody chose.
    function test_itStartsWhereTheCompiledConstantsAre() public view {
        assertEq(registry.relayer(), ATTESTATION_RELAYER);
        assertEq(registry.treasury(), address(treasury));
        assertEq(registry.workOracle(), WORK_ORACLE);
    }

    function test_aReplacementWaitsOutTheSameDelay() public {
        _propose(NEW_RELAYER, address(treasury), WORK_ORACLE);
        assertEq(registry.relayer(), ATTESTATION_RELAYER, "unchanged for the whole window");

        vm.warp(block.timestamp + registry.TIMELOCK() - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, registry.pendingEta()));
        registry.applyPending();

        vm.warp(block.timestamp + 1);
        vm.prank(STRANGER);
        registry.applyPending();
        assertEq(registry.relayer(), NEW_RELAYER);
    }

    function test_thePendingSetIsPublicWhileItWaits() public {
        _propose(NEW_RELAYER, address(treasury), WORK_ORACLE);
        (Registry.Addresses memory next, uint256 eta) = registry.pendingSet();
        assertEq(next.relayer, NEW_RELAYER);
        assertEq(eta, block.timestamp + registry.TIMELOCK());
    }

    function test_onlyTheGovernorMayProposeOrCancel() public {
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        registry.propose(Registry.Addresses(NEW_RELAYER, address(treasury), WORK_ORACLE));

        _propose(NEW_RELAYER, address(treasury), WORK_ORACLE);
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        registry.cancel();

        vm.prank(APPROVED_OPERATOR);
        registry.cancel();
        assertEq(registry.relayer(), ATTESTATION_RELAYER);
    }

    /// @dev A zero in any of the three would silently disable the mechanism it names — a relay
    /// nothing can reach, revenue burned, a work oracle that answers nothing.
    function test_noneOfThemMayBeZero() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.propose(Registry.Addresses(address(0), address(treasury), WORK_ORACLE));
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.propose(Registry.Addresses(NEW_RELAYER, address(0), WORK_ORACLE));
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.propose(Registry.Addresses(NEW_RELAYER, address(treasury), address(0)));
        vm.stopPrank();

        vm.expectRevert(Registry.ZeroAddress.selector);
        new Registry(address(0), WORK_ORACLE);
        vm.expectRevert(Registry.ZeroAddress.selector);
        new Registry(address(treasury), address(0));
    }

    function test_oneProposalAtATime() public {
        _propose(NEW_RELAYER, address(treasury), WORK_ORACLE);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Governed.ProposalPending.selector);
        registry.propose(Registry.Addresses(NEW_RELAYER, address(treasury), WORK_ORACLE));
    }

    /// @dev The registry holds nothing and names nothing that prices collateral. There is no
    /// function here that could point the protocol at a different attester or feed, which is the
    /// whole reason those three live in the vault's immutables instead.
    function test_itHasNoReachIntoThePriceOrTheSigner() public view {
        assertEq(address(registry).balance, 0);
        Registry.Addresses memory live = registry.current();
        assertEq(live.relayer, ATTESTATION_RELAYER);
        assertEq(live.treasury, address(treasury));
        assertEq(live.workOracle, WORK_ORACLE);
    }
}
