// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Delta panel audit 2026-10-08 (job fc96f209), medium F1: the panel's proof, kept as written.
// A band position's draw (170-200%: its term is its whole collateral) adds COLD debt and no cold secured term.
// _backingPerUnit's lagged figure takes that debt out of the supply but leaves the collateral that now stands
// behind it in the lagged secured term, so the lagged figure reads ABOVE the honest backing of the book, by up to
// fresh/(supply - fresh) (17.6% for a position drawn from 200% to 170%). The live figure catches it, but the live
// figure is what a newcomer's one-transaction-old capital raises, so lock+draw in one transaction and cash in the
// next is paid the overstated lagged figure: the D1 round trip the lag exists to close.
//
// Fails on 07905bb: honest 0.897, after the newcomer 1.000, and 5,000 imdUSD is paid 9,700 raw IMD from the
// reserve where the honest payout is at most 8,705. Passes once a debt-only draw in a collateral-bound position
// cools a pro-rata slice of the term (see the finding's fix).

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BdFeed is ISwarmFeed {
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

contract BdMirror is ISwarmFeed {
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

contract BdAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract BandDrawLagTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    BdFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BdAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new BdFeed(DOLLAR);
        BdFeed health = new BdFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BdMirror(primary))
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

    function test_bandDrawLetsNewcomerLiftRedemptionToPar() public {
        // A warm book: one borrower at 200% (term = its whole collateral = 2 x principal).
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(200_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        // The borrower draws down to ~171%: 17,000 of cold debt, and the term (its whole collateral) is unchanged.
        vm.prank(BORROWER);
        vault.draw(17_000 ether);
        _next();
        // IMD halves: the book is below par.
        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
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

        assertLe(lifted, honest, "fresh capital lifted a redemption's backing");
        assertLe(paid, honestPay, "a redemption was paid above the honest backing of the book it found");
    }
}