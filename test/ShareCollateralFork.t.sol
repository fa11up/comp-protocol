// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {ReserveUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {CHAINLINK_ETH_USD} from "src/DeploymentConfig.sol";

/// @notice `lockIMD` against the LIVE StakedIMD vault on Ethereum mainnet, not a mock: the wrap, the
/// credit, the valuation, and that liquidation can move the shares in the very block they were minted.
/// @dev Run with a mainnet fork: `forge test --match-path test/ShareCollateralFork.t.sol --fork-url
/// $MAINNET_RPC_URL`. Skipped otherwise, like the other fork suites.
contract ShareCollateralForkTest is Test {
    address private constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xBEEF);
    uint256 private constant IMD_ETH = 0.003 ether;

    ParameterizedVault private vault;
    TestSwarmFeed private primary;

    function setUp() public {
        if (block.chainid != 1 || SIMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        primary = new TestSwarmFeed(IMD_ETH);
        TestSwarmFeed health = new TestSwarmFeed(0.9 ether);
        // The pinned ETH/USD address is a per-network constant; give it a fixed answer on the fork.
        vm.etch(CHAINLINK_ETH_USD, address(new ReserveUsdAggregator()).code);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).setDecimals(8);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).set(3_000e8, block.timestamp);
        vault = new ParameterizedVault(
            SIMD, address(0), address(0), address(primary), address(health),
            address(new MirroredSwarmFeed(address(primary)))
        );
        deal(IMD, BORROWER, 10_000 ether);
        deal(IMD, KEEPER, 50_000 ether);
    }

    function _lockIMD(address who, uint256 assets) private returns (uint256 shares) {
        vm.startPrank(who);
        IERC20(IMD).approve(address(vault), assets);
        uint256 before = IERC20(SIMD).balanceOf(address(vault));
        vault.lockIMD(assets);
        vm.stopPrank();
        shares = IERC20(SIMD).balanceOf(address(vault)) - before;
    }

    function test_lockIMDWrapsIntoTheLiveVaultAndKeepsItsValue() public {
        uint256 shares = _lockIMD(BORROWER, 1_000 ether);
        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, shares, "credited the shares the live vault minted");
        assertGt(shares, 0);
        // 1,000 IMD at 0.003 ETH and $3,000/ETH is $9,000; at mat 150 it backs up to $6,000 of debt.
        vm.prank(BORROWER);
        vault.draw(5_000 ether);
        uint256 cr = vault.collateralRatio(BORROWER);
        // The live rate has moved since the deposit only by rounding, so the ratio is 180% or a hair under.
        assertGe(cr, 179, "the wrapped collateral is worth what the IMD was");
        assertLe(cr, 180);
        assertEq(IERC20(IMD).allowance(address(vault), SIMD), 0, "no allowance left on the live vault");
    }

    /// @dev The one-block hold is on the share vault's withdraw path only. Liquidation moves shares by
    /// plain transfer, so a position wrapped in this very block can still be bitten in it.
    function test_sharesMintedThisBlockCanBeSeizedThisBlock() public {
        _lockIMD(BORROWER, 1_000 ether);
        vm.prank(BORROWER);
        vault.draw(5_000 ether);
        _lockIMD(KEEPER, 40_000 ether);
        vm.prank(KEEPER);
        vault.draw(20_000 ether);

        primary.setValue(IMD_ETH * 7 / 10); // 126%: under mat
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        vm.warp(block.timestamp + vault.lull() + 1);
        primary.setValue(IMD_ETH * 7 / 10);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).set(3_000e8, block.timestamp);

        // Fresh shares into the vault in the SAME block as the bite.
        _lockIMD(BORROWER, 1 ether);
        uint256 before = IERC20(SIMD).balanceOf(KEEPER);
        vm.prank(KEEPER);
        vault.bite(BORROWER, 1_000 ether);
        assertGt(IERC20(SIMD).balanceOf(KEEPER), before, "seized as sIMD in the block it was minted");
    }
}
