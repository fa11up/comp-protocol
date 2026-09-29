// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Explicit operator named in the approved Sepolia workflow (miyagod.eth).
/// Preserves the specified constructor signatures while allowing a constructor-only factory
/// to deploy. The operator completes the two one-time links and operates the mock faucets.
/// This release is specific to that operator; neither msg.sender nor tx.origin selects authority.
address constant APPROVED_OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
