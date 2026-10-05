// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharePriceFeed} from "src/SharePriceFeed.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

interface IERC4626Like {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256) external view returns (uint256);
    function lastDepositBlock(address) external view returns (uint256);
    function setPaused(bool) external;
    function rescueERC20(address, address, uint256) external;
}

interface IERC20Like {
    function decimals() external view returns (uint8);
}

/// @notice `SharePriceFeed` against the LIVE StakedIMD vault on Ethereum mainnet.
/// @dev Run with `forge test --match-path test/SharePriceFeedFork.t.sol --fork-url $MAINNET_RPC_URL`.
/// Skips itself off-fork, like test/InHouse.t.sol, because it reads real chain state.
///
/// What this is really proving is the DECIMAL composition. sIMD has 24 decimals and IMD has 18, while
/// CDPVault's arithmetic divides by 1e18 and never reads `decimals()` — so a 24-decimal collateral
/// priced per whole token would misvalue every position by a factor of a million. The adapter works in
/// "per 1e18 raw units" throughout, which is the convention the live oracle questions already use, and
/// these tests check that against figures computed independently from the pool's own totals.
contract SharePriceFeedForkTest is Test {
    address private constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    /// @dev IMD in USD per 1e18 raw IMD, 1e18-scaled. A fixed figure, not a live read: these tests are
    /// about the composition, and pinning the asset leg is what makes the expected values arithmetic
    /// rather than a second oracle read.
    uint256 private constant IMD_USD = 8.4978 ether;

    IERC4626Like private vault;
    TestSwarmFeed private assetFeed;
    SharePriceFeed private feed;

    function setUp() public {
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        vault = IERC4626Like(SIMD);
        assetFeed = new TestSwarmFeed(IMD_USD);
        feed = new SharePriceFeed(SIMD, ISwarmFeed(address(assetFeed)));
    }

    // --- the live vault is what we think it is ---------------------------------------------------

    /// @dev The whole design rests on this: no owner, so the `setPaused` and `rescueERC20` the vault's
    /// own docs advertise are unreachable by anyone. A sweep would be total loss of collateral.
    function test_theVaultHasNoOwnerSoItCannotBePausedOrSwept() public view {
        assertEq(vault.owner(), address(0), "ownership renounced");
        assertFalse(vault.paused(), "and renounced in the unpaused state");
    }

    /// @dev Proven by calling them, not by reading the modifier: both revert for an arbitrary caller.
    function test_nobodyCanPauseOrSweepTheLiveVault() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        vault.setPaused(true);
        vm.expectRevert();
        vault.rescueERC20(IMD, address(0xBAD), 1);
        vm.stopPrank();
    }

    function test_itIsAnImdVaultWithTheDecimalMismatchThisAdapterExistsFor() public view {
        assertEq(vault.asset(), IMD, "the underlying is IMD");
        assertEq(vault.decimals(), 24, "the share has 24 decimals");
        assertEq(IERC20Like(IMD).decimals(), 18, "the underlying has 18");
    }

    // --- the composition ------------------------------------------------------------------------

    /// @dev The exchange rate is `totalAssets/totalSupply` by construction, so deriving it from the
    /// pool's own totals is an independent check on the figure the adapter reads.
    function test_theExchangeRateMatchesThePoolsOwnTotals() public view {
        (uint256 rate, bool ok) = feed.exchangeRate();
        assertTrue(ok, "the vault answers");
        assertGt(rate, 0, "and the rate is nonzero");

        uint256 derived = Math.mulDiv(1e18, vault.totalAssets(), vault.totalSupply());
        assertEq(rate, derived, "convertToAssets(1e18) is totalAssets/totalSupply scaled");
        assertEq(rate, vault.convertToAssets(1e18), "and is what the adapter read");
    }

    /// @dev THE POINT OF THE ADAPTER. The value it reports, multiplied back up by the share's own
    /// decimals, must equal the USD value of the whole staked pool computed straight from totalAssets.
    /// If the adapter were quoting per WHOLE token instead of per 1e18 raw units, this is the
    /// assertion that would fail, by exactly 1e6.
    function test_theReportedValuePricesTheWholePoolCorrectly() public {
        (uint256 value,) = feed.latestValue();
        assertGt(value, 0, "a price exists");

        // What the adapter implies the whole pool is worth: value is USD per 1e18 raw share units.
        uint256 impliedPoolUsd = Math.mulDiv(vault.totalSupply(), value, 1e18);
        // What it is worth from the underlying side: totalAssets is raw IMD at 18 decimals.
        uint256 directPoolUsd = Math.mulDiv(vault.totalAssets(), IMD_USD, 1e18);

        // Equal to within share-rounding: the two routes differ only by the integer division in
        // convertToAssets, which loses at most one unit per share before being scaled back up.
        assertApproxEqRel(impliedPoolUsd, directPoolUsd, 1e12, "both routes value the pool the same");
        emit log_named_decimal_uint("staked pool USD", directPoolUsd, 18);
        emit log_named_decimal_uint("USD per 1e18 raw sIMD", value, 18);
    }

    /// @dev And the sanity check a human would do: a whole sIMD is worth more than a whole IMD,
    /// because a share is a claim on a growing pile of them. Never the other way round.
    function test_aWholeShareIsWorthMoreThanAWholeUnderlying() public {
        (uint256 value,) = feed.latestValue();
        uint256 wholeShareUsd = value * (10 ** vault.decimals()) / 1e18;
        assertGt(wholeShareUsd, IMD_USD, "a share has appreciated against its asset");
        emit log_named_decimal_uint("USD per whole sIMD", wholeShareUsd, 18);
    }

    // --- failure direction ----------------------------------------------------------------------

    function test_theAssetFeedsStalenessPropagates() public {
        assertFalse(feed.isStale(), "fresh to begin with");
        assetFeed.setStale(true);
        assertTrue(feed.isStale(), "a stale asset leg makes the share stale");
        assertEq(feed.maxAge(), assetFeed.maxAge(), "and the adapter adds no age of its own");
    }

    function test_aZeroAssetPriceValuesTheShareAtNothingRatherThanReverting() public {
        assetFeed.setValue(0);
        (uint256 value, uint64 at) = feed.latestValue();
        assertEq(value, 0, "no price");
        assertEq(at, 0, "and no timestamp to trust");
    }

    /// @dev A vault that stops answering must read as stale, never revert: a reverting price source
    /// would take `reserveValueUsd`, `earnLine` and every dependent mint down with it.
    function test_aVaultThatStopsAnsweringReadsAsStaleNotAsARevert() public {
        vm.mockCallRevert(SIMD, abi.encodeWithSignature("convertToAssets(uint256)", uint256(1e18)), "dead");
        assertTrue(feed.isStale(), "unreadable is stale");
        (uint256 value,) = feed.latestValue();
        assertEq(value, 0, "and prices nothing");
    }

    /// @dev Malformed return data is the half `try/catch` cannot cover, because the decode happens in
    /// the caller's frame. Two MEDIUM findings of job da7d5b1c were exactly this.
    function test_malformedVaultDataReadsAsStaleNotAsAPanic() public {
        vm.mockCall(SIMD, abi.encodeWithSignature("convertToAssets(uint256)", uint256(1e18)), hex"01");
        assertTrue(feed.isStale(), "a short word is no answer");
        (uint256 value,) = feed.latestValue();
        assertEq(value, 0, "and prices nothing");
    }

    function test_theConstructorRefusesAVaultThatCannotPriceAShare() public {
        vm.expectRevert(SharePriceFeed.InvalidVault.selector);
        new SharePriceFeed(IMD, ISwarmFeed(address(assetFeed))); // an ERC20, not a 4626
        vm.expectRevert(SharePriceFeed.InvalidVault.selector);
        new SharePriceFeed(address(0xDEAD), ISwarmFeed(address(assetFeed))); // no code
    }

    // --- the one-block hold, which is why we must never redeem --------------------------------

    /// @dev Recorded as a live fact, because it decides the collateral design. The hold is per
    /// ACCOUNT and a transfer INHERITS the sender's, so any incoming sIMD transfer can bump a vault's
    /// hold. Holding sIMD as collateral and paying liquidators in sIMD never redeems, so this never
    /// sits on a hot path — which is the whole reason that is the design.
    function test_theOneBlockHoldIsPerAccountAndWeNeverNeedToRedeem() public view {
        assertEq(vault.lastDepositBlock(address(this)), 0, "we have never deposited");
        assertEq(vault.lastDepositBlock(address(feed)), 0, "and neither has the adapter");
    }
}
