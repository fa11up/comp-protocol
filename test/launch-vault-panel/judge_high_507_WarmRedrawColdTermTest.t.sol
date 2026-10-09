// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// A band position (170-200%) that repays WARM principal and redraws it has the debt credited back warm from
// its bank, but `draw`'s band branch (the delta-panel fix) still cools `term x amount / debt` of its secured
// term, with no bank credit, because the repayment never moved the term. Repeating the round trip walks the
// position's whole secured term into the cold total while its debt stays warm. `_backingPerUnit`'s lagged
// figure then drops that collateral and pays every redeemer against the rest of the book, for gas.
//
// Fails on the pinned commit: backing reads 1.0 before the churn and 0.667 after it, with nothing about the
// book changed; an honest 10,000 imdUSD redemption is paid 6,566 raw IMD where 9,850 is honest.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract WrFeed is ISwarmFeed {
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

contract WrMirror is ISwarmFeed {
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

contract WrAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract WarmRedrawColdTermTest is Test {
    address private constant CHURNER = address(0xC4);
    address private constant HONEST = address(0xB0B);
    address private constant REDEEMER = address(0x5EED);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    WrFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new WrAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new WrFeed(DOLLAR);
        WrFeed health = new WrFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new WrMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(CHURNER, 180_000 ether);
        imd.mint(HONEST, 100_000 ether);
        vm.stopPrank();
        vm.prank(CHURNER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(HONEST);
        imd.approve(address(vault), type(uint256).max);
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_warmRedrawInBandCoolsTermAndUnderpaysRedeemers() public {
        // A warm book: the churner at 180% (term = its whole collateral), an honest borrower at 200%.
        vm.startPrank(CHURNER);
        vault.lock(180_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        vm.startPrank(HONEST);
        vault.lock(100_000 ether);
        vault.draw(50_000 ether);
        stable.transfer(REDEEMER, 10_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();

        uint256 before = vault.backingPerUnit();
        emit log_named_uint("backing before the churn (book fully warm)", before);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 feeBps = vault.redemptionFeeBps(10_000 ether);
        uint256 honestPay = Math.mulDiv(Math.mulDiv(10_000 ether, before, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        // The churner repays 10% of its warm principal and redraws it, ten times, in ONE transaction. Each
        // repayment leaves its term (= collateral) unchanged, so nothing secured is banked; each redraw is
        // credited warm from the debt bank, yet cools term x 10,000 / 100,000 = 18,000 IMD of the term.
        vm.startPrank(CHURNER);
        for (uint256 i; i < 10; ++i) {
            vault.wipe(10_000 ether);
            vault.draw(10_000 ether);
        }
        vm.stopPrank();
        _next();

        uint256 after_ = vault.backingPerUnit();
        emit log_named_uint("backing after the churn (same book, same prices)", after_);
        (uint256 lagDebt, uint256 lagSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("lagged debt (warm principal)", lagDebt);
        emit log_named_uint("lagged secured (warm collateral)", lagSecured);

        vm.prank(REDEEMER);
        uint256 paid = vault.cash(10_000 ether, 0, CHURNER);
        emit log_named_uint("paid for 10,000 imdUSD (raw IMD)", paid);
        emit log_named_uint("honest payout (raw IMD)", honestPay);

        assertGe(after_, before, "a warm wipe/redraw round trip lowered the backing of an unchanged book");
        assertGe(paid, honestPay, "an honest redemption was underpaid against the honest backing of the book");
    }
}