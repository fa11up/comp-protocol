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

/// @notice Concrete SwarmFeed artifact for the collateral price.
/// @dev Who may relay, who may report, who signs, and what payload shape is accepted all come from
/// DeploymentConfig — see the pinning note there for why they are not constructor arguments. The two
/// remaining arguments are the only values that legitimately differ between feeds: a price moves far
/// more often than a health index, so each needs its own freshness and deviation bound.
contract PriceFeed is SwarmFeed {
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
