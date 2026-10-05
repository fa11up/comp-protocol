// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of an IdentityMD launch factory's `PoolFees` the Treasury uses. Both the project
/// and the hook factories inherit it: a launch pool's LP fees are split between the launch's requester
/// and the network, and only the current requester may hand its share to another address.
interface ILaunchFeeShare {
    function setRequester(uint64 launchNumber, address next) external;
}
