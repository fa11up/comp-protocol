// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Consumable work credits, denominated in imdUSD minor units (18 decimals).
/// @dev Implementations must restrict consumption to their associated vault.
interface IWorkOracle {
    function mintingRights(address account) external view returns (uint256);

    function consumeRights(address account, uint256 amount) external;
}
