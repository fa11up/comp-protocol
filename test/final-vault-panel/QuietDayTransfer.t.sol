// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final vault panel audit 2026-10-08 (job 45bf3777): the panel's reproduction of the medium F4 (a quiet-day cutoff on the totals alone let an old repayment warm new capital; the cutoff is now uniform),
// kept as written. It failed on d7fceab and passes on the fix.

// After d7fceab a position's own cold cools without the quiet-day cutoff while the vault totals read zero after a
// quiet BACKING_WARMUP. The next position to draw puts its cold into a total that no longer holds the old
// position's share; the old position's repayment then takes its own (continuously cooled) cold out of that
// total, which is the new position's. What one position removes warms what another added.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract QdFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
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

contract QdMirror is ISwarmFeed {
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

contract QdAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract QuietDayOrphanTest is Test {
    address private constant OLD = address(0x01D);
    address private constant NEW = address(0x0E3);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new QdAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        QdFeed primary = new QdFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        QdFeed health = new QdFeed(0.85 ether); // mat 170, gap 50
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new QdMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(OLD, 100_000 ether);
        imd.mint(NEW, 100_000 ether);
        vm.stopPrank();
        vm.prank(OLD);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(NEW);
        imd.approve(address(vault), type(uint256).max);
    }

    /// OLD draws 16,000; the vault is quiet for a day and a second (the totals read zero, OLD's own cold is
    /// 1,000). NEW draws 1,000 (cold, the totals hold exactly it). OLD repays: its 1,000 of cold comes out of the
    /// totals, which held only NEW's. EXPECTED: NEW's second-old 1,000 of principal and 2,000 of term stay cold.
    /// ACTUAL: laggedNow reads them warm in full.
    function test_anOldPositionsRepaymentAfterAQuietDayWarmsANewPositionsCapital() public {
        vm.startPrank(OLD);
        vault.lock(32_000 ether);
        vault.draw(16_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        vm.startPrank(NEW);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        stable.transfer(OLD, 100 ether); // OLD's day of stability fee
        vm.stopPrank();
        (uint256 lagDebt, uint256 lagSecured) = vault.laggedNow();
        assertEq(lagDebt, 16_000 ether, "OLD is warm after a quiet day, NEW is cold");
        assertEq(lagSecured, 32_000 ether, "OLD's term is warm, NEW's is cold");
        vm.prank(OLD);
        vault.wipe(16_000 ether);
        (lagDebt, lagSecured) = vault.laggedNow();
        // What is left: OLD's day of fee (about 2 imdUSD of principal, warm) and NEW's 1,000, one second old.
        assertLe(lagDebt, 3 ether, "NEW's one-second-old principal must stay cold after OLD's repayment");
        assertLe(lagSecured, 6 ether, "NEW's one-second-old term must stay cold after OLD's repayment");
    }
}