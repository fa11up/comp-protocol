// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The three ERC-4626 members the vault uses to accept a share token as collateral.
/// @dev Deliberately minimal. The VAULT deposits and reads the rate and never withdraws: sIMD's one-block
/// hold (`SameBlockRedeem`) lives only on its withdraw path and travels with the shares, so a vault
/// withdraw would inherit the hold of whoever last moved them. The TREASURY withdraws, only to fund the
/// oracle budget, and only from shares it has held since an earlier block.
interface IShareVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}
