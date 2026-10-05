// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WorkBackingFixture, ReserveTestToken} from "./helpers/WorkBackingFixture.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Treasury} from "src/Treasury.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {CDPVault} from "src/CDPVault.sol";
import {APPROVED_OPERATOR, ETH_USD_MAX_AGE} from "src/DeploymentConfig.sol";

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
    /// @dev The Chainlink leg as the handler last set it: the 8-decimal answer and whether it was
    /// dated too old to be fresh. Governance helpers warp and re-date the leg, so they restore this.
    int256 public ethUsdAnswer = ETH_USD_ANSWER;
    bool public ethUsdStale;

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

    /// @dev USD per reserve token, anywhere from worthless to four times the fixture's one-ETH price.
    function setReserveMarket(uint96 rawPrice, bool stale) external {
        reservePrice.setValue(bound(rawPrice, 0, 4 * ASSET_USD));
        reservePrice.setStale(stale);
    }

    function setEthUsd(uint64 rawAnswer, bool stale) external {
        ethUsdAnswer = int256(bound(rawAnswer, 100e8, 10_000e8));
        ethUsdStale = stale;
        _restoreEthUsd();
    }

    function governRatio(uint16 raw) external {
        _setRatio(bound(raw, 0, 2500));
        _restoreEthUsd();
    }

    function governReserveHaircut(uint16 raw) external {
        uint256 factor = bound(raw, 0, 10_000);
        _register(asset, reservePrice, factor);
        reserveHaircutBps = factor;
        _restoreEthUsd();
    }

    function _restoreEthUsd() private {
        uint256 at = vm.getBlockTimestamp();
        usd.set(ethUsdAnswer, ethUsdStale ? at - ETH_USD_MAX_AGE - 1 : at);
    }

    function borrow(uint256 raw) external {
        // The vault denominates in USD, so a stale ETH/USD leg halts every priced action. A halted
        // vault is modelled by taking no action, not by reverting the campaign.
        if (ethUsdStale) return;
        uint256 amount = bound(raw, 1, 1000 ether);
        // Pay for enough collateral to cover both new borrowing and all accrued obligations, PRICED.
        // The vault denominates in USD, so the ETH/USD leg this handler moves changes what a unit of
        // collateral is worth — it used to touch only the reserve term. A fixed multiple of the debt
        // was enough while one unit of collateral was one unit of account; now the top-up has to be
        // divided by the live price or a cheap ETH leaves the position under mat.
        // Rounded UP, so the top-up is never zero: with the debt repaid, a 1-wei borrow and a price
        // above two dollars per unit, the floored quotient was 0 and lock(0) reverted
        // ZeroAmount, which fail_on_revert turned into a failed campaign (reviewer finding, 2026-10-04).
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        if (price == 0) return;
        uint256 topUp = Math.mulDiv((backedVault.debtOf(BORROWER) + amount) * 2, 1e18, price, Math.Rounding.Ceil);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, topUp);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), topUp);
        backedVault.lock(topUp);
        backedVault.draw(amount);
        vm.stopPrank();
        collateralDeposited += topUp;
        debtMinted += amount;
    }

    function repay(uint256 raw) external {
        // The vault denominates in USD, so a stale ETH/USD leg halts every priced action. A halted
        // vault is modelled by taking no action, not by reverting the campaign.
        if (ethUsdStale) return;

        uint256 available = stable.balanceOf(BORROWER);
        uint256 debt = backedVault.debtOf(BORROWER);
        if (debt < available) available = debt;
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        uint256 fees = backedVault.stabilityFeeOf(BORROWER);
        uint256 paidFees = amount < fees ? amount : fees;
        vm.prank(BORROWER);
        backedVault.wipe(amount);
        feePaid += paidFees;
        principalRepaid += amount - paidFees;
    }

    function free(uint256 raw) external {
        // The vault denominates in USD, so a stale ETH/USD leg halts every priced action. A halted
        // vault is modelled by taking no action, not by reverting the campaign.
        if (ethUsdStale) return;

        (uint256 deposited, uint256 debt) = backedVault.positions(BORROWER);
        // Priced, for the same reason borrow's top-up is: the vault measures collateral in USD, so
        // what mat requires depends on the ETH/USD leg this handler moves.
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        if (price == 0) return;
        uint256 required = Math.mulDiv((debt * backedVault.mat() + 99) / 100, 1e18, price) + 1;
        if (deposited <= required) return;
        uint256 amount = bound(raw, 1, deposited - required);
        vm.prank(BORROWER);
        backedVault.free(amount);
        collateralWithdrawn += amount;
    }

    function mintWork(uint256 raw, bool overCeiling) external {
        // The vault denominates in USD, so a stale ETH/USD leg halts every priced action. A halted
        // vault is modelled by taking no action, not by reverting the campaign.
        if (ethUsdStale) return;

        uint256 ceiling = backedVault.earnLine();
        uint256 minted = backedVault.totalEarned();
        uint256 remaining = ceiling > minted ? ceiling - minted : 0;
        uint256 amount = overCeiling || remaining == 0 ? remaining + 1 : bound(raw, 1, remaining);
        uint256 rights = workOracle.mintingRights(WORKER);
        uint256 supply = stable.totalSupply();
        if (overCeiling || remaining == 0) {
            vm.prank(WORKER);
            vm.expectRevert(CDPVault.WorkCeilingReached.selector);
            backedVault.earn(amount);
            assertEq(stable.totalSupply(), supply);
            assertEq(workOracle.mintingRights(WORKER), rights);
            assertEq(backedVault.totalEarned(), minted);
            ++rejectedWorkCalls;
        } else {
            _mintWork(WORKER, amount);
            assertLe(backedVault.totalEarned(), ceiling, "successful mint respects backing at execution");
            workMinted += amount;
            ++acceptedWorkCalls;
        }
    }

    function backedVaultCeiling() external view returns (uint256) {
        return backedVault.earnLine();
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
        assertEq(reserve.reserveValueUsd(), value, "the register is a USD figure");
        uint256 ethUsd = uint256(ethUsdAnswer) * 1e10;
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), ethUsdStale ? 0 : ethUsd);
        // The register IS the ceiling's reserve term now, with no conversion, because the vault
        // denominates in USD. This assertion used to divide by ETH/USD and to zero on a stale leg;
        // both were consequences of the vault measuring in ETH while the register was in dollars.
        // A stale ETH/USD leg no longer shrinks the reserve term — it halts the vault instead, which
        // the handler asserts where it toggles staleness.
        assertEq(backedVault.reserveValue(), value, "the ceiling's reserve term is the register itself");
        uint256 principal = debtMinted - principalRepaid;
        assertEq(backedVault.totalDebt(), principal);
        assertEq(backedVault.totalBadDebt(), 0, "a borrower kept at or above mat never leaves bad debt");
        assertEq(backedVault.backedDebt(), principal, "between transactions every open position counts");
        assertEq(backedVault.earnLine(), value + principal * backedVault.earnMat() / 10_000);
        assertLe(backedVault.earnMat(), 2500);
        assertEq(backedVault.totalEarned(), workMinted);
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
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.syncReserve.selector;
        selectors[2] = handler.withdrawReserve.selector;
        selectors[3] = handler.rejectUnauthorizedWithdrawal.selector;
        selectors[4] = handler.setReserveMarket.selector;
        selectors[5] = handler.governRatio.selector;
        selectors[6] = handler.borrow.selector;
        selectors[7] = handler.repay.selector;
        selectors[8] = handler.free.selector;
        selectors[9] = handler.mintWork.selector;
        selectors[10] = handler.governReserveHaircut.selector;
        selectors[11] = handler.setEthUsd.selector;
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
        handler.setReserveMarket(uint96(2000 ether), false); // the fixture's one-ETH asset price
        handler.syncReserve();
        handler.mintWork(1 ether, false);
        handler.borrow(10 ether);
        handler.repay(5 ether);
        handler.free(1 ether);
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

    /// @dev Inverted by USD denomination, and the inversion is the point. The register is kept in
    /// dollars and the vault now measures in dollars, so the ETH price does not move the reserve term
    /// at all — it used to divide it. And an expired leg no longer shrinks the ceiling: it halts every
    /// priced action, because a position cannot be measured at a price nobody knows.
    function test_ethUsdDoesNotMoveTheCeilingAndAnExpiredLegHaltsTheVault() public {
        handler.governRatio(0);
        handler.checkAccounting();
        assertEq(handler.backedVaultCeiling(), 100 ether);

        // Twice the ETH price, same dollars of reserve, same ceiling.
        handler.setEthUsd(4000e8, false);
        handler.checkAccounting();
        assertEq(handler.backedVaultCeiling(), 100 ether, "the ETH price is not in the vault's unit any more");
        handler.mintWork(100 ether, false);
        handler.mintWork(1, true);

        // An expired leg halts every priced action rather than removing the reserve term. The ceiling
        // itself is a view over the register and keeps reading, which is why the handler models a
        // halted vault by doing nothing: its actions would all revert StaleFeed.
        handler.setEthUsd(4000e8, true);
        assertEq(handler.backedVaultCeiling(), 100 ether, "the register is unchanged by a dead leg");
        uint256 accepted = handler.acceptedWorkCalls();
        uint256 rejected = handler.rejectedWorkCalls();
        handler.mintWork(1 ether, false);
        handler.borrow(1 ether);
        assertEq(handler.acceptedWorkCalls(), accepted, "no work is minted while the vault is halted");
        assertEq(handler.rejectedWorkCalls(), rejected);
    }
}
