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

/// @notice Concrete SwarmFeed artifact for network health.
/// @dev Authority and attestation policy come from DeploymentConfig, not from the deployer; see the
/// pinning note there. A composite NHI question now exists and attests, so unlike the 519 release
/// the attestation path here is live and used, not merely present.
contract NhiFeed is SwarmFeed {
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
