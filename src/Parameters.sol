// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Governed} from "./Governed.sol";
import {Treasury} from "./Treasury.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {
    MARKER_SHARE_BPS,
    MAX_DIVERGENCE_BPS,
    PROTOCOL_BONUS_SHARE_BPS,
    STABILITY_FEE_BPS,
    WORK_RATIO_BPS,
    COMP_PER_TASK_WAD
} from "./DeploymentConfig.sol";

/// @notice The vault's economic knobs, moved out of source constants into a governed contract.
interface ICheckpointedVault {
    function totalDebt() external view returns (uint256);
    function pokeIndex() external;
    function treasury() external view returns (address);
}

/// @notice The numbers that set the protocol's economics, and the reserve register that backs its
/// work minting, changeable under a delay.
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

    /// @notice What a pending payload changes. One Governed slot, three shapes of change: the
    /// payload's first word says which, so the 48-hour delay, the public pending window and the
    /// permissionless application are the same code for all of them.
    /// @dev The work ratio and the register travel separately from the five-value set rather than
    /// inside it, so a listing can be queued without restating every fee and a fee change without
    /// naming an asset — and so the set a borrower prices against keeps its shape.
    enum Change {
        Economics,
        WorkRatio,
        ReserveAsset,
        CompPerTask
    }

    uint256 private constant BPS = 10_000;

    /// @notice Hard cap on the work ceiling's ratio term. 5000 is the cliff where worst-case backing
    /// touches one at the loosest NHI (minCR 150); this is half of it, 120% with an empty reserve.
    /// A constant, so governance can lower the ratio and can never raise it past here.
    uint256 public constant MAX_WORK_RATIO_BPS = 2_500;

    /// @notice Hard cap on the COMP one accepted task earns. One task can never be worth more than
    /// one COMP, whatever a governor proposes.
    /// @dev The binding constraint on work minting is the work ceiling, not this: the ceiling asks
    /// whether backing exists, and this only converts a count into an amount. The cap is here anyway
    /// because the two multiply — an unbounded rate would let a governor turn a modest task count
    /// into a claim the ceiling then has to absorb — and because a rate above one COMP per task makes
    /// no sense against a token meant to be worth a dollar.
    uint256 public constant MAX_COMP_PER_TASK_WAD = 1 ether;

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

    /// @notice The live ratio term of the vault's work ceiling, in basis points of totalDebt.
    uint256 private _workRatioBps;

    /// @notice The live COMP-per-accepted-task rate, 1e18-scaled.
    uint256 private _compPerTaskWad;

    /// @notice The vault these parameters govern: its creator, fixed at construction.
    /// @dev Needed for two things that cannot be done without it: checking a proposed ceiling
    /// against debt that is actually outstanding, and checkpointing the fee index before the rate
    /// changes. The binding is one-way and one-time — it is an address this contract reads, never an
    /// authority over the vault beyond the permissionless `pokeIndex`.
    ICheckpointedVault public vault;

    error ZeroVault();
    error FeeTooHigh(uint256 bps);
    error DivergenceOutOfRange(uint256 bps);
    error SharesExceedBonus(uint256 markerBps, uint256 protocolBps);
    error ZeroCeiling();
    error WorkRatioTooHigh(uint256 bps);
    error CompPerTaskTooHigh(uint256 wad);

    /// @dev Seeded from the shipped constants, so a fresh Parameters is exactly the configuration
    /// the vault would have had with them compiled in — including the unlimited default ceiling,
    /// which CDPVault pins as a literal rather than a named constant. Governance starts from the
    /// status quo, so binding it to a live vault changes nothing by itself.
    /// @param vault_ the vault these parameters govern, which is always its creator.
    /// @dev AUDIT FIX (two mediums, job c71449d1). Parameters used to be deployable standalone and
    /// bound afterwards, which was unsafe in two ways that share one root cause — the binding was a
    /// separate transaction. An attacker could front-run the deployer and bind an impostor whose
    /// `pokeIndex` does nothing, so rate changes reached the real vault with no checkpoint; and a
    /// second vault could be pointed at an already-bound Parameters and read a rate it is never
    /// checkpointed for. Both end in `stabilityFeeOf` underflowing and freezing positions.
    ///
    /// There is no fix that keeps a separate binding transaction: a mid-construction callback cannot
    /// verify the caller, because the vault has no code yet. So the transaction is gone. A vault
    /// creates its own Parameters and is the only thing it can ever govern, which also means a
    /// deployment comes up linked with nothing sent afterwards — what a launch manifest requires.
    constructor(ICheckpointedVault vault_) {
        if (address(vault_) == address(0)) revert ZeroVault();
        vault = vault_;
        _current = ParamSet({
            debtCeiling: type(uint256).max,
            protocolBonusShareBps: PROTOCOL_BONUS_SHARE_BPS,
            stabilityFeeBps: STABILITY_FEE_BPS,
            maxDivergenceBps: MAX_DIVERGENCE_BPS,
            markerShareBps: MARKER_SHARE_BPS
        });
        // The shipped ratio is subject to the same bound as any proposal; a constant above the cap
        // is a misconfiguration this contract refuses to be deployed with.
        if (WORK_RATIO_BPS > MAX_WORK_RATIO_BPS) revert WorkRatioTooHigh(WORK_RATIO_BPS);
        _workRatioBps = WORK_RATIO_BPS;
        // Same treatment as the ratio: a shipped constant above its own cap is a misconfiguration
        // this contract refuses to exist with, rather than one discovered at the first proposal.
        if (COMP_PER_TASK_WAD > MAX_COMP_PER_TASK_WAD) revert CompPerTaskTooHigh(COMP_PER_TASK_WAD);
        _compPerTaskWad = COMP_PER_TASK_WAD;
    }

    /// @notice Queue a complete replacement set. Always all five, so the pending payload is the whole
    /// configuration a borrower will face rather than a diff they have to apply themselves.
    function propose(ParamSet calldata next) external {
        _propose(abi.encode(Change.Economics, next));
    }

    /// @notice Queue a change to the work ceiling's ratio term. Refused above MAX_WORK_RATIO_BPS.
    function proposeWorkRatio(uint256 bps) external {
        _propose(abi.encode(Change.WorkRatio, bps));
    }

    /// @notice Queue a change to the COMP an accepted task earns. Refused above one COMP per task.
    function proposeCompPerTask(uint256 wad) external {
        _propose(abi.encode(Change.CompPerTask, wad));
    }

    /// @notice Queue a listing, repricing or (with a zero price source) delisting of one of the
    /// Treasury's reserve assets. The Treasury's own rules apply at proposal — COMP is refused with
    /// `CompIsNotReserve`, a haircut must be at most 10000 — so a change the register would refuse
    /// never occupies the slot. Applying it, like every other change, is anyone's to do after the delay.
    function proposeReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) external {
        _propose(abi.encode(Change.ReserveAsset, asset, priceFeed, haircutBps));
    }

    function current() external view returns (ParamSet memory) {
        return _current;
    }

    function workRatioBps() external view returns (uint256) {
        return _workRatioBps;
    }

    /// @notice What SwarmWorkOracle multiplies an attested task count by, 1e18-scaled.
    function compPerTaskWad() external view returns (uint256) {
        return _compPerTaskWad;
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

    /// @notice What kind of change is waiting, and when it can be applied; eta is zero if nothing is.
    function pendingChange() public view returns (Change kind, uint256 eta) {
        if (pendingEta == 0) return (kind, 0);
        return (_kind(pending), pendingEta);
    }

    /// @notice The pending five-value set, or an empty one with a zero eta if the pending change is
    /// of another kind or there is none. `pendingChange` says which.
    function pendingSet() external view returns (ParamSet memory next, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.Economics) return (next, 0);
        (, next) = abi.decode(pending, (Change, ParamSet));
        return (next, at);
    }

    function pendingWorkRatio() external view returns (uint256 bps, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.WorkRatio) return (0, 0);
        (, bps) = abi.decode(pending, (Change, uint256));
        return (bps, at);
    }

    function pendingReserveAsset()
        external
        view
        returns (IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps, uint256 eta)
    {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.ReserveAsset) return (asset, priceFeed, 0, 0);
        (, asset, priceFeed, haircutBps) = abi.decode(pending, (Change, IERC20, ISwarmFeed, uint256));
        return (asset, priceFeed, haircutBps, at);
    }

    function _kind(bytes memory payload) private pure returns (Change) {
        return abi.decode(payload, (Change));
    }

    function _treasury() private view returns (Treasury) {
        return Treasury(vault.treasury());
    }

    function _validate(bytes memory payload) internal view override {
        Change kind = _kind(payload);
        if (kind == Change.WorkRatio) {
            (, uint256 bps) = abi.decode(payload, (Change, uint256));
            if (bps > MAX_WORK_RATIO_BPS) revert WorkRatioTooHigh(bps);
            return;
        }
        if (kind == Change.CompPerTask) {
            (, uint256 wad) = abi.decode(payload, (Change, uint256));
            if (wad > MAX_COMP_PER_TASK_WAD) revert CompPerTaskTooHigh(wad);
            return;
        }
        if (kind == Change.ReserveAsset) {
            (, IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) =
                abi.decode(payload, (Change, IERC20, ISwarmFeed, uint256));
            // The register's rules, applied where they fail fast and with the register's own errors.
            _treasury().validateReserveAsset(asset, priceFeed, haircutBps);
            return;
        }
        (, ParamSet memory next) = abi.decode(payload, (Change, ParamSet));

        if (next.stabilityFeeBps > MAX_STABILITY_FEE_BPS) revert FeeTooHigh(next.stabilityFeeBps);
        if (next.maxDivergenceBps < MIN_DIVERGENCE_BPS || next.maxDivergenceBps > MAX_DIVERGENCE_BPS_LIMIT) {
            revert DivergenceOutOfRange(next.maxDivergenceBps);
        }
        // The vault pays the marker out of the liquidator's bonus and keeps the protocol's cut from
        // the same bonus; together they cannot exceed it, or a liquidation owes more than it earns.
        //
        // AUDIT NOTE (job c71449d1, info): this bound is economically empty at its top. At
        // protocolBonusShareBps 10000 a liquidator who did not mark receives exactly the principal
        // back — no reward for the stablecoin, the inventory risk or the gas — so liquidations stop
        // and bad debt accumulates. It stays a bound rather than a tighter cap because the borrower's
        // loss is identical at every split and the change is visible for 48 hours, so this is a trust
        // assumption to state plainly, not a bypass to close.
        if (next.markerShareBps + next.protocolBonusShareBps > BPS) {
            revert SharesExceedBonus(next.markerShareBps, next.protocolBonusShareBps);
        }
        if (next.debtCeiling == 0) revert ZeroCeiling();

        // There is deliberately NO check that the ceiling clears outstanding debt, and an independent
        // audit is why (job c71449d1, low). Checking it at application made the proposal's success
        // depend on a figure third parties control: minting is permissionless up to the CURRENT
        // ceiling, so any borrower with collateral could front-run applyPending with mintCOMP to keep
        // totalDebt above the proposed figure, then repay next block and repeat. The whole five-value
        // payload travelled in one struct, so a fee or divergence change could be held hostage too.
        //
        // The check was also protecting nothing. A ceiling below outstanding debt strands no one: it
        // gates new minting only, and repayment, withdrawal and liquidation are not ceiling-gated. So
        // the worst a low ceiling does is stop growth, which is what a ceiling is for.
    }

    function _apply(bytes memory payload) internal override {
        Change kind = _kind(payload);
        if (kind == Change.WorkRatio) {
            (, _workRatioBps) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.CompPerTask) {
            (, _compPerTaskWad) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.ReserveAsset) {
            (, IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) =
                abi.decode(payload, (Change, IERC20, ISwarmFeed, uint256));
            _treasury().setReserveAsset(asset, priceFeed, haircutBps);
            return;
        }
        // Freeze accrual to date at the old rate, in this transaction, before the new rate is
        // readable. The vault's index is linear from its last checkpoint, so without this the change
        // would reach time that has already passed.
        vault.pokeIndex();
        (, _current) = abi.decode(payload, (Change, ParamSet));
    }
}
