// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

contract ProtocolHandler is Test {
    address private constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    uint256 public constant INITIAL_BALANCE = 1e30;
    uint256 public constant INITIAL_RIGHTS = 1e30;
    MockIMD public imd;
    CompToken public comp;
    MockWorkOracle public oracle;
    CDPVault public vault;
    TestSwarmFeed public priceFeed;
    TestSwarmFeed public nhiFeed;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public debtMinted;
    mapping(address => uint256) public workMinted;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public repaid;
    mapping(address => uint256) public debtLiquidated;
    mapping(address => uint256) public collateralSeized;
    mapping(address => uint256) public collateralReceived;
    mapping(address => uint256) public donations;
    mapping(address => uint256) public markedAt;
    mapping(address => uint256) public graceSnapshot;
    uint256 public donated;
    uint256 public successfulDebtMints;
    uint256 public successfulWorkMints;
    uint256 public successfulRepayments;
    uint256 public successfulLiquidations;
    uint256 public successfulMarks;
    uint256 public successfulRecoveries;

    constructor() {
        imd = new MockIMD();
        comp = new CompToken(address(0));
        priceFeed = new TestSwarmFeed(1 ether);
        nhiFeed = new TestSwarmFeed(0.85 ether);
        vault = new CDPVault(address(imd), address(comp), address(0), address(priceFeed), address(nhiFeed));
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.prank(OPERATOR);
        comp.setVault(address(vault));
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            vm.startPrank(OPERATOR);
            imd.mint(actor, INITIAL_BALANCE);
            oracle.grantRights(actor, INITIAL_RIGHTS);
            vm.stopPrank();
            vm.startPrank(actor);
            imd.approve(address(vault), type(uint256).max);
            vault.depositCollateral(150 ether);
            vault.mintCOMP(100 ether);
            // Both supply channels start nonzero, so the retired invariant fails immediately.
            vault.mintFromWork(25 ether);
            vm.stopPrank();
            deposited[actor] = 150 ether;
            debtMinted[actor] = 100 ether;
            workMinted[actor] = 25 ether;
        }
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = _min(imd.balanceOf(actor), 1000 ether);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.depositCollateral(amount);
        deposited[actor] += amount;
    }

    function mintDebt(uint256 seed, uint256 amount) external {
        if (!_fresh()) return;
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 maximumDebt = collateral * _price() * 100 / (_minimumRatio() * 1e18);
        if (maximumDebt <= debt) return;
        amount = bound(amount, 1, _min(maximumDebt - debt, 1000 ether));
        vm.prank(actor);
        vault.mintCOMP(amount);
        debtMinted[actor] += amount;
        ++successfulDebtMints;
    }

    function mintWork(uint256 seed, uint256 amount) external {
        if (!_fresh()) return;
        address actor = actors[seed % 4];
        uint256 rights = oracle.mintingRights(actor);
        if (rights == 0) return;
        amount = bound(amount, 1, _min(rights, 1000 ether));
        vm.prank(actor);
        vault.mintFromWork(amount);
        workMinted[actor] += amount;
        ++successfulWorkMints;
    }

    function repay(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (, uint256 debt) = vault.positions(actor);
        uint256 available = _min(comp.balanceOf(actor), debt);
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
        if (debt != 0 && !_fresh()) return;
        uint256 denominator = _price() * 100;
        uint256 requiredCollateral = (debt * _minimumRatio() * 1e18 + denominator - 1) / denominator;
        if (collateral <= requiredCollateral) return;
        amount = bound(amount, 1, collateral - requiredCollateral);
        vm.prank(actor);
        vault.withdrawCollateral(amount);
        withdrawn[actor] += amount;
    }

    function donateIMD(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = _min(imd.balanceOf(actor), 1000 ether);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        imd.transfer(address(vault), amount);
        donations[actor] += amount;
        donated += amount;
    }

    function transferCOMP(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address actor = actors[fromSeed % 4];
        amount = bound(amount, 0, comp.balanceOf(actor));
        vm.prank(actor);
        comp.transfer(actors[toSeed % 4], amount);
    }

    function setMarket(uint256 priceSeed, uint256 nhi) external {
        // Include unit price frequently, with price-only and NHI-only shocks both reachable.
        uint256[3] memory prices = [uint256(0.8 ether), uint256(1 ether), uint256(1.2 ether)];
        priceFeed.setValue(prices[priceSeed % 3]);
        nhiFeed.setValue(bound(nhi, 0.5 ether, 0.95 ether));
    }

    function setStale(bool priceStale, bool nhiStale) external {
        priceFeed.setStale(priceStale);
        nhiFeed.setStale(nhiStale);
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 12 hours));
    }

    function markOrClear(uint256 seed) external {
        address actor = actors[seed % 4];
        if (!_fresh()) {
            vm.expectRevert(CDPVault.StaleFeed.selector);
            vault.markUnderwater(actor);
            return;
        }
        (uint256 timestamp, uint256 grace, bool marked) = vault.liquidationMarks(actor);
        if (_healthy(actor)) {
            if (marked) {
                vault.clearRecoveredMark(actor);
                ++successfulRecoveries;
            } else {
                vm.expectRevert(CDPVault.HealthyPosition.selector);
                vault.markUnderwater(actor);
            }
            return;
        }
        vault.markUnderwater(actor);
        (uint256 actualTimestamp, uint256 actualGrace, bool actualMarked) = vault.liquidationMarks(actor);
        assertTrue(actualMarked);
        if (marked) {
            assertEq(actualTimestamp, timestamp, "repeat marking preserves timestamp");
            assertEq(actualGrace, grace, "repeat marking preserves grace");
        } else {
            markedAt[actor] = block.timestamp;
            (uint256 nhi,) = nhiFeed.latestValue();
            graceSnapshot[actor] =
                nhi >= 0.85 ether ? 6 hours : nhi <= 0.6 ether ? 0 : (nhi - 0.6 ether) * 6 hours / 0.25 ether;
            ++successfulMarks;
        }
    }

    function liquidate(uint256 ownerSeed, uint256 callerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address caller = actors[callerSeed % 4];
        if (!_fresh() || _healthy(owner)) return;
        (uint256 timestamp, uint256 grace, bool marked) = vault.liquidationMarks(owner);
        if (!marked || block.timestamp < timestamp + grace) return;
        (uint256 collateral, uint256 debt) = vault.positions(owner);
        // At every generated price, half the collateral bounds an affordable repayment.
        uint256 available = _min(_min(debt, comp.balanceOf(caller)), collateral / 2);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        _executeLiquidation(owner, caller, amount);
    }

    function _executeLiquidation(address owner, address caller, uint256 amount) private {
        (uint256 collateral, uint256 debt) = vault.positions(owner);
        uint256 beforeIMD = imd.balanceOf(caller);
        uint256 beforeCOMP = comp.balanceOf(caller);
        vm.prank(caller);
        vault.liquidate(owner, amount);
        (uint256 remainingCollateral, uint256 remainingDebt) = vault.positions(owner);
        uint256 received = imd.balanceOf(caller) - beforeIMD;
        assertEq(comp.balanceOf(caller), beforeCOMP - amount, "liquidator pays its own COMP");
        assertEq(remainingDebt, debt - amount, "liquidation retires debt");
        assertEq(collateral - remainingCollateral, received, "seized collateral reaches liquidator");
        // Non-unit payout policy is reported separately; conservation is independent of that policy.
        if (_price() == 1 ether) assertEq(received, amount * 110 / 100, "exact liquidation bonus");
        debtLiquidated[owner] += amount;
        collateralSeized[owner] += received;
        collateralReceived[caller] += received;
        ++successfulLiquidations;
    }

    function attemptUnsafeMint(uint256 seed) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 maximumDebt = collateral * _price() * 100 / (_minimumRatio() * 1e18);
        uint256 amount = maximumDebt >= debt ? maximumDebt - debt + 1 : 1;
        bytes4 reason = _fresh() ? CDPVault.UnsafeCollateralRatio.selector : CDPVault.StaleFeed.selector;
        vm.prank(actor);
        vm.expectRevert(reason);
        vault.mintCOMP(amount);
    }

    function attemptUnsafeWithdrawal(uint256 seed) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        if (debt == 0 || collateral == 0) return;
        uint256 denominator = _price() * 100;
        uint256 requiredCollateral = (debt * _minimumRatio() * 1e18 + denominator - 1) / denominator;
        uint256 amount = collateral >= requiredCollateral ? collateral - requiredCollateral + 1 : 1;
        bytes4 reason = _fresh() ? CDPVault.UnsafeCollateralRatio.selector : CDPVault.StaleFeed.selector;
        vm.prank(actor);
        vm.expectRevert(reason);
        vault.withdrawCollateral(amount);
    }

    function attemptExcessRepayment(uint256 seed) external {
        address actor = actors[seed % 4];
        (, uint256 debt) = vault.positions(actor);
        vm.prank(actor);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(debt + 1);
    }

    function attemptInsufficientWork(uint256 seed) external {
        address actor = actors[seed % 4];
        uint256 amount = oracle.mintingRights(actor) + 1;
        bytes4 reason = _fresh() ? CDPVault.InsufficientRights.selector : CDPVault.StaleFeed.selector;
        vm.prank(actor);
        vm.expectRevert(reason);
        vault.mintFromWork(amount);
    }

    function attemptPrematureLiquidation(uint256 ownerSeed, uint256 callerSeed) external {
        address owner = actors[ownerSeed % 4];
        bytes4 expected;
        if (!_fresh()) {
            expected = CDPVault.StaleFeed.selector;
        } else if (_healthy(owner)) {
            expected = CDPVault.HealthyPosition.selector;
        } else {
            (uint256 timestamp, uint256 grace, bool marked) = vault.liquidationMarks(owner);
            if (!marked) expected = CDPVault.PositionNotMarked.selector;
            else if (block.timestamp < timestamp + grace) expected = CDPVault.GracePeriodNotElapsed.selector;
            else return;
        }
        vm.prank(actors[callerSeed % 4]);
        vm.expectRevert(expected);
        vault.liquidate(owner, 1);
    }

    function _fresh() private view returns (bool) {
        return !priceFeed.isStale() && !nhiFeed.isStale();
    }

    function _price() private view returns (uint256 price) {
        (price,) = priceFeed.latestValue();
    }

    function _minimumRatio() private view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        if (nhi >= 0.85 ether) return 150;
        if (nhi <= 0.6 ether) return 200;
        return 150 + (0.85 ether - nhi) * 50 / 0.25 ether;
    }

    function _healthy(address actor) private view returns (bool) {
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        return debt == 0 || collateral * _price() * 100 >= debt * 1e18 * _minimumRatio();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ProtocolInvariantTest is StdInvariant, Test {
    ProtocolHandler internal handler;

    function setUp() public {
        handler = new ProtocolHandler();
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mintDebt.selector;
        selectors[2] = handler.mintWork.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.transferCOMP.selector;
        selectors[6] = handler.attemptUnsafeMint.selector;
        selectors[7] = handler.attemptPrematureLiquidation.selector;
        selectors[8] = handler.attemptUnsafeWithdrawal.selector;
        selectors[9] = handler.attemptExcessRepayment.selector;
        selectors[10] = handler.donateIMD.selector;
        selectors[11] = handler.setMarket.selector;
        selectors[12] = handler.setStale.selector;
        selectors[13] = handler.advanceTime.selector;
        selectors[14] = handler.markOrClear.selector;
        selectors[15] = handler.liquidate.selector;
        selectors[16] = handler.attemptInsufficientWork.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyEqualsDebtPlusWorkAndCollateralIsConserved() public view {
        uint256 debts;
        uint256 work;
        uint256 collateral;
        uint256 walletCOMP;
        uint256 walletIMD;
        CDPVault vault = handler.vault();
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 c, uint256 d) = vault.positions(actor);
            debts += d;
            work += handler.workMinted(actor);
            collateral += c;
            walletCOMP += handler.comp().balanceOf(actor);
            walletIMD += handler.imd().balanceOf(actor);
            assertEq(
                c,
                handler.deposited(actor) - handler.withdrawn(actor) - handler.collateralSeized(actor),
                "collateral history"
            );
            assertEq(
                d, handler.debtMinted(actor) - handler.repaid(actor) - handler.debtLiquidated(actor), "debt history"
            );
            assertEq(
                handler.oracle().mintingRights(actor) + handler.workMinted(actor),
                handler.INITIAL_RIGHTS(),
                "only work consumes rights"
            );
            assertEq(
                handler.imd().balanceOf(actor),
                handler.INITIAL_BALANCE() + handler.withdrawn(actor) + handler.collateralReceived(actor)
                    - handler.deposited(actor) - handler.donations(actor),
                "wallet collateral history"
            );
            (uint256 timestamp, uint256 grace, bool marked) = vault.liquidationMarks(actor);
            if (marked) {
                assertEq(timestamp, handler.markedAt(actor), "mark timestamp snapshot");
                assertEq(grace, handler.graceSnapshot(actor), "NHI cannot change in-flight grace");
            } else {
                assertEq(timestamp, 0, "cleared mark timestamp");
                assertEq(grace, 0, "cleared grace snapshot");
            }
        }
        assertEq(vault.totalWorkMinted(), work, "work history");
        assertEq(handler.comp().totalSupply(), debts + vault.totalWorkMinted(), "supply equals debt plus work");
        assertEq(walletCOMP, handler.comp().totalSupply(), "all COMP accounted for");
        assertEq(handler.imd().balanceOf(address(vault)), collateral + handler.donated(), "vault custody");
        assertEq(
            walletIMD + collateral + handler.donated(), handler.imd().totalSupply(), "all collateral accounted for"
        );
    }

    /// @dev Redistribute existing COMP and close debt, even after market shocks or while feeds are stale.
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
        assertEq(comp.totalSupply(), handler.vault().totalWorkMinted(), "closing debt preserves work supply");
        assertEq(comp.balanceOf(collector), handler.vault().totalWorkMinted(), "work tokens remain spendable");
        assertEq(handler.imd().balanceOf(address(handler.vault())), handler.donated());
        invariant_supplyEqualsDebtPlusWorkAndCollateralIsConserved();
    }

    function test_handlerExercisesBothMintsLiquidationRecoveryAndExit() public {
        handler.deposit(0, 30 ether);
        handler.mintDebt(0, 10 ether);
        handler.mintWork(0, 10 ether);
        handler.transferCOMP(0, 1, 10 ether);
        handler.repay(1, 5 ether);
        handler.withdraw(1, 1 ether);
        handler.donateIMD(2, 7 ether);
        handler.attemptUnsafeMint(0);
        handler.attemptUnsafeWithdrawal(0);
        handler.attemptExcessRepayment(0);
        handler.attemptInsufficientWork(0);
        handler.attemptPrematureLiquidation(0, 1);
        // Constant price, NHI-only mark, followed by a mid-window NHI decline.
        handler.setMarket(1, 0.8 ether);
        handler.markOrClear(2);
        handler.attemptPrematureLiquidation(2, 1);
        handler.advanceTime(1 hours);
        handler.setMarket(1, 0.6 ether);
        handler.markOrClear(2);
        handler.attemptPrematureLiquidation(2, 1);
        handler.advanceTime(5 hours);
        handler.liquidate(2, 1, 10 ether);
        // Recovery through a later feed update is explicitly observed by the keeper action.
        handler.markOrClear(3);
        handler.setMarket(2, 0.85 ether);
        handler.markOrClear(3);
        handler.setStale(true, false);
        handler.attemptUnsafeMint(0);
        handler.attemptInsufficientWork(0);
        handler.attemptPrematureLiquidation(2, 1);
        assertEq(handler.successfulDebtMints(), 1);
        assertEq(handler.successfulWorkMints(), 1);
        assertEq(handler.successfulRepayments(), 1);
        assertEq(handler.successfulLiquidations(), 1, "successful liquidation is reachable");
        assertEq(handler.successfulMarks(), 2);
        assertEq(handler.successfulRecoveries(), 1);
        invariant_supplyEqualsDebtPlusWorkAndCollateralIsConserved();
        afterInvariant();
    }
}
