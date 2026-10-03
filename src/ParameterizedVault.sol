// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "./CDPVault.sol";
import {Parameters, ICheckpointedVault} from "./Parameters.sol";
import {Treasury} from "./Treasury.sol";
import {UsdPriceFeed} from "./UsdPriceFeed.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";

/// @notice CDPVault with its economic knobs read from a governed Parameters contract, its revenue
/// routed to a Treasury it owns, and its work minting bounded by what that Treasury and the
/// collateral pool back.
/// @dev The difference from CDPVault is a handful of overrides. That is the whole point of having
/// made those functions virtual: adding governance and a ceiling required no change to the vault's
/// logic, so the accounting, liquidation and attestation paths audited for CDPVault are the same
/// code here.
///
/// What this does NOT do is make the vault upgradeable. The price feeds, the attester and the
/// collateral token are still immutable constructor arguments, and `parameters`, `treasury` and
/// `usdPriceFeed` are immutables this constructor creates: the governor can change what the numbers
/// are, never where the price comes from, where the revenue goes, or which contract governs.
/// Governance over this vault is therefore bounded by what Parameters can express and by the hard
/// limits Parameters enforces on itself.
contract ParameterizedVault is CDPVault {
    /// @notice The governed source of this vault's economics. Immutable: a governor who could
    /// replace it would have unbounded authority through the replacement.
    Parameters public immutable parameters;

    /// @notice Where this vault's protocol bonus share (IMD) and paid stability fees (COMP) land,
    /// and the reserve whose value is the first term of `workCeiling`.
    Treasury public immutable treasury;

    /// @notice IMD in USD: this vault's primary IMD/ETH feed times Chainlink ETH/USD. The price
    /// source the Treasury's register is expected to hold for IMD.
    UsdPriceFeed public immutable usdPriceFeed;

    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) CDPVault(imdToken_, compToken_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {
        // AUDIT FIX (job c71449d1): there is deliberately no way to pass a Parameters in. Accepting
        // one allowed an attacker to bind an impostor ahead of the deployer, and allowed a second
        // vault to borrow a Parameters already bound elsewhere and read a rate it is never
        // checkpointed for. The vault creates its own, which also means the pair comes up linked with
        // no post-deploy transaction — what a launch manifest requires, since it makes none and can
        // name at most four contracts.
        parameters = new Parameters(ICheckpointedVault(address(this)));
        // The same idiom for the other two, and for the same reasons: a Treasury passed in could be
        // anyone's wallet (which is what FEE_RECIPIENT is today), and a manifest has no fifth slot
        // to deploy one in. Created here, the Treasury's creator is this vault, so its register is
        // governed by this vault's Parameters and refuses this vault's COMP, with nothing bound later.
        treasury = new Treasury();
        usdPriceFeed = new UsdPriceFeed(ISwarmFeed(priceFeed_));
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

    /// @notice Both revenue streams land in the Treasury this vault created, never in an account.
    function feeRecipient() public view override returns (address) {
        return address(treasury);
    }

    /// @notice The ratio term of the work ceiling, in basis points of collateral-backed debt.
    function workRatioBps() public view returns (uint256) {
        return parameters.workRatioBps();
    }

    /// @notice reserveValueUsd + totalDebt * workRatioBps / 10000, in COMP units (one COMP is a
    /// dollar of account).
    /// @dev A sum, not a maximum, because the two terms are backed by different things: the reserve
    /// one-for-one by assets the protocol owns, the ratio term by the surplus collateral every
    /// borrower posts above their own debt. Section 3 of docs/COMPUTE-BACKING-DESIGN.md shows
    /// backing exceeds one for every reserve size exactly when the ratio is below minCR - 1, and
    /// Parameters caps the ratio at half that cliff.
    function workCeiling() public view override returns (uint256) {
        return treasury.reserveValueUsd() + Math.mulDiv(totalDebt, parameters.workRatioBps(), 10_000);
    }
}
