// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {
    ATTESTATION_RELAYER,
    CHAINLINK_ETH_USD,
    ETH_USD_MAX_AGE,
    TREASURY_FACTORY
} from "../src/DeploymentConfig.sol";

/// @notice Refuse to deploy against addresses that do not exist on this chain.
/// @dev Every one of these is a source constant read by immutable contracts, and a wrong one fails
/// SILENTLY: feeds that nobody can ever submit to, a USD leg that reads stale forever, a vault that
/// cannot be built. The constants as committed name Sepolia contracts, so compiling them unchanged for
/// mainnet is exactly this mistake (launch audit, oracle panel, four specialists). Checked here, before
/// a single transaction is broadcast, so the deploy fails loudly instead.
abstract contract DeployPreflight {
    function _preflight() internal view {
        require(ATTESTATION_RELAYER.code.length != 0, "preflight: ATTESTATION_RELAYER has no code on this chain");
        require(TREASURY_FACTORY.code.length != 0, "preflight: TREASURY_FACTORY has no code on this chain");
        require(CHAINLINK_ETH_USD.code.length != 0, "preflight: CHAINLINK_ETH_USD has no code on this chain");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(CHAINLINK_ETH_USD).latestRoundData();
        require(answer > 0, "preflight: CHAINLINK_ETH_USD answers no price");
        require(block.timestamp - updatedAt <= ETH_USD_MAX_AGE, "preflight: CHAINLINK_ETH_USD is stale");
    }
}
