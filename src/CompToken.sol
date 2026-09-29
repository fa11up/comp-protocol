// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Elastic-supply COMP; starts with zero supply and has no configured supply cap.
/// @dev The workflow's approved operator registers CDPVault once, discarding its initialization authority.
/// There are no ownership, upgrade, pause, rescue, or role-management functions.
contract CompToken is ERC20 {
    error Unauthorized();
    error AlreadyInitialized();
    error InvalidVault();

    event VaultSet(address indexed vault);

    address public vault;
    address private _initializer;

    constructor() ERC20("Compute Money", "COMP") {
        _initializer = APPROVED_OPERATOR;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    /// @notice Irreversibly register CDPVault; callable once by the workflow's approved operator.
    function setVault(address vault_) external {
        if (_initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != _initializer) revert Unauthorized();
        if (vault_.code.length == 0) revert InvalidVault();
        vault = vault_;
        delete _initializer;
        emit VaultSet(vault_);
    }

    function mint(address account, uint256 amount) external onlyVault {
        _mint(account, amount);
    }

    /// @notice Burn from an account as instructed by the registered vault, without an ERC-20 allowance.
    /// @dev CDPVault only burns the caller's tokens during repayment or liquidation.
    function burn(address account, uint256 amount) external onlyVault {
        _burn(account, amount);
    }
}
