// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// The delta panel's medium (#1, job fc96f209) is fixed only for a draw that leaves the term where it was. A band
// borrower that repays all (or enough to move its term) banks its warm term, then redraws MORE than it repaid:
// the extra principal is cold, the term comes back whole from the secured bank, and the band branch is skipped
// because the term moved. The lagged figure again keeps the collateral behind the new imdUSD while dropping the
// imdUSD, and a newcomer's one-transaction-old capital lifts the live figure so a redemption is paid that
// overstated lagged figure: the panel's own sequence, with wipe(100,000) + draw(117,000) in place of draw(17,000).
//
// Fails on the pinned commit: honest 0.897, after the newcomer 1.000; 5,000 imdUSD is paid 9,700 raw IMD from
// the reserve where at most 8,705 is honest.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BgFeed is ISwarmFeed {
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

contract BgMirror is ISwarmFeed {
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

contract BgAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract BandRedrawBankGapTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    BgFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BgAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new BgFeed(DOLLAR);
        BgFeed health = new BgFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BgMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 200_000 ether);
        imd.mint(NEWCOMER, 400_000 ether);
        imd.mint(address(vault.treasury()), 10_000 ether); // the reserve
        vm.stopPrank();
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_wipeAllThenRedrawMoreSkipsTheBandBranch() public {
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        // Repay everything (the term goes to a few IMD and the rest is banked warm), then redraw 117,000: the
        // bank credits 99,976 of debt and the whole term, 17,024 of new principal is cold, and no collateral is.
        vm.startPrank(BORROWER);
        vault.wipe(100_000 ether);
        vault.draw(117_000 ether);
        vm.stopPrank();
        _next();
        (uint256 lagDebt, uint256 lagSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("totalDebt", vault.totalDebt());
        emit log_named_uint("lagged debt (warm principal)", lagDebt);
        emit log_named_uint("lagged secured (warm collateral; honest is 200,000 x warm / debt)", lagSecured);

        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest, the live figure (5,000 + 100,000) / 117,024", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");
        uint256 feeBps = vault.redemptionFeeBps(5_000 ether);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 honestPay = Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        vm.startPrank(NEWCOMER);
        imd.approve(address(vault), type(uint256).max);
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
