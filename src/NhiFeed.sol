// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "./SwarmFeed.sol";

/// @notice Concrete SwarmFeed artifact for network health.
/// @dev No validated oracle question exists for NHI in this release; reporters alone supply its values.
/// The attestation path remains live but unused.
contract NhiFeed is SwarmFeed {
    constructor(
        address attester_,
        address relayer_,
        uint256 attestationChainId_,
        uint8 attestationAnswerType_,
        address reporter0_,
        address reporter1_,
        address reporter2_,
        uint8 quorum_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    )
        SwarmFeed(
            attester_,
            relayer_,
            attestationChainId_,
            attestationAnswerType_,
            reporter0_,
            reporter1_,
            reporter2_,
            quorum_,
            maxAge_,
            maxDeviationBps_
        )
    {}
}
