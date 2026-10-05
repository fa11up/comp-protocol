// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {ReserveUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {MockShareVault} from "./helpers/MockShareVault.sol";
import {Treasury} from "src/Treasury.sol";
import {Parameters} from "src/Parameters.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD} from "src/DeploymentConfig.sol";

/// @notice sIMD as collateral: a share of an ERC-4626 vault over IMD, 24 decimals against IMD's 18.
/// @dev The share is priced as its exchange rate times IMD's USD price, per 1e18 RAW units, so the
/// vault's arithmetic (which never reads decimals) values it correctly. `lockIMD` wraps on deposit.
contract ShareCollateralTest is Test {
    event Lock(address indexed account, uint256 amount);

    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xBEEF);

    /// @dev 1 IMD = 0.001 ETH and 1 ETH = $2,000, so 1 IMD = $2.
    uint256 private constant IMD_ETH = 0.001 ether;
    int256 private constant ETH_USD_ANSWER = 2_000e8;
    /// @dev 1 whole sIMD (1e24 raw) = 1.25 IMD (1.25e18 raw), so 1e18 raw shares = 1.25e12 raw IMD.
    uint256 private constant RATE = 1.25e12;

    MockIMD private imd;
    MockShareVault private share;
    TestSwarmFeed private primary;
    TestSwarmFeed private health;
    ReserveUsdAggregator private usd;
    ParameterizedVault private vault;

    function setUp() public {
        TreasuryFactoryEtch.etch(vm);
        vm.chainId(11155111);
        vm.warp(1_000_000);
        imd = new MockIMD();
        share = new MockShareVault(imd, RATE);
        primary = new TestSwarmFeed(IMD_ETH);
        health = new TestSwarmFeed(0.9 ether);
        usd = ReserveUsdAggregator(CHAINLINK_ETH_USD);
        vm.etch(CHAINLINK_ETH_USD, address(new ReserveUsdAggregator()).code);
        usd.setDecimals(8);
        usd.set(ETH_USD_ANSWER, block.timestamp);
        vault = new ParameterizedVault(
            address(share), address(0), address(0), address(primary), address(health),
            address(new MirroredSwarmFeed(address(primary)))
        );
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 10_000 ether);
        imd.mint(KEEPER, 10_000 ether);
        vm.stopPrank();
    }

    function _lockIMD(address who, uint256 assets) private returns (uint256 shares) {
        vm.startPrank(who);
        imd.approve(address(vault), assets);
        uint256 before = share.balanceOf(address(vault));
        vault.lockIMD(assets);
        vm.stopPrank();
        shares = share.balanceOf(address(vault)) - before;
    }

    function test_shareCollateralIsPricedAsRateTimesIMD() public view {
        assertTrue(address(vault.collateralPriceFeed()) != address(vault.usdPriceFeed()), "a share gets its own feed");
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        // 1e18 raw shares = 1.25e12 raw IMD, and 1e18 raw IMD = $2, so 1e18 raw shares = $2.5e-6.
        assertEq(price, RATE * 2e18 / 1e18, "rate x USD per IMD, per 1e18 raw share units");
    }

    function test_lockIMDWrapsAndCreditsTheSharesReceived() public {
        vm.startPrank(BORROWER);
        imd.approve(address(vault), 1_000 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Lock(BORROWER, 800e24);
        vault.lockIMD(1_000 ether);
        vm.stopPrank();
        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, 800e24, "1,000 IMD at 1.25 IMD per sIMD is 800 sIMD");
        assertEq(share.balanceOf(address(vault)), 800e24, "the vault holds the shares");
        assertEq(imd.balanceOf(address(vault)), 0, "and none of the underlying");
        assertEq(imd.allowance(address(vault), address(share)), 0, "no allowance is left behind");
    }

    /// @dev Wrapping changes the unit, not the value: 1,000 IMD at $2 backs 1,000 imdUSD at 200%
    /// whether it arrives as IMD through lockIMD or as the equivalent sIMD through lock.
    function test_wrappingPreservesValue() public {
        _lockIMD(BORROWER, 1_000 ether);
        vm.prank(BORROWER);
        vault.draw(1_000 ether);
        assertEq(vault.collateralRatio(BORROWER), 200, "wrapped IMD keeps its dollar value");

        vm.startPrank(KEEPER);
        imd.approve(address(share), 1_000 ether);
        uint256 shares = share.deposit(1_000 ether, KEEPER);
        share.approve(address(vault), shares);
        vault.lock(shares);
        vault.draw(1_000 ether);
        vm.stopPrank();
        assertEq(vault.collateralRatio(KEEPER), 200, "and so do shares locked directly");
    }

    /// @dev The point of sIMD: its rate only rises, so a position repairs itself over time.
    function test_shareYieldRaisesTheRatio() public {
        _lockIMD(BORROWER, 1_000 ether);
        vm.prank(BORROWER);
        vault.draw(1_000 ether);
        share.setRate(RATE * 11 / 10);
        assertEq(vault.collateralRatio(BORROWER), 220, "a 10% rate rise is a 10% higher ratio");
    }

    function test_creditIsWhatArrivedNotWhatDepositReported() public {
        share.setReportDouble(true);
        uint256 shares = _lockIMD(BORROWER, 1_000 ether);
        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, shares, "credited by balance, not by the return value");
        assertEq(collateral, 800e24);
    }

    /// @dev A share vault that stops answering reads as stale: priced actions halt, deposits do not.
    function test_aSilentShareVaultHaltsPricedActions() public {
        _lockIMD(BORROWER, 1_000 ether);
        share.setSilent(true);
        assertTrue(vault.collateralPriceFeed().isStale(), "unreadable rate is stale");
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.draw(1 ether);
    }

    /// @dev Liquidation moves shares by plain transfer, which sIMD's one-block hold does not block.
    function test_biteSeizesShares() public {
        _lockIMD(BORROWER, 1_000 ether);
        vm.prank(BORROWER);
        vault.draw(1_000 ether);
        // The keeper needs imdUSD to burn: borrow it against its own wrapped collateral.
        _lockIMD(KEEPER, 5_000 ether);
        vm.prank(KEEPER);
        vault.draw(600 ether);

        // IMD falls to $1.40: the borrower sits at 140%, under mat 170; the keeper stays safe.
        primary.setValue(IMD_ETH * 7 / 10);
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        vm.warp(block.timestamp + vault.lull() + 1);
        primary.setValue(IMD_ETH * 7 / 10);
        usd.set(ETH_USD_ANSWER, block.timestamp);

        uint256 before = share.balanceOf(KEEPER);
        vm.prank(KEEPER);
        vault.bite(BORROWER, 100 ether);
        assertGt(share.balanceOf(KEEPER), before, "the keeper is paid in sIMD");
    }

    function test_lockIMDIsRefusedWhenTheCollateralIsNotAShare() public {
        ParameterizedVault plain = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health),
            address(new MirroredSwarmFeed(address(primary)))
        );
        assertEq(address(plain.collateralPriceFeed()), address(plain.usdPriceFeed()), "IMD is priced directly");
        vm.startPrank(BORROWER);
        imd.approve(address(plain), 1 ether);
        vm.expectRevert(CDPVault.CollateralNotWrappable.selector);
        plain.lockIMD(1 ether);
        vm.stopPrank();
    }

    /// @dev Docs job 2f5a387d: the Treasury divided a listed asset's balance by 10**decimals, which
    /// means "price per whole token", while sIMD's only price source quotes per 1e18 RAW units. Listed
    /// through the vault's own collateralPriceFeed, sIMD counted for a millionth of its value.
    function test_shareCollateralInTheReserveIsValuedAsTheVaultValuesIt() public {
        Treasury treasury = vault.treasury();
        Parameters params = vault.parameters();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(address(this), 100 ether);
        vm.stopPrank();
        imd.approve(address(share), 100 ether);
        uint256 shares = share.deposit(100 ether, address(treasury));

        ISwarmFeed source = vault.collateralPriceFeed();
        vm.prank(APPROVED_OPERATOR);
        params.proposeReserveAsset(share, source, 10_000);
        vm.warp(block.timestamp + params.TIMELOCK());
        usd.set(ETH_USD_ANSWER, block.timestamp);
        primary.setValue(IMD_ETH);
        params.applyPending();

        (uint256 price,) = source.latestValue();
        assertEq(treasury.reserveValueOf(share), Math.mulDiv(shares, price, 1e18), "per 1e18 raw, like the vault");
        // 100 IMD at $2 = $200, wrapped or not.
        assertApproxEqAbs(treasury.reserveValueOf(share), 200 ether, 1e6);
    }
}
