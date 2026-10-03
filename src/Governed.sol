// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice One proposal at a time, held for a fixed delay, then applied by anyone.
/// @dev The delay is the whole point. Every value these contracts hold is one a borrower priced
/// their position against, so a change that lands in the same block as its announcement is
/// indistinguishable from a rug: a fee rise or a tighter ceiling would reach a position whose owner
/// had no chance to close it. Holding a proposal in public for `TIMELOCK` first means the terms a
/// borrower can see are the terms that apply for at least that long, and the only thing governance
/// can do inside the window is cancel.
///
/// `applyPending` is permissionless. Once the delay has run, applying is mechanical — the payload
/// has been readable the whole time — and a governor who could also withhold the application would
/// be able to hold a validated change over the protocol indefinitely, choosing its moment.
///
/// The payload is `bytes` so this contract knows nothing about what it governs; the subclass decodes
/// it in `_validate` and `_apply`. `_validate` runs twice, at proposal and again at application,
/// because a bound that reads live state (a ceiling against outstanding debt) can hold when proposed
/// and be false two days later. The second check is the one that protects anybody.
abstract contract Governed {
    /// @notice How long a proposal must be public before it can be applied.
    uint256 public constant TIMELOCK = 48 hours;

    /// @notice The encoded pending change, readable by anyone for the whole delay.
    bytes public pending;

    /// @notice When `pending` becomes applicable; zero when nothing is pending.
    uint256 public pendingEta;

    error NotGovernor();
    error NothingPending();
    error ProposalPending();
    error TooEarly(uint256 eta);

    event Proposed(bytes payload, uint256 eta);
    event Cancelled(bytes payload);
    event Applied(bytes payload);

    modifier onlyGovernor() {
        if (msg.sender != APPROVED_OPERATOR) revert NotGovernor();
        _;
    }

    /// @notice Who may propose and cancel. A source constant, like every other authority here.
    function governor() public pure returns (address) {
        return APPROVED_OPERATOR;
    }

    /// @notice Queue a change. Reverts immediately if it violates a bound, so an invalid proposal
    /// never occupies the slot or the two days.
    function _propose(bytes memory payload) internal onlyGovernor {
        if (pendingEta != 0) revert ProposalPending();
        _validate(payload);
        pending = payload;
        pendingEta = block.timestamp + TIMELOCK;
        emit Proposed(payload, block.timestamp + TIMELOCK);
    }

    /// @notice Withdraw the pending change. The only governance action with no delay, because
    /// abandoning a change can only return things to what borrowers already priced.
    function cancel() external onlyGovernor {
        if (pendingEta == 0) revert NothingPending();
        bytes memory payload = pending;
        delete pending;
        pendingEta = 0;
        emit Cancelled(payload);
    }

    /// @notice Apply the pending change once its delay has run. Callable by anyone.
    /// @dev AUDIT NOTE (job c71449d1, info): nothing bounds how long AFTER eta a payload may sit, so
    /// the guarantee a borrower actually has is "these values will not change for at least TIMELOCK
    /// after Proposed", not "they change at eta". A matured proposal nobody applies can be applied by
    /// the governor weeks later at a chosen moment — the very thing permissionless application was
    /// meant to prevent. An expiry window would close it; it is left open deliberately for now
    /// because adding one lets a change be blocked by simply not applying it until it lapses, and the
    /// ceiling finding below already shows third parties can stall an application.
    function applyPending() external {
        uint256 eta = pendingEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        bytes memory payload = pending;
        delete pending;
        pendingEta = 0;
        _validate(payload);
        _apply(payload);
        emit Applied(payload);
    }

    function _validate(bytes memory payload) internal view virtual;

    function _apply(bytes memory payload) internal virtual;
}
