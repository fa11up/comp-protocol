// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {WorkBackingFixture, ReserveTestToken} from "./helpers/WorkBackingFixture.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Treasury} from "src/Treasury.sol";
import {CompToken} from "src/CompToken.sol";
import {CDPVault} from "src/CDPVault.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

contract WorkBackingHandler is WorkBackingFixture {
    uint256 public reserveDeposited;
    uint256 public reserveWithdrawn;
    uint256 public workMinted;
    uint256 public debtMinted;
    uint256 public principalRepaid;
    uint256 public feePaid;
    uint256 public collateralDeposited;
    uint256 public collateralWithdrawn;
    uint256 public acceptedWorkCalls;
    uint256 public rejectedWorkCalls;
    uint256 public reserveHaircutBps = 5000;

    constructor() {
        setUp();
        _fundReserve(100 ether);
        reserveDeposited = 200 ether;
        _openDebt(400 ether);
        debtMinted = 400 ether;
        collateralDeposited = 800 ether;
    }

    function donate(uint256 raw) external {
        uint256 amount = bound(raw, 1, 1e24);
        asset.mint(address(reserve), amount);
        reserveDeposited += amount;
    }

    function syncReserve() external {
        reserve.sync(asset);
    }

    function withdrawReserve(uint256 raw) external {
        uint256 balance = asset.balanceOf(address(reserve));
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(asset, OTHER_WORKER, amount);
        reserveWithdrawn += amount;
    }

    function rejectUnauthorizedWithdrawal(uint256 raw) external {
        uint256 amount = bound(raw, 1, 1e24);
        vm.prank(WORKER);
        vm.expectRevert(Treasury.Unauthorized.selector);
        reserve.withdraw(asset, WORKER, amount);
    }

    function setReserveMarket(uint64 rawPrice, bool stale) external {
        reservePrice.setValue(bound(rawPrice, 0, 4 ether));
        reservePrice.setStale(stale);
    }

    function governRatio(uint16 raw) external {
        _setRatio(bound(raw, 0, 2500));
    }

    function governReserveHaircut(uint16 raw) external {
        uint256 factor = bound(raw, 0, 10_000);
        _register(asset, reservePrice, factor);
        reserveHaircutBps = factor;
    }

    function borrow(uint256 raw) external {
        uint256 amount = bound(raw, 1, 1000 ether);
        // Pay for enough collateral to cover both new borrowing and all accrued obligations.
        uint256 topUp = (backedVault.debtOf(BORROWER) + amount) * 2;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, topUp);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), topUp);
        backedVault.depositCollateral(topUp);
        backedVault.mintCOMP(amount);
        vm.stopPrank();
        collateralDeposited += topUp;
        debtMinted += amount;
    }

    function repay(uint256 raw) external {
        uint256 available = stable.balanceOf(BORROWER);
        uint256 debt = backedVault.debtOf(BORROWER);
        if (debt < available) available = debt;
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        uint256 fees = backedVault.stabilityFeeOf(BORROWER);
        uint256 paidFees = amount < fees ? amount : fees;
        vm.prank(BORROWER);
        backedVault.repayCOMP(amount);
        feePaid += paidFees;
        principalRepaid += amount - paidFees;
    }

    function withdrawCollateral(uint256 raw) external {
        (uint256 deposited, uint256 debt) = backedVault.positions(BORROWER);
        uint256 required = (debt * 150 + 99) / 100;
        if (deposited <= required) return;
        uint256 amount = bound(raw, 1, deposited - required);
        vm.prank(BORROWER);
        backedVault.withdrawCollateral(amount);
        collateralWithdrawn += amount;
    }

    function mintWork(uint256 raw, bool overCeiling) external {
        uint256 ceiling = backedVault.workCeiling();
        uint256 minted = backedVault.totalWorkMinted();
        uint256 remaining = ceiling > minted ? ceiling - minted : 0;
        uint256 amount = overCeiling || remaining == 0 ? remaining + 1 : bound(raw, 1, remaining);
        uint256 rights = workOracle.mintingRights(WORKER);
        uint256 supply = stable.totalSupply();
        if (overCeiling || remaining == 0) {
            vm.prank(WORKER);
            vm.expectRevert(CDPVault.WorkCeilingReached.selector);
            backedVault.mintFromWork(amount);
            assertEq(stable.totalSupply(), supply);
            assertEq(workOracle.mintingRights(WORKER), rights);
            assertEq(backedVault.totalWorkMinted(), minted);
            ++rejectedWorkCalls;
        } else {
            _mintWork(WORKER, amount);
            assertLe(backedVault.totalWorkMinted(), ceiling, "successful mint respects backing at execution");
            workMinted += amount;
            ++acceptedWorkCalls;
        }
    }

    function checkAccounting() external view {
        uint256 reserveBalance = reserveDeposited - reserveWithdrawn;
        assertEq(asset.balanceOf(address(reserve)), reserveBalance);
        assertEq(asset.balanceOf(OTHER_WORKER), reserveWithdrawn);
        assertEq(asset.totalSupply(), reserveDeposited);
        assertEq(reserve.totalReceived(asset), reserve.lastSynced(asset) + reserveWithdrawn);
        assertLe(reserve.lastSynced(asset), reserveBalance);
        assertLe(reserve.totalReceived(asset), reserveDeposited);
        (uint256 price,) = reservePrice.latestValue();
        uint256 marked = reserveBalance * price / 1 ether;
        uint256 value = reservePrice.isStale() ? 0 : marked * reserveHaircutBps / 10_000;
        assertEq(reserve.reserveAsset(asset).haircutBps, reserveHaircutBps);
        assertEq(reserve.reserveValueUsd(), value);
        uint256 principal = debtMinted - principalRepaid;
        assertEq(backedVault.totalDebt(), principal);
        assertEq(backedVault.workCeiling(), value + principal * backedVault.workRatioBps() / 10_000);
        assertLe(backedVault.workRatioBps(), 2500);
        assertEq(backedVault.totalWorkMinted(), workMinted);
        assertEq(workOracle.mintingRights(WORKER) + workMinted, type(uint128).max);
        assertEq(stable.balanceOf(WORKER), workMinted);
        assertEq(stable.balanceOf(address(reserve)), feePaid);
        assertEq(backedVault.totalFeesMinted(), feePaid);
        assertEq(stable.totalSupply(), principal + workMinted);
        assertEq(
            stable.balanceOf(BORROWER) + stable.balanceOf(WORKER) + stable.balanceOf(address(reserve)),
            stable.totalSupply()
        );
        (uint256 deposited,) = backedVault.positions(BORROWER);
        assertEq(deposited, collateralDeposited - collateralWithdrawn);
        assertEq(collateral.balanceOf(address(backedVault)), deposited);
        assertEq(collateral.balanceOf(BORROWER), collateralWithdrawn);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract WorkBackingInvariantTest is StdInvariant, Test {
    WorkBackingHandler internal handler;

    function setUp() public {
        handler = new WorkBackingHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.syncReserve.selector;
        selectors[2] = handler.withdrawReserve.selector;
        selectors[3] = handler.rejectUnauthorizedWithdrawal.selector;
        selectors[4] = handler.setReserveMarket.selector;
        selectors[5] = handler.governRatio.selector;
        selectors[6] = handler.borrow.selector;
        selectors[7] = handler.repay.selector;
        selectors[8] = handler.withdrawCollateral.selector;
        selectors[9] = handler.mintWork.selector;
        selectors[10] = handler.governReserveHaircut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_custodySupplyReceiptsAndCeilingMatchIndependentHistories() public view {
        handler.checkAccounting();
    }

    function test_handlerReachesSuccessfulMintsAndRejectsAfterBackingContracts() public {
        handler.mintWork(100 ether, false);
        handler.mintWork(1, true);
        handler.withdrawReserve(type(uint256).max);
        handler.governRatio(0);
        handler.mintWork(1, false);
        handler.donate(400 ether);
        handler.setReserveMarket(uint64(1 ether), false);
        handler.syncReserve();
        handler.mintWork(1 ether, false);
        handler.borrow(10 ether);
        handler.repay(5 ether);
        handler.withdrawCollateral(1 ether);
        handler.rejectUnauthorizedWithdrawal(1);
        assertEq(handler.acceptedWorkCalls(), 2);
        assertEq(handler.rejectedWorkCalls(), 2);
        handler.checkAccounting();
    }

    function test_handlerHaircutEndpointsRemoveAndRestoreWorkBacking() public {
        handler.governRatio(0);
        handler.governReserveHaircut(0);
        handler.mintWork(1, false);
        handler.checkAccounting();
        assertEq(handler.reserveHaircutBps(), 0);

        handler.governReserveHaircut(10_000);
        handler.mintWork(200 ether, false);
        handler.mintWork(1, true);
        handler.checkAccounting();
        assertEq(handler.reserveHaircutBps(), 10_000);
        assertEq(handler.workMinted(), 200 ether);

        handler.governReserveHaircut(0);
        handler.mintWork(1, false);
        handler.checkAccounting();
        assertEq(handler.acceptedWorkCalls(), 1);
        assertEq(handler.rejectedWorkCalls(), 3);
    }
}
