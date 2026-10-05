// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ERC-4626 members of a share token (sIMD) that this protocol and its interface touch.
/// @dev Deliberately minimal. The VAULT deposits and reads the rate and never withdraws: sIMD's one-block
/// hold (`SameBlockRedeem`) lives only on its withdraw path and travels with the shares, so a vault
/// withdraw would inherit the hold of whoever last moved them. The TREASURY withdraws, only to fund the
/// oracle budget, and only from shares it has held since an earlier block. `redeem` is listed for the
/// people who hold sIMD paid out by the vault: unstaking is their call to the staking vault, never ours.
interface IShareVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
