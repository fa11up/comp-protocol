// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";

/// @dev A distinct spot address for legacy tests that exercise a single market price.
/// New divergence tests use independently controlled feeds instead.
contract MirroredSwarmFeed is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(address primary_) {
        primary = ISwarmFeed(primary_);
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}
