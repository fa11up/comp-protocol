// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Sepolia collateral faucet. Starts with zero supply and has no configured supply cap.
/// @dev Only the workflow's approved operator can mint; this privilege is permanent and nontransferable.
contract MockIMD is ERC20 {
    error Unauthorized();

    /// @notice Workflow deployer/operator, independent of the factory that executes CREATE/CREATE2.
    address public immutable deployer;

    constructor() ERC20("Identity MD", "IMD") {
        deployer = APPROVED_OPERATOR;
    }

    function mint(address account, uint256 amount) external {
        if (msg.sender != deployer) revert Unauthorized();
        _mint(account, amount);
    }
}
