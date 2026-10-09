// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// Judge's reproduction of the band-draw fix bypass (delta panel #1, CDPVault.draw lines 507-510).
// The fix cools the new debt's share of a band position's term only when `position.secured == termBefore`, and
// cools it THROUGH `_lag`'s increase path, which credits the position's secured bank first. Three ways to leave the
// collateral behind new cold debt warm in the lagged figure:
//   1. wipe one wei of principal first: the term moves by 2 wei, the branch is skipped, the bank restores the term;
//   2. wipe everything then redraw more: the term moves from ~0 back to the collateral, credited whole from the bank;
// (A third way, a free after a cooled band draw consuming the phantom cold, is in FreeConsumesPhantom.t.sol.)
// In each, a newcomer's one-transaction lock+draw lifts the live figure and a reserve-funded cash in the next
// transaction is paid the overstated lagged figure.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract JbFeed is ISwarmFeed {
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

contract JbMirror is ISwarmFeed {
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

contract JbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract BandFixBypassTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    JbFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new JbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new JbFeed(DOLLAR);
        JbFeed health = new JbFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new JbMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 200_000 ether);
        imd.mint(NEWCOMER, 400_000 ether);
        imd.mint(address(vault.treasury()), 10_000 ether); // the reserve
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(NEWCOMER);
        imd.approve(address(vault), type(uint256).max);
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _warmBook() private {
        vm.startPrank(BORROWER);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether); // 200%: term = 200,000 = the whole collateral
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
    }

    /// @dev Variant 1: one wei of principal repaid moves the term by two wei; the next draw is not cooled.
    function test_oneWeiWipeSkipsBandCooling() public {
        _warmBook();
        uint256 oneWeiOfPrincipal = vault.stabilityFeeOf(BORROWER) + 1;
        vm.prank(BORROWER);
        vault.wipe(oneWeiOfPrincipal);
        _next();
        vm.prank(BORROWER);
        vault.draw(17_000 ether);
        _next();
        (uint256 lagDebt, uint256 lagSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("lagged debt", lagDebt);
        emit log_named_uint("lagged secured", lagSecured);
        _crashAndRedeem();
    }

    /// @dev Variant 2: repay everything (term to ~0, banked), redraw more: term restored whole from the bank.
    function test_wipeAllThenRedrawMoreSkipsBandCooling() public {
        _warmBook();
        vm.startPrank(BORROWER);
        vault.wipe(100_000 ether);
        vault.draw(117_000 ether);
        vm.stopPrank();
        _next();
        (uint256 lagDebt, uint256 lagSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("lagged debt", lagDebt);
        emit log_named_uint("lagged secured", lagSecured);
        // The panel's property: the lagged secured term should be at most term x warm debt / debt.
        uint256 expectedAtMost = Math.mulDiv(200_000 ether, lagDebt, 117_000 ether);
        emit log_named_uint("lagged secured at most, per the stated property", expectedAtMost);
        _crashAndRedeem();
    }

    function _crashAndRedeem() private {
        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest, the live figure before the newcomer", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");
        uint256 feeBps = vault.redemptionFeeBps(5_000 ether);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 honestPay = Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        vm.startPrank(NEWCOMER);
        vault.lock(400_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        _next();
        uint256 lifted = vault.backingPerUnit();
        emit log_named_uint("after the newcomer", lifted);
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
