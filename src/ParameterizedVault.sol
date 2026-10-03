// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CDPVault} from "./CDPVault.sol";
import {Parameters, ICheckpointedVault} from "./Parameters.sol";

/// @notice CDPVault with its five economic knobs read from a governed Parameters contract.
/// @dev The entire difference from CDPVault is five overrides. That is the whole point of having
/// made those functions virtual: adding governance required no change to the vault's logic, so the
/// accounting, liquidation and attestation paths audited for CDPVault are the same code here.
///
/// What this does NOT do is make the vault upgradeable. The price feeds, the attester and the
/// collateral token are still immutable constructor arguments, and `parameters` itself is immutable:
/// the governor can change what the numbers are, never where the price comes from, and cannot
/// repoint the vault at a different Parameters contract. Governance over this vault is therefore
/// bounded by what Parameters can express and by the hard limits Parameters enforces on itself.
contract ParameterizedVault is CDPVault {
    /// @notice The governed source of this vault's economics. Immutable: a governor who could
    /// replace it would have unbounded authority through the replacement.
    Parameters public immutable parameters;

    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_,
        Parameters parameters_
    ) CDPVault(imdToken_, compToken_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {
        // Zero means self-contained, the same convention compToken_ and oracle_ already use: create
        // the Parameters contract here and bind it in its own constructor, so the pair comes up
        // mutually linked with no post-deploy transaction. A launch manifest makes no post-deploy
        // calls and can name at most four contracts, so this is what lets the governed stack deploy
        // from one: three feeds and this vault, with Parameters created inside it.
        parameters = address(parameters_) == address(0)
            ? new Parameters(ICheckpointedVault(address(this)))
            : parameters_;
    }

    function debtCeiling() public view override returns (uint256) {
        return parameters.debtCeiling();
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return parameters.protocolBonusShareBps();
    }

    function stabilityFeeBps() public view override returns (uint256) {
        return parameters.stabilityFeeBps();
    }

    function maxDivergenceBps() public view override returns (uint256) {
        return parameters.maxDivergenceBps();
    }

    function markerShareBps() public view override returns (uint256) {
        return parameters.markerShareBps();
    }
}
