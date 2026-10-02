// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "src/SwarmFeed.sol";

/// @notice Test-only concrete SwarmFeed whose authority and policy are supplied per test.
/// @dev SwarmFeed is abstract and PriceFeed/NhiFeed deliberately accept no authority arguments, so
/// the mechanics suite needs a leaf it can parameterise: it has to install reporters it can prank
/// and an attester whose key it holds, neither of which a pinned deployment artifact will ever do.
/// Nothing under src/ or script/ references this contract, so it is absent from every deployment —
/// which is the point. It is not a loophole in the pinning: a deployer cannot choose WHICH contract
/// a pinned script deploys, and DeployComp.verify() reads the authorities back off chain regardless.
contract ConfigurableSwarmFeed is SwarmFeed {
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
