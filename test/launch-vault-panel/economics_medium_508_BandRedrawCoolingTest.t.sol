// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// Final audit 2026-10-08: `draw`'s band-draw cooling (delta panel #1) cools the NEW DEBT's share of a band
// position's term whatever part of that debt came back WARM from the position's own debt bank. A band borrower
// that repays and redraws the same principal (its debt is credited warm, so the warm supply is unchanged) has
// `term x amount / debt` of its collateral term made cold on every redraw, bounded only by what is not cold
// yet, so a handful of wipe/draw pairs in one block make its whole collateral cold while its debt stays warm.
// The lagged backing figure then excludes that collateral against the full warm supply, and every redemption,
// reserve- or candidate-funded, is paid that much less for hours (6-hour half-life), re-armed for gas.
//
// Here: a 430,000 IMD / 100,000 imdUSD band borrower (172% at $0.40) is a quarter of the collateral behind a
// 600,000 book backed at 0.8625. Nine wipe(12,000)/draw(12,000) pairs take backingPerUnit() to 0.575.
// Expected: an own-warmth redraw moves nothing, so the figure stays at the live 0.8625 (within rounding).
// Fails on 9bd5f59; passes once the cooling applies only to the cold part of the new debt.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BrFeed is ISwarmFeed {
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

contract BrMirror is ISwarmFeed {
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

contract BrAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract BandRedrawCoolingTest is Test {
    address private constant VICTIM = address(0xD00D);
    address private constant GRIEFER = address(0xBAD);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH such that IMD = $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    BrFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BrAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new BrFeed(DOLLAR);
        BrFeed health = new BrFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BrMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(VICTIM, 850_000 ether);
        imd.mint(GRIEFER, 430_000 ether);
        imd.mint(address(vault.treasury()), 12_500 ether); // the reserve: $5,000 at $0.40
        vm.stopPrank();
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_bandRedrawOfOwnWarmDebtCoolsCollateralForGas() public {
        // An honest borrower at 170% at $1.
        vm.startPrank(VICTIM);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(850_000 ether);
        vault.draw(500_000 ether);
        vm.stopPrank();
        _next();
        // IMD falls to $0.40: the borrower is at 68%, the book is below par.
        primary.set(DOLLAR * 2 / 5);
        _next();
        // The griefer opens a band position at the new price: 430,000 IMD ($172,000) against 100,000 (172%).
        vm.startPrank(GRIEFER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(430_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        // Everything warms: two quiet days.
        vm.warp(block.timestamp + 2 days);
        _next();

        uint256 before = vault.backingPerUnit();
        (, uint256 laggedSecuredBefore) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("backingPerUnit before the churn (live = lagged)", before);
        assertLt(before, 1e18, "the scenario needs a book below par");

        // Nine wipe/draw pairs of the same 12,000 in one block. The debt leaves warm and comes back warm from the
        // position's own bank; the term (its whole collateral, 430,000) never moves.
        vm.startPrank(GRIEFER);
        for (uint256 i; i < 9; ++i) {
            vault.wipe(12_000 ether);
            vault.draw(12_000 ether);
        }
        vm.stopPrank();
        _next();

        uint256 after_ = vault.backingPerUnit();
        (uint256 laggedDebt, uint256 laggedSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("backingPerUnit after nine wipe/draw pairs", after_);
        emit log_named_uint("lagged secured before", laggedSecuredBefore);
        emit log_named_uint("lagged secured after", laggedSecured);
        emit log_named_uint("lagged debt after (all warm)", laggedDebt);

        // Expected: a redraw of the position's own warm debt leaves the lagged figure where the live one is.
        assertGe(after_ + 1e15, before, "an own-warmth redraw cooled the position's collateral and cut every redemption");
    }
}