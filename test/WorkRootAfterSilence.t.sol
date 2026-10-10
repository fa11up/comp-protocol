// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {WORK_ORACLE_FACTORY, WORK_ORACLE_SENTINEL, WORK_ORACLE_MAX_AGE} from "src/DeploymentConfig.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {SeedableWorkOracle, SeedableWorkOracleFactory} from "./helpers/SeedableFeeds.sol";

/// @notice Regression, found 2026-10-10. A work root has no magnitude, but SwarmFeed._accept ran the epoch
/// rule on rollover anyway, and once the feed was stale the allowance exceeded 100%: mulDiv(root, allowance,
/// 10_000) overflowed for any root above 2^256 / multiple. Silence only widens the allowance, so one missed
/// day bricked the feed for good. Root feeds now keep no epoch (`_hasMagnitude`).
contract WorkRootAfterSilenceTest is WorkBackingFixture {
    SeedableWorkOracle private work;

    function setUp() public override {
        TreasuryFactoryEtch.etch(vm);
        super.setUp();
        vm.etch(WORK_ORACLE_FACTORY, address(new SeedableWorkOracleFactory()).code);
        ParameterizedVault v = new ParameterizedVault(
            address(collateral), address(0), WORK_ORACLE_SENTINEL, address(primary), address(health),
            address(backedVault.spotFeed())
        );
        work = SeedableWorkOracle(address(v.oracle()));
    }

    function test_aDailyRootLandsOnTime() public {
        work.seed(uint256(keccak256("day-1")) | (1 << 255));
        vm.warp(block.timestamp + WORK_ORACLE_MAX_AGE);
        work.seed(uint256(keccak256("day-2")) | (1 << 255));
    }

    function test_aRootAfterAMissedDayIsAccepted() public {
        work.seed(uint256(keccak256("day-1")) | (1 << 255));
        vm.warp(block.timestamp + WORK_ORACLE_MAX_AGE + 2 hours);
        work.seed(uint256(keccak256("day-3")) | (1 << 255));
        work.recordRoot();
        assertTrue(work.acceptedRoots(bytes32(uint256(keccak256("day-3")) | (1 << 255))));
    }

    /// @dev The worst case: a month of silence, where the allowance has reached MAX_ALLOWANCE_BPS (100x)
    /// and all but one root in a hundred overflowed. Minting from work ships off, so this is the likely
    /// state of the feed on the day it is switched on.
    function test_aRootAfterAMonthOfSilenceIsAcceptedAndAcceptsSaysSo() public {
        work.seed(uint256(keccak256("first")));
        vm.warp(block.timestamp + 30 days);
        uint256 root = type(uint256).max - 1;
        assertTrue(work.accepts(root), "the view agrees with the delivery");
        work.seed(root);
        work.recordRoot();
        assertTrue(work.acceptedRoots(bytes32(root)));
    }
}
