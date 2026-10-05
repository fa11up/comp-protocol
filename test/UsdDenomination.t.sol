// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {ReserveUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD} from "src/DeploymentConfig.sol";

/// @notice One COMP of debt is one USD-worth of collateral.
/// @dev What makes COMP a dollar stablecoin rather than an ETH-denominated CDP token. The swarm feed
/// quotes IMD in wei of ETH, so the base vault measures a position in ETH and a borrower's required
/// collateral moved whenever ETH moved even with IMD/ETH flat. ParameterizedVault prices through
/// `usdPriceFeed` instead — the same feed times Chainlink ETH/USD — which changes neither formula,
/// because both are ratios in `_price()`.
contract UsdDenominationTest is Test {
    address private constant BORROWER = address(0xB0B);

    /// @dev 1 IMD = 0.001 ETH, 1 ETH = $2,000, so 1 IMD = $2 exactly.
    uint256 private constant IMD_ETH = 0.001 ether;
    int256 private constant ETH_USD_ANSWER = 2_000e8;

    MockIMD private imd;
    TestSwarmFeed private primary;
    TestSwarmFeed private health;
    ParameterizedVault private usdVault;
    CDPVault private ethVault;
    ReserveUsdAggregator private usd;

    function setUp() public {
        TreasuryFactoryEtch.etch(vm);
        vm.chainId(11155111);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new TestSwarmFeed(IMD_ETH);
        health = new TestSwarmFeed(0.9 ether);
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(primary));

        usd = ReserveUsdAggregator(CHAINLINK_ETH_USD);
        vm.etch(CHAINLINK_ETH_USD, address(new ReserveUsdAggregator()).code);
        usd.setDecimals(8);
        usd.set(ETH_USD_ANSWER, block.timestamp);

        usdVault = new ParameterizedVault(address(imd), address(0), address(0), address(primary), address(health), address(spot));
        // The same inputs through the base vault, which still prices in the feed's own unit.
        MirroredSwarmFeed spot2 = new MirroredSwarmFeed(address(primary));
        ethVault = new CDPVault(address(imd), address(0), address(0), address(primary), address(health), address(spot2));

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 2_000 ether);
    }

    function _open(CDPVault vault, uint256 collateral, uint256 debt) private {
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(collateral);
        vault.draw(debt);
        vm.stopPrank();
    }

    /// @dev 1,000 IMD at $2 is $2,000 of collateral. Against 1,000 COMP of debt that is 200% — and it
    /// is 200% because a COMP is a dollar, not because of anything about ETH.
    function test_oneCompOfDebtIsOneUsdWorthOfCollateral() public {
        _open(usdVault, 1_000 ether, 1_000 ether);
        assertEq(usdVault.collateralRatio(BORROWER), 200, "1000 IMD at $2 backs 1000 COMP at 200%");

        // Doubling the dollar price of IMD doubles the ratio, whichever leg moves.
        usd.set(4_000e8, block.timestamp);
        assertEq(usdVault.collateralRatio(BORROWER), 400, "ETH doubling doubles it");
        usd.set(ETH_USD_ANSWER, block.timestamp);
        primary.setValue(IMD_ETH * 2);
        assertEq(usdVault.collateralRatio(BORROWER), 400, "and so does IMD doubling against ETH");
    }

    /// @dev The same position, measured both ways, and the gap is the whole reason for this change.
    /// 1,000 IMD at 0.001 ETH is 1 ETH of collateral. The base vault reads that against 0.5 COMP of
    /// debt as 200%, because it treats a COMP as an ETH. The USD vault reads the identical position as
    /// 400,000%, because 1,000 IMD is $2,000 and a COMP is a dollar.
    function test_theSamePositionMeasuresDifferentlyInEachUnit() public {
        _open(ethVault, 1_000 ether, 0.5 ether);
        assertEq(ethVault.collateralRatio(BORROWER), 200, "the base vault prices a COMP as an ETH");

        _open(usdVault, 1_000 ether, 0.5 ether);
        assertEq(usdVault.collateralRatio(BORROWER), 400_000, "the usd vault prices a COMP as a dollar");

        // And 1,000 COMP of debt is simply unopenable in ETH terms: 1 ETH cannot back it at mat 170.
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        ethVault.draw(1_000 ether);
    }

    /// @dev The regression that would have broken everything silently. The guard compares the primary
    /// feed against spot, both quoting IMD in ETH. Had it used `_price()`, the USD figure would sit
    /// ~2,000x from spot and every priced action would revert PriceDivergence.
    function test_denominationDoesNotTripTheDivergenceGuard() public {
        _open(usdVault, 1_000 ether, 100 ether);
        // _price() is three orders of magnitude larger than the spot feed, and that is fine.
        (uint256 spot,) = primary.latestValue();
        assertGt(usdVault.collateralRatio(BORROWER) , 0);
        assertEq(spot, IMD_ETH, "spot still quotes ETH per IMD");

        vm.startPrank(BORROWER);
        usdVault.draw(1);           // a priced action, through the guard
        usdVault.wipe(1);
        vm.stopPrank();
    }

    /// @dev Denominating in a unit this protocol does not publish adds a way to halt. That is the right
    /// direction — a position cannot be safely liquidated at a price nobody knows — but it is a real
    /// dependency, so it is pinned rather than discovered later.
    function test_aDeadUsdLegHaltsRatherThanMispricing() public {
        _open(usdVault, 1_000 ether, 100 ether);
        usd.set(0, block.timestamp);

        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        usdVault.draw(1);

        // The base vault, which does not read the USD leg, keeps working through the same outage.
        _open(ethVault, 1_000 ether, 0.5 ether);
        assertEq(ethVault.collateralRatio(BORROWER), 200, "a vault that does not price in USD is unaffected");
    }
}
