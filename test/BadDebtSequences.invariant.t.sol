// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT, CHIP_BPS} from "src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

/// @dev At a price of (100 + CHOP_PERCENT)%, every repayment wei seizes exactly one collateral wei.
/// This deliberately makes complete exhaustion reachable throughout random call sequences.
contract BadDebtSequenceHandler is Test {
    address public constant MARKER = address(0xA001);
    address public constant LIQUIDATOR = address(0xA002);
    address[3] public actors = [address(0xB001), address(0xB002), address(0xB003)];
    MockIMD public imd;
    CDPVault public vault;
    ImdUSD public comp;
    TestSwarmFeed private primary;
    TestSwarmFeed private spot;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public recorded;
    uint256 public markerReceived;
    uint256 public liquidatorReceived;
    uint256 public exhaustionCount;
    /// @dev 1 + the liquidation bonus, read from the vault: the price at which seizure is one-for-one.
    uint256 public unitPrice;

    constructor() {
        imd = new MockIMD();
        primary = new TestSwarmFeed(4 ether);
        spot = new TestSwarmFeed(4 ether);
        TestSwarmFeed nhi = new TestSwarmFeed(0.6 ether);
        vault = new BaselineVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.stablecoin();
        unitPrice = (100 + vault.CHOP_PERCENT()) * 1e16;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            _deposit(actor, 60 ether);
            vm.startPrank(actor);
            vault.draw(100 ether);
            comp.transfer(LIQUIDATOR, 100 ether);
            vm.stopPrank();
            debt[actor] = 100 ether;
        }
        _price(unitPrice);
        // Every sequence starts with a real recorded shortfall and two further exhaustible positions.
        _liquidate(actors[0], 60 ether);
    }

    function exhaust(uint256 seed) external {
        address actor = actors[seed % actors.length];
        uint256 available = collateral[actor];
        if (available == 0 || available >= debt[actor]) return;
        _liquidate(actor, available);
    }

    function partialLiquidation(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % actors.length];
        uint256 outstanding = debt[actor];
        uint256 available = collateral[actor];
        if (outstanding == 0 || available == 0 || available * unitPrice >= outstanding * 2 ether) return;
        uint256 maximum = available < outstanding ? available : outstanding;
        _liquidate(actor, bound(rawAmount, 1, maximum));
    }

    function repay(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % actors.length];
        uint256 outstanding = debt[actor];
        if (outstanding == 0) return;
        uint256 amount = bound(rawAmount, 1, outstanding);
        vm.prank(LIQUIDATOR);
        comp.transfer(actor, amount);
        vm.prank(actor);
        vault.wipe(amount);
        debt[actor] = outstanding - amount;
        // Repayment cannot erase more historical residual than the debt that actually remains.
        if (recorded[actor] > debt[actor]) recorded[actor] = debt[actor];
    }

    function recapitalize(uint256 seed, uint256 rawAmount) external {
        _deposit(actors[seed % actors.length], bound(rawAmount, 1, 150 ether));
    }

    function borrowAgain(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % actors.length];
        uint256 amount = bound(rawAmount, 1, 100 ether);
        // Supply real new collateral even if this actor still owes an earlier realized shortfall.
        _deposit(actor, debt[actor] + 2 * amount);
        _price(4 ether);
        vm.startPrank(actor);
        vault.draw(amount);
        comp.transfer(LIQUIDATOR, amount);
        vm.stopPrank();
        debt[actor] += amount;
        _price(unitPrice);
    }

    function withdrawDebtFree(uint256 seed, uint256 rawAmount) external {
        address actor = actors[seed % actors.length];
        if (debt[actor] != 0 || collateral[actor] == 0) return;
        uint256 amount = bound(rawAmount, 1, collateral[actor]);
        vm.prank(actor);
        vault.free(amount);
        collateral[actor] -= amount;
    }

    function elapse(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 2 days));
    }

    function _liquidate(address actor, uint256 amount) private {
        vm.prank(MARKER);
        vault.bark(actor);
        vm.prank(LIQUIDATOR);
        vault.bite(actor, amount);
        collateral[actor] -= amount;
        debt[actor] -= amount;
        if (recorded[actor] > debt[actor]) recorded[actor] = debt[actor];
        if (collateral[actor] == 0) {
            recorded[actor] = debt[actor];
            ++exhaustionCount;
        }
        uint256 bonus = amount - amount * 1 ether / unitPrice;
        uint256 markerCut = bonus * CHIP_BPS / 10_000;
        markerReceived += markerCut;
        liquidatorReceived += amount - markerCut;
    }

    function _deposit(address actor, uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(actor, amount);
        vm.startPrank(actor);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(amount);
        vm.stopPrank();
        collateral[actor] += amount;
    }

    function _price(uint256 price) private {
        primary.setValue(price);
        spot.setValue(price);
    }
}

contract BadDebtSequencesInvariantTest is StdInvariant, Test {
    BadDebtSequenceHandler private handler;

    function setUp() public {
        handler = new BadDebtSequenceHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.exhaust.selector;
        selectors[1] = handler.partialLiquidation.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.recapitalize.selector;
        selectors[4] = handler.borrowAgain.selector;
        selectors[5] = handler.withdrawDebtFree.selector;
        selectors[6] = handler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_realizedShortfallsAndCustodyMatchIndependentHistory() public view {
        CDPVault vault = handler.vault();
        MockIMD imd = handler.imd();
        ImdUSD comp = handler.comp();
        uint256 totalCollateral;
        uint256 totalDebt;
        uint256 totalRecorded;
        uint256 borrowerBalances;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 expectedCollateral = handler.collateral(actor);
            uint256 expectedDebt = handler.debt(actor);
            (uint256 actualCollateral, uint256 actualDebt) = vault.positions(actor);
            assertEq(actualCollateral, expectedCollateral, "borrower collateral follows cash movements");
            assertEq(actualDebt, expectedDebt, "principal is never forgiven at exhaustion");
            assertEq(vault.badDebtOf(actor), expectedDebt > expectedCollateral ? expectedDebt - expectedCollateral : 0);
            totalCollateral += expectedCollateral;
            totalDebt += expectedDebt;
            totalRecorded += handler.recorded(actor);
            borrowerBalances += imd.balanceOf(actor);
        }
        assertEq(vault.totalBadDebt(), totalRecorded, "each realized shortfall is counted exactly once");
        assertEq(vault.totalDebt(), totalDebt);
        assertEq(comp.totalSupply(), totalDebt, "zero-rate supply invariant is unchanged");
        assertEq(comp.balanceOf(handler.LIQUIDATOR()), totalDebt, "all outstanding minted COMP remains accounted for");
        assertEq(vault.totalFeesMinted(), 0);
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0);
        assertEq(imd.balanceOf(address(vault)), totalCollateral);
        assertEq(imd.balanceOf(handler.MARKER()), handler.markerReceived());
        assertEq(imd.balanceOf(handler.LIQUIDATOR()), handler.liquidatorReceived());
        assertEq(
            imd.totalSupply(),
            totalCollateral + borrowerBalances + handler.markerReceived() + handler.liquidatorReceived()
        );
        assertGt(handler.exhaustionCount(), 0, "every random history contains an actual exhaustion");
    }
}
