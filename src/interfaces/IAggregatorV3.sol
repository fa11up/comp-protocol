// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The two Chainlink AggregatorV3 reads UsdPriceFeed needs. Declared here rather than vendored:
/// this repository's dependency checkout carries only what it uses.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
