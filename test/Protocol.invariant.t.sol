// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";

contract ProtocolHandler is Test {
    address private constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    MockIMD public imd;
    CompToken public comp;
    MockWorkOracle public oracle;
    CDPVault public vault;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public consumed;
    uint256 public successfulMints;
    uint256 public successfulRepayments;

    constructor() {
        imd = new MockIMD();
        comp = new CompToken(address(0));
        vault = new CDPVault(address(imd), address(comp), address(0));
        oracle = new MockWorkOracle(address(vault));
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        vm.stopPrank();
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(OPERATOR);
            imd.mint(actors[i], 1e30);
            oracle.grantRights(actors[i], 1e30);
            vm.stopPrank();
            vm.prank(actors[i]);
            imd.approve(address(vault), type(uint256).max);
        }
        // Seed debt so the supply/debt invariant is exercised even before the first generated borrow.
        vm.startPrank(actors[0]);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        consumed[actors[0]] = 100 ether;
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = imd.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.depositCollateral(amount);
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
        vm.prank(actor);
        vm.expectRevert();
        vault.mintCOMP(amount);
    }

    function attemptHealthyLiquidation(uint256 ownerSeed, uint256 callerSeed) external {
        vm.prank(actors[callerSeed % 4]);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(actors[ownerSeed % 4], 1);
    }
}

contract ProtocolInvariantTest is StdInvariant, Test {
    ProtocolHandler internal handler;

    function setUp() public {
        handler = new ProtocolHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.transferCOMP.selector;
        selectors[5] = handler.attemptUnsafeMint.selector;
        selectors[6] = handler.attemptHealthyLiquidation.selector;
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
            assertGe(vault.collateralRatio(actor), 150);
            assertEq(handler.oracle().mintingRights(actor) + handler.consumed(actor), 1e30);
        }
        assertEq(handler.comp().totalSupply(), debts);
        assertEq(walletCOMP, debts);
        assertEq(handler.imd().balanceOf(address(vault)), collateral);
        assertEq(walletIMD + collateral, handler.imd().totalSupply());
    }
}
