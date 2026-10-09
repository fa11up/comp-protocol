// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// Final audit 2026-10-08: a band position's draw makes a share of its secured term cold (delta panel #1 fix), but a
// wipe of that same cold principal never warms the term back. Draw/wipe cycles therefore accumulate phantom cold
// secured until the position's WHOLE term reads cold in laggedNow(), while its debt is warm. The lagged backing figure
// then excludes that borrower's collateral against the whole warm supply, and every redemption is paid that figure.
// Gas only, in one transaction, no price exposure, re-armable every block, lasting hours.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract PcFeed is ISwarmFeed {
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

contract PcMirror is ISwarmFeed {
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

contract PcAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev The borrower as a contract, so the whole churn is one transaction.
contract Churner {
    ParameterizedVault private immutable vault;

    constructor(ParameterizedVault v) {
        vault = v;
    }

    function open(MockIMD imd, uint256 collateral, uint256 debt) external {
        imd.approve(address(vault), type(uint256).max);
        vault.lock(collateral);
        vault.draw(debt);
    }

    function churn(uint256 amount, uint256 cycles) external {
        for (uint256 i; i < cycles; ++i) {
            vault.draw(amount);
            vault.wipe(amount);
        }
    }
}

contract PhantomColdTest is Test {
    address private constant OTHER = address(0x07E);
    address private constant HOLDER = address(0x401D);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    PcFeed private primary;
    Churner private churner;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new PcAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new PcFeed(DOLLAR);
        PcFeed health = new PcFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new PcMirror(primary))
        );
        stable = vault.stablecoin();
        churner = new Churner(vault);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(address(churner), 180_000 ether);
        imd.mint(OTHER, 20_000 ether);
        vm.stopPrank();
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_drawWipeCyclesMakeAWarmTermReadColdAndCrushTheRedemptionFigure() public {
        // A warm book: the churner at 180% (band: its term is its whole collateral), another borrower at 200%.
        churner.open(imd, 180_000 ether, 100_000 ether);
        vm.startPrank(OTHER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(20_000 ether);
        vault.draw(10_000 ether);
        stable.transfer(HOLDER, 10_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        _next();
        (, uint256 warmSecuredBefore) = (vault.totalDebt(), vault.securedCollateral());
        assertEq(warmSecuredBefore, 200_000 ether, "everything is warm after two quiet days");
        assertEq(vault.backingPerUnit(), 1e18, "fully backed");

        // One transaction, gas only: draw 5,000 / wipe 5,000, twenty times. The position ends exactly where it was.
        churner.churn(5_000 ether, 20);
        (uint256 collateral, uint256 debt) = vault.positions(address(churner));
        assertEq(collateral, 180_000 ether);
        assertApproxEqAbs(debt, 100_000 ether, 100 ether, "the same loan, plus two days of fee");
        assertEq(vault.securedCollateral(), 200_000 ether, "the live secured total did not move");
        (uint256 lagDebt, uint256 lagSecured) = (vault.totalDebt(), vault.securedCollateral());
        emit log_named_uint("lagged debt (all warm)", lagDebt);
        emit log_named_uint("lagged secured after the churn", lagSecured);
        _next();

        // EXPECTED: the churner's collateral has been in the vault for days and its debt is warm, so the lagged
        // figure still counts it. ACTUAL: its whole 180,000 term reads cold, and the figure is OTHER's 20,000
        // against the whole 110,000 supply.
        uint256 figure = vault.backingPerUnit();
        emit log_named_uint("backingPerUnit after the churn", figure);
        vm.prank(HOLDER);
        uint256 paid = vault.cash(1_000 ether, 0, OTHER);
        emit log_named_uint("paid for 1,000 imdUSD against OTHER (raw IMD)", paid);
        assertGe(lagSecured, 190_000 ether, "a position's own cold draw, repaid, must not leave its warm term cold");
        assertGe(figure, 0.99e18, "a redemption on a fully backed book was paid a fraction of par");
    }
}