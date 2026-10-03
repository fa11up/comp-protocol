// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkBackingFixture, ReserveTestToken} from "./helpers/WorkBackingFixture.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {Treasury} from "src/Treasury.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Governed} from "src/Governed.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, ETH_USD_MAX_AGE, FEE_RECIPIENT} from "src/DeploymentConfig.sol";

contract ReserveValuationTest is WorkBackingFixture {
    function test_vaultOwnsItsReserveAndUsesTheSameTreasuryForFeesAndCeiling() public view {
        assertEq(reserve.vault(), address(backedVault));
        assertEq(reserve.registrar(), address(parameters));
        assertEq(backedVault.feeRecipient(), address(reserve));
        assertTrue(address(reserve) != FEE_RECIPIENT);
        assertEq(address(backedVault.usdPriceFeed().imdEthFeed()), address(primary));
        assertEq(reserve.reserveAssetCount(), 0);
    }

    function test_registerRequiresGovernanceDelayAndAllowsAnyoneToApply() public {
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeReserveAsset(asset, reservePrice, 5000);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.Unauthorized.selector);
        reserve.setReserveAsset(asset, reservePrice, 5000);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeReserveAsset(asset, reservePrice, 5000);
        asset.mint(address(reserve), 100 ether);
        assertEq(reserve.reserveValueUsd(), 0, "pending listing cannot back work");
        uint256 eta = parameters.pendingEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        _apply();
        assertEq(reserve.reserveValueUsd(), 50 ether);
        assertEq(backedVault.workCeiling(), 50 ether);
    }

    function test_compExplicitlyRejectedAndUnlistedBalancesNeverBackWork() public {
        _openDebt(100 ether);
        vm.prank(BORROWER);
        stable.transfer(address(reserve), 50 ether);
        asset.mint(address(reserve), 100 ether);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(reserve.reserveValueOf(stable), 0);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.CompIsNotReserve.selector);
        parameters.proposeReserveAsset(stable, reservePrice, 5000);
        assertEq(parameters.pendingEta(), 0);
    }

    function test_invalidAssetFeedAndOutOfRangeHaircutCannotOccupyProposalSlot() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        parameters.proposeReserveAsset(IERC20(address(0)), reservePrice, 5000);
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        parameters.proposeReserveAsset(IERC20(address(0x123)), reservePrice, 5000);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, ISwarmFeed(address(0x123)), 5000);
        vm.expectRevert(abi.encodeWithSelector(Treasury.HaircutOutOfRange.selector, 10001));
        parameters.proposeReserveAsset(asset, reservePrice, 10001);
        vm.expectRevert(Treasury.NotAReserveAsset.selector);
        parameters.proposeReserveAsset(asset, ISwarmFeed(address(0)), 0);
        vm.stopPrank();
        assertEq(parameters.pendingEta(), 0);
        assertEq(reserve.reserveAssetCount(), 0);
    }

    function test_zeroHaircutValuesFundedAssetAtNothingAndCannotAuthorizeWork() public {
        _register(asset, reservePrice, 0);
        asset.mint(address(reserve), 100 ether);
        assertTrue(reserve.isReserveAsset(asset), "zero factor is a valid listing");
        assertEq(reserve.reserveAssetCount(), 1);
        assertEq(reserve.reserveAsset(asset).haircutBps, 0);
        assertEq(reserve.reserveValueOf(asset), 0);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(backedVault.workCeiling(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.mintFromWork(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        assertEq(backedVault.totalWorkMinted(), 0);
        assertEq(stable.totalSupply(), 0);
    }

    function test_fullHaircutValuesEntireAssetAndAuthorizesOnlyItsValue() public {
        _register(asset, reservePrice, 10_000);
        reservePrice.setValue(3 ether);
        asset.mint(address(reserve), 2 ether + 1);
        uint256 expected = 6 ether + 3;
        assertEq(reserve.reserveAsset(asset).haircutBps, 10_000);
        assertEq(reserve.reserveValueOf(asset), expected);
        assertEq(reserve.reserveValueUsd(), expected);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(backedVault.workCeiling(), expected);
        _mintWork(WORKER, expected);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.mintFromWork(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - expected);
        assertEq(backedVault.totalWorkMinted(), expected);
        assertEq(stable.balanceOf(WORKER), expected);
        assertEq(stable.totalSupply(), expected);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_valuesTokenDecimalsAndRoundsDustDown(
        uint96 rawBalance,
        uint64 rawPrice,
        uint8 rawDecimals,
        uint16 rawHaircut
    ) public {
        uint8 decimals = uint8(bound(rawDecimals, 0, 18));
        uint256 balance = rawBalance;
        uint256 price = bound(rawPrice, 1, type(uint64).max);
        uint256 haircut = bound(rawHaircut, 0, 10_000);
        ReserveTestToken token = new ReserveTestToken(decimals);
        TestSwarmFeed feed = new TestSwarmFeed(price);
        _register(token, feed, haircut);
        token.mint(address(reserve), balance);
        uint256 marked = balance * price / (10 ** decimals);
        uint256 expected = marked * haircut / 10_000;
        assertEq(reserve.reserveValueOf(token), expected);
        assertEq(reserve.reserveValueUsd(), expected);
        assertEq(backedVault.workCeiling(), expected);
        assertLe(expected, marked);
    }

    function test_largeReserveProductUsesFullPrecisionBeforeDecimalScaling() public {
        _register(asset, reservePrice, 5000);
        uint256 balance = uint256(1) << 200;
        asset.mint(address(reserve), balance);
        reservePrice.setValue(1e24);
        assertEq(reserve.reserveValueUsd(), balance * 1e6 / 2);
    }

    function test_registerSumsDifferentDecimalsAndRepricingDoesNotDuplicateAsset() public {
        ReserveTestToken six = new ReserveTestToken(6);
        TestSwarmFeed dollars = new TestSwarmFeed(2 ether);
        _fundReserve(7 ether);
        _register(six, dollars, 5000);
        six.mint(address(reserve), 3e6);
        assertEq(reserve.reserveValueUsd(), 10 ether);
        _register(six, reservePrice, 5000);
        assertEq(reserve.reserveAssetCount(), 2);
        assertEq(reserve.reserveValueUsd(), 8.5 ether);
        _register(asset, ISwarmFeed(address(0)), 0);
        assertEq(reserve.reserveAssetCount(), 1);
        assertEq(address(reserve.reserveAssets()[0]), address(six));
        assertEq(reserve.reserveValueUsd(), 1.5 ether);
        _register(six, ISwarmFeed(address(0)), 0);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(reserve.reserveAssetCount(), 0);
        _register(asset, reservePrice, 5000);
        assertEq(reserve.reserveValueUsd(), 7 ether);
    }

    function test_valuationReadsLiveCustodyWithoutRequiringSync() public {
        _fundReserve(10 ether);
        assertEq(reserve.totalReceived(asset), 0);
        assertEq(reserve.reserveValueUsd(), 10 ether);
        assertEq(reserve.sync(asset), 20 ether);
        assertEq(reserve.sync(asset), 0);
        asset.mint(address(reserve), 4 ether);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(asset, OTHER_WORKER, 2 ether);
        assertEq(reserve.totalReceived(asset), 24 ether);
        assertEq(reserve.lastSynced(asset), 22 ether);
        assertEq(reserve.reserveValueUsd(), 11 ether);
        assertEq(reserve.sync(asset), 0);
    }

    function test_staleImdLegReportsStaleAndCannotValueOrAuthorizeReserve() public {
        _seedUsdReserve();
        primary.setStale(true);
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 0, "never use the stale composite quote");
        assertEq(backedVault.workCeiling(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        backedVault.mintFromWork(1);
        primary.setStale(false);
        assertEq(reserve.reserveValueUsd(), 2000 ether);
    }

    function test_staleUsdLegAtExactAgeBoundaryCannotAuthorizeNewWork() public {
        _seedUsdReserve();
        uint256 timestamp = vm.getBlockTimestamp();
        vm.warp(timestamp + ETH_USD_MAX_AGE);
        assertFalse(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 2000 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(primary.isStale());
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.workCeiling(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.mintFromWork(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        usd.set(2000e8, vm.getBlockTimestamp());
        _mintWork(WORKER, 2000 ether);
    }

    function test_missingNonpositiveAndUndatedUsdAnswersCannotBackWork() public {
        _seedUsdReserve();
        usd.set(0, vm.getBlockTimestamp());
        _assertUsdUnavailable();
        usd.set(-1, vm.getBlockTimestamp());
        _assertUsdUnavailable();
        usd.set(2000e8, 0);
        _assertUsdUnavailable();
        usd.set(2000e8, vm.getBlockTimestamp());
        usd.setDecimals(78);
        _assertUsdUnavailable();
        vm.etch(CHAINLINK_ETH_USD, hex"");
        _assertUsdUnavailable();
    }

    function test_zeroReservePriceAndOneStaleAssetDoNotValueOtherAssetsIncorrectly() public {
        _fundReserve(12 ether);
        _register(collateral, backedVault.usdPriceFeed(), 5000);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), 2 ether);
        assertEq(reserve.reserveValueUsd(), 2012 ether);
        usd.set(0, vm.getBlockTimestamp());
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 12 ether);
        reservePrice.setValue(0);
        assertEq(reserve.reserveValueUsd(), 0);
    }

    function test_usdCompositeScalesBothLegsAndKeepsOldestTimestamp() public {
        primary.setValue(0.002 ether);
        usd.set(2500e8, vm.getBlockTimestamp() - 10);
        (uint256 value, uint64 at) = backedVault.usdPriceFeed().latestValue();
        assertEq(value, 5 ether);
        assertEq(at, vm.getBlockTimestamp() - 10);
        vm.warp(vm.getBlockTimestamp() + 20);
        usd.set(2500e8, vm.getBlockTimestamp());
        (, at) = backedVault.usdPriceFeed().latestValue();
        assertEq(at, vm.getBlockTimestamp() - 20);
    }

    function test_liquidationProtocolCutAndMintedStabilityFeesBothLandInVaultTreasury() public {
        _openDebt(100 ether);
        vm.prank(BORROWER);
        stable.transfer(WORKER, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        primary.setValue(0.6 ether);
        health.setValue(0.6 ether); // Zero grace, preserving the exact accrued fee read below.
        vm.prank(OTHER_WORKER);
        backedVault.markUnderwater(BORROWER);
        uint256 fee = backedVault.stabilityFeeOf(BORROWER);
        assertGt(fee, 0);
        assertLt(fee, 50 ether);
        uint256 seized = 50 ether * 1.1 ether / uint256(0.6 ether);
        uint256 principalCollateral = 50 ether * 1 ether / uint256(0.6 ether);
        uint256 cut = (seized - principalCollateral) * backedVault.protocolBonusShareBps() / 10_000;
        uint256 markerCut = (seized - principalCollateral) * backedVault.markerShareBps() / 10_000;
        assertGt(cut, 0);
        uint256 oldRecipientCollateral = collateral.balanceOf(FEE_RECIPIENT);
        uint256 oldRecipientComp = stable.balanceOf(FEE_RECIPIENT);
        vm.prank(WORKER);
        backedVault.liquidate(BORROWER, 50 ether);
        assertEq(collateral.balanceOf(address(reserve)), cut);
        assertEq(stable.balanceOf(address(reserve)), fee);
        assertEq(backedVault.totalFeesMinted(), fee);
        assertEq(collateral.balanceOf(WORKER), seized - cut - markerCut);
        assertEq(collateral.balanceOf(OTHER_WORKER), markerCut);
        assertEq(backedVault.totalDebt(), 50 ether + fee);
        assertEq(stable.totalSupply(), 50 ether + fee);
        assertEq(collateral.balanceOf(FEE_RECIPIENT), oldRecipientCollateral);
        assertEq(stable.balanceOf(FEE_RECIPIENT), oldRecipientComp);
        assertEq(reserve.sync(collateral), cut);
        assertEq(reserve.sync(stable), fee);
        assertEq(reserve.reserveValueOf(stable), 0, "fee liability is never reserve backing");
    }

    function _seedUsdReserve() internal {
        _register(collateral, backedVault.usdPriceFeed(), 5000);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), 2 ether);
        assertEq(reserve.reserveValueUsd(), 2000 ether);
    }

    function _assertUsdUnavailable() internal view {
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.workCeiling(), 0);
    }
}
