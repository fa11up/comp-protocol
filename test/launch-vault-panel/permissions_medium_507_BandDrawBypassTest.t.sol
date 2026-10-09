// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// The delta panel's medium (job fc96f209, #1) was fixed in `draw` with a branch that cools the new debt's share of
// the term ONLY when `position.secured == termBefore`. Any change of the term in the SAME position before the draw
// (a one-wei `wipe`, which shrinks the term by 2 wei / price and banks it) makes the draw's `_resecure` restore the
// term FROM THE BANK (warm), the equality fails, and nothing of the collateral behind the new imdUSD goes cold. The
// delta panel's proof, re-run with `wipe(1)` inserted before the band draw, fails again exactly as it did on 07905bb.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BbFeed is ISwarmFeed {
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

contract BbMirror is ISwarmFeed {
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

contract BbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract BandDrawBypassTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    BbFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new BbFeed(DOLLAR);
        BbFeed health = new BbFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BbMirror(primary))
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

    function test_oneWeiWipeBeforeBandDrawBypassesTheColdShare() public {
        // A warm book: one borrower at 200% (term = its whole collateral = 2 x principal).
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        // THE BYPASS: a one-wei PRINCIPAL repayment shrinks the term by 2 wei / price and banks that warm sliver ...
        // (one wei past the accrued stability fee, which `wipe` retires first: the repayment must touch principal)
        uint256 oneWeiOfPrincipal = vault.stabilityFeeOf(BORROWER) + 1;
        vm.prank(BORROWER);
        vault.wipe(oneWeiOfPrincipal);
        _next();
        // ... so the band draw's `_resecure` restores the term from the bank and `position.secured != termBefore`:
        // the branch that was meant to cool the new debt's share of the term is skipped.
        vm.prank(BORROWER);
        vault.draw(17_000 ether);
        _next();
        // IMD halves: the book is below par.
        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest, the live figure (5,000 + 100,000) / 117,000", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");
        uint256 feeBps = vault.redemptionFeeBps(5_000 ether);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 honestPay = Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

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
