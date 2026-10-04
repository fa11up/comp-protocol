// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwarmRelay} from "../src/SwarmRelay.sol";
import {Treasury} from "../src/Treasury.sol";
import {WorkOracleFactory} from "../src/WorkOracleFactory.sol";
import {APPROVED_OPERATOR, ATTESTATION_RELAYER, FEE_RECIPIENT, WORK_ORACLE_FACTORY} from "../src/DeploymentConfig.sol";

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
        // Third of the same kind: a contract whose address another contract reads as a source
        // constant, so it cannot be deployed by whatever consumes it. SwarmWorkOracle's creation
        // code is 16,464 bytes and would put ParameterizedVault's initcode over the EIP-3860 limit,
        // so the vault asks this factory for one instead of embedding it.
        WorkOracleFactory workOracleFactory = new WorkOracleFactory();
        vm.stopBroadcast();

        console2.log("SwarmRelay (bundling)", address(relay));
        console2.log("Treasury             ", address(treasury));
        console2.log("WorkOracleFactory    ", address(workOracleFactory));
        console2.log("broadcast from       ", operator);

        verify(relay, treasury, workOracleFactory);

        console2.log("\nNow edit src/DeploymentConfig.sol:");
        console2.log("  ATTESTATION_RELAYER =", address(relay));
        console2.log("  FEE_RECIPIENT       =", address(treasury));
        console2.log("  WORK_ORACLE_FACTORY =", address(workOracleFactory));
        console2.log("currently:");
        console2.log("  ATTESTATION_RELAYER =", ATTESTATION_RELAYER);
        console2.log("  FEE_RECIPIENT       =", FEE_RECIPIENT);
        console2.log("  WORK_ORACLE_FACTORY =", WORK_ORACLE_FACTORY);
    }

    /// @dev Relay and factory are permissionless. Only the Treasury carries custody authority.
    function verify(SwarmRelay relay, Treasury treasury, WorkOracleFactory workOracleFactory)
        internal
        view
    {
        // Deliberately NOT asserting a zero ETH balance: anyone can send ether to an address before
        // it has code, and this fork already had some at the relay's counterfactual address. It is
        // harmless — the relay has no payable function and no way to spend ether — and an assertion
        // that a stranger can fail at will is worse than no assertion.
        require(address(relay).code.length != 0, "relay: no code");
        require(address(treasury).code.length != 0, "treasury: no code");
        require(address(workOracleFactory).code.length != 0, "work oracle factory: no code");
        require(treasury.withdrawer() == APPROVED_OPERATOR, "treasury: wrong withdrawer");
        // `treasury.vault()` is `msg.sender` at construction, which for a standalone deploy is THIS
        // SCRIPT CONTRACT and never the broadcaster — so an assertion that it equals `operator`
        // cannot hold and made this script revert its own dry run. (Shipped that way in round 5 and
        // accepted despite an acceptance criterion requiring the dry run to pass.)
        //
        // The property actually worth asserting is the one below, and it is stronger: whatever the
        // creator turns out to be, it exposes no `parameters()`, so `registrar()` resolves to zero and
        // this Treasury's reserve register can never be written. A standalone Treasury is a revenue
        // sink with a frozen register, which is exactly what FEE_RECIPIENT should name.
        require(treasury.registrar() == address(0), "treasury: standalone reserve register must be frozen");
    }
}
