// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IFeedLike {
    function latestValue() external view returns (uint256 value, uint256 updatedAt);
    function isStale() external view returns (bool);
    function report(uint256 value) external;
    function isReporter(address who) external view returns (bool);
    function maxDeviationBps() external view returns (uint256);
}

interface IVaultLike {
    function usdPriceFeed() external view returns (address);
    function priceFeed() external view returns (address);
    function spotFeed() external view returns (address);
    function nhiFeed() external view returns (address);
    function mat() external view returns (uint256);
}

/// @notice Seed launch 688's spot and health feeds from the price the SWARM attested.
///
/// RUN THIS ONLY AFTER a price attestation has been relayed into PriceFeed. The order is
/// deliberate and not interchangeable: `SwarmFeed._checkValue` applies its deviation bound only
/// `if (_hasValue && !_tooOld(...))`, so the FIRST value a feed accepts is unconstrained. Buying the
/// attestation while PriceFeed is empty means whatever the window median turns out to be will land.
/// Seeding PriceFeed by hand first would instead force the attestation to come within 20% of a
/// figure we invented, which is an avoidable way to lose 0.5 IMD.
///
/// Spot is then set to the attested price EXACTLY, so `skew` has nothing to object to.
/// NHI is set to 0.9e18, which the curve maps to mat 150 and a six-hour grace.
///
/// TESTNET ONLY. This uses the reporter fallback, which is the mainnet hole this protocol is
/// deleting (see `src/DeploymentConfig.sol`): past `maxAge` the deviation bound lifts and the next
/// reported value re-anchors the feed to anything. It is here because launch 688 was deployed from
/// a commit that predates the deletion, and because seeding two feeds by hand costs gas instead of
/// 1.0 IMD. Nothing about this path should ever be copied to mainnet.
contract SeedLaunch688 is Script {
    address constant PRICE_FEED = 0x5bbFA44200AcE481388B0B69355F7Bd1FeAb0462;
    address constant NHI_FEED = 0xd7C9a4604d9FbFE192232D7c4B7215EFe0005bbB;
    address constant SPOT_FEED = 0x73BF2ebfc5Bf181AC23799D2d79AC2B48F20284b;
    address constant VAULT = 0x850B0d7a6dD95bE3e842c0ef14EEFE0008f2c68F;

    /// @dev 0.9e18 maps to mat 150 / grace 6h on the health curve.
    uint256 constant NHI_SEED = 0.9 ether;

    function run() external {
        address me = msg.sender;
        console.log("reporter:", me);

        (uint256 price, uint256 priceAt) = IFeedLike(PRICE_FEED).latestValue();
        console.log("PriceFeed value:", price);
        console.log("PriceFeed updatedAt:", priceAt);
        require(price != 0, "PriceFeed is still empty: relay the attestation FIRST, then run this");
        require(!IFeedLike(PRICE_FEED).isStale(), "PriceFeed is stale: relay a fresh attestation first");

        require(IFeedLike(SPOT_FEED).isReporter(me), "not a reporter on SpotFeed");
        require(IFeedLike(NHI_FEED).isReporter(me), "not a reporter on NhiFeed");

        vm.startBroadcast();
        // Spot takes the attested price verbatim, so divergence is exactly zero rather than merely
        // inside the bound. Any later drift is then a real market move and not a seeding artefact.
        IFeedLike(SPOT_FEED).report(price);
        IFeedLike(NHI_FEED).report(NHI_SEED);
        vm.stopBroadcast();

        verify(price);
    }

    /// @notice Read every figure back off chain rather than trusting the calls above returned.
    function verify(uint256 price) internal view {
        (uint256 spot,) = IFeedLike(SPOT_FEED).latestValue();
        (uint256 nhi,) = IFeedLike(NHI_FEED).latestValue();
        console.log("SpotFeed value:", spot);
        console.log("NhiFeed value:", nhi);
        require(spot == price, "spot did not take the attested price");
        require(nhi == NHI_SEED, "nhi did not take its seed");
        require(!IFeedLike(SPOT_FEED).isStale(), "spot stale after seeding");
        require(!IFeedLike(NHI_FEED).isStale(), "nhi stale after seeding");

        // The guard the vault actually applies, recomputed here so a pass means the vault will act.
        uint256 gap = spot > price ? spot - price : price - spot;
        console.log("divergence (wei):", gap);
        require(gap == 0, "seeded with a nonzero gap");

        console.log("vault mat:", IVaultLike(VAULT).mat());
        console.log("SEEDED. The vault can price, and divergence is zero.");
    }
}
