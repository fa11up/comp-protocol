// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A numeric oracle feed; values use 18 decimals and timestamps are Unix seconds.
interface ISwarmFeed {
    function latestValue() external view returns (uint256 value, uint64 updatedAt);

    /// @notice True before the first accepted value, or once its immutable maximum age has elapsed.
    function isStale() external view returns (bool);

    /// @notice Immutable maximum accepted age of the latest value, in seconds.
    function maxAge() external view returns (uint256);
}
