// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-08 (whole system, job 08a12413), low F3: the lagged backing figure counted the
// whole redemption reserve against the WARM supply alone. While most supply was new, as in the hours after launch,
// it read above par, so the live figure stood, and a newcomer's capital held across one transaction raised it: a
// reserve-funded redemption in the next transaction was paid more than the honest post-exit backing. The lagged
// figure now counts the warm supply's share of the reserve (CDPVault._backingPerUnit). Fails on 6085c8a: 0.96 before
// the newcomer, 1.00 after; with the fix 0.83 after (the reserve's part is diluted by the new supply, the safe way).

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract RsFeed is ISwarmFeed {
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

contract RsMirror is ISwarmFeed {
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

contract RsAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract ReserveShareTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    RsFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new RsAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new RsFeed(DOLLAR);
        RsFeed health = new RsFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new RsMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 20_000 ether);
        imd.mint(NEWCOMER, 1_000_000 ether);
        imd.mint(address(vault.treasury()), 4_000 ether); // the reserve
        vm.stopPrank();
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_newcomerCannotLiftTheBackingInTheLaunchWindow() public {
        // Launch: one book, drawn at 200%.
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(20_000 ether);
        vault.draw(10_000 ether);
        vm.stopPrank();
        // Three hours in, IMD falls 60%: the book is below par and most of its supply still cold.
        vm.warp(block.timestamp + 3 hours);
        primary.set(DOLLAR * 40 / 100);
        _next();
        uint256 honest = vault.backingPerUnit();
        emit log_named_uint("honest", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");

        // A newcomer brings capital in one transaction ...
        vm.startPrank(NEWCOMER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(1_000_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        _next();
        emit log_named_uint("after the newcomer", vault.backingPerUnit());
        // ... and in the next, a redemption must not be paid more than the book it found.
        assertLe(vault.backingPerUnit(), honest, "fresh capital lifted a redemption's backing");
    }
}
