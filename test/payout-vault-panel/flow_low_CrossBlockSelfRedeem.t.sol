// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Kept proof from the payout vault panel (2026-10-09, job f936eafb), audit_flow, low. Failed on c90e8d9; passes
// on the fix (PAYOUT_PRICE_FALL_BPS_PER_HOUR 100, and the fresh-principal netting in _tallyPrincipalRetired).

// A self-redemption of a ONE-BLOCK-OLD draw is booked as cancelling pre-existing principal and clamps the
// paced debt by the whole amount, though that debt never counted in it. Repeated, it ratchets the paced
// debt to zero for gas while the seasoned book is untouched.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract CbFeed is ISwarmFeed {
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

contract CbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev The attacker: cash against itself, re-lock what it was paid, draw again, in one transaction.
contract Churner {
    ParameterizedVault private immutable vault;
    MockIMD private immutable imd;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd = imd_;
        imd.approve(address(vault), type(uint256).max);
    }

    function open(uint256 collateral, uint256 debt) external {
        vault.lock(collateral);
        vault.draw(debt);
    }

    function cycle(uint256 debt) external {
        uint256 before = imd.balanceOf(address(this));
        vault.cash(debt, 0, address(this));
        vault.lock(imd.balanceOf(address(this)) - before);
        vault.draw(debt);
    }
}

contract CrossBlockSelfRedeemTest is Test {
    address private constant BOOK = address(0xB00C);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether;

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    CbFeed private primary;
    CbFeed private health;
    CbFeed private spot;
    Churner private churner;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new CbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new CbFeed(DOLLAR);
        health = new CbFeed(0.85 ether);
        spot = new CbFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        churner = new Churner(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(address(churner), 200_000 ether);
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

    function test_selfRedemptionOfOneBlockOldDrawZeroesThePacedDebt() public {
        // Block n: open 200,000 / 100,000 (a candidate at 200%). The paced debt stays ~99,500.
        churner.open(200_000 ether, 100_000 ether);
        (,, uint256 pacedAfterDraw,,,) = vault.paced();
        assertEq(pacedAfterDraw, 99_500 ether, "fresh debt does not count yet");
        // Block n+1: cash the one-block-old draw against itself, re-lock the IMD paid, draw again.
        _next(12);
        churner.cycle(100_000 ether);
        _next(12);
        (uint256 collateral, uint256 debt) = vault.positions(address(churner));
        assertApproxEqAbs(debt, 100_000 ether, 1 ether, "the churner holds the same loan");
        assertEq(collateral, 200_000 ether, "and the same collateral: the fee stayed in its own position");
        assertApproxEqAbs(vault.totalDebt(), 199_500 ether, 1 ether, "the live book is unchanged");
        (,, uint256 pacedDebt,,,) = vault.paced();
        // EXPECTED: the seasoned 99,500 untouched, so the paced debt stays at least 99,500 and backedDebt with it.
        // ACTUAL: the cancellation of the churner's own one-block-old principal is booked as pre-existing and the
        // clamp takes the paced debt to zero; backedDebt is zero and recovers at 10,000 an hour.
        assertGe(pacedDebt, 99_500 ether, "self-redemption of fresh debt lowered the paced debt");
        assertGe(vault.backedDebt(), 99_500 ether, "the work ceiling lost the seasoned book");
    }
}
