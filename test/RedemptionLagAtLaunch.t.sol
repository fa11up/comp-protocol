// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract DFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 public value;

    constructor(uint256 v) {
        value = v;
    }

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract DMirror is ISwarmFeed {
    ISwarmFeed private immutable p;

    constructor(ISwarmFeed p_) {
        p = p_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return p.latestValue();
    }

    function isStale() external view returns (bool) {
        return p.isStale();
    }

    function maxAge() external view returns (uint256) {
        return p.maxAge();
    }
}

contract DAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Adversarial review 2026-10-05, finding 1 (medium), replayed from its own proof. D1's
/// REDEMPTION half needs no work minting: after a price fall leaves backing below par, capital brought
/// in ONE transaction earlier (same block, no interest, no price exposure) used to lift backingPerUnit
/// to 1.0 and let the next transaction redeem the Treasury's reserve at par (9.875 IMD here). The
/// reviewer's suggested fix — the existing lag, ungated — paid 3.11, half the fair figure, because the
/// fresh debt still diluted supply. As built, the redemption cap is min(live, lagged) where the lagged
/// figure removes fresh capital from BOTH sides, at every wage: it pays the pre-existing backing, 6.22.
/// Each top-level call below is its own transaction (isolate), so transient storage clears between them.
contract RedemptionLagAtLaunchTest is Test {
    address private constant HONEST = address(0x40E);
    address private constant ATTACKER = address(0xBAD);
    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    DFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new DAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new DFeed(uint256(1 ether) * 1e18 / 2000 ether); // $1 per IMD
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(new DFeed(0.85 ether)), address(new DMirror(primary))
        );
        stable = vault.stablecoin();
        assertEq(vault.parameters().wage(), 0, "launch configuration: lag dormant");
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(HONEST, 200 ether);
        imd.mint(ATTACKER, 1_000 ether);
        imd.mint(address(vault.treasury()), 10 ether); // the Treasury's reserve (liquidation cuts, dust)
        vm.stopPrank();
        vm.prank(HONEST);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(ATTACKER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(HONEST);
        vault.lock(200 ether);
        vm.prank(HONEST);
        vault.draw(100 ether);
        // Three days: the honest capital is warm (1 - 2^-12 of it, BACKING_HALF_LIFE six hours).
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 21_600);
        // IMD falls 70%; the honest position is underwater and not yet liquidated (grace).
        primary.set(uint256(0.3 ether) * 1e18 / 2000 ether);
    }

    /// forge-config: default.isolate = true
    function test_freshCapitalOneTransactionOldDoesNotLiftTheReservePayoutAtLaunch() public {
        uint256 before = vault.backingPerUnit();
        assertLt(before, 0.7e18, "backing is ~0.64 after the fall");

        // Transaction 1: real capital, in the same block.
        vm.prank(ATTACKER);
        vault.lock(1_000 ether);
        vm.prank(ATTACKER);
        vault.draw(100 ether);

        // Transaction 2, same block: redeem 3 imdUSD; the Treasury's reserve alone funds it.
        uint256 feeBps = vault.redemptionFeeBps(3 ether);
        uint256 reserveBefore = imd.balanceOf(address(vault.treasury()));
        vm.prank(ATTACKER);
        uint256 gemOut = vault.cash(3 ether, 0, address(0));
        assertEq(reserveBefore - imd.balanceOf(address(vault.treasury())), gemOut, "paid from the reserve");

        // What D1's fix promises: the payout scale is the backing that stood before this capital arrived.
        uint256 price = uint256(0.3 ether); // USD per IMD, as the vault reads it
        uint256 fair = Math.mulDiv(3 ether, Math.mulDiv(before, 10_000 - feeBps, 10_000), price);
        emit log_named_decimal_uint("reserve IMD paid", gemOut, 18);
        emit log_named_decimal_uint("at the pre-existing backing", fair, 18);
        // Within the honest capital's own residual cold (2^-12 of it after three days): an underwater
        // position still partly cold reads the lagged figure a hair above the live one, and the attacker's
        // capital can lift the live one that far, never toward par.
        assertLe(gemOut, fair + fair / 10_000, "fresh capital must not let a redemption take the reserve at par");
        assertGe(gemOut, fair - 1e9, "nor push it below the backing that already stood (the 3.11 fix)");

        // Transaction 3: unwind. Only 3 imdUSD of the 100 drawn stays owed; the rest of the capital leaves.
        vm.prank(ATTACKER);
        vault.wipe(97 ether);
        vm.prank(ATTACKER);
        vault.free(950 ether);
    }
}

/// @notice The other side of the two-sided lag: an HONEST redemption is not underpaid while the vault
/// is young. On launch day every unit of supply is fresh debt, so the lagged figure has nothing left to
/// divide by and the live figure stands; a day later the lag has caught up and agrees with it.
contract RedemptionLagHonestTest is Test {
    address private constant BORROWER = address(0x40E);
    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new DAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        DFeed primary = new DFeed(uint256(1 ether) * 1e18 / 2000 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(new DFeed(0.85 ether)), address(new DMirror(primary))
        );
        stable = vault.stablecoin();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 400 ether);
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function test_launchDayRedemptionAgainstFreshDebtIsPaidAtPar() public {
        // 180%: inside the redeemable band, so the burn is funded from the position (no reserve).
        vm.prank(BORROWER);
        vault.lock(180 ether);
        vm.prank(BORROWER);
        vault.draw(100 ether);
        (uint256 lagDebt,) = vault.laggedNow();
        assertEq(lagDebt, 0, "every unit of debt is fresh");
        assertEq(vault.backingPerUnit(), 1e18, "all supply is fresh debt, so the live figure stands");
        uint256 feeBps = vault.redemptionFeeBps(10 ether);
        vm.prank(BORROWER);
        uint256 out = vault.cash(10 ether, 0, BORROWER);
        assertEq(out, 10 ether * (10_000 - feeBps) / 10_000, "par less the fee, at $1");
    }

    /// forge-config: default.isolate = true
    function test_partWarmCapitalPaysTheLowerOfTheTwoFiguresAndCatchesUp() public {
        vm.prank(BORROWER);
        vault.lock(200 ether);
        vm.prank(BORROWER);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(BORROWER);
        vault.lock(200 ether);
        (uint256 lagDebt, uint256 lagSecured) = vault.laggedNow();
        assertApproxEqAbs(lagDebt, 75 ether, 1e9, "two half-lives credit three quarters of the debt");
        assertApproxEqAbs(lagSecured, 150 ether, 1e9, "and of the secured collateral, which now stops growing");
        assertEq(vault.backingPerUnit(), 1e18, "warm capital on both sides keeps par");
        vm.warp(block.timestamp + 3 days);
        (lagDebt, lagSecured) = vault.laggedNow();
        assertApproxEqRel(lagDebt, 100 ether, 0.0003e18);
        assertApproxEqRel(lagSecured, vault.securedCollateral(), 0.0003e18);
        assertEq(vault.backingPerUnit(), 1e18);
    }
}
