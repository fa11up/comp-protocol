// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply imdUSD Launch (CPL) token for the project's launch distribution.
/// @dev Separate from the vault's elastic-supply ImdUSD. All 1 billion tokens (18 decimals)
/// are minted to the actual deployer, including a deploying factory. No post-construction mint,
/// burn, owner, pause, fee, blocklist, or upgrade functions exist.
contract LaunchToken is ERC20 {
    constructor() ERC20("COMP Launch", "CPL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
