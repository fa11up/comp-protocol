// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";

/// @notice Prices an ERC-4626 vault share from a feed that prices its underlying asset.
/// @dev What this exists for: a yield-bearing wrapper is strictly better collateral than the token it
/// wraps, because its exchange rate to the underlying only rises, so a borrower's position repairs
/// itself over time instead of decaying against the stability fee. The protocol's first use is
/// `StakedIMD` (sIMD), IdentityMD's staking vault, where a share of every market burn streams into the
/// vault. But nothing here is specific to it: any ERC-4626 over any asset this protocol can already
/// price works, which is also how a diversified reserve gets priced.
///
/// DECIMALS ARE WHY THIS IS SAFE, and they are the part worth reading twice. sIMD has 24 decimals
/// while IMD has 18, and the vault's collateral arithmetic divides by 1e18 without ever reading
/// `decimals()` — so handing it a 24-decimal token priced per whole token would misvalue collateral by
/// a factor of a million. This adapter cannot make that mistake, because every quantity in it is
/// expressed PER 1e18 RAW UNITS, which is the convention the live oracle questions already use ("per
/// 1e18 raw units of IMD"). `convertToAssets(1e18)` is, by definition, exactly that figure for a share
/// token. So the composition is decimal-agnostic: it is correct for any combination of share and asset
/// decimals, and nothing in it needs to know either one.
///
///   value = convertToAssets(1e18) * assetValue / 1e18
///         = (underlying raw per 1e18 share raw) * (USD per 1e18 underlying raw) / 1e18
///         = USD per 1e18 share raw
///
/// FAILURE DIRECTION, learned from an audit. Both reads are raw staticcalls with explicit decoding
/// rather than typed calls, because a typed call to a vault that stops answering REVERTS, and a
/// reverting price source takes down `reserveValueUsd`, `earnLine` and every mint that depends on
/// them. `try/catch` is not a fix either: it catches a revert inside the callee, while the returned
/// bytes are decoded in THIS frame where no catch clause can see a malformed encoding. That exact gap
/// was two MEDIUM findings in job da7d5b1c. Here anything unreadable reads as zero, which reports as
/// stale, which values what it priced at nothing. Degrading is safe; reverting is not.
contract SharePriceFeed is ISwarmFeed {
    /// @notice The ERC-4626 vault whose share this prices.
    address public immutable shareVault;

    /// @notice Prices the vault's underlying asset, in USD per 1e18 raw units of it.
    ISwarmFeed public immutable assetFeed;

    error InvalidVault();
    error InvalidFeed();

    constructor(address shareVault_, ISwarmFeed assetFeed_) {
        if (shareVault_.code.length == 0) revert InvalidVault();
        if (address(assetFeed_).code.length == 0) revert InvalidFeed();
        // A vault that cannot answer the one question this adapter asks is not a vault it can price.
        // Read through the ARGUMENT, not the immutable: the immutable is not assigned yet.
        (uint256 rate, bool ok) = _rateOf(shareVault_);
        if (!ok || rate == 0) revert InvalidVault();
        shareVault = shareVault_;
        assetFeed = assetFeed_;
    }

    /// @notice USD per 1e18 raw share units, 1e18-scaled, dated at the underlying feed's timestamp.
    /// @dev Zero if either leg is unreadable. The exchange rate carries no timestamp of its own and
    /// needs none: it is read from chain state in this call, so it is always current, and it is the
    /// ASSET price that can go stale.
    function latestValue() external view override returns (uint256 value, uint64 updatedAt) {
        (uint256 rate, bool ok) = _rateOf(shareVault);
        if (!ok || rate == 0) return (0, 0);
        (uint256 assetValue, uint64 assetAt) = assetFeed.latestValue();
        if (assetValue == 0) return (0, 0);
        return (Math.mulDiv(rate, assetValue, 1e18), assetAt);
    }

    /// @notice Stale if the underlying feed is, or if the vault stops answering.
    function isStale() external view override returns (bool) {
        if (assetFeed.isStale()) return true;
        (uint256 rate, bool ok) = _rateOf(shareVault);
        return !ok || rate == 0;
    }

    /// @notice The underlying feed's maximum age; this adapter adds no staleness of its own.
    function maxAge() external view override returns (uint256) {
        return assetFeed.maxAge();
    }

    /// @notice Underlying raw units per 1e18 raw share units, read live from the vault.
    function exchangeRate() external view returns (uint256 rate, bool ok) {
        return _rateOf(shareVault);
    }

    /// @dev `convertToAssets(1e18)`. One word out, and it must decode as one word; anything else is
    /// "no answer" rather than a revert, for the reason in the contract docstring.
    function _rateOf(address vault) private view returns (uint256 rate, bool ok) {
        (bool success, bytes memory data) =
            vault.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", uint256(1e18)));
        if (!success || data.length < 32) return (0, false);
        return (abi.decode(data, (uint256)), true);
    }
}
