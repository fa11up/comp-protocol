// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "src/SwarmFeed.sol";

/// @notice Test-only concrete SwarmFeed whose authority and policy are supplied per test.
/// @dev SwarmFeed is abstract and PriceFeed/NhiFeed deliberately accept no authority arguments, so
/// the mechanics suite needs a leaf it can parameterise: it needs an attester whose key it holds,
/// which a pinned deployment artifact will never provide.
/// Nothing under src/ or script/ references this contract, so it is absent from every deployment —
/// which is the point. It is not a loophole in the pinning: a deployer cannot choose WHICH contract
/// a pinned script deploys, and DeployProtocol.verify() reads the authorities back off chain regardless.
contract ConfigurableSwarmFeed is SwarmFeed {
    constructor(
        address attester_,
        address relayer_,
        uint256 attestationChainId_,
        uint8 attestationAnswerType_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    )
        SwarmFeed(attester_, relayer_, attestationChainId_, attestationAnswerType_, maxAge_, maxDeviationBps_)
    {}

    /// @notice Put a value in without an attestation. Test-only; see SwarmFeed._accept.
    /// @dev This is what replaced `report()` in the suite. It is NOT the reporter fallback in
    /// disguise: there is no allowlist and no key, because there is no deployed contract on which it
    /// exists — nothing under src/ or script/ inherits from this.
    function seed(uint256 value) external {
        _accept(value, uint64(block.timestamp));
    }
}
