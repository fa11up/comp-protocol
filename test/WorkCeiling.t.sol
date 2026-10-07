// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OpenWorkVault} from "./helpers/OpenWorkVault.sol";
import {Treasury} from "src/Treasury.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {Parameters} from "src/Parameters.sol";
import {Governed} from "src/Governed.sol";
import {APPROVED_OPERATOR, ETH_USD_MAX_AGE} from "src/DeploymentConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A rights holder that borrows and mints work inside ONE transaction. Every top-level call a
/// test makes is its own transaction (forge isolates them), so the only way to reach the vault's
/// transient same-transaction debt cap is from a contract that chains the calls itself.
contract AtomicWorkBorrower {
    ParameterizedVault private immutable vault;

    constructor(ParameterizedVault vault_) {
        vault = vault_;
        vault_.gem().approve(address(vault_), type(uint256).max);
    }

    function borrowThenMintWork(uint256 collateral, uint256 debt, uint256 work) external {
        vault.lock(collateral);
        vault.draw(debt);
        vault.earn(work);
    }

    function borrowMintWorkRepayAndLeave(uint256 collateral, uint256 debt, uint256 work) external {
        vault.lock(collateral);
        vault.draw(debt);
        vault.earn(work);
        vault.wipe(debt);
        vault.free(collateral);
    }

    function borrowThenRead(uint256 collateral, uint256 debt) external returns (uint256 backed, uint256 ceiling) {
        vault.lock(collateral);
        vault.draw(debt);
        return (vault.backedDebt(), vault.earnLine());
    }

    function repayThenMintWork(uint256 repay, uint256 work) external {
        vault.wipe(repay);
        vault.earn(work);
    }

    function open(uint256 collateral, uint256 debt) external {
        vault.lock(collateral);
        vault.draw(debt);
    }
}

contract WorkCeilingTest is WorkBackingFixture {
    function test_emptyReserveAndNoDebtRefusesEvenOneWeiAndPreservesRights() public {
        assertEq(reserve.reserveValueUsd(), 0);
        assertEq(backedVault.reserveValue(), 0);
        assertEq(backedVault.totalDebt(), 0);
        assertEq(backedVault.backedDebt(), 0);
        assertEq(backedVault.earnLine(), 0);
        _assertRejected(WORKER, 1);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max);
        assertEq(stable.totalSupply(), 0);
    }

    function test_ceilingAddsBothTermsAndAllowsLastWeiButRefusesFirstWeiPast() public {
        _fundReserve(71 ether + 1);
        _openDebt(100 ether + 3);
        uint256 ceiling = 96 ether + 1;
        assertEq(reserve.reserveValueUsd(), 71 ether + 1, "register is kept in USD, which is the vault's unit");
        assertEq(backedVault.reserveValue(), 71 ether + 1, "reserve term is the register, unconverted");
        assertEq(backedVault.backedDebt(), 100 ether + 3, "a position held across transactions counts in full");
        assertEq(backedVault.earnLine(), ceiling, "sum, with ratio rounded down");
        _assertRejected(WORKER, ceiling + 1);
        _mintWork(WORKER, ceiling - 1);
        assertEq(backedVault.totalEarned(), ceiling - 1);
        _assertRejected(OTHER_WORKER, 2);
        _mintWork(OTHER_WORKER, 1);
        assertEq(backedVault.totalEarned(), ceiling);
        _assertRejected(WORKER, 1);
        assertEq(stable.totalSupply(), backedVault.totalDebt() + ceiling);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - ceiling + 1);
        assertEq(workOracle.mintingRights(OTHER_WORKER), type(uint128).max - 1);
    }

    function test_largeDebtRatioUsesFullPrecisionMultiplication() public {
        // About full-precision arithmetic at sizes far above the $1M launch ceiling, not about the
        // ceiling: lift it through governance first.
        _raiseLine(type(uint256).max);
        uint256 debt = uint256(1) << 250;
        _openDebt(debt);
        uint256 ceiling = debt / 4;
        assertEq(backedVault.earnLine(), ceiling);
        vm.prank(APPROVED_OPERATOR);
        workOracle.grantRights(WORKER, ceiling);
        _mintWork(WORKER, ceiling);
        _assertRejected(WORKER, 1);
        assertEq(stable.totalSupply(), debt + ceiling);
    }

    function test_reserveAloneSupportsWorkAndDoesNotCreateWorkerDebt() public {
        _fundReserve(10 ether);
        _mintWork(WORKER, 10 ether);
        _assertRejected(WORKER, 1);
        assertEq(backedVault.totalDebt(), 0);
        (uint256 c, uint256 d) = backedVault.positions(WORKER);
        assertEq(c, 0);
        assertEq(d, 0);
        assertEq(stable.balanceOf(WORKER), 10 ether);
    }

    function test_debtDustIsRoundedDownBeforeAddingReserve() public {
        _fundReserve(1);
        _openDebt(3);
        assertEq(backedVault.earnLine(), 1);
        _mintWork(WORKER, 1);
        _assertRejected(WORKER, 1);
        // One more unit of collateral first: 6 against 4 would be 150%, under the 170% floor.
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, 1);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), 1);
        backedVault.lock(1);
        backedVault.draw(1);
        vm.stopPrank();
        assertEq(backedVault.earnLine(), 2);
        _mintWork(OTHER_WORKER, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ceilingArithmeticAndAtomicBoundary(uint96 rawDebt, uint96 rawReserve, uint16 rawRatio) public {
        // About full-precision arithmetic at sizes far above the $1M launch ceiling, not about the
        // ceiling: lift it through governance first.
        _raiseLine(type(uint256).max);
        uint256 debt = bound(rawDebt, 1, 1e28);
        uint256 value = bound(rawReserve, 0, 1e28);
        uint256 ratio = bound(rawRatio, 0, 2500);
        _setRatio(ratio);
        _fundReserve(value);
        _openDebt(debt);
        uint256 expected = value + debt * ratio / 10_000;
        assertEq(backedVault.earnLine(), expected);
        _assertRejected(WORKER, expected + 1);
        if (expected != 0) _mintWork(WORKER, expected);
        _assertRejected(OTHER_WORKER, 1);
        assertEq(stable.totalSupply(), debt + expected);
    }

    /// @dev D > 0 is essential: when D = 0, reserve-only backing is exactly one; 0/0 is undefined.
    /// Compare cross-products instead of a rounded fixed-point ratio, which can hide a tiny surplus.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_worstCaseBackingExceedsOneForEveryReserveSize(
        uint128 rawDebt,
        uint128 rawReserve,
        uint16 rawRatio,
        uint64 rawNhi
    ) public {
        // About full-precision arithmetic at sizes far above the $1M launch ceiling, not about the
        // ceiling: lift it through governance first.
        _raiseLine(type(uint256).max);
        uint256 debt = bound(rawDebt, 1, type(uint128).max);
        uint256 value = rawReserve;
        uint256 ratio = bound(rawRatio, 0, 2500);
        _setRatio(ratio);
        health.setValue(bound(rawNhi, 0.5 ether, 0.95 ether));
        uint256 mat = backedVault.mat();
        assertGe(mat, 170);
        // Exact rational worst-case C = mat * D / 100, W = R + rD (before rounding).
        uint256 backingScaled = mat * debt * 100 + value * 10_000;
        uint256 liabilitiesScaled = debt * 10_000 + value * 10_000 + debt * backedVault.earnMat();
        assertGt(backingScaled, liabilitiesScaled);
        // Tight at the 170 floor and the 2500 ratio cap: 17000 - 10000 - 2500.
        assertGe(backingScaled - liabilitiesScaled, debt * 4500);
        // The reserve cancels, proving the bound also for R beyond the fuzz range.
        assertEq(backingScaled - liabilitiesScaled, (mat * 100 - 10_000 - ratio) * debt);
    }

    function test_bindingMinimumRatioGives136PercentAtEmptyReserveAnd7000IsTheCliff() public view {
        uint256 debt = 100 ether;
        uint256 assets = backedVault.mat() * debt / 100;
        assertEq(backedVault.earnMat(), 2500);
        assertEq(assets * 10_000 / (debt + debt * backedVault.earnMat() / 10_000), 13_600);
        for (uint256 i; i < 5; ++i) {
            uint256[5] memory reserves = [uint256(0), 1, 50 ether, 200 ether, uint256(type(uint128).max)];
            uint256 r = reserves[i];
            assertGt(assets + r, debt + r + debt / 4);
            // The cliff is mat - 100: at a 170 floor that is 7000 bps.
            assertEq(assets + r, debt + r + debt * 7 / 10, "7000 bps has no surplus for any R");
        }
    }

    function test_ratioHardCapDelayAndPermissionlessApplication() public {
        assertEq(parameters.MAX_EARN_MAT_BPS(), 2500);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeEarnMat(1);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.EarnMatTooHigh.selector, 2501));
        parameters.proposeEarnMat(2501);
        assertEq(parameters.pendingEta(), 0);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeEarnMat(0);
        uint256 eta = parameters.pendingEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        assertEq(backedVault.earnMat(), 2500);
        _apply();
        assertEq(backedVault.earnMat(), 0);
        _openDebt(100 ether);
        assertEq(backedVault.earnLine(), 0);
        _assertRejected(WORKER, 1);
        _setRatio(2500);
        _mintWork(WORKER, 25 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ratioAboveHardCapCannotBeQueued(uint256 rawRatio) public {
        uint256 ratio = bound(rawRatio, 2501, type(uint256).max);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.EarnMatTooHigh.selector, ratio));
        parameters.proposeEarnMat(ratio);
        assertEq(parameters.pendingEta(), 0);
    }

    function test_repaymentTightensCeilingAndDoesNotRestoreWorkRights() public {
        _openDebt(100 ether);
        _mintWork(WORKER, 25 ether);
        vm.prank(BORROWER);
        backedVault.wipe(100 ether);
        assertEq(backedVault.earnLine(), 0);
        assertEq(backedVault.totalEarned(), 25 ether);
        _assertRejected(WORKER, 1);
        _openDebt(104 ether);
        _mintWork(WORKER, 1 ether);
        assertEq(workOracle.mintingRights(WORKER), type(uint128).max - 26 ether);
    }

    function test_accruedUnpaidFeesDoNotIncreaseRatioHeadroom() public {
        _openDebt(100 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertGt(backedVault.stabilityFeeOf(BORROWER), 0);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.earnLine(), 25 ether);
    }

    function test_withdrawalAndRatioReductionBlockFurtherWorkWithoutBurningExistingSupply() public {
        _fundReserve(20 ether);
        _openDebt(100 ether);
        _mintWork(WORKER, 45 ether);
        // The operator can no longer take a listed reserve asset out: removing backing needs a
        // delisting through governance, visible for 48 hours.
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ReserveProtected.selector, asset));
        reserve.withdraw(asset, address(0xBEEF), 2 ether);
        // The reserve shrinks the same 5% through its market instead: 40 tokens at 95% of the price
        // are worth what 38 were, so the ceiling falls exactly as the withdrawal used to make it.
        (uint256 assetPrice,) = reservePrice.latestValue();
        reservePrice.setValue(assetPrice * 95 / 100);
        assertEq(backedVault.earnLine(), 44 ether);
        _assertRejected(OTHER_WORKER, 1);
        _setRatio(0);
        assertEq(backedVault.earnLine(), 19 ether);
        _assertRejected(WORKER, 1);
        assertEq(stable.balanceOf(WORKER), 45 ether);
    }

    // --- the reserve term is converted into the vault's unit, never added as USD -----------------

    /// @dev The mirror of what finding 9366455 caught. The register is kept in dollars, and the vault
    /// now measures in dollars, so the reserve term IS the register and the ETH price does not touch
    /// it. The finding was that a USD figure was being added to an ETH-denominated debt term
    /// unconverted, authorising ETH/USD times too much work; the protection was never the division
    /// itself but that both terms share a unit. Reintroducing a conversion would make the ceiling move
    /// with ETH again, which is what this now refuses.
    function test_theEthPriceDoesNotMoveTheReserveTerm() public {
        _fundReserve(10 ether);
        assertEq(reserve.reserveValueUsd(), 10 ether);
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), ETH_USD);
        assertEq(backedVault.reserveValue(), 10 ether);
        assertEq(backedVault.earnLine(), 10 ether);
        _assertRejected(WORKER, 10 ether + 1);

        // Twice the ETH price. The same dollars of reserve back the same dollars of work.
        usd.set(4000e8, vm.getBlockTimestamp());
        assertEq(reserve.reserveValueUsd(), 10 ether);
        assertEq(backedVault.reserveValue(), 10 ether, "a conversion here would halve it");
        assertEq(backedVault.earnLine(), 10 ether);

        // And half the ETH price does not double it either.
        usd.set(1000e8, vm.getBlockTimestamp());
        assertEq(backedVault.reserveValue(), 10 ether, "a conversion here would double it");
        _mintWork(WORKER, 10 ether);
        _assertRejected(OTHER_WORKER, 1);
        assertEq(backedVault.totalEarned(), 10 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reserveValueIsTheRegisterWhateverTheEthUsdLegSays(uint96 rawBalance, uint64 rawAnswer) public {
        uint256 balance = rawBalance;
        uint256 answer = bound(rawAnswer, 1, 1e13);
        _register(asset, reservePrice, 5000);
        asset.mint(address(reserve), balance);
        usd.set(int256(answer), vm.getBlockTimestamp());
        uint256 usdValue = balance / 2; // ASSET_USD is $1 a token and the haircut is half of it
        uint256 ethUsd = answer * 1e10;
        uint256 expected = usdValue; // the register IS the reserve term; the ETH/USD leg does not convert it
        assertEq(reserve.reserveValueUsd(), usdValue);
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), ethUsd);
        assertEq(backedVault.reserveValue(), expected);
        assertEq(backedVault.earnLine(), expected);
        assertEq(reserve.reserveValueUsd(), expected, "no conversion: the register and the vault share a unit");
    }

    /// @dev Also inverted. A stale ETH/USD leg used to remove the reserve term and leave the debt
    /// term, because that leg was what converted the register. Now it converts nothing, so the ceiling
    /// is untouched — and instead the vault refuses to act at all, because it denominates in a price
    /// it can no longer read. Halting is the right answer to not knowing a price; it is also a real
    /// dependency, which is why it is pinned here.
    function test_aStaleEthUsdLegHaltsTheVaultAndLeavesTheCeilingAlone() public {
        _fundReserve(10 ether);
        _openDebt(100 ether);
        assertEq(backedVault.earnLine(), 35 ether);

        vm.warp(vm.getBlockTimestamp() + ETH_USD_MAX_AGE + 1);
        assertFalse(reservePrice.isStale(), "the asset's own USD source is still fresh");
        assertEq(reserve.reserveValueUsd(), 10 ether, "the register still values the asset in USD");
        assertEq(backedVault.usdPriceFeed().ethUsdPrice(), 0, "the leg the vault prices through is stale");
        assertEq(backedVault.reserveValue(), 10 ether, "which no longer converts anything");
        assertEq(backedVault.earnLine(), 35 ether, "so both terms survive");

        // What does not survive is the ability to act on any of it.
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        backedVault.earn(1);

        _refreshEthUsd();
        assertEq(backedVault.earnLine(), 35 ether);
        _mintWork(WORKER, 35 ether);
        _assertRejected(WORKER, 1);
    }

    // --- the ratio term counts only debt that pre-dates the transaction and has collateral ---------

    function test_debtOpenedInTheSameTransactionBacksNoWork() public {
        AtomicWorkBorrower atomic = new AtomicWorkBorrower(backedVault);
        vm.startPrank(APPROVED_OPERATOR);
        workOracle.grantRights(address(atomic), type(uint128).max);
        collateral.mint(address(atomic), 10_000 ether);
        vm.stopPrank();

        // Empty balance sheet: the quarter of a fresh 100 of debt is zero inside its own transaction.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        atomic.borrowThenMintWork(200 ether, 100 ether, 1);
        assertEq(backedVault.totalDebt(), 0, "the whole bundle rolled back");
        assertEq(stable.totalSupply(), 0);
        assertEq(workOracle.mintingRights(address(atomic)), type(uint128).max);

        // The full round trip the finding describes: borrow, mint work, repay, withdraw, in one call.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        atomic.borrowMintWorkRepayAndLeave(200 ether, 100 ether, 1);
        assertEq(backedVault.totalEarned(), 0);

        // Inside the transaction the vault reports the cap; the next transaction sees the full debt.
        (uint256 backed, uint256 ceiling) = atomic.borrowThenRead(200 ether, 100 ether);
        assertEq(backed, 0);
        assertEq(ceiling, 0);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.backedDebt(), 100 ether, "held across a transaction boundary it counts in full");
        assertEq(backedVault.earnLine(), 25 ether);

        // With 100 of pre-existing debt, a further 400 opened in the same call still backs nothing
        // beyond the 25 the pre-existing position already backed.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        atomic.borrowThenMintWork(800 ether, 400 ether, 25 ether + 1);
        atomic.borrowThenMintWork(800 ether, 400 ether, 25 ether);
        assertEq(backedVault.totalDebt(), 500 ether);
        assertEq(backedVault.totalEarned(), 25 ether);
        assertEq(backedVault.earnLine(), 125 ether, "and the slow path counts it all next transaction");
    }

    function test_repaymentInTheSameTransactionTightensTheRatioTermAtOnce() public {
        AtomicWorkBorrower atomic = new AtomicWorkBorrower(backedVault);
        vm.startPrank(APPROVED_OPERATOR);
        workOracle.grantRights(address(atomic), type(uint128).max);
        collateral.mint(address(atomic), 400 ether);
        vm.stopPrank();
        atomic.open(400 ether, 200 ether);
        assertEq(backedVault.earnLine(), 50 ether);
        // The cap is the level the transaction began at, but the live total is lower after the
        // repayment, and the smaller of the two is what counts.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        atomic.repayThenMintWork(100 ether, 25 ether + 1);
        atomic.repayThenMintWork(100 ether, 25 ether);
        assertEq(backedVault.totalDebt(), 100 ether);
        assertEq(backedVault.totalEarned(), 25 ether);
        _assertRejected(WORKER, 1);
    }

    function test_drainedPositionResidualPrincipalIsNotBacking() public {
        health.setValue(0.6 ether); // mat 200, zero grace
        _openDebt(100 ether);
        vm.prank(BORROWER);
        stable.transfer(WORKER, 91 ether);
        assertEq(backedVault.earnLine(), 25 ether);
        _setVaultPrice(0.5 ether);
        vm.prank(OTHER_WORKER);
        backedVault.bark(BORROWER);
        // The largest debt whose 120% payout at 0.5 fits the 200 of collateral. It leaves 1 wei, which
        // no further liquidation could seize, so the sweep folds it in: the position drains to zero
        // collateral and the residual principal is recorded as bad debt.
        uint256 repaid = 83_333_333_333_333_333_333;
        vm.prank(WORKER);
        backedVault.bite(BORROWER, repaid);
        (uint256 c, uint256 d) = backedVault.positions(BORROWER);
        assertEq(c, 0);
        assertEq(d, 100 ether - repaid);
        assertEq(backedVault.totalDebt(), 100 ether - repaid);
        assertEq(backedVault.totalBadDebt(), 100 ether - repaid);
        assertEq(backedVault.backedDebt(), 0, "principal with no collateral behind it backs nothing");
        assertEq(backedVault.earnLine(), 0);
        _assertRejected(WORKER, 1);

        // Fees accrue on the drained residual, and a repayment re-records it as accrued debt, which
        // now exceeds the principal that totalDebt counts. The subtraction saturates instead of
        // reverting the ceiling.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        // A year leaves the ETH/USD leg stale, which halts a vault denominated in USD. This test is
        // about the ceiling's treatment of drained principal, not about staleness.
        _refreshEthUsd();
        vm.prank(BORROWER);
        backedVault.wipe(1);
        assertGt(backedVault.totalBadDebt(), backedVault.totalDebt());
        assertEq(backedVault.backedDebt(), 0);
        assertEq(backedVault.earnLine(), 0);
        _assertRejected(WORKER, 1);

        // A healthy position opened afterwards is counted, less the over-count by unpaid fees, which
        // only ever tightens.
        address second = address(0xB2);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(second, 200 ether);
        vm.startPrank(second);
        collateral.approve(address(backedVault), 200 ether);
        backedVault.lock(200 ether);
        backedVault.draw(40 ether);
        vm.stopPrank();
        uint256 overcount = backedVault.totalBadDebt() - (100 ether - repaid);
        assertGt(overcount, 0, "the record carries the drained position's unpaid fees");
        assertEq(backedVault.totalDebt(), 40 ether + 100 ether - repaid);
        assertEq(backedVault.backedDebt(), 40 ether - overcount);
        assertLt(backedVault.backedDebt(), 40 ether);
        assertEq(backedVault.earnLine(), (40 ether - overcount) / 4);
        _assertRejected(WORKER, (40 ether - overcount) / 4 + 1);
        _mintWork(WORKER, (40 ether - overcount) / 4);
    }

    // --- a finite ceiling is price-dependent, so spot must agree with the primary ----------------

    function test_divergentOrStaleSpotRefusesWorkAgainstFiniteCeiling() public {
        (uint256 primaryValue,) = primary.latestValue();
        TestSwarmFeed spot = new TestSwarmFeed(primaryValue);
        ParameterizedVault vaultWithSpot = new OpenWorkVault(
            address(collateral), address(0), address(0), address(primary), address(health), address(spot)
        );
        MockWorkOracle rights = MockWorkOracle(address(vaultWithSpot.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        rights.grantRights(WORKER, type(uint128).max);
        collateral.mint(BORROWER, 200 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        collateral.approve(address(vaultWithSpot), 200 ether);
        vaultWithSpot.lock(200 ether);
        vaultWithSpot.draw(100 ether);
        vm.stopPrank();
        assertEq(vaultWithSpot.earnLine(), 25 ether);

        // Scaled off the feed's own figure, not a hardcoded 1e18: the primary quotes IMD in wei of
        // ETH, so the band is a fraction of THAT, whatever the vault then denominates in.
        uint256 tolerance = primaryValue * vaultWithSpot.skew() / 10_000;
        spot.setValue(primaryValue + tolerance + 1);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vaultWithSpot.earn(1);
        spot.setValue(primaryValue - tolerance - 1);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vaultWithSpot.earn(1);
        spot.setValue(primaryValue);
        spot.setStale(true);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vaultWithSpot.earn(1);
        assertEq(vaultWithSpot.totalEarned(), 0);
        assertEq(rights.mintingRights(WORKER), type(uint128).max);

        spot.setStale(false);
        spot.setValue(primaryValue + tolerance);
        vm.prank(WORKER);
        vaultWithSpot.earn(25 ether);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vaultWithSpot.earn(1);
        assertEq(vaultWithSpot.totalEarned(), 25 ether);
    }

    // --- the derivation, checked against the deployed vault rather than on paper -----------------

    /// @dev Worst case: the only position sits exactly at mat, the reserve is any size, and the
    /// whole ceiling is minted. Assets (collateral priced by the primary, plus the reserve in the
    /// same unit) must still exceed liabilities (all COMP) by at least (mat - 1 - r) x D.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_worstCaseBackingExceedsOneOnChain(
        uint96 rawDebt,
        uint96 rawReserve,
        uint16 rawRatio,
        uint64 rawNhi
    ) public {
        // About solvency arithmetic at sizes far above the $1M launch ceiling, not about the ceiling:
        // lift it through governance first.
        _raiseLine(type(uint256).max);
        uint256 debt = bound(rawDebt, 1e6, 1e28);
        uint256 reserveUnits = bound(rawReserve, 0, 1e28);
        uint256 ratio = bound(rawRatio, 0, 2500);
        health.setValue(bound(rawNhi, 0.5 ether, 0.95 ether));
        _setRatio(ratio);
        _fundReserve(reserveUnits);
        uint256 mat = backedVault.mat();
        uint256 collateralAtMinCR = (mat * debt + 99) / 100;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, collateralAtMinCR);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), collateralAtMinCR);
        backedVault.lock(collateralAtMinCR);
        backedVault.draw(debt);
        vm.stopPrank();
        assertGe(backedVault.collateralRatio(BORROWER), mat);
        assertLt(backedVault.collateralRatio(BORROWER), mat + 1);

        uint256 ceiling = backedVault.earnLine();
        assertEq(ceiling, reserveUnits + debt * ratio / 10_000);
        if (ceiling != 0) _mintWork(WORKER, ceiling);
        _assertRejected(OTHER_WORKER, 1);

        uint256 assets = collateralAtMinCR + backedVault.reserveValue();
        uint256 liabilities = stable.totalSupply();
        assertEq(liabilities, debt + ceiling);
        assertGt(assets, liabilities, "backing above one for this reserve size");
        assertGe(assets - liabilities, (mat * 100 - 10_000 - ratio) * debt / 10_000);
    }

    function _assertRejected(address worker, uint256 amount) internal {
        uint256 rights = workOracle.mintingRights(worker);
        uint256 supply = stable.totalSupply();
        uint256 minted = backedVault.totalEarned();
        uint256 balance = stable.balanceOf(worker);
        vm.prank(worker);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        backedVault.earn(amount);
        assertEq(workOracle.mintingRights(worker), rights);
        assertEq(stable.totalSupply(), supply);
        assertEq(backedVault.totalEarned(), minted);
        assertEq(stable.balanceOf(worker), balance);
    }
}
