// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @dev The one view a vault must expose so this token can verify the reciprocal link before locking it.
interface IStablecoinConsumer {
    function stablecoin() external view returns (address);
}

/// @notice Elastic-supply imdUSD; starts with zero supply and has no configured supply cap.
/// @dev Two ways to register the single minter/burner, both irreversible:
/// - `ImdUSD(address(0))`: the workflow's approved operator later calls `setVault` once.
/// - `ImdUSD(vault)`: the link is fixed at construction. A CDPVault creating this token in its own
///   constructor passes itself; any other target must already have code and report this token.
/// There are no ownership, upgrade, pause, rescue, or role-management functions.
contract ImdUSD is ERC20 {
    error Unauthorized();
    error AlreadyInitialized();
    error InvalidVault();

    event VaultSet(address indexed vault);

    address public vault;
    address private _initializer;

    /// @param vault_ Zero for deferred one-time setup, or the CDPVault that will mint and burn imdUSD.
    constructor(address vault_) ERC20("imdUSD", "imdUSD") {
        if (vault_ == address(0)) {
            _initializer = APPROVED_OPERATOR;
        } else if (vault_ == msg.sender) {
            // The creating vault is still under construction, so it has no code and cannot be probed yet.
            vault = vault_;
            emit VaultSet(vault_);
        } else {
            _setVault(vault_);
        }
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    /// @notice Irreversibly register CDPVault; callable once by the workflow's approved operator.
    /// @dev Rejects, without consuming initialization authority, any target that lacks code or whose
    /// `stablecoin()` is not this token.
    function setVault(address vault_) external {
        if (_initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != _initializer) revert Unauthorized();
        _setVault(vault_);
        delete _initializer;
    }

    function mint(address account, uint256 amount) external onlyVault {
        _mint(account, amount);
    }

    /// @notice Burn from an account as instructed by the registered vault, without an ERC-20 allowance.
    /// @dev CDPVault only burns the caller's tokens during repayment, liquidation or redemption.
    function burn(address account, uint256 amount) external onlyVault {
        _burn(account, amount);
    }

    function _setVault(address vault_) private {
        if (vault_.code.length == 0) revert InvalidVault();
        (bool ok, bytes memory data) = vault_.staticcall(abi.encodeCall(IStablecoinConsumer.stablecoin, ()));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != uint256(uint160(address(this)))) {
            revert InvalidVault();
        }
        vault = vault_;
        emit VaultSet(vault_);
    }
}
