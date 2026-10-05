// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwarmRelay} from "../src/SwarmRelay.sol";
import {WorkOracleFactory} from "../src/WorkOracleFactory.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";
import {ATTESTATION_RELAYER, WORK_ORACLE_FACTORY, TREASURY_FACTORY} from "../src/DeploymentConfig.sol";

/// @notice The contracts that MUST exist before anything else is compiled.
/// @dev Each is read as a source constant by contracts that are immutable once deployed, so none can
/// be deployed by whatever consumes it — the bytecode has to already hold the address.
///
///   SwarmRelay        -> ATTESTATION_RELAYER, read by all three feeds.
///   WorkOracleFactory -> WORK_ORACLE_FACTORY, asked by the vault for its work oracle.
///   TreasuryFactory   -> TREASURY_FACTORY, asked by the vault for its Treasury.
///
/// The two factories exist for EIP-3860: a vault that created its work oracle or its Treasury with
/// `new` would carry their creation code in its own initcode and could not be deployed. There is no
/// standalone Treasury: ParameterizedVault pays the one it creates, never FEE_RECIPIENT.
///
/// After running this, write the addresses into src/DeploymentConfig.sol, re-run the suite, and only
/// then deploy anything that reads them.
contract DeployPrereqs is Script {
    function run() external {
        address operator = vm.envAddress("OPERATOR");

        vm.startBroadcast();
        SwarmRelay relay = new SwarmRelay();
        WorkOracleFactory workOracleFactory = new WorkOracleFactory();
        TreasuryFactory treasuryFactory = new TreasuryFactory();
        vm.stopBroadcast();

        console2.log("SwarmRelay (bundling)", address(relay));
        console2.log("WorkOracleFactory    ", address(workOracleFactory));
        console2.log("TreasuryFactory      ", address(treasuryFactory));
        console2.log("broadcast from       ", operator);

        // All three are permissionless and hold nothing; existing code is the property to check.
        // Deliberately NOT asserting a zero ETH balance: anyone can send ether to an address before
        // it has code, and that is harmless for contracts with no way to spend it.
        require(address(relay).code.length != 0, "relay: no code");
        require(address(workOracleFactory).code.length != 0, "work oracle factory: no code");
        require(address(treasuryFactory).code.length != 0, "treasury factory: no code");

        console2.log("\nNow edit src/DeploymentConfig.sol:");
        console2.log("  ATTESTATION_RELAYER =", address(relay));
        console2.log("  WORK_ORACLE_FACTORY =", address(workOracleFactory));
        console2.log("  TREASURY_FACTORY    =", address(treasuryFactory));
        console2.log("currently:");
        console2.log("  ATTESTATION_RELAYER =", ATTESTATION_RELAYER);
        console2.log("  WORK_ORACLE_FACTORY =", WORK_ORACLE_FACTORY);
        console2.log("  TREASURY_FACTORY    =", TREASURY_FACTORY);
    }
}
