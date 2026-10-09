// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice OpenZeppelin's ReentrancyGuard with the flag in transient storage (EIP-1153), which the EVM
/// clears when the transaction ends: about 300 gas per guarded call instead of a cold load and two
/// stores of a storage slot. The error and the modifier keep OpenZeppelin's names, so nothing that
/// reads them changes.
/// @dev The flag is a transient slot at keccak256("comp.TransientReentrancyGuard.entered"), set on entry
/// and cleared on exit of the outermost guarded call; a nested guarded call reverts. Cancun or later.
abstract contract TransientReentrancyGuard {
    error ReentrancyGuardReentrantCall();

    uint256 private constant ENTERED_SLOT = 0xfc4723845a22fb395e781c447f1e7cb5e1bbdcd35babb820c5627eff95b4858f;

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        bool entered;
        assembly ("memory-safe") {
            entered := tload(ENTERED_SLOT)
        }
        if (entered) revert ReentrancyGuardReentrantCall();
        assembly ("memory-safe") {
            tstore(ENTERED_SLOT, 1)
        }
    }

    function _nonReentrantAfter() private {
        assembly ("memory-safe") {
            tstore(ENTERED_SLOT, 0)
        }
    }
}
