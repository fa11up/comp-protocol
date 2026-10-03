// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {CHAINLINK_ETH_USD, ETH_USD_MAX_AGE} from "./DeploymentConfig.sol";

/// @notice The IMD price in USD, 1e18-scaled: the vault's IMD/ETH SwarmFeed multiplied by Chainlink
/// ETH/USD. It is what the Treasury prices its IMD reserve with.
/// @dev An ISwarmFeed so the Treasury's register can hold it next to any other price source without a
/// special case. It holds no state and no authority: the IMD leg is an immutable set by the vault that
/// creates it, and the USD leg is a source constant, so nothing can repoint either.
///
/// Stale if EITHER leg is stale. The composite's timestamp is the older of the two, and its maxAge the
/// shorter, so a consumer reading it like any other feed gets the conservative answer on both.
///
/// The USD leg is read with a low-level staticcall rather than a typed call. A typed call to an
/// aggregator that is missing, paused or returning a malformed answer reverts, and that revert would
/// surface as `workCeiling()` reverting — which blocks every work mint and breaks the view the
/// frontend reads. Here such a leg reads as zero, which is reported as stale, which values whatever
/// it priced at nothing. Degrading the ceiling is the safe direction; bricking the channel is not.
contract UsdPriceFeed is ISwarmFeed {
    /// @notice The IMD/ETH leg: wei of ETH per 1e18 IMD, the vault's primary price feed.
    ISwarmFeed public immutable imdEthFeed;

    /// @notice The ETH/USD leg, pinned in source.
    IAggregatorV3 public constant ETH_USD = IAggregatorV3(CHAINLINK_ETH_USD);

    error InvalidFeed();

    constructor(ISwarmFeed imdEthFeed_) {
        if (address(imdEthFeed_).code.length == 0) revert InvalidFeed();
        imdEthFeed = imdEthFeed_;
    }

    /// @notice USD per IMD scaled by 1e18, dated at the older of the two legs. Zero if either leg is.
    function latestValue() external view override returns (uint256 value, uint64 updatedAt) {
        (uint256 imdEth, uint64 imdAt) = imdEthFeed.latestValue();
        (uint256 ethUsd, uint64 ethAt, uint8 decimals) = _ethUsd();
        if (imdEth == 0 || ethUsd == 0) return (0, 0);
        // imdEth is 1e18-scaled ETH per IMD; ethUsd is USD per ETH in the aggregator's decimals.
        value = Math.mulDiv(imdEth, ethUsd, 10 ** decimals);
        updatedAt = imdAt < ethAt ? imdAt : ethAt;
    }

    /// @notice True if the IMD/ETH feed is stale, or the ETH/USD answer is missing, non-positive or
    /// older than ETH_USD_MAX_AGE.
    function isStale() external view override returns (bool) {
        if (imdEthFeed.isStale()) return true;
        (uint256 ethUsd, uint64 ethAt,) = _ethUsd();
        return ethUsd == 0 || _tooOld(ethAt);
    }

    /// @notice The ETH/USD leg on its own: USD per ETH scaled by 1e18. Zero if the answer is missing,
    /// non-positive or older than ETH_USD_MAX_AGE.
    /// @dev What converts a USD figure back into the unit the IMD/ETH leg prices in. The vault reads
    /// it to bring the Treasury's USD reserve value into the unit its own debt is denominated in; a
    /// zero means "no price", and the vault counts the reserve for nothing rather than dividing by it.
    function ethUsdPrice() external view returns (uint256) {
        (uint256 ethUsd, uint64 ethAt, uint8 decimals) = _ethUsd();
        if (ethUsd == 0 || _tooOld(ethAt)) return 0;
        return Math.mulDiv(ethUsd, 1e18, 10 ** decimals);
    }

    /// @notice The shorter of the two legs' maximum ages.
    function maxAge() external view override returns (uint256) {
        return Math.min(imdEthFeed.maxAge(), ETH_USD_MAX_AGE);
    }

    function _tooOld(uint64 at) private view returns (bool) {
        return block.timestamp > at && block.timestamp - at > ETH_USD_MAX_AGE;
    }

    /// @dev (0, 0, 0) for anything that is not a well-formed positive answer with a timestamp.
    function _ethUsd() private view returns (uint256 price, uint64 updatedAt, uint8 decimals) {
        (bool ok, bytes memory data) = address(ETH_USD).staticcall(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || data.length < 160) return (0, 0, 0);
        (, int256 answer,, uint256 at,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || at == 0 || at > type(uint64).max) return (0, 0, 0);
        (ok, data) = address(ETH_USD).staticcall(abi.encodeCall(IAggregatorV3.decimals, ()));
        if (!ok || data.length < 32) return (0, 0, 0);
        uint256 places = abi.decode(data, (uint256));
        if (places > 77) return (0, 0, 0); // 10 ** 78 overflows; no real aggregator is near this
        return (uint256(answer), uint64(at), uint8(places));
    }
}
