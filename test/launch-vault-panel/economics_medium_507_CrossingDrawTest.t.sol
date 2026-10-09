// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// Final audit 2026-10-08: the delta-panel fix in `draw` (the band-draw cooling) only fires when the position's
// secured term is EXACTLY unchanged by the draw and only cools through `_lag`'s crediting path.
//
// Gap 1 (test_drawCrossingIntoBandSkipsCooling): a position one raw unit ABOVE 200% (term = 2D/price, a hair
// below its collateral) draws into the band. Its term moves by that hair, so `position.secured != termBefore`
// and the new debt's share of the term (about 29,000 of 200,001 IMD here) stays warm while the new debt goes
// cold. The lagged figure drops the imdUSD but keeps the collateral behind it, exactly the delta-panel medium.
//
// Gap 2 (test_secondBankAbsorbsBandCooling): a band position that FREED collateral earlier banked that warm term
// (`bankSecured`). The fix calls `_lag(position, true, term, term + share)`, which credits the increase from the
// bank first, so the share never goes cold: `credit = min(share, bank)`.
//
// Both: a newcomer's one-transaction lock + draw lifts the live figure, and a reserve-funded cash in the next
// transaction is paid the overstated lagged figure. Both fail on 9bd5f59 and pass once the cooling is computed
// as the new debt's pro-rata share of the term net of the increase already cooled, written to cold directly.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract XdFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        set(v);
    }

    function set(uint256 v) public {
        value = v;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract XdMirror is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(ISwarmFeed p) {
        primary = p;
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}

contract XdAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract CrossingDrawTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH such that IMD = $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    XdFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new XdAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new XdFeed(DOLLAR);
        XdFeed health = new XdFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new XdMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 200_001 ether);
        imd.mint(NEWCOMER, 400_000 ether);
        imd.mint(address(vault.treasury()), 10_000 ether); // the reserve
        vm.stopPrank();
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// @dev The delta panel's proof with ONE IMD more collateral: 200,001 against a 100,000 draw, so the term
    /// (200,000 = 2 x principal) is one IMD short of the collateral and the next draw moves it by that one IMD.
    function test_drawCrossingIntoBandSkipsCooling() public {
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(200_001 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        // Draw into the band: the term goes from 200,000 to 200,001, so the band-draw cooling is skipped.
        vm.prank(BORROWER);
        vault.draw(17_000 ether);
        _next();
        _crashAndRedeem();
    }

    /// @dev A band position that freed collateral holds a warm secured bank; the fix's `_lag` call is credited
    /// from it instead of cooling anything.
    function test_secondBankAbsorbsBandCooling() public {
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether); // 200%: term = 200,000 = the whole collateral
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        // Free 20,000 (still 180%): the term falls to 180,000 and the warm 20,000 is banked.
        vm.prank(BORROWER);
        vault.free(20_000 ether);
        _next();
        // Draw 5,800 (to ~170%): the term stays 180,000, the cooling share is 180,000 x 5,800 / 105,800 = 9,868,
        // and `_lag` credits all of it from the 20,000 bank: nothing goes cold.
        vm.prank(BORROWER);
        vault.draw(5_800 ether);
        _next();
        _crashAndRedeem();
    }

    function _crashAndRedeem() private {
        // IMD halves: the book is below par.
        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest, the live figure before the newcomer", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");
        uint256 feeBps = vault.redemptionFeeBps(5_000 ether);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 honestPay =
            Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        // A newcomer brings capital in one transaction ...
        vm.startPrank(NEWCOMER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(400_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        _next();
        uint256 lifted = vault.backingPerUnit();
        emit log_named_uint("after the newcomer", lifted);
        // ... and in the next is paid from the reserve at that figure.
        vm.prank(NEWCOMER);
        uint256 paid = vault.cash(5_000 ether, 0, address(0));
        emit log_named_uint("paid for 5,000 imdUSD (raw IMD)", paid);
        emit log_named_uint("honest payout at most (raw IMD)", honestPay);

        assertLe(lifted, honest + _rise(honestAt), "fresh capital lifted a redemption's backing");
        assertLe(paid, Math.mulDiv(honestPay, honest + _rise(honestAt), honest) + 1, "a redemption was paid above the honest backing of the book it found");
    }

    /// @dev The paced backing's allowed rise since `since` (CDPVault.BACKING_RISE_PER_HOUR): what the paced figures permit
    /// a figure to have climbed over the honest one, however much capital arrived in the meantime.
    function _rise(uint256 since) internal view returns (uint256) {
        return vault.BACKING_RISE_PER_HOUR() * (block.timestamp - since) / 1 hours;
    }
}
