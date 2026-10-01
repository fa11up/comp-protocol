// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Explicit operator named in the approved Sepolia workflow (miyagod.eth).
/// Preserves the specified constructor signatures while allowing a constructor-only factory
/// to deploy. The operator completes the two one-time links and operates the mock faucets.
/// This release is specific to that operator; neither msg.sender nor tx.origin selects authority.
address constant APPROVED_OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;

/// @dev Receives the protocol's share of liquidation bonuses, when a deployment turns that share on.
/// Pinned in source for the same reason APPROVED_OPERATOR is: a manifest placeholder resolved to the
/// platform's own address on launch 519, not to the requester.
/// MUST NOT be the feed's reporter or relayer — whoever sets the price would otherwise profit from
/// liquidations they can trigger. Nothing on chain enforces that; see SPEC-ceiling-and-fee.md.
address constant FEE_RECIPIENT = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
