// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CDPVault} from "src/CDPVault.sol";

/// @notice A vault with its economics inert, for suites that are about mechanics rather than money.
/// @dev The shipped rate is non-zero, and accrual moves every debt figure by the time elapsed in a
/// test. Suites that exist to pin liquidation payouts, divergence, bad debt or borrower accounting
/// would all have to restate their expectations in terms of accrual to say the same things they say
/// now, which would bury what each one is actually asserting. They use this instead, so zero-rate
/// behaviour stays covered exactly as before and the shipped rate is covered where it belongs.
///
/// This is why duty is virtual, as line and cut already were.
/// It replaces test/check_stability_fee.py, which could only reach a non-zero rate by copying the
/// source and rewriting the constant outside the build.
contract BaselineVault is CDPVault {
    constructor(
        address gem_,
        address stablecoin_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) CDPVault(gem_, stablecoin_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {}

    function duty() public pure override returns (uint256) {
        return 0;
    }

    /// @dev Zero too, for the same reason: a protocol share changes every liquidation payout, and
    /// suites pinning those payouts longhand are testing the split arithmetic, not the share.
    /// ProtocolShare tests and the shipped-configuration tests cover the real value.
    function cut() public pure override returns (uint256) {
        return 0;
    }
}

/// @notice A vault at a fixed 10% annual rate.
/// @dev NonzeroStabilityFeeTest's arithmetic is written out longhand against this rate — index
/// deltas, fee totals and ratios all stated as exact numbers. Holding the rate here keeps every one
/// of those assertions saying what it says, instead of restating them in terms of whatever the
/// deployment currently ships and losing the exactness that makes them worth having.
contract TenPercentFeeVault is CDPVault {
    constructor(
        address gem_,
        address stablecoin_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) CDPVault(gem_, stablecoin_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {}

    function duty() public pure override returns (uint256) {
        return 1_000;
    }
}
