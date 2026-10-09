// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Kept proof from the final sweep panel 3 (2026-10-09, job ed4f7f6d), audit_flow, low. Failed on e4baedf (the
// twelve-hour netting of 73191e0); passes since the netting was reverted to the transaction's own mint.

// The fresh-principal netting in _tallyPrincipalRetired (payout vault panel 2026-10-09, low #3) assumes the
// paced debt "has had at most twelve hours to follow" principal younger than FRESH_DEBT_WINDOW. At the
// committed constants the follow absorbs a draw in hours (10% of max(paced, 100,000) an hour, compounding),
// so a sibling position's draw that is already fully inside the paced debt, cancelled one block after a
// second position's draw, is netted out as "fresh" and the clamp never fires: the second position's
// zero-second debt counts in full for ParameterizedVault.backedDebt. This is the final sweep 2 low #2 (1)
// reopened for cancellations of debt between its follow time and twelve hours old.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract FnFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 hours;
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

    function isStale() external view returns (bool) {
        return block.timestamp - updatedAt > maxAge;
    }
}

contract FnAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract FreshNettingHidesFollowedDebtTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether;

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    FnFeed private primary;
    FnFeed private health;
    FnFeed private spot;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new FnAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new FnFeed(DOLLAR);
        health = new FnFeed(0.85 ether);
        spot = new FnFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(ALICE, 200_000 ether);
        imd.mint(BOB, 200_000 ether);
        vm.stopPrank();
        vm.startPrank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        for (uint256 i; i < 24; ++i) {
            _hour();
        }
        assertEq(vault.backedDebt(), 99_500 ether, "the seasoned book counts in full");
    }

    function _next(uint256 seconds_) private {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1 + seconds_ / 12);
        primary.set(DOLLAR);
        spot.set(DOLLAR);
        health.set(0.85 ether);
    }

    function _hour() private {
        _next(1 hours);
        vault.pace();
    }

    function test_cancellingAFollowedSiblingDrawLetsAZeroSecondDrawCountInFull() public {
        // Alice draws 100,000 against 190,000 IMD (CR 190%, inside the redeemable band) and holds it eight
        // paced hours: the paced debt follows at 10% of max(paced, floor) an hour and absorbs all of it.
        vm.startPrank(ALICE);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(190_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();
        for (uint256 i; i < 8; ++i) {
            _hour();
        }
        assertEq(vault.backedDebt(), 199_500 ether, "Alice's eight-hour-old draw is fully inside the paced debt");

        // Block n: Bob draws 100,000 of zero-second debt.
        _next(12);
        vm.startPrank(BOB);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(190_000 ether);
        vault.draw(100_000 ether);
        vm.stopPrank();

        // Block n + 1: Alice redeems her own 100,000 imdUSD against her own position (the fee stays in her
        // collateral). Her principal is eight hours old, younger than FRESH_DEBT_WINDOW, so the netting books
        // none of it as pre-existing and the clamp does not fire, though the paced debt had absorbed all of it.
        _next(12);
        vm.prank(ALICE);
        vault.cash(100_000 ether, 0, ALICE);

        // Block n + 2: the book is 99,500 seasoned plus Bob's 24-second-old 100,000. The paced debt should be
        // about 99,500 plus two 12-second steps (under 100,000 in all); it is 199,500.
        _next(12);
        uint256 backed = vault.backedDebt();
        emit log_named_uint("backedDebt after the sequence", backed);
        assertLt(backed, 110_000 ether, "Bob's zero-second draw counts in full for the work ceiling");
    }
}
