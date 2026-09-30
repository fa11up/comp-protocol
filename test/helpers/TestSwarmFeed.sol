// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";

/// @dev Controllable offline feed for isolating vault transitions and stale-feed failures.
contract TestSwarmFeed is ISwarmFeed {
    uint256 private value;
    uint64 private updatedAt;
    bool private stale;

    constructor(uint256 initialValue) {
        setValue(initialValue);
    }

    function setValue(uint256 nextValue) public {
        value = nextValue;
        updatedAt = uint64(block.timestamp);
    }

    function setStale(bool nextStale) external {
        stale = nextStale;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external view returns (bool) {
        return stale;
    }
}
