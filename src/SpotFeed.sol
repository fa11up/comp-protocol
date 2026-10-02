// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "./SwarmFeed.sol";
import {
    ORACLE_ATTESTER,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    FEED_REPORTER_0,
    FEED_REPORTER_1,
    FEED_REPORTER_2,
    FEED_QUORUM
} from "./DeploymentConfig.sol";

/// @notice Concrete SwarmFeed artifact for the point-in-time spot price.
/// @dev A third named artifact exists for one reason: a launch manifest identifies a deployment by
/// its contract name and has no alias field, so it cannot list the same artifact twice. CDPVault
/// needs a spot feed at an address distinct from the primary — `InvalidFeed` otherwise — and
/// deploying PriceFeed a second time is unrepresentable in launch.json. That is what parked the
/// launch on workflow be84ca8c, and it is the same constraint that parked round 1.
///
/// Behaviourally this is PriceFeed: same authority, same attestation policy, same guards. Only the
/// role differs. The vault prices off the primary's window average and uses this one solely as a
/// divergence bound, so it is fed point-in-time values and wants a tighter freshness window than a
/// feed whose value is an average over one.
contract SpotFeed is SwarmFeed {
    constructor(uint256 maxAge_, uint256 maxDeviationBps_)
        SwarmFeed(
            ORACLE_ATTESTER,
            ATTESTATION_RELAYER,
            ATTESTATION_CHAIN_ID,
            ATTESTATION_ANSWER_TYPE,
            FEED_REPORTER_0,
            FEED_REPORTER_1,
            FEED_REPORTER_2,
            FEED_QUORUM,
            maxAge_,
            maxDeviationBps_
        )
    {}
}
