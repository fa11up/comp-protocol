// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";

contract ProtocolHandler is Test {
    MockIMD public imd;
    CompToken public comp;
    MockWorkOracle public oracle;
    CDPVault public vault;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public consumed;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public repaid;
    uint256 public donated;
    uint256 public successfulMints;
    uint256 public successfulRepayments;

    constructor() {
        imd = new MockIMD();
        comp = new CompToken();
        vault = new CDPVault(address(imd), address(comp), address(0));
        oracle = new MockWorkOracle(address(vault));
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        for (uint256 i; i < actors.length; ++i) {
            imd.mint(actors[i], 1e30);
            oracle.grantRights(actors[i], 1e30);
            vm.prank(actors[i]);
            imd.approve(address(vault), type(uint256).max);
            // Every actor begins with a real, healthy position. No storage writes or mocked calls.
            vm.startPrank(actors[i]);
            vault.depositCollateral(150 ether);
            vault.mintCOMP(100 ether);
            vm.stopPrank();
            deposited[actors[i]] = 150 ether;
            consumed[actors[i]] = 100 ether;
        }
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = imd.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.depositCollateral(amount);
        deposited[actor] += amount;
    }

    function mint(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 available = collateral * 2 / 3 - debt;
        uint256 rights = oracle.mintingRights(actor);
        if (available > rights) available = rights;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.mintCOMP(amount);
        consumed[actor] += amount;
        ++successfulMints;
    }

    function repay(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (, uint256 debt) = vault.positions(actor);
        uint256 available = comp.balanceOf(actor);
        if (available > debt) available = debt;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.repayCOMP(amount);
        repaid[actor] += amount;
        ++successfulRepayments;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 available = collateral - debt - (debt + 1) / 2;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.withdrawCollateral(amount);
        withdrawn[actor] += amount;
    }

    function donateIMD(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = imd.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        imd.transfer(address(vault), amount);
        donated += amount;
    }

    function transferCOMP(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address actor = actors[fromSeed % 4];
        amount = bound(amount, 0, comp.balanceOf(actor));
        vm.prank(actor);
        comp.transfer(actors[toSeed % 4], amount);
    }

    function attemptUnsafeMint(uint256 seed) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 amount = collateral * 2 / 3 - debt + 1;
        bytes4 reason = oracle.mintingRights(actor) < amount
            ? CDPVault.InsufficientRights.selector
            : CDPVault.UnsafeCollateralRatio.selector;
        vm.prank(actor);
        vm.expectRevert(reason);
        vault.mintCOMP(amount);
    }

    function attemptUnsafeWithdrawal(uint256 seed) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        if (debt == 0) return;
        uint256 amount = collateral - (debt * 150 + 99) / 100 + 1;
        vm.prank(actor);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(amount);
    }

    function attemptExcessRepayment(uint256 seed) external {
        address actor = actors[seed % 4];
        (, uint256 debt) = vault.positions(actor);
        vm.prank(actor);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(debt + 1);
    }

    function attemptHealthyLiquidation(uint256 ownerSeed, uint256 callerSeed) external {
        vm.prank(actors[callerSeed % 4]);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(actors[ownerSeed % 4], 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ProtocolInvariantTest is StdInvariant, Test {
    ProtocolHandler internal handler;

    function setUp() public {
        handler = new ProtocolHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.transferCOMP.selector;
        selectors[5] = handler.attemptUnsafeMint.selector;
        selectors[6] = handler.attemptHealthyLiquidation.selector;
        selectors[7] = handler.attemptUnsafeWithdrawal.selector;
        selectors[8] = handler.attemptExcessRepayment.selector;
        selectors[9] = handler.donateIMD.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyEqualsDebtAndCollateralIsConserved() public view {
        uint256 debts;
        uint256 collateral;
        uint256 walletCOMP;
        uint256 walletIMD;
        CDPVault vault = handler.vault();
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 c, uint256 d) = vault.positions(actor);
            debts += d;
            collateral += c;
            walletCOMP += handler.comp().balanceOf(actor);
            walletIMD += handler.imd().balanceOf(actor);
            // Check the raw inequality independently of the contract's CR implementation.
            assertGe(c * 100, d * 150, "position below 150%");
            assertGe(vault.collateralRatio(actor), 150);
            assertEq(c, handler.deposited(actor) - handler.withdrawn(actor), "collateral history");
            assertEq(d, handler.consumed(actor) - handler.repaid(actor), "debt history");
            assertEq(handler.oracle().mintingRights(actor) + handler.consumed(actor), 1e30);
        }
        assertEq(handler.comp().totalSupply(), debts);
        assertEq(walletCOMP, debts);
        assertEq(handler.imd().balanceOf(address(vault)), collateral + handler.donated());
        assertEq(walletIMD + collateral + handler.donated(), handler.imd().totalSupply());
    }

    /// @dev Redistribute existing COMP to its debtors, then close every position after each run.
    /// This proves redeemability without minting tokens, restoring rights, or changing storage.
    function afterInvariant() public {
        CompToken comp = handler.comp();
        address collector = handler.actors(0);
        for (uint256 i = 1; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = comp.balanceOf(actor);
            vm.prank(actor);
            comp.transfer(collector, balance);
        }
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 collateral, uint256 debt) = handler.vault().positions(actor);
            if (debt != 0) {
                if (i != 0) {
                    vm.prank(collector);
                    comp.transfer(actor, debt);
                }
                handler.repay(i, debt);
            }
            if (collateral != 0) handler.withdraw(i, collateral);
            (uint256 remainingCollateral, uint256 remainingDebt) = handler.vault().positions(actor);
            assertEq(remainingCollateral, 0, "all collateral redeemable");
            assertEq(remainingDebt, 0, "all debt repayable");
        }
        assertEq(comp.totalSupply(), 0);
        assertEq(handler.imd().balanceOf(address(handler.vault())), handler.donated());
        invariant_supplyEqualsDebtAndCollateralIsConserved();
    }

    function test_handlerExercisesAllTransitionsAndClosesPositions() public {
        handler.deposit(0, 30 ether);
        handler.mint(0, 10 ether);
        handler.transferCOMP(0, 1, 10 ether);
        handler.repay(1, 5 ether);
        handler.withdraw(1, 1 ether);
        handler.donateIMD(2, 7 ether);
        handler.attemptUnsafeMint(0);
        handler.attemptUnsafeWithdrawal(0);
        handler.attemptExcessRepayment(0);
        handler.attemptHealthyLiquidation(0, 1);
        assertEq(handler.successfulMints(), 1);
        assertEq(handler.successfulRepayments(), 1);
        invariant_supplyEqualsDebtAndCollateralIsConserved();
        afterInvariant();
    }
}
