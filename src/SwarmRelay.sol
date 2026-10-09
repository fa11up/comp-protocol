// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {SwarmFeed} from "./SwarmFeed.sol";
import {CDPVault} from "./CDPVault.sol";

/// @notice Permissionless relayer for swarm attestations, and the only address the feeds accept.
/// @dev A feed pins a single relayer. It once had to, because `questionHash` alone cannot say WHICH
/// question an attestation answers and a trusted relayer was what stood behind the unseeded first value
/// and stale re-anchors. Every shipped feed now pins its question document (`expectedQuestionHash`) and
/// bounds every value after the first per epoch, so the relayer is no longer a trust boundary, and this
/// contract does not pretend to be one: anyone may call it, the trust is the same as a zero relayer, and
/// the first value is bounded by nothing on chain (DeployMainnet.verifySeeded checks it). What pinning
/// this contract buys is what an EOA cannot do:
///
///   - several feeds update in ONE transaction, so the price and the health index can never be read
///     a block apart, which is what the vault's divergence guard compares;
///   - a keeper can bundle an update with the action it enables, removing the race where someone
///     else liquidates between your update and your call.
///
/// AUDIT NOTE (job c71449d1, info): "holds nothing" is not quite true, and the balance-delta
/// accounting is why. `barkFor` lets any caller name any beneficiary, so a griefer can name
/// THIS contract as the marker of a position they do not intend to bite. A later DIRECT
/// liquidation then pays the marker's cut here, and with no owner and no sweep it stays forever. A
/// liquidation through `relayAndBite` pays the keeper instead, so the loss is bounded to a
/// griefer's own forgone reward plus the stranded cut. Left as is: a sweep would need to decide who
/// deserves the funds, and the vault cannot be asked to recognise which addresses are relays.
///
/// This contract holds nothing it is given on purpose, approves nothing and has no owner. It cannot report, cannot seed a
/// feed, and cannot alter an attestation: every guard the feed applies — attester signature, replay,
/// freshness, panel floors, deviation — is untouched and still runs on the forwarded call. The worst
/// a caller can do is relay a valid attestation the feed would have accepted anyway, or waste gas.
contract SwarmRelay is TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Forward one attestation to one feed.
    function relay(SwarmFeed feed, SwarmFeed.OracleAttestation calldata attestation, bytes calldata signature)
        external
    {
        feed.submitAttestation(attestation, signature);
    }

    /// @notice Forward several attestations in one transaction, each to its own feed.
    /// @dev All or nothing: a feed that refuses its attestation reverts the batch, so a caller never
    /// half-updates a set of feeds the vault compares against each other. Ordering is the caller's.
    function relayMany(
        SwarmFeed[] calldata feeds,
        SwarmFeed.OracleAttestation[] calldata attestations,
        bytes[] calldata signatures
    ) external {
        _relayMany(feeds, attestations, signatures);
    }

    /// @notice Relay, then mark a position underwater with the CALLER as the marker.
    /// @dev Moves no tokens. `bark` would record THIS contract as the marker and pay its
    /// share of a later liquidation bonus to an address with no owner and no sweep, stranding it;
    /// `barkFor` exists precisely so a relayed mark pays the keeper that caused it.
    function relayAndBark(
        SwarmFeed[] calldata feeds,
        SwarmFeed.OracleAttestation[] calldata attestations,
        bytes[] calldata signatures,
        CDPVault vault,
        address borrower
    ) external nonReentrant {
        _relayMany(feeds, attestations, signatures);
        vault.barkFor(borrower, msg.sender);
    }

    /// @notice Relay, then bite, so nobody can act on the fresh price in between.
    /// @dev The custody problem, and the whole difficulty of this function: the vault burns the
    /// CALLER's stablecoin and pays the CALLER the seized collateral, and here the caller is this
    /// contract. So it must hold both for the length of one call and end holding neither.
    ///
    /// It pulls exactly `debtToRepay`, never an approved surplus, so an over-approving keeper keeps
    /// the difference. It forwards whatever the vault actually paid — measured as a balance delta,
    /// not computed — because the liquidation's own dust sweep means the payout is not a pure
    /// function of the inputs. Both balances are asserted to be zero before returning: anything left
    /// is a bug, and this contract has no owner and no sweep with which to recover it.
    ///
    /// Balance deltas rather than absolute balances, so a donation to this contract cannot be swept
    /// out by a liquidator and cannot make the final assertion fail for everyone.
    function relayAndBite(
        SwarmFeed[] calldata feeds,
        SwarmFeed.OracleAttestation[] calldata attestations,
        bytes[] calldata signatures,
        CDPVault vault,
        address borrower,
        uint256 debtToRepay
    ) external nonReentrant {
        _relayMany(feeds, attestations, signatures);

        IERC20 stable = IERC20(address(vault.stablecoin()));
        IERC20 collateral = vault.gem();

        uint256 stableBefore = stable.balanceOf(address(this));
        uint256 collateralBefore = collateral.balanceOf(address(this));

        stable.safeTransferFrom(msg.sender, address(this), debtToRepay);
        vault.bite(borrower, debtToRepay);

        uint256 seized = collateral.balanceOf(address(this)) - collateralBefore;
        if (seized != 0) collateral.safeTransfer(msg.sender, seized);

        // The vault burns from this contract, so a correct liquidation consumes the pull exactly.
        if (stable.balanceOf(address(this)) != stableBefore) revert StablecoinRetained();
        if (collateral.balanceOf(address(this)) != collateralBefore) revert CollateralRetained();

        emit RelayedLiquidation(msg.sender, address(vault), borrower, debtToRepay, seized);
    }

    function _relayMany(
        SwarmFeed[] calldata feeds,
        SwarmFeed.OracleAttestation[] calldata attestations,
        bytes[] calldata signatures
    ) private {
        if (feeds.length != attestations.length || feeds.length != signatures.length) revert LengthMismatch();
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].submitAttestation(attestations[i], signatures[i]);
        }
    }

    event RelayedLiquidation(
        address indexed keeper, address indexed vault, address indexed borrower, uint256 debtRepaid, uint256 seized
    );

    error LengthMismatch();
    error StablecoinRetained();
    error CollateralRetained();
}
