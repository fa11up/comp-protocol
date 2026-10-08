// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry panel audit 2026-10-07 (vault, job 3226aaed): the panel's reproduction of a medium (the debt-side bank measured against a stale aggregate lag),
// kept as it was written apart from reading the lag through laggedNow(). It failed on 973369e and passes on the fix.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {Parameters} from "src/Parameters.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract SbFeed is ISwarmFeed {
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

contract SbMirror is ISwarmFeed {
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

contract SbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice CDPVault._reduceDebt calls the debt-side `_bank` (line 1265) BEFORE the first `_advanceLag` of the
/// call (inside `_resecureBounded`, line 886, and again at line 1299). `_bank` measures what the lag loses
/// as `laggedDebt - liveAfter` from the STORED `laggedDebt`, which is the lag as of the last checkpoint.
/// After a quiet warm-up (no deposit, borrow or repayment by anyone since the position's draw) the stored
/// figure is still the pre-draw one, `lost` saturates to zero and nothing is banked; `_advanceLag` then
/// lifts the lag to the warm level and `_clampLag` drops it to the post-repayment level. The same position's
/// redraw finds an empty bank and warms from zero, which is the final panel's medium the bank was added for.
contract StaleBankTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant HELPER = address(0x4E1);
    address private constant WORKER = address(0xCA);
    address private constant REDEEMER = address(0x5ED);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    MockWorkOracle private oracle;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new SbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        // 1 IMD = 1/2000 ETH and 1 ETH = $2000: the vault prices IMD at exactly $1.
        SbFeed primary = new SbFeed(uint256(1 ether) * 1e18 / 2000 ether);
        SbFeed health = new SbFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new SbMirror(primary))
        );
        stable = vault.stablecoin();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 2_000 ether);
        imd.mint(HELPER, 200 ether);
        oracle.grantRights(WORKER, 1_000 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(HELPER);
        imd.approve(address(vault), type(uint256).max);
        // Minting from work switched on the governed way (the work-ceiling half; the backing half needs no wage).
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0.01 ether);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
    }

    /// @dev Fee money for the borrower, given BEFORE the quiet period so the helper's draw is the last checkpoint.
    function test_quietVaultWipeBanksNothingAndTheRedrawWarmsFromZero() public {
        vm.startPrank(HELPER);
        vault.lock(200 ether);
        vault.draw(50 ether);
        stable.transfer(BORROWER, 50 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        // Three quiet days: no call checkpoints the lag.
        vm.warp(block.timestamp + 3 days);
        (uint256 warm,) = vault.laggedNow();
        assertEq(warm, 1_050 ether, "warm as of now");
        assertApproxEqAbs(vault.earnLine(), 262.5 ether, 0.01 ether);

        // Transaction N: repay half. Transaction N+1, same block: draw it back.
        vm.prank(BORROWER);
        vault.wipe(500 ether);
        (uint256 afterWipe,) = vault.laggedNow();
        assertApproxEqAbs(afterWipe, 550.4 ether, 0.1 ether, "a decrease counts at once");
        vm.prank(BORROWER);
        vault.draw(500 ether);
        (uint256 afterRedraw,) = vault.laggedNow();
        // EXPECTED (NatSpec 316-318, 900-901): the same position's capital returned within the day is
        // credited back, so the lag is about 1,050 again and the ceiling about 262.5.
        // ACTUAL: about 550: the wipe banked nothing because it read the stale stored lag (0).
        assertGe(afterRedraw, 1_049 ether, "a borrower's own wipe-and-redraw must leave the lag where it was");
        assertGe(vault.earnLine(), 262 ether, "and the work ceiling with it");
    }

    /// @dev The backing half, at the same wage: with work-minted supply outstanding the lagged backing falls
    /// to zero and cash is closed for every redeemer until the redraw warms up.
    function test_quietVaultWipeAndRedrawZeroesTheLaggedBacking() public {
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(WORKER);
        vault.earn(250 ether); // the ceiling: the debt is warm as of now
        stable.transfer(BORROWER, 10 ether); // fee money
        stable.transfer(REDEEMER, 10 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days); // another quiet day: earn and transfers are not checkpoints
        assertEq(vault.backingPerUnit(), 1e18, "fully backed before the churn");

        uint256 whole = vault.debtOf(BORROWER);
        vm.prank(BORROWER);
        vault.wipe(whole);
        vm.prank(BORROWER);
        vault.draw(1_000 ether);
        // EXPECTED: still at par (the position's own capital returned within the day).
        // ACTUAL: 0, and cash reverts ZeroAmount for every redeemer for a day.
        assertGe(vault.backingPerUnit(), 0.99e18, "the lagged backing must not read the redraw as fresh");
        vm.prank(REDEEMER);
        uint256 out = vault.cash(10 ether, 0, BORROWER);
        assertGt(out, 9 ether, "a redemption pays about par");
    }
}