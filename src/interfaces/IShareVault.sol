// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The three ERC-4626 members the vault uses to accept a share token as collateral.
/// @dev Deliberately minimal: the vault deposits and reads the rate, and NEVER redeems. sIMD's
/// one-block hold (`SameBlockRedeem`) lives only in its withdraw path, and it travels with the shares,
/// so a redeem path here would inherit the hold of whoever last moved them.
interface IShareVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
