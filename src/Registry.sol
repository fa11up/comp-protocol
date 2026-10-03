// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governed} from "./Governed.sol";
import {ATTESTATION_RELAYER} from "./DeploymentConfig.sol";

/// @notice The protocol's replaceable counterparties, under the same delay as its parameters.
/// @dev Split from Parameters by blast radius, not by type. These three are addresses the protocol
/// SENDS to or ASKS, where a wrong value costs the protocol money or stops a mechanism — recoverable
/// damage, visible in advance, worth being able to fix without a migration:
///
///   relayer    — who may push an attestation into the feeds. Replaceable because the relay is
///                infrastructure: SwarmRelay supersedes an EOA, and something will supersede it.
///   treasury   — where protocol revenue lands. Replaceable because the eventual answer is paired
///                liquidity and that contract does not exist yet.
///   workOracle — who attests accepted compute. Replaceable because the real one is not built; the
///                live deployment points at a mock.
///
/// What is NOT here, and must never be: the attestation signer, the three price feeds, and the
/// collateral token. The difference is not that those are more important — it is that a wrong value
/// there is not a cost, it is custody. Whoever names the price feed decides what every position is
/// worth and can liquidate all of them in one block; whoever names the attester decides what counts
/// as a swarm answer. A 48-hour delay does not make that safe, it only makes it slow, and a borrower
/// who has to watch for a feed swap has no guarantee worth anything. Those stay immutable in the
/// vault and pinned in DeploymentConfig, where changing them means a new deployment someone has to
/// choose to move to.
contract Registry is Governed {
    struct Addresses {
        address relayer;
        address treasury;
        address workOracle;
    }

    Addresses private _current;

    error ZeroAddress();

    /// @param treasury_ the Treasury deployment; @param workOracle_ the work attestation source.
    /// @dev The relayer is seeded from the source constant the feeds are compiled against, so the
    /// registry agrees with the feeds at deployment and any divergence afterwards is a decision.
    constructor(address treasury_, address workOracle_) {
        if (treasury_ == address(0) || workOracle_ == address(0)) revert ZeroAddress();
        _current = Addresses({relayer: ATTESTATION_RELAYER, treasury: treasury_, workOracle: workOracle_});
    }

    /// @notice Queue a complete replacement set, all three at once for the same reason Parameters
    /// takes all five: the pending payload is the configuration, not a diff.
    function propose(Addresses calldata next) external {
        _propose(abi.encode(next));
    }

    function current() external view returns (Addresses memory) {
        return _current;
    }

    function relayer() external view returns (address) {
        return _current.relayer;
    }

    function treasury() external view returns (address) {
        return _current.treasury;
    }

    function workOracle() external view returns (address) {
        return _current.workOracle;
    }

    function pendingSet() external view returns (Addresses memory next, uint256 eta) {
        if (pendingEta == 0) return (next, 0);
        return (abi.decode(pending, (Addresses)), pendingEta);
    }

    function _validate(bytes memory payload) internal view override {
        Addresses memory next = abi.decode(payload, (Addresses));
        if (next.relayer == address(0) || next.treasury == address(0) || next.workOracle == address(0)) {
            revert ZeroAddress();
        }
    }

    function _apply(bytes memory payload) internal override {
        _current = abi.decode(payload, (Addresses));
    }
}
