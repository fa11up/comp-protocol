// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry2 panel audit 2026-10-08 (vault, job a2640621): the panel's reproduction of the medium F1 (a cold draw and repayment by another position erased a warm repayment from the fee base),
// kept as written. It failed on 24337a2 and passes on the fix.

// A cold draw by any position absorbs a warm repayment's fading share of the lagged fee base at the next
// checkpoint, and the cold repayment is then subtracted from the base a second time: a dominant borrower's
// wipe, a helper's draw-and-wipe, and a small cash pin the redemption fee at the cap for a tenth of the
// honest cost, with no seasoned capital and no wait.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {SmallFloorVault} from "test/helpers/SmallFloorVault.sol"; // the 1,000 floor these figures assume
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract FbFeed is ISwarmFeed {
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

contract FbMirror is ISwarmFeed {
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

contract FbAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev A helper position that draws cold principal and repays it in the same call.
contract FbHelper {
    ParameterizedVault private immutable vault;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function lockDrawWipe(uint256 collateral, uint256 debt) external {
        vault.lock(collateral);
        vault.draw(debt);
        vault.wipe(debt);
    }
}

contract FeeBaseColdMintTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant OTHER = address(0x07E);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    FbHelper private helper;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new FbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        FbFeed primary = new FbFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        FbFeed health = new FbFeed(0.85 ether); // mat 170, gap 50
        vault = new SmallFloorVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new FbMirror(primary))
        );
        stable = vault.stablecoin();
        helper = new FbHelper(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 10_000 ether);
        imd.mint(OTHER, 10_000 ether);
        imd.mint(address(helper), 10_000 ether);
        imd.mint(address(vault.treasury()), 100 ether); // the redemption is reserve-funded
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(OTHER);
        imd.approve(address(vault), type(uint256).max);

        // A seasoned dominant position: 900 of a 1,000 supply, warm for two days.
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(900 ether);
        vm.stopPrank();
        vm.startPrank(OTHER);
        vault.lock(200 ether);
        vault.draw(100 ether);
        stable.transfer(BORROWER, 9 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        assertEq(stable.totalSupply(), 1_000 ether);
        assertEq(vault.redemptionFeeBps(9 ether), 95, "floor 50 + 9 / 1,000 / 2 = 45 bps");
    }

    /// Transaction 1: the dominant borrower repays its warm 900 (the base keeps it, fading over hours).
    /// Transaction 2: a helper position draws 900 cold and repays it in the same call.
    /// Transaction 3: a 9 imdUSD redemption. EXPECTED: an increase of 45 bps against a base of about 1,000.
    /// ACTUAL: the base read about 100, and the rate is pinned at the 450 bps cap for a tenth of the cost.
    function test_aColdDrawAndRepayByAnotherPositionEmptiesTheLaggedFeeBase() public {
        vm.prank(BORROWER);
        vault.wipe(900 ether);
        helper.lockDrawWipe(2_000 ether, 900 ether);
        assertApproxEqAbs(stable.totalSupply(), 100 ether, 0.5 ether, "supply is back where the wipe left it");
        // The quote already shows it: the increase for 9 imdUSD reads the cap instead of 45 bps.
        assertLe(vault.redemptionFeeBps(9 ether), 95 + 1, "the lagged base must still hold the warm 900 repaid moments ago");
        vm.prank(BORROWER);
        vault.cash(9 ether, 0, address(0));
        assertLe(vault.redemptionBaseRate(), 0.0046e18, "a 9-of-1,000 burn must not pin the fee at the cap");
        // The dominant borrower redraws from its bank, warm, and the position is where it was.
        vm.prank(BORROWER);
        vault.draw(900 ether);
    }

    /// The same, as three separate transactions from two keys (no contract needed).
    function test_theHelperNeedsNoContract() public {
        vm.prank(BORROWER);
        vault.wipe(900 ether);
        vm.startPrank(OTHER);
        vault.lock(2_000 ether);
        vault.draw(900 ether);
        vault.wipe(900 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        vault.cash(9 ether, 0, address(0));
        assertLe(vault.redemptionBaseRate(), 0.0046e18, "a 9-of-1,000 burn must not pin the fee at the cap");
    }
}