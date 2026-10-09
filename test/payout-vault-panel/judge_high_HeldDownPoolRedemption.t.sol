// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Kept proof from the payout vault panel (2026-10-09, job f936eafb), audit_judge, high. Failed on c90e8d9; passes
// on the fix (PAYOUT_PRICE_FALL_BPS_PER_HOUR 100, and the fresh-principal netting in _tallyPrincipalRetired).

// The paced payout price (PAYOUT_PRICE_FALL_BPS_PER_HOUR = 500) follows a one-step 20% fall of the attested price
// in five paced hours (0.95^5 = 0.774 < 0.80). A pool held 20% down and kept attested hourly (the feeds' lifetime)
// therefore still pays a redeemer the whole fall in extra IMD after five hours; from the second hour the payout
// is already above what the imdUSD burned was worth. This test fails on c90e8d9: 50,000 imdUSD takes 59,375 IMD
// (worth $59,375 at the pre-fall price) out of the candidate's collateral after a five-hour hold.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract HdFeed is ISwarmFeed {
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

contract HdAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract HeldDownPoolRedemptionTest is Test {
    address private constant BOOK = address(0xB00C);
    address private constant HOLDER = address(0x401D);
    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    HdFeed private primary;
    HdFeed private health;
    HdFeed private spot;
    uint256 private imdEth = DOLLAR;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new HdAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new HdFeed(DOLLAR);
        health = new HdFeed(0.85 ether); // mat 170, gap 50: a position at 200% is a candidate
        spot = new HdFeed(DOLLAR);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BOOK, 200_000 ether);
        imd.mint(HOLDER, 300_000 ether);
        vm.stopPrank();
        vm.startPrank(BOOK);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(199_000 ether);
        vault.draw(99_500 ether); // 200%: the candidate
        vm.stopPrank();
        vm.startPrank(HOLDER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(300_000 ether);
        vault.draw(100_000 ether); // the redeemer's imdUSD, held for a day
        vm.stopPrank();
        for (uint256 i; i < 24; ++i) {
            _hour();
        }
        assertEq(vault.backingPerUnit(), 1e18, "a par book");
    }

    function _next(uint256 seconds_) private {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1 + seconds_ / 12);
        primary.set(imdEth);
        spot.set(imdEth);
        health.set(0.85 ether);
    }

    function _hour() private {
        _next(1 hours);
        vault.pace();
    }

    /// @dev One step the feeds accept (20%), then the pool is held there and re-attested every hour for five
    /// hours (anyone may `pace`, and the Treasury's own fall trigger buys the first update). The next block a
    /// holder redeems against the candidate.
    function test_aPoolHeldDownFiveHoursStillPaysTheWholeFallInExtraIMD() public {
        uint256 preFall = DOLLAR;
        imdEth = DOLLAR * 80 / 100;
        _next(12);
        for (uint256 i; i < 5; ++i) {
            _hour();
        }
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        assertEq(price, 0.8 ether, "the vault prices at the attested low");
        // On c90e8d9 (5% an hour) the paid price had followed the fall in full here; at 1% an hour it has fallen
        // 0.99^5, so the five-hour hold is paid at most the fee back.
        assertGe(vault.payoutPrice(), 0.95 ether, "after five paced hours the paid price has fallen at most 5%");
        (uint256 bookCollateralBefore, uint256 bookDebtBefore) = vault.positions(BOOK);
        vm.prank(HOLDER);
        uint256 gemOut = vault.cash(50_000 ether, 0, BOOK);
        (uint256 bookCollateralAfter, uint256 bookDebtAfter) = vault.positions(BOOK);
        assertEq(bookCollateralBefore - bookCollateralAfter, gemOut, "paid from the candidate");
        assertEq(bookDebtBefore - bookDebtAfter, 50_000 ether, "fifty thousand of debt cancelled");
        // EXPECTED: 50,000 imdUSD takes at most 50,000 IMD at the pre-fall price. ACTUAL on c90e8d9: 59,375 IMD.
        uint256 valueAtPreFall = Math.mulDiv(gemOut, preFall * 2000, 1e18);
        assertLe(valueAtPreFall, 50_000 ether, "a pool held down five hours pays the redeemer more than it burned");
    }

    /// @dev The other direction, ACCEPTED with its bound stated at PAYOUT_PRICE_FALL_BPS_PER_HOUR (payout vault
    /// panel, low): a pool pushed up 20% through one window and paced writes the rise at once; released, the paid
    /// price sits 20% above the attested one and decays 1% a paced hour, underpaying redeemers (never overpaying)
    /// until it has: about 18 hours for 20%. The figures the panel measured at 5% an hour, at 1%.
    function test_aPumpThroughOneWindowUnderpaysRedeemersUntilItHasDecayed() public {
        imdEth = DOLLAR * 120 / 100;
        _next(12);
        vault.pace(); // the rise is written at once
        assertEq(vault.payoutPrice(), 1.2 ether, "a pushed-up price is paid at once");
        imdEth = DOLLAR;
        _next(12);
        assertApproxEqRel(vault.payoutPrice(), 1.2 ether, 0.001e18, "released, the paid price is still the push");
        vm.prank(HOLDER);
        uint256 gemOut = vault.cash(50_000 ether, 0, BOOK);
        assertLt(gemOut, 47_500 ether, "redeemers are underpaid while the push decays");
        assertGt(gemOut, 39_000 ether, "by at most the push (0.95 / 1.2)");
        for (uint256 i; i < 19; ++i) {
            _hour();
        }
        assertEq(vault.payoutPrice(), 1 ether, "nineteen paced hours later the push has decayed (0.99^19 x 1.2 < 1)");
        assertGe(vault.payoutPrice(), 1 ether, "never below the attested price");
    }

    /// @dev The same hold, two hours: already above break-even (the fee is at most 5%).
    function test_aPoolHeldDownTwoHoursAlreadyPaysMoreThanBurned() public {
        uint256 preFall = DOLLAR;
        imdEth = DOLLAR * 80 / 100;
        _next(12);
        for (uint256 i; i < 2; ++i) {
            _hour();
        }
        vm.prank(HOLDER);
        uint256 gemOut = vault.cash(50_000 ether, 0, BOOK);
        uint256 valueAtPreFall = Math.mulDiv(gemOut, preFall * 2000, 1e18);
        assertLe(valueAtPreFall, 50_000 ether, "a pool held down two hours pays the redeemer more than it burned");
    }
}
