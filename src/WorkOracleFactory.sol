// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmWorkOracle} from "./SwarmWorkOracle.sol";

/// @notice Deploys a `SwarmWorkOracle` on behalf of the vault that will consume it.
/// @dev THIS EXISTS FOR A SIZE LIMIT, and the measurement is the argument. `SwarmWorkOracle` carries
/// SwarmFeed plus a 3.5 KB question document, so its creation code is 16,464 bytes. A contract that
/// creates another embeds that creation code in its OWN initcode, and `ParameterizedVault` is already
/// within about 2 KB of the 49,152 EIP-3860 allows — so a vault that created its own work oracle would be
/// 52,880 bytes of initcode and could not be deployed at all. Holding the creation code here instead
/// costs the vault one external call.
///
/// It is not an authority and holds nothing. `create` is permissionless because there is nothing to
/// gate: the oracle it returns names its CALLER as the only address that may consume rights, so an
/// oracle created for someone else's vault is useless to the caller, and the vault verifies the link
/// before accepting it.
///
/// WHY NOT A BINDING TRANSACTION. The alternative is to deploy the oracle first and tell it its vault
/// afterwards, which is exactly the shape two MEDIUM findings of audit c71449d1 killed for
/// `Parameters`: a separate binding transaction can be front-run, and a mid-construction callback
/// cannot verify its caller. CREATE2 precomputation does not help either, because the vault's
/// deterministic address depends on its constructor arguments, which would include the oracle's
/// address, which depends on the vault's — a genuine cycle. A factory has no cycle: the oracle learns
/// its vault from the caller, and the caller is mid-construction, which the oracle can check.
///
/// DEPLOY ORDER MATTERS, the same way it does for `ATTESTATION_RELAYER`. This must exist before a
/// vault that asks for a real work oracle is deployed, and its address is a source constant.
contract WorkOracleFactory {
    event WorkOracleCreated(address indexed vault, address oracle);

    /// @notice Deploy a work oracle whose sole consumer is the caller.
    /// @param maxAge_ Seconds after which the feed's latest tally reads stale. Claims against an accepted
    /// root are NOT gated on it (launch audit, deferred with minting from work: see WAGE_WAD).
    function create(uint256 maxAge_) external returns (SwarmWorkOracle oracle) {
        oracle = new SwarmWorkOracle(msg.sender, maxAge_);
        emit WorkOracleCreated(msg.sender, address(oracle));
    }
}
