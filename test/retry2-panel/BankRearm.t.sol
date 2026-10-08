// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry2 panel audit 2026-10-08 (vault, job a2640621): the panel's reproduction of the medium F2 (a bank emptied by a one-block visit was re-dated on the next departure),
// kept as written. It failed on 24337a2 and passes on the fix.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BrfFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        value = v;
        updatedAt = uint64(block.timestamp);
    }

    function set(uint256 v) external {
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

contract BrfMirror is ISwarmFeed {
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

contract BrfAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Q2: a bank's date is set when it goes from empty to full. A one-block visit (lock + draw, credited
/// in full, then wipe + free, banked again) empties and refills it, so the day restarts. A once-seasoned
/// position keeps its warmth forever while its capital is away all but one block a day.
contract BankRefreshTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant OTHER = address(0x07E);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    BrfFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BrfAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new BrfFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        BrfFeed health = new BrfFeed(0.85 ether); // mat 170, gap 50
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BrfMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 100_000 ether);
        imd.mint(OTHER, 100_000 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(OTHER);
        imd.approve(address(vault), type(uint256).max);
        // OTHER gives the borrower fee money so it can always repay in full.
        vm.startPrank(OTHER);
        vault.lock(1_000 ether);
        vault.draw(200 ether);
        stable.transfer(BORROWER, 200 ether);
        vm.stopPrank();
    }

    /// @dev Season 2,000 / 1,000 for two days, leave, and come back for one block every 23 hours. After the
    /// capital has been away for more than BACKING_WARMUP in total (two visits of one block in 46 hours), the
    /// bank that was created when it FIRST left has had its day, and the returning capital should be cold.
    function test_oneBlockVisitsKeepTheBankAliveForever() public {
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        (uint256 warmBefore, uint256 warmSecBefore) = vault.laggedNow();
        assertEq(warmBefore, 1_200 ether, "everything warm after a quiet warm-up");
        assertEq(warmSecBefore, 2_000 ether + 400 ether, "both terms warm");

        // Leave: the capital first leaves at t0.
        _leave();
        uint256 t0 = block.timestamp;
        (uint256 warmAway,) = vault.laggedNow();
        assertEq(warmAway, 200 ether, "only OTHER's debt remains");

        // Ten one-block visits, 23 hours apart: in each, come back (credited), and leave the next transaction.
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 23 hours);
            _comeBack();
            (uint256 warm, uint256 warmSec) = vault.laggedNow();
            if (block.timestamp - t0 > vault.BACKING_WARMUP()) {
                // EXPECTED: the returning 1,000 of debt and 2,000 of collateral are cold: the bank was created
                // when the capital first left, more than a warm-up ago, and the capital has been in the vault
                // for one block since. ACTUAL: credited in full, every time.
                assertLe(warm, 200 ether + 70 ether, "capital away for a day comes back cold");
                assertLe(warmSec, 400 ether + 140 ether, "collateral away for a day comes back cold");
            }
            _leave();
        }
    }

    function _leave() private {
        vm.startPrank(BORROWER);
        vault.wipe(vault.debtOf(BORROWER));
        (uint256 collateral,) = vault.positions(BORROWER);
        vault.free(collateral);
        vm.stopPrank();
    }

    function _comeBack() private {
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
    }
}