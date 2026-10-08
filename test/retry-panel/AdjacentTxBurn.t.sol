// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry panel audit 2026-10-07 (vault, job 3226aaed): the panel's reproduction of two mediums (a repayment one transaction before a redemption: the fee base is fixed, the backing premium accepted and bounded),
// kept as written apart from reading the lag through laggedNow() and seasoning the fee test's position.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract AbFeed is ISwarmFeed {
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

contract AbMirror is ISwarmFeed {
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

contract AbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice BURNED_THIS_TX_SLOT is transient: it adds a repayment back to the supply only inside the transaction
/// that burned it. The sweep panel's two mediums (a same-call wipe / cash / draw paid above pro rata and pinned
/// the fee base) are closed for one call and open for three consecutive transactions, which cost gas and a
/// few seconds, not "real capital in an open position" (CDPVault.sol 239-241).
contract AdjacentTxBurnTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant OTHER = address(0x07E);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    AbFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new AbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new AbFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        AbFeed health = new AbFeed(0.85 ether); // mat 170, gap 50
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new AbMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 10_000 ether);
        imd.mint(OTHER, 10_000 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(OTHER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// @dev The same below-par book as the test below, warm.
    function _bandBook() private returns (uint256 backing) {
        vm.startPrank(BORROWER);
        vault.lock(5_790 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.startPrank(OTHER);
        vault.lock(5_100 ether);
        vault.draw(3_000 ether);
        stable.transfer(BORROWER, 3_000 ether);
        vm.stopPrank();
        primary.set(uint256(0.294 ether) * 1e18 / 2000 ether);
        vm.prank(BORROWER);
        vault.lock(1);
        vm.prank(OTHER);
        vault.lock(1);
        vm.warp(block.timestamp + 3 days);
        backing = vault.backingPerUnit();
    }

    /// @dev Backing below par (OTHER underwater), the borrower in the 170-200% band so its term is its whole
    /// collateral and a repayment of up to 15% of principal leaves the numerator untouched.
    function test_adjacentWipeCashDrawPremiumIsBounded() public {
        vm.startPrank(BORROWER);
        vault.lock(5_790 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.startPrank(OTHER);
        vault.lock(5_100 ether);
        vault.draw(3_000 ether);
        stable.transfer(BORROWER, 3_000 ether);
        vm.stopPrank();
        // IMD to $0.294: the borrower at 170.2%, OTHER at 50%.
        primary.set(uint256(0.294 ether) * 1e18 / 2000 ether);
        vm.prank(BORROWER);
        vault.lock(1);
        vm.prank(OTHER);
        vault.lock(1);
        vm.warp(block.timestamp + 3 days);
        uint256 backing = vault.backingPerUnit();
        assertApproxEqRel(backing, 0.8004e18, 1e15, "below par");

        // The honest payout for a 500 redemption against the borrower, in a world with no churn.
        uint256 snap = vm.snapshotState();
        vm.prank(BORROWER);
        uint256 honest = vault.cash(500 ether, 0, BORROWER);
        vm.revertToState(snap);

        // Three consecutive transactions: wipe 140 (term unchanged: 2 x 860 / 0.294 > 5,790), cash 500, draw 140.
        vm.prank(BORROWER);
        vault.wipe(140 ether);
        assertEq(vault.securedCollateral(), 5_790 ether + 5_100 ether + 2, "the numerator did not move");
        vm.prank(BORROWER);
        uint256 churned = vault.cash(500 ether, 0, BORROWER);
        vm.prank(BORROWER);
        vault.draw(140 ether);
        // ACCEPTED (CDPVault._backingPerUnit): the cash reads the true backing of that moment, 3,860 of supply under
        // an unchanged numerator; the premium is at most (supply - fresh) / (supply - fresh - repaid), here
        // 4,000 / 3,860 with nothing fresh. Closing it per position (58f73de) could be pumped without bound (final
        // vault panel 2026-10-08, high) and was removed; lagging the whole supply underpaid every honest redeemer.
        assertGt(churned, honest, "the churn is paid the backing it briefly created");
        assertLe(churned, honest * 4_000 / 3_860 + 1e9, "and never more than the bound");
    }

    /// @dev The fee base: a borrower holding 90% of the supply as its own debt pins the base rate at the cap
    /// for 0.045 imdUSD of fee instead of 4.5.
    function test_adjacentWipeCashDrawPinsTheFeeBase() public {
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(900 ether);
        vm.stopPrank();
        vm.startPrank(OTHER);
        vault.lock(200 ether);
        vault.draw(100 ether);
        stable.transfer(BORROWER, 9 ether);
        vm.stopPrank();
        address treasury = address(vault.treasury());
        vm.prank(APPROVED_OPERATOR);
        imd.mint(treasury, 100 ether); // the redemption is reserve-funded
        // A SEASONED dominant position, as the finding describes: principal drawn moments before and repaid is
        // cold, and its repayment counts at once (the base is then the warm supply that stood before it, and
        // pinning the fee costs exactly the honest amount). Warm principal's repayment lags.
        vm.warp(block.timestamp + 2 days);
        assertEq(stable.totalSupply(), 1_000 ether);
        assertEq(vault.redemptionFeeBps(9 ether), 95, "floor 50 + 9 / 1,000 / 2 = 45 bps");

        vm.prank(BORROWER);
        vault.wipe(900 ether);
        vm.prank(BORROWER);
        vault.cash(9 ether, 0, address(0));
        vm.prank(BORROWER);
        vault.draw(900 ether);
        (, uint256 debt) = vault.positions(BORROWER);
        assertApproxEqAbs(debt, 900 ether, 0.5 ether, "the position is where it was, but for two days of fee");
        // EXPECTED: 45 bps, the increase for 9 of 1,000. ACTUAL: the 450 bps cap, for everyone, for a half-life.
        // Within the position's own residual cold after two days (1/256 of it, which repays at once).
        assertApproxEqRel(vault.redemptionBaseRate(), 0.0045e18, 0.005e18, "the fee base is the supply before the churn");
    }
}