// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Treasury} from "./Treasury.sol";

/// @notice Deploys a `Treasury` for the vault that calls it.
/// @dev THIS EXISTS FOR A SIZE LIMIT, like WorkOracleFactory. A contract that creates another embeds
/// that creation code in its own initcode, and the Treasury's (~10 KB, after native-ETH support and
/// launch-fee hand-off) put ParameterizedVault over the 49,152 bytes EIP-3860 allows. Holding it here
/// costs the vault one external call.
///
/// It is not an authority and holds nothing. `create` is permissionless because there is nothing to
/// gate: the Treasury it returns serves its CALLER, so one created for someone else is useless to the
/// caller, and its register is governed only by the caller's own `parameters()`.
contract TreasuryFactory {
    event TreasuryCreated(address indexed vault, address treasury);

    /// @notice Deploy a Treasury that serves the caller.
    function create() external returns (Treasury treasury) {
        treasury = new Treasury(msg.sender);
        emit TreasuryCreated(msg.sender, address(treasury));
    }
}
