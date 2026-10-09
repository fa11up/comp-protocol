// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Paced vault panel audit 2026-10-08 (job dc27aade, pinned d3861ac): a proof the panel attached, kept as a regression
// test. On d3861ac it failed as reported (the paced debt was clamped after a draw only); it passes with the clamp
// after every cancellation (CDPVault._clampPacedDebt).

// CDPVault._clampPacedDebt runs only after `draw`. A transaction that draws FIRST and cancels another position's
// debt afterwards (cash, bite or cover) ends with totalDebt where it began and the paced debt untouched, so the
// next transaction counts the zero-second principal in full: the sweep panel's high (2026-10-07) by the other
// ordering. The NatSpec at _clampPacedDebt and ParameterizedVault.backedDebt claim the paced debt never exceeds
// the debt the transaction began with less what it cancelled.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {Parameters} from "src/Parameters.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract CoFeed is ISwarmFeed {
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

contract CoAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract Attacker {
    ParameterizedVault private immutable vault;
    MockIMD private immutable imd;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd = imd_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    /// @dev One transaction: lock, draw X, then cancel X of `victim`'s debt by redeeming the fresh imdUSD against it.
    function drawThenCancel(uint256 collateral, uint256 amount, address victim) external {
        vault.lock(collateral);
        vault.draw(amount);
        vault.cash(amount, 0, victim);
    }

    /// @dev The other ordering, which the clamp catches.
    function cancelThenDraw(uint256 collateral, uint256 amount, address victim) external {
        vault.cash(amount, 0, victim);
        vault.lock(collateral);
        vault.draw(amount);
    }

    function earn(uint256 amount) external {
        vault.earn(amount);
    }

    function wipeAndFree(uint256 amount, uint256 collateral) external {
        vault.wipe(amount);
        vault.free(collateral);
    }
}

contract ClampOrderingTest is Test {
    address private constant BOOK = address(0xB00C);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    MockWorkOracle private oracle;
    CoFeed private primary;
    CoFeed private health;
    CoFeed private spot;
    Attacker private attacker;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new CoAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new CoFeed(DOLLAR);
        health = new CoFeed(0.85 ether);
        spot = new CoFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        oracle = MockWorkOracle(address(vault.oracle()));
        attacker = new Attacker(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(address(attacker), 400_000 ether);
        oracle.grantRights(address(attacker), 100_000 ether);
        vm.stopPrank();
        vm.prank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0.01 ether);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
    }

    function _next(uint256 seconds_) private {
        vm.roll(block.number + 1 + seconds_ / 12);
        vm.warp(block.timestamp + seconds_);
        primary.set(DOLLAR);
        spot.set(DOLLAR);
        health.set(0.85 ether);
    }

    function _hours(uint256 n) private {
        for (uint256 i; i < n; ++i) {
            _next(1 hours);
            vault.pace();
        }
    }

    function _book() private {
        // BOOK at 200%, inside the redeemable band (mat 170 + gap 50 = 220), seasoned for a day: paced debt = 99,500.
        vm.startPrank(BOOK);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether);
        vm.stopPrank();
        _hours(30);
        (,, uint256 pacedDebt,,,) = vault.paced();
        assertEq(pacedDebt, 99_500 ether, "seasoned");
    }

    function test_cancelThenDrawIsClamped() public {
        _book();
        vm.prank(BOOK);
        stable.transfer(address(attacker), 99_500 ether); // the spare imdUSD the sweep panel's proof gave the attacker
        attacker.cancelThenDraw(300_000 ether, 99_500 ether, BOOK);
        _next(12);
        (,, uint256 pacedDebt,,,) = vault.paced();
        emit log_named_uint("paced debt after cancel-then-draw", pacedDebt);
        assertLt(pacedDebt, 200 ether, "the redrawn 99,500 counts only at the follow rate");
    }

    function test_drawThenCancelIsNotClamped() public {
        _book();
        attacker.drawThenCancel(300_000 ether, 99_500 ether, BOOK);
        _next(12);
        (,, uint256 pacedDebt,,,) = vault.paced();
        emit log_named_uint("paced debt after draw-then-cancel", pacedDebt);
        emit log_named_uint("totalDebt", vault.totalDebt());
        (, uint256 bookDebt) = vault.positions(BOOK);
        emit log_named_uint("BOOK's debt left", bookDebt);
        emit log_named_uint("backedDebt", vault.backedDebt());
        emit log_named_uint("earnLine", vault.earnLine());
        // EXPECTED (NatSpec): the paced debt is the debt the transaction began with less what it cancelled, about
        // BOOK's residue, and the attacker's zero-second 99,500 counts at 10% of the floor an hour. ACTUAL: 99,500.
        assertLt(pacedDebt, 200 ether, "the redrawn 99,500 counts only at the follow rate");
    }

    function test_drawThenCancelBacksWorkMintingAtOnce() public {
        _book();
        attacker.drawThenCancel(300_000 ether, 99_500 ether, BOOK);
        _next(12);
        // The ceiling: the reserve is empty, so earnLine = 25% of backedDebt. Honest: about 25% of (residue + one
        // hour's step at most). Actual: 25% of 99,500.
        uint256 line = vault.earnLine();
        emit log_named_uint("earnLine one block after the swap", line);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        attacker.earn(24_000 ether);
    }
}