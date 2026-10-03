// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governed} from "./Governed.sol";
import {
    MARKER_SHARE_BPS,
    MAX_DIVERGENCE_BPS,
    PROTOCOL_BONUS_SHARE_BPS,
    STABILITY_FEE_BPS
} from "./DeploymentConfig.sol";

/// @notice The vault's economic knobs, moved out of source constants into a governed contract.
interface ICheckpointedVault {
    function totalDebt() external view returns (uint256);
    function pokeIndex() external;
}

/// @notice Read back off a candidate vault to prove it already names this parameters contract.
interface IParameterized {
    function parameters() external view returns (address);
}

/// @notice The five numbers that set the protocol's economics, changeable under a delay.
/// @dev Why these and not everything: a parameter is safe to govern when the worst a wrong value can
/// do is price the protocol badly. A fee can be too high, a ceiling too tight, a divergence bound too
/// loose — each is a bad business decision that a borrower can see coming and exit ahead of. The
/// things deliberately NOT here are the ones where a wrong value is not a bad decision but a theft:
/// the attester, the three feeds and the collateral token. Swapping a feed is not adjusting a
/// parameter, it IS control of the price, and whoever sets the price can liquidate everyone. Those
/// stay immutable in the vault, which is why this contract is given no way to reach them.
///
/// Every bound below is a constant in this file rather than a governance choice, so the governor
/// cannot widen its own authority — raising the fee cap takes a new Parameters contract and a new
/// vault, which is a visible event rather than a transaction.
contract Parameters is Governed {
    struct ParamSet {
        uint256 debtCeiling;
        uint256 protocolBonusShareBps;
        uint256 stabilityFeeBps;
        uint256 maxDivergenceBps;
        uint256 markerShareBps;
    }

    uint256 private constant BPS = 10_000;

    /// @notice Hard cap on the annual stability fee. 10% is high for a fee this protocol charges on
    /// its own stablecoin; above it the fee stops being a cost of borrowing and becomes a way to
    /// drive positions into liquidation.
    uint256 public constant MAX_STABILITY_FEE_BPS = 1_000;

    /// @notice Floor on the divergence bound. Below 1% the primary feed and the spot feed disagree
    /// from ordinary market noise alone and the vault halts constantly.
    uint256 public constant MIN_DIVERGENCE_BPS = 100;

    /// @notice Ceiling on the divergence bound. The bound is the only thing standing between a bad
    /// attestation and the collateral; at 20% it is already permissive.
    uint256 public constant MAX_DIVERGENCE_BPS_LIMIT = 2_000;

    /// @notice The live values.
    ParamSet private _current;

    /// @notice The vault these parameters govern, bound once after both exist.
    /// @dev Needed for two things that cannot be done without it: checking a proposed ceiling
    /// against debt that is actually outstanding, and checkpointing the fee index before the rate
    /// changes. The binding is one-way and one-time — it is an address this contract reads, never an
    /// authority over the vault beyond the permissionless `pokeIndex`.
    ICheckpointedVault public vault;

    error AlreadyBound();
    error ZeroVault();
    error NotOurVault(address named);
    error VaultNotBound();
    error FeeTooHigh(uint256 bps);
    error DivergenceOutOfRange(uint256 bps);
    error SharesExceedBonus(uint256 markerBps, uint256 protocolBps);
    error ZeroCeiling();
    error CeilingBelowDebt(uint256 ceiling, uint256 outstanding);

    event VaultBound(address indexed vault);

    /// @dev Seeded from the shipped constants, so a fresh Parameters is exactly the configuration
    /// the vault would have had with them compiled in — including the unlimited default ceiling,
    /// which CDPVault pins as a literal rather than a named constant. Governance starts from the
    /// status quo, so binding it to a live vault changes nothing by itself.
    /// @param vault_ the vault these parameters govern, or zero to bind it later with `bindVault`.
    /// @dev A vault that creates its own Parameters passes itself here, because the verification
    /// `bindVault` performs is impossible during construction: the vault has no code yet, so reading
    /// its `parameters()` back would revert. No verification is needed on this path — the creator IS
    /// the vault — and on the standalone path an unverified address could at worst make this contract
    /// useless to itself, never reach the vault it names: all it may do there is read `totalDebt` and
    /// call the permissionless `pokeIndex`.
    constructor(ICheckpointedVault vault_) {
        vault = vault_;
        _current = ParamSet({
            debtCeiling: type(uint256).max,
            protocolBonusShareBps: PROTOCOL_BONUS_SHARE_BPS,
            stabilityFeeBps: STABILITY_FEE_BPS,
            maxDivergenceBps: MAX_DIVERGENCE_BPS,
            markerShareBps: MARKER_SHARE_BPS
        });
    }

    /// @notice Record the vault these parameters govern. Callable once, by anyone.
    /// @dev Deliberately not governor-gated, because it confers no choice. The only vault that can
    /// be bound is one whose own immutable `parameters` already points here — fixed at that vault's
    /// construction and unforgeable afterwards — so this transaction records a link that already
    /// exists rather than creating one. Gating it would have bought nothing and would have put a
    /// governor signature in the middle of a deployment broadcast from the reporter key.
    function bindVault(ICheckpointedVault vault_) external {
        if (address(vault) != address(0)) revert AlreadyBound();
        if (address(vault_) == address(0)) revert ZeroVault();
        address named = IParameterized(address(vault_)).parameters();
        if (named != address(this)) revert NotOurVault(named);
        vault = vault_;
        emit VaultBound(address(vault_));
    }

    /// @notice Queue a complete replacement set. Always all five, so the pending payload is the whole
    /// configuration a borrower will face rather than a diff they have to apply themselves.
    function propose(ParamSet calldata next) external {
        _propose(abi.encode(next));
    }

    function current() external view returns (ParamSet memory) {
        return _current;
    }

    function debtCeiling() external view returns (uint256) {
        return _current.debtCeiling;
    }

    function protocolBonusShareBps() external view returns (uint256) {
        return _current.protocolBonusShareBps;
    }

    function stabilityFeeBps() external view returns (uint256) {
        return _current.stabilityFeeBps;
    }

    function maxDivergenceBps() external view returns (uint256) {
        return _current.maxDivergenceBps;
    }

    function markerShareBps() external view returns (uint256) {
        return _current.markerShareBps;
    }

    function pendingSet() external view returns (ParamSet memory next, uint256 eta) {
        if (pendingEta == 0) return (next, 0);
        return (abi.decode(pending, (ParamSet)), pendingEta);
    }

    function _validate(bytes memory payload) internal view override {
        ParamSet memory next = abi.decode(payload, (ParamSet));

        if (next.stabilityFeeBps > MAX_STABILITY_FEE_BPS) revert FeeTooHigh(next.stabilityFeeBps);
        if (next.maxDivergenceBps < MIN_DIVERGENCE_BPS || next.maxDivergenceBps > MAX_DIVERGENCE_BPS_LIMIT) {
            revert DivergenceOutOfRange(next.maxDivergenceBps);
        }
        // The vault pays the marker out of the liquidator's bonus and keeps the protocol's cut from
        // the same bonus; together they cannot exceed it, or a liquidation owes more than it earns.
        if (next.markerShareBps + next.protocolBonusShareBps > BPS) {
            revert SharesExceedBonus(next.markerShareBps, next.protocolBonusShareBps);
        }
        if (next.debtCeiling == 0) revert ZeroCeiling();

        // A ceiling below what is already borrowed does not strand anyone — repayment and withdrawal
        // are not ceiling-gated — but it does make the protocol report a limit it is already past,
        // and it is far more likely to be a mistyped figure than a decision. Checked against live
        // debt at application, not at proposal, because that is when it takes effect.
        ICheckpointedVault bound = vault;
        if (address(bound) != address(0)) {
            uint256 outstanding = bound.totalDebt();
            if (next.debtCeiling < outstanding) revert CeilingBelowDebt(next.debtCeiling, outstanding);
        } else if (next.stabilityFeeBps != _current.stabilityFeeBps) {
            // Without the binding there is no way to checkpoint the index before the rate moves, and
            // an unpoked rate change reprices every second already elapsed.
            revert VaultNotBound();
        }
    }

    function _apply(bytes memory payload) internal override {
        ICheckpointedVault bound = vault;
        // Freeze accrual to date at the old rate, in this transaction, before the new rate is
        // readable. The vault's index is linear from its last checkpoint, so without this the change
        // would reach time that has already passed.
        if (address(bound) != address(0)) bound.pokeIndex();
        _current = abi.decode(payload, (ParamSet));
    }
}
