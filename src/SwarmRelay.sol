// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "./SwarmFeed.sol";

/// @notice Permissionless relayer for swarm attestations, and the only address the feeds accept.
/// @dev A feed pins a single relayer because `questionHash` binds a moving block window and so cannot
/// say WHICH question an attestation answers — SwarmFeed.submitAttestation documents that a nonzero
/// relayer is what covers the unseeded first value and stale re-anchors. Pinning an EOA buys that
/// guarantee at the cost of liveness: one key, held by one party, has to be online for the protocol
/// to see a price.
///
/// Pinning this contract instead keeps the guarantee and drops the key. Anyone may call it, so the
/// trust is the same as a zero relayer, and in exchange two things become possible that an EOA
/// cannot do:
///
///   - several feeds update in ONE transaction, so the price and the health index can never be read
///     a block apart, which is what the vault's divergence guard compares;
///   - a keeper can bundle an update with the action it enables, removing the race where someone
///     else liquidates between your update and your call.
///
/// This contract holds nothing, approves nothing and has no owner. It cannot report, cannot seed a
/// feed, and cannot alter an attestation: every guard the feed applies — attester signature, replay,
/// freshness, panel floors, deviation — is untouched and still runs on the forwarded call. The worst
/// a caller can do is relay a valid attestation the feed would have accepted anyway, or waste gas.
contract SwarmRelay {
    /// @notice Forward one attestation to one feed.
    function relay(SwarmFeed feed, SwarmFeed.OracleAttestation calldata attestation, bytes calldata signature)
        external
    {
        feed.submitAttestation(attestation, signature);
    }

    /// @notice Forward several attestations in one transaction, each to its own feed.
    /// @dev All or nothing: a feed that refuses its attestation reverts the batch, so a caller never
    /// half-updates a set of feeds the vault compares against each other. Ordering is the caller's.
    function relayMany(
        SwarmFeed[] calldata feeds,
        SwarmFeed.OracleAttestation[] calldata attestations,
        bytes[] calldata signatures
    ) external {
        if (feeds.length != attestations.length || feeds.length != signatures.length) revert LengthMismatch();
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].submitAttestation(attestations[i], signatures[i]);
        }
    }

    error LengthMismatch();
}
