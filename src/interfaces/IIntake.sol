// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The members of the swarm's on-chain Intake (Identity-md/protocol PR #66) that OracleAsker uses.
/// @dev `request` forwards the payment to the Intake's `payTo` and records where the result goes. When
/// the work ends, the plane's writer calls the named callback once, with a fixed gas stipend, passing
/// `abi.encode(requestId, attestation, signature)` for an `oracle.request`.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function priceOf(bytes32 action, address asset) external view returns (uint256 amount);
}
