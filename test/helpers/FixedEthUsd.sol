// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice FORK REHEARSAL ONLY (deploy/mainnet/rehearse-fork.sh): an ETH/USD leg that always reads
/// fresh, etched over Chainlink on a fork whose clock is warped past its last real round. `answer` is
/// written into slot 0 with anvil_setStorageAt, because etched code carries no storage.
contract FixedEthUsd {
    int256 public answer;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
