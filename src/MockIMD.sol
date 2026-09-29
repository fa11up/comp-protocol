// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Sepolia collateral faucet. Starts with zero supply and has no configured supply cap.
/// @dev Only the deploying account can mint; that testnet privilege is permanent and nontransferable.
contract MockIMD is ERC20 {
    error Unauthorized();

    address public immutable deployer;

    constructor() ERC20("Identity MD", "IMD") {
        deployer = msg.sender;
    }

    function mint(address account, uint256 amount) external {
        if (msg.sender != deployer) revert Unauthorized();
        _mint(account, amount);
    }
}
