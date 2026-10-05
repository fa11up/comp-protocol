// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmWorkOracle} from "src/SwarmWorkOracle.sol";
import {WorkOracleFactory} from "src/WorkOracleFactory.sol";

/// @notice Who may create a SwarmWorkOracle naming a vault that has no code yet.
/// @dev It used to be WORK_ORACLE_FACTORY by address, which put the factory's own address inside the
/// factory's initcode: no CREATE2 address could satisfy that, and DeployMainnet's plan never converged
/// (2026-10-05). Now any contract may — the factory passing its mid-construction caller is the case
/// that matters — and only an account with no code is refused. What actually protects a vault is its
/// own check (`CDPVault._validateOracle`: the oracle's `vault()` must be the vault itself).
/// The self-reference itself is caught by deploy/mainnet/plan.py, which exits "did not converge".
contract WorkOracleCreatorTest is Test {
    address private constant NOT_YET_DEPLOYED = address(0xFA17);

    function test_anAccountWithNoCodeCannotNameACodelessVault() public {
        vm.prank(address(0xE0A));
        vm.expectRevert(SwarmWorkOracle.InvalidVault.selector);
        new SwarmWorkOracle(NOT_YET_DEPLOYED, 1 days);
    }

    function test_aContractMayAndTheOracleNamesExactlyThatVault() public {
        SwarmWorkOracle oracle = new SwarmWorkOracle(NOT_YET_DEPLOYED, 1 days);
        assertEq(oracle.vault(), NOT_YET_DEPLOYED);
    }

    function test_theFactoryNamesItsCallerWhateverAddressItLivesAt() public {
        WorkOracleFactory factory = new WorkOracleFactory();
        vm.prank(NOT_YET_DEPLOYED);
        assertEq(factory.create(1 days).vault(), NOT_YET_DEPLOYED);
    }
}
