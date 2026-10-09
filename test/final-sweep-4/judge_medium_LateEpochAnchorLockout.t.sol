// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Kept proof from the final sweep panel 4 (2026-10-09, job 6229d0fc), judge, medium. Failed on c7d50ee with
// ExcessDeviation; passes since SwarmFeed._returnAnchor lets an honest value back to the expired epoch's level.

// A value relayed in the last minute of a live SwarmFeed epoch becomes the next epoch's anchor. For the spot
// feed, whose recipe reads one block, that is one end-of-block push of the pool (restored the next block),
// attested honestly: the honest spot, 25% above a 0.8x push, is then refused ExcessDeviation until the pushed
// value has been stale a whole hour (two hours after the push), and the vault refuses every price action
// (PriceDivergence for the first hour, StaleFeed for the second). This test FAILS on the committed code at
// the honest re-seed and passes once a value within maxDeviationBps of the expired epoch's anchor is accepted
// when a new epoch opens (and anchors the new epoch there).

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "src/CDPVault.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {PriceFeed} from "src/PriceFeed.sol";
import {NhiFeed} from "src/NhiFeed.sol";
import {SpotFeed} from "src/SpotFeed.sol";
import {MockIMD} from "src/MockIMD.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

contract LockoutProofPriceFeed is PriceFeed {
    constructor() PriceFeed(1 hours, 2000) {}

    function seed(uint256 v) external {
        _accept(v, uint64(block.timestamp));
    }
}

contract LockoutProofNhiFeed is NhiFeed {
    constructor() NhiFeed(1 days, 2000) {}

    function seed(uint256 v) external {
        _accept(v, uint64(block.timestamp));
    }
}

contract LockoutProofSpotFeed is SpotFeed {
    constructor() SpotFeed(1 hours, 2000) {}

    function seed(uint256 v) external {
        _accept(v, uint64(block.timestamp));
    }
}

contract SpotEpochLockoutProofTest is Test {
    address private constant BORROWER = address(0xB0B);
    uint256 private constant V = 4e15; // wei of ETH per 1e18 IMD: the honest spot and primary

    MockIMD private imd;
    CDPVault private vault;
    LockoutProofPriceFeed private primary;
    LockoutProofNhiFeed private health;
    LockoutProofSpotFeed private spot;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(20_000_000);
        imd = new MockIMD();
        primary = new LockoutProofPriceFeed();
        health = new LockoutProofNhiFeed();
        spot = new LockoutProofSpotFeed();
        vault = new CDPVault(address(imd), address(0), address(0), address(primary), address(health), address(spot));
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_000_000 ether);
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// @dev t0: an honest refresh (anyone's 0.5 IMD) opens a live spot epoch anchored at V. t0 + 59 min: the
    /// attacker relays a spot attestation of 0.8 V, an honest reading of the one block the pool was pushed in
    /// (inside the epoch's 20% of V, so accepted). t0 + 61 min: the epoch has expired; the honest V is within
    /// 20% of the expired epoch's anchor and must land, so the vault's price actions resume. On the committed
    /// code the new epoch anchors at 0.8 V with the fresh 20% allowance, V is 25% above it, and this reverts
    /// ExcessDeviation; the vault then refuses draw, bark, bite and cash for two hours.
    function test_honestSpotLandsOnceTheLatePushsEpochHasExpired() public {
        health.seed(0.9e18);
        primary.seed(V);
        spot.seed(V);
        uint256 t0 = block.timestamp;
        vm.startPrank(BORROWER);
        vault.lock(1000 ether);
        vault.draw(1 ether);
        vm.stopPrank();

        vm.warp(t0 + 59 minutes);
        vm.roll(block.number + 295);
        spot.seed(V * 8 / 10); // inside the live epoch: anchor V, allowance 20%

        vm.warp(t0 + 61 minutes);
        vm.roll(block.number + 10);
        primary.seed(V);
        assertTrue(spot.accepts(V), "the feed says it would accept the honest value: a buyer can see the way back");
        assertFalse(spot.accepts(V * 12 / 10 + 1), "and that it would refuse one beyond both bands");
        spot.seed(V); // committed code: ExcessDeviation, the next epoch anchored at 0.8 V
        (uint256 value,) = spot.latestValue();
        assertEq(value, V, "the honest spot lands once the push's epoch has expired");
        vm.prank(BORROWER);
        vault.draw(1 ether); // and the vault's price actions resume at agreeing prices
    }

    /// @dev The way back reaches no level the expired epoch did not already allow, and only for a while.
    function test_theWayBackNeverWidensTheBandAndCloses() public {
        spot.seed(V);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 59 minutes);
        spot.seed(V * 8 / 10); // late push, inside the epoch anchored at V
        vm.warp(t0 + 61 minutes);
        // Beyond the cap of BOTH the pushed value and the expired epoch's anchor: refused.
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        spot.seed(V * 12 / 10 + 1);
        // The walk the epoch rule always allowed, from the pushed value, is unchanged.
        spot.seed(V * 64 / 100);
        (uint256 value,) = spot.latestValue();
        assertEq(value, V * 64 / 100, "a step from the current value is accepted as before");

        // Once the expired epoch is older than two lifetimes and a growth period, the way back is closed: a
        // value back at V is judged by the stale allowance from the last value alone.
        LockoutProofSpotFeed fresh = new LockoutProofSpotFeed();
        fresh.seed(V);
        uint256 t1 = block.timestamp;
        vm.warp(t1 + 59 minutes);
        fresh.seed(V * 8 / 10);
        vm.warp(t1 + 3 hours + 1);
        fresh.seed(V); // at three hours the last value has been silent two: the stale 40% covers V
        (value,) = fresh.latestValue();
        assertEq(value, V);
    }
}
