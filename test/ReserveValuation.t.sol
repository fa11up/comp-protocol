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

/// @dev A price source that answers correctly until told to revert on one read or the other.
contract FlakyFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    bool public breakIsStale;
    bool public breakLatestValue;

    constructor(uint256 value_) {
        value = value_;
    }

    function setBroken(bool isStale_, bool latestValue_) external {
        breakIsStale = isStale_;
        breakLatestValue = latestValue_;
    }

    function latestValue() external view returns (uint256, uint64) {
        if (breakLatestValue) revert("source is dead");
        return (value, uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        if (breakIsStale) revert("source is dead");
        return false;
    }
}

/// @dev Has code, never reverts, returns one byte to anything: a typed call would fail to decode it.
contract OneByteFeed {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 1)
        }
    }
}

/// @dev Answers isStale properly but returns a single word where latestValue needs two.
contract ShortLatestValueFeed {
    function isStale() external pure returns (bool) {
        return false;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

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
        assertEq(backedVault.reserveValue(), 50 ether);
        assertEq(backedVault.earnLine(), 50 ether);
    }

    function test_compExplicitlyRejectedAndUnlistedBalancesNeverBackWork() public {
        _openDebt(100 ether);
        vm.prank(BORROWER);
        stable.transfer(address(reserve), 50 ether);
        asset.mint(address(reserve), 100 ether);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(reserve.reserveValueOf(stable), 0);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.StablecoinIsNotReserve.selector);
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

    function test_priceSourceWithCodeThatDoesNotAnswerBothReadsIsRefusedAtProposal() public {
        FlakyFeed flaky = new FlakyFeed(ASSET_USD);
        ISwarmFeed oneByte = ISwarmFeed(address(new OneByteFeed()));
        ISwarmFeed shortLatest = ISwarmFeed(address(new ShortLatestValueFeed()));
        vm.startPrank(APPROVED_OPERATOR);
        // A contract that is not a feed at all: the IMD token has code and no isStale().
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, ISwarmFeed(address(collateral)), 5000);
        // Answers, but with one byte where a bool word is needed.
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, oneByte, 5000);
        // isStale is fine, latestValue is one word short.
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, shortLatest, 5000);
        // Reverts on exactly one of the two reads, either way round.
        flaky.setBroken(true, false);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, flaky, 5000);
        flaky.setBroken(false, true);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(asset, flaky, 5000);
        vm.stopPrank();
        assertEq(parameters.pendingEta(), 0);
        assertEq(reserve.reserveAssetCount(), 0);
        // The same source answering both reads lists normally.
        flaky.setBroken(false, false);
        _register(asset, flaky, 5000);
        assertTrue(reserve.isReserveAsset(asset));
    }

    function test_sourceThatDiesAfterListingCountsForNothingInsteadOfRevertingTheCeiling() public {
        ReserveTestToken second = new ReserveTestToken(18);
        FlakyFeed flaky = new FlakyFeed(ASSET_USD);
        _fundReserve(10 ether);
        _register(second, flaky, 5000);
        second.mint(address(reserve), 10 ether);
        _openDebt(100 ether);
        assertEq(reserve.reserveValueOf(second), 5 ether);
        assertEq(reserve.reserveValueUsd(), 15 ether);
        assertEq(backedVault.earnLine(), 40 ether);

        flaky.setBroken(true, false);
        assertEq(reserve.reserveValueOf(second), 0, "a source that cannot say whether it is stale is stale");
        assertEq(reserve.reserveValueUsd(), 10 ether, "the other asset still counts");
        assertEq(backedVault.earnLine(), 35 ether);
        flaky.setBroken(false, true);
        assertEq(reserve.reserveValueOf(second), 0, "a source with no price prices nothing");
        assertEq(backedVault.earnLine(), 35 ether);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(35 ether + 1);
        _mintWork(WORKER, 35 ether);

        flaky.setBroken(false, false);
        assertEq(backedVault.earnLine(), 40 ether);
        _mintWork(WORKER, 5 ether);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(1);
        // And the dead source could still have been delisted had it stayed dead: removal reads nothing.
        flaky.setBroken(true, true);
        _register(second, ISwarmFeed(address(0)), 0);
        assertFalse(reserve.isReserveAsset(second));
        assertEq(reserve.reserveValueUsd(), 10 ether);
    }

    function test_tokenClaimingMoreThanSeventySevenDecimalsIsRefusedAndSeventySevenIsNot() public {
        ReserveTestToken tooMany = new ReserveTestToken(78);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        parameters.proposeReserveAsset(tooMany, reservePrice, 5000);
        assertEq(parameters.pendingEta(), 0);

        ReserveTestToken most = new ReserveTestToken(77);
        _register(most, reservePrice, 10_000);
        assertEq(reserve.reserveAsset(most).decimals, 77);
        most.mint(address(reserve), 10 ** 77 - 1);
        assertEq(reserve.reserveValueOf(most), ASSET_USD - 1, "a hair under one whole token rounds down, no panic");
        most.mint(address(reserve), 1);
        assertEq(reserve.reserveValueOf(most), ASSET_USD, "one whole token at 77 places is priced once");
        assertEq(backedVault.reserveValue(), 1 ether);
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
        assertEq(backedVault.earnLine(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        assertEq(backedVault.totalEarned(), 0);
        assertEq(stable.totalSupply(), 0);
    }

    function test_fullHaircutValuesEntireAssetAndAuthorizesOnlyItsValue() public {
        _register(asset, reservePrice, 10_000);
        asset.mint(address(reserve), 2 ether + 1);
        // USD and the vault's unit are the same now, so the register's figure IS the ceiling's term.
        uint256 expectedUsd = 2 ether + 1;
        uint256 expected = expectedUsd;
        assertEq(reserve.reserveAsset(asset).haircutBps, 10_000);
        assertEq(reserve.reserveValueOf(asset), expectedUsd);
        assertEq(reserve.reserveValueUsd(), expectedUsd);
        assertEq(backedVault.reserveValue(), expected, "every unit of a one-dollar token, in dollars");
        assertEq(backedVault.totalDebt(), 0);
        assertEq(backedVault.earnLine(), expected);
        _mintWork(WORKER, expected);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - expected);
        assertEq(backedVault.totalEarned(), expected);
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
        assertEq(backedVault.reserveValue(), _inVaultUnit(expected));
        assertEq(backedVault.earnLine(), _inVaultUnit(expected));
        assertLe(expected, marked);
        assertEq(_inVaultUnit(expected), expected, "no conversion: the register and the vault share a unit");
    }

    function test_largeReserveProductUsesFullPrecisionBeforeDecimalScaling() public {
        _register(asset, reservePrice, 5000);
        uint256 balance = uint256(1) << 200;
        asset.mint(address(reserve), balance);
        reservePrice.setValue(1e24);
        assertEq(reserve.reserveValueUsd(), balance * 1e6 / 2);
        assertEq(backedVault.reserveValue(), balance * 1e6 / 2, "USD x 1e18 overflows; mulDiv does not");
    }

    function test_registerSumsDifferentDecimalsAndRepricingDoesNotDuplicateAsset() public {
        ReserveTestToken six = new ReserveTestToken(6);
        TestSwarmFeed dollars = new TestSwarmFeed(2 * ASSET_USD);
        _fundReserve(7 ether);
        _register(six, dollars, 5000);
        six.mint(address(reserve), 3e6);
        assertEq(reserve.reserveValueUsd(), 10 ether);
        assertEq(backedVault.reserveValue(), 10 ether);
        _register(six, reservePrice, 5000);
        assertEq(reserve.reserveAssetCount(), 2);
        assertEq(reserve.reserveValueUsd(), 8.5 ether);
        assertEq(backedVault.reserveValue(), 8.5 ether);
        _register(asset, ISwarmFeed(address(0)), 0);
        assertEq(reserve.reserveAssetCount(), 1);
        assertEq(address(reserve.reserveAssets()[0]), address(six));
        assertEq(reserve.reserveValueUsd(), 1.5 ether);
        assertEq(backedVault.reserveValue(), 1.5 ether);
        _register(six, ISwarmFeed(address(0)), 0);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(reserve.reserveAssetCount(), 0);
        _register(asset, reservePrice, 5000);
        assertEq(reserve.reserveValueUsd(), 7 ether);
        assertEq(backedVault.reserveValue(), 7 ether);
    }

    function test_valuationReadsLiveCustodyWithoutRequiringSync() public {
        _fundReserve(10 ether);
        assertEq(reserve.totalReceived(asset), 0);
        assertEq(reserve.reserveValueUsd(), 10 ether);
        assertEq(backedVault.reserveValue(), 10 ether);
        assertEq(reserve.sync(asset), 20 ether);
        assertEq(reserve.sync(asset), 0);
        asset.mint(address(reserve), 4 ether);
        // Valuation follows custody with the 4 unsynced: 24 tokens at half value.
        assertEq(reserve.reserveValueUsd(), 12 ether);
        assertEq(backedVault.reserveValue(), 12 ether);
        // A listed reserve asset cannot be withdrawn by the operator at all.
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ReserveProtected.selector, asset));
        reserve.withdraw(asset, OTHER_WORKER, 2 ether);
        // The route that remains: delist through governance (48 hours), then withdraw. The withdrawal
        // still credits what arrived since the last sync before it lowers the baseline.
        _register(asset, ISwarmFeed(address(0)), 0);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(asset, OTHER_WORKER, 2 ether);
        assertEq(reserve.totalReceived(asset), 24 ether);
        assertEq(reserve.lastSynced(asset), 22 ether);
        assertEq(reserve.reserveValueUsd(), 0, "delisted: no longer backing");
        assertEq(backedVault.reserveValue(), 0);
        assertEq(reserve.sync(asset), 0);
    }

    function test_staleImdLegReportsStaleAndCannotValueOrAuthorizeReserve() public {
        _seedUsdReserve();
        assertEq(backedVault.reserveValue(), 1 ether, "the ETH/USD leg cancels for IMD: balance x primary x haircut");
        primary.setStale(true);
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 0, "never use the stale composite quote");
        assertEq(backedVault.reserveValue(), 0);
        assertEq(backedVault.earnLine(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        backedVault.earn(1);
        primary.setStale(false);
        assertEq(reserve.reserveValueUsd(), 1 ether);
        assertEq(backedVault.reserveValue(), 1 ether);
    }

    function test_staleUsdLegAtExactAgeBoundaryCannotAuthorizeNewWork() public {
        _seedUsdReserve();
        uint256 timestamp = vm.getBlockTimestamp();
        vm.warp(timestamp + ETH_USD_MAX_AGE);
        assertFalse(backedVault.usdPriceFeed().isStale());
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), ETH_USD, "exactly at the maximum age is fresh");
        assertEq(reserve.reserveValueUsd(), 1 ether);
        assertEq(backedVault.reserveValue(), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(primary.isStale());
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 0);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.reserveValue(), 0);
        assertEq(backedVault.earnLine(), 0);
        // StaleFeed rather than WorkCeilingReached: the vault denominates in USD, so it refuses to act
        // at all on a price it cannot read, before it ever consults the ceiling. Still cannot authorise
        // new work, by a stricter route.
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        backedVault.earn(1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        _refreshEthUsd();
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(2000 ether);
        _mintWork(WORKER, 1 ether);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(1);
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
        assertEq(reserve.reserveValueUsd(), 13 ether);
        assertEq(backedVault.reserveValue(), 13 ether);
        // A dead ETH/USD answer drops the IMD leg from the register, because that leg is what prices
        // IMD in dollars. The other asset keeps its own USD source and keeps counting — the dead leg
        // no longer converts anything, it only stops the vault acting.
        usd.set(0, vm.getBlockTimestamp());
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(reserve.reserveValueUsd(), 12 ether);
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 0);
        // The register is in USD and so is the vault, so a dead ETH/USD leg no longer shrinks the
        // reserve term. It halts every priced action instead, which is asserted below.
        assertEq(backedVault.reserveValue(), 12 ether, "assets priced without the dead leg still count");
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        backedVault.earn(1);
        assertEq(backedVault.earnLine(), 12 ether, "the surviving asset still backs work once the leg returns");
        reservePrice.setValue(0);
        assertEq(reserve.reserveValueUsd(), 0);
        _refreshEthUsd();
        assertEq(reserve.reserveValueUsd(), 1 ether, "only the IMD leg is priced now");
        assertEq(backedVault.reserveValue(), 1 ether);
    }

    function test_usdCompositeScalesBothLegsAndKeepsOldestTimestamp() public {
        primary.setValue(0.002 ether);
        usd.set(2500e8, vm.getBlockTimestamp() - 10);
        (uint256 value, uint64 at) = backedVault.usdPriceFeed().latestValue();
        assertEq(value, 5 ether);
        assertEq(at, vm.getBlockTimestamp() - 10);
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 2500 ether, "eight aggregator places scaled to 1e18");
        usd.setDecimals(18);
        usd.set(2500e18, vm.getBlockTimestamp() - 10);
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 2500 ether, "and eighteen left as they are");
        usd.setDecimals(8);
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
        // The USD leg would be a year stale, which halts a vault denominated in USD. This test is
        // about where revenue lands, not about staleness, so the leg is refreshed with the clock.
        usd.set(ETH_USD_ANSWER, vm.getBlockTimestamp());
        _setVaultPrice(0.6 ether);
        health.setValue(0.6 ether); // Zero grace, preserving the exact accrued fee read below.
        vm.prank(OTHER_WORKER);
        backedVault.bark(BORROWER);
        uint256 fee = backedVault.stabilityFeeOf(BORROWER);
        assertGt(fee, 0);
        assertLt(fee, 50 ether);
        uint256 seized = 50 ether * ((100 + backedVault.CHOP_PERCENT()) * 1e16) / uint256(0.6 ether);
        uint256 principalCollateral = 50 ether * 1 ether / uint256(0.6 ether);
        uint256 cut = (seized - principalCollateral) * backedVault.cut() / 10_000;
        uint256 markerCut = (seized - principalCollateral) * backedVault.chip() / 10_000;
        assertGt(cut, 0);
        uint256 oldRecipientCollateral = collateral.balanceOf(FEE_RECIPIENT);
        uint256 oldRecipientComp = stable.balanceOf(FEE_RECIPIENT);
        vm.prank(WORKER);
        backedVault.bite(BORROWER, 50 ether);
        assertEq(collateral.balanceOf(address(reserve)), cut);
        assertEq(stable.balanceOf(address(reserve)), fee);
        assertEq(backedVault.totalFeesMinted(), fee);
        assertEq(collateral.balanceOf(WORKER), seized - cut - markerCut);
        assertEq(collateral.balanceOf(OTHER_WORKER), markerCut);
        assertEq(backedVault.totalDebt(), 50 ether + fee);
        assertEq(backedVault.totalBadDebt(), 0, "collateral remains, so nothing is recorded as bad debt");
        assertEq(backedVault.backedDebt(), 50 ether + fee);
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
        assertEq(reserve.reserveValueUsd(), 1 ether);
    }

    function _assertUsdUnavailable() internal view {
        assertTrue(backedVault.usdPriceFeed().isStale());
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 0);
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.reserveValue(), 0);
        assertEq(backedVault.earnLine(), 0);
    }
}
