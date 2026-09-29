// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Sepolia work-credit faucet, not a verifier of actual compute work.
/// @dev The workflow's approved operator permanently retains only the ability to add credits.
contract MockWorkOracle is IWorkOracle {
    error Unauthorized();
    error InvalidVault();
    error InvalidAccount();
    error ZeroAmount();
    error InsufficientRights();

    event RightsGranted(address indexed account, uint256 amount);
    event RightsConsumed(address indexed account, uint256 amount);

    /// @notice Workflow deployer/operator, independent of the factory that executes CREATE/CREATE2.
    address public immutable deployer;
    address public immutable vault;
    mapping(address account => uint256 amount) public override mintingRights;

    constructor(address vault_) {
        if (vault_.code.length == 0) revert InvalidVault();
        deployer = APPROVED_OPERATOR;
        vault = vault_;
    }

    function grantRights(address account, uint256 amount) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (account == address(0)) revert InvalidAccount();
        if (amount == 0) revert ZeroAmount();
        mintingRights[account] += amount;
        emit RightsGranted(account, amount);
    }

    function consumeRights(address account, uint256 amount) external override {
        if (msg.sender != vault) revert Unauthorized();
        if (account == address(0)) revert InvalidAccount();
        if (amount == 0) revert ZeroAmount();
        uint256 rights = mintingRights[account];
        if (rights < amount) revert InsufficientRights();
        mintingRights[account] = rights - amount;
        emit RightsConsumed(account, amount);
    }
}
