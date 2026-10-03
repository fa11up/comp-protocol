// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwarmRelay} from "../src/SwarmRelay.sol";
import {Treasury} from "../src/Treasury.sol";
import {APPROVED_OPERATOR, ATTESTATION_RELAYER, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";

/// @notice The two contracts that MUST exist before anything else is compiled.
/// @dev Both are read as source constants by contracts that are immutable once deployed, so neither
/// can be deployed by the same launch that consumes it — the bytecode has to already hold the
/// address. This is the same ordering that made the first SwarmRelay a separate deployment, and
/// getting it wrong is how an increment ships code that the freshly deployed feeds will not accept.
///
///   SwarmRelay -> ATTESTATION_RELAYER, read by all three feeds.
///   Treasury   -> FEE_RECIPIENT, read by CDPVault for both the bonus share and the stability fee.
///
/// After running this, write both addresses into src/DeploymentConfig.sol, re-run the suite, and only
/// then pin the commit as a build request's baseCommit.
contract DeployPrereqs is Script {
    function run() external {
        address operator = vm.envAddress("OPERATOR");

        vm.startBroadcast();
        SwarmRelay relay = new SwarmRelay();
        Treasury treasury = new Treasury();
        vm.stopBroadcast();

        console2.log("SwarmRelay (bundling)", address(relay));
        console2.log("Treasury             ", address(treasury));
        console2.log("broadcast from       ", operator);

        // Deliberately NOT asserting a zero ETH balance: anyone can send ether to an address before
        // it has code, and this fork already had some at the relay's counterfactual address. It is
        // harmless — the relay has no payable function and no way to spend ether — and an assertion
        // that a stranger can fail at will is worse than no assertion.
        require(address(relay).code.length != 0, "relay: no code");
        require(address(treasury).code.length != 0, "treasury: no code");
        require(treasury.withdrawer() == APPROVED_OPERATOR, "treasury: wrong withdrawer");

        console2.log("\nNow edit src/DeploymentConfig.sol:");
        console2.log("  ATTESTATION_RELAYER =", address(relay));
        console2.log("  FEE_RECIPIENT       =", address(treasury));
        console2.log("currently:");
        console2.log("  ATTESTATION_RELAYER =", ATTESTATION_RELAYER);
        console2.log("  FEE_RECIPIENT       =", FEE_RECIPIENT);
    }
}
