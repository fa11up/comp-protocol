// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "../../src/ParameterizedVault.sol";
import {CDPVault} from "../../src/CDPVault.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {MockWorkOracle} from "../../src/MockWorkOracle.sol";
import {ISwarmFeed} from "../../src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD} from "../../src/DeploymentConfig.sol";

contract RedemptionFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    bool public stale;

    constructor(uint256 initial) {
        value = initial;
    }

    function setValue(uint256 next) external {
        value = next;
    }

    function setStale(bool next) external {
        stale = next;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return stale;
    }
}

/// @dev Etched at the pinned Chainlink address; no constructor state is needed.
contract RedemptionUsdFeed {
    bool public stale;
    int256 private answer;

    function setStale(bool next) external {
        stale = next;
    }

    function setAnswer(int256 next) external {
        answer = next;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 updated = stale ? block.timestamp - 2 days : block.timestamp;
        return (1, answer == 0 ? int256(1e8) : answer, updated, updated, 1);
    }
}

/// @dev Everything in `run` happens inside ONE transaction, which `isolate = true` otherwise splits.
contract AtomicRedeemer {
    function run(
        ParameterizedVault vault,
        MockIMD imd,
        uint256 deposit,
        uint256 mint,
        uint256 amount,
        address candidate
    ) external returns (bool ok, uint256 out) {
        imd.approve(address(vault), type(uint256).max);
        vault.lock(deposit);
        if (mint != 0) vault.draw(mint);
        bytes memory result;
        (ok, result) = address(vault).call(abi.encodeCall(vault.redeem, (amount, 0, candidate)));
        if (ok) out = abi.decode(result, (uint256));
        uint256 debt = vault.debtOf(address(this));
        uint256 held = vault.stablecoin().balanceOf(address(this));
        if (debt != 0 && held != 0) vault.wipe(Math.min(debt, held));
        if (vault.debtOf(address(this)) == 0) vault.free(deposit);
    }
}

/// @notice Run with FOUNDRY_TEST=script/checks forge test --match-path script/checks/Redemption.t.sol.
/// This fixture deploys the real governed vault and exercises its constructor-created Treasury.
contract RedemptionTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant REDEEMER = address(0xCA11);
    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private comp;
    Parameters private parameters;
    Treasury private treasury;
    RedemptionFeed private primary;
    RedemptionFeed private spot;
    RedemptionFeed private nhi;
    RedemptionUsdFeed private usd;

    function setUp() public {
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new RedemptionFeed(1 ether);
        spot = new RedemptionFeed(1 ether);
        nhi = new RedemptionFeed(0.85 ether);
        RedemptionUsdFeed implementation = new RedemptionUsdFeed();
        vm.etch(CHAINLINK_ETH_USD, address(implementation).code);
        usd = RedemptionUsdFeed(CHAINLINK_ETH_USD);
        vault =
            new ParameterizedVault(address(imd), address(0), address(0), address(primary), address(nhi), address(spot));
        comp = vault.stablecoin();
        parameters = vault.parameters();
        treasury = vault.treasury();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(ALICE, 1e30);
        imd.mint(BOB, 1e30);
        MockWorkOracle(address(vault.oracle())).grantRights(REDEEMER, 1000 ether);
        vm.stopPrank();
        vm.prank(ALICE);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(vault), type(uint256).max);
    }

    function test_reserveFirstBurnsExactlyAndIgnoresCandidateWithoutRegistration() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(20 ether);
        _fundReserve(30 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        uint256 supply = comp.totalSupply();
        uint256 operatorBalance = imd.balanceOf(APPROVED_OPERATOR);
        assertEq(vault.reserveValue(), 0, "unregistered IMD still spends first");

        vm.prank(REDEEMER);
        assertEq(vault.redeem(10 ether, payout, address(0)), payout);

        assertEq(comp.totalSupply(), supply - 10 ether);
        assertEq(comp.balanceOf(REDEEMER), 10 ether);
        assertEq(imd.balanceOf(REDEEMER), payout);
        assertEq(imd.balanceOf(address(treasury)), 30 ether - payout);
        assertEq(imd.balanceOf(APPROVED_OPERATOR), operatorBalance, "fee is paid to nobody");
        assertEq(vault.totalFeesMinted(), 0);
        _assertPosition(ALICE, 180 ether, 100 ether);
        assertEq(vault.totalDebt(), 100 ether);
        assertEq(treasury.totalReceived(imd), 30 ether, "spending records unsynced receipts");
        assertEq(treasury.sync(imd), 0, "spent receipts cannot be counted twice");
    }

    function test_borrowerOnlyCancelsBurnedDebtAndRetainsFeeAsCollateral() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        uint256 ratioBefore = vault.collateralRatio(ALICE);

        vm.prank(REDEEMER);
        vault.redeem(10 ether, payout, ALICE);

        _assertPosition(ALICE, 180 ether - payout, 90 ether);
        assertGt(vault.collateralRatio(ALICE), ratioBefore);
        assertEq(vault.totalDebt(), 90 ether);
        assertEq(comp.totalSupply(), 90 ether);
        assertEq(imd.balanceOf(address(vault)), 180 ether - payout);
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(comp.balanceOf(address(treasury)), 0);
        assertLt(payout, 10 ether, "fee remains in backing");
    }

    function test_mixedRouteExhaustsReserveAndCancelsOnlyBorrowerShare() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        uint256 amount = 10 ether;
        uint256 payout = _quote(amount, 1 ether);
        uint256 reserveOut = payout / 2;
        uint256 canceled = amount - Math.mulDiv(reserveOut, 1 ether, _payoutScale(amount));
        _fundReserve(reserveOut);

        vm.prank(REDEEMER);
        vault.redeem(amount, payout, ALICE);

        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(imd.balanceOf(REDEEMER), payout);
        assertEq(comp.totalSupply(), 100 ether - amount);
        _assertPosition(ALICE, 180 ether - (payout - reserveOut), 100 ether - canceled);
        assertEq(vault.totalDebt(), 100 ether - canceled);
        assertGe(vault.collateralRatio(ALICE), 180);
    }

    function test_oneWeiBorrowerPayoutCancelsRoundedUpDebtAfterReserveExhaustion() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(10 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        _fundReserve(payout - 1);
        vm.prank(REDEEMER);
        vault.redeem(10 ether, payout, ALICE);
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(imd.balanceOf(REDEEMER), payout);
        _assertPosition(ALICE, 180 ether - 1, 100 ether - 2);
        assertEq(vault.totalNonPrincipalRedeemed(), 10 ether - 2);
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted() - vault.totalNonPrincipalRedeemed());
    }

    function test_payoutIsIndependentOfWhichEligiblePositionSuppliesIt() public {
        _open(ALICE, 160 ether, 100 ether);
        _open(BOB, 190 ether, 100 ether);
        _giveStable(50 ether);
        uint256 snapshot = vm.snapshotState();
        vm.prank(REDEEMER);
        uint256 first = vault.redeem(10 ether, 0, ALICE);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(REDEEMER);
        uint256 second = vault.redeem(10 ether, 0, BOB);
        assertEq(first, second);
    }

    function test_redemptionUsesDollarPriceWhileDivergenceUsesRawEthPrice() public {
        usd.setAnswer(1000e8);
        _price(0.002 ether);
        _open(ALICE, 90 ether, 100 ether);
        _giveStable(10 ether);
        assertEq(vault.collateralRatio(ALICE), 180);
        vm.prank(REDEEMER);
        uint256 payout = vault.redeem(10 ether, 4.85 ether, ALICE);
        assertEq(payout, 4.85 ether);
        assertEq(imd.balanceOf(REDEEMER), payout);
        _assertPosition(ALICE, 90 ether - payout, 90 ether);
    }

    function test_ceilingBoundaryIsStrictAndStressPreservesEligibleBand() public {
        _open(ALICE, 200 ether, 100 ether);
        _giveStable(50 ether);
        assertEq(vault.mat(), 150);
        assertEq(vault.redemptionCeilingCR(), 200);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, ALICE);
        nhi.setValue(0.6 ether);
        assertEq(vault.mat(), 200);
        assertEq(vault.redemptionCeilingCR(), 250);
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, ALICE);
        assertGt(vault.collateralRatio(ALICE), 200);
    }

    function test_justBelowCeilingIsEligible() public {
        _open(ALICE, 200 ether - 1, 100 ether);
        _giveStable(1 ether);
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, ALICE);
        assertEq(vault.debtOf(ALICE), 99 ether);
    }

    function test_ineligibleCandidateCannotSpendEvenPartialReserve() public {
        _open(ALICE, 250 ether, 100 ether);
        _giveStable(50 ether);
        _fundReserve(1 ether);
        bytes32 before = _state(ALICE);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(_state(ALICE), before);
    }

    function test_minimumOutFailureRollsBackBothRoutesAndFeeState() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        _fundReserve(1 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        bytes32 before = _state(ALICE);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, payout + 1, ALICE);
        assertEq(_state(ALICE), before);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(10 ether, payout, ALICE), payout);
    }

    function test_callerMustOwnTheWholeBurn() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(1 ether);
        _fundReserve(1 ether);
        bytes32 before = _state(ALICE);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(_state(ALICE), before);
    }

    function test_noDebtAndExcessDebtCandidatesCannotReleaseCollateral() public {
        _open(ALICE, 180 ether, 100 ether);
        _open(BOB, 18 ether, 10 ether);
        _giveStable(50 ether);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, address(0));
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(11 ether, 0, BOB);
        _assertPosition(BOB, 18 ether, 10 ether);
        assertEq(comp.balanceOf(REDEEMER), 50 ether);
    }

    /// @dev The payout is no longer fixed at par, so a SOLE position cannot be made worse: the
    /// figure the payout is capped at IS that position's own ratio, and removing value at a
    /// position's own ratio leaves the ratio where it was, with the fee making it better. The ratio
    /// guard is still needed for a candidate BELOW the aggregate — see the next test.
    function test_insolventCandidateCannotBeMadeWorseByRedemption() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        _price(0.4 ether);
        assertEq(vault.collateralRatio(ALICE), 72);
        assertEq(vault.backingPerUnit(), 0.72 ether, "one position is the whole protocol");
        (uint256 collateralWas, uint256 debtWas) = vault.positions(ALICE);
        uint256 payout = _expectCapped(10 ether, ALICE);
        (uint256 collateralNow, uint256 debtNow) = vault.positions(ALICE);
        assertEq(collateralNow, collateralWas - payout);
        assertGt(collateralNow * debtWas, collateralWas * debtNow, "the exact ratio strictly improves");
    }

    /// @dev A second, healthy position lifts the aggregate the cap is computed from above this
    /// candidate's own ratio, which is the only way the gap the ratio guard covers can open now.
    /// The point of the test is unchanged: whole-percent `collateralRatio` would hide the
    /// deterioration, and the guard compares the exact fractions instead.
    function test_ratioRegressionHiddenByIntegerCRRoundingIsStillRejected() public {
        _open(ALICE, 180 ether, 100 ether);
        _open(BOB, 1000 ether, 100 ether);
        _giveStable(1 ether);
        _price(0.538 ether);
        uint256 payout = _quote(1 ether, 0.538 ether);
        uint256 initialRatio = vault.collateralRatio(ALICE);
        uint256 roundedResult = Math.mulDiv(180 ether - payout, 0.538 ether, 99 ether) / 1e16;
        assertEq(initialRatio, roundedResult, "integer CR would hide deterioration");
        vm.expectRevert(CDPVault.RedemptionWorsensRatio.selector);
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, ALICE);
        _assertPosition(ALICE, 180 ether, 100 ether);
    }

    function test_fullDebtRedemptionLeavesBorrowersRemainingCollateral() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(100 ether);
        uint256 payout = _quote(100 ether, 1 ether);
        vm.prank(REDEEMER);
        vault.redeem(100 ether, payout, ALICE);
        _assertPosition(ALICE, 180 ether - payout, 0);
        assertEq(comp.totalSupply(), 0);
        uint256 before = imd.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.free(180 ether - payout);
        assertEq(imd.balanceOf(ALICE), before + 180 ether - payout);
    }

    function test_accruedFeesAreCanceledWithoutMintingFeeRecipientTokens() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = vault.debtOf(ALICE);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        assertGt(fees, 1 ether);
        uint256 recipientComp = comp.balanceOf(address(treasury));
        uint256 mintedFees = vault.totalFeesMinted();
        vm.prank(REDEEMER);
        vault.redeem(1 ether, 0, ALICE);
        assertEq(vault.debtOf(ALICE), debt - 1 ether);
        assertEq(vault.stabilityFeeOf(ALICE), fees - 1 ether);
        assertEq(vault.totalDebt(), 100 ether, "accrued fee canceled before principal");
        assertEq(comp.totalSupply(), 99 ether);
        assertEq(comp.balanceOf(address(treasury)), recipientComp);
        assertEq(vault.totalFeesMinted(), mintedFees);
    }

    function test_feeBumpUsesPreburnSupplyAndThenCurrentSupply() public {
        _open(ALICE, 1800 ether, 1000 ether);
        _giveStable(300 ether);
        _fundReserve(500 ether);
        assertEq(vault.REDEMPTION_FEE_FLOOR_BPS(), 50);
        assertEq(vault.REDEMPTION_FEE_CAP_BPS(), 500);
        assertEq(vault.redemptionBaseRate(), 0);
        assertEq(vault.redemptionFeeBps(100 ether), 300);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(100 ether, 0, address(0)), 97 ether);
        assertEq(vault.redemptionBaseRate(), 0.025 ether);
        assertEq(vault.lastRedemptionAt(), block.timestamp);
        assertEq(comp.totalSupply(), 900 ether);
        assertEq(vault.redemptionFeeBps(36 ether), 400);
        vm.prank(REDEEMER);
        vault.redeem(36 ether, 0, address(0));
        assertEq(vault.redemptionBaseRate(), 0.035 ether);
    }

    function test_baseRateDecaysApproximatelyByHalfEveryTwelveHours() public {
        _open(ALICE, 1800 ether, 1000 ether);
        _giveStable(200 ether);
        _fundReserve(300 ether);
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, address(0));
        uint256 base = vault.redemptionBaseRate();
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(vault.decayedRedemptionBaseRate(), base / 2, base / 10_000);
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(vault.decayedRedemptionBaseRate(), base / 4, base / 10_000);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.decayedRedemptionBaseRate(), 0);
        assertEq(vault.redemptionFeeBps(1), 50);
    }

    function test_baseRateAndFeeRemainCappedAfterLargeRedemption() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(100 ether);
        _fundReserve(200 ether);
        assertEq(vault.redemptionFeeBps(80 ether), 500);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(80 ether, 0, address(0)), 76 ether);
        assertEq(vault.redemptionBaseRate(), 0.045 ether);
        assertEq(vault.redemptionFeeBps(20 ether), 500);
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(vault.decayedRedemptionBaseRate(), 0.0225 ether, 0.00001 ether);
    }

    function test_nextRedemptionAddsBumpToDecayedBaseAndCheckpointsIt() public {
        _open(ALICE, 1800 ether, 1000 ether);
        _giveStable(200 ether);
        _fundReserve(300 ether);
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, address(0));
        vm.warp(block.timestamp + 12 hours);
        uint256 expectedBase = vault.decayedRedemptionBaseRate() + 0.025 ether;
        uint256 payout = _quote(90 ether, 1 ether);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(90 ether, payout, address(0)), payout);
        assertEq(vault.redemptionBaseRate(), expectedBase);
        assertEq(vault.lastRedemptionAt(), block.timestamp);
        assertApproxEqAbs(expectedBase, 0.0375 ether, 0.00001 ether);
    }

    function test_governedSpreadShipsAtFiftyAndHasSameDelayAndAuthority() public {
        assertEq(parameters.redemptionSpread(), 50);
        assertEq(vault.redemptionSpread(), 50);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeRedemptionSpread(25);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(25);
        (uint256 spread, uint256 eta) = parameters.pendingRedemptionSpread();
        assertEq(spread, 25);
        assertEq(eta, block.timestamp + 48 hours);
        assertEq(vault.redemptionCeilingCR(), 200);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        vm.warp(eta);
        vm.prank(REDEEMER);
        parameters.applyPending();
        assertEq(vault.redemptionSpread(), 25);
        assertEq(vault.redemptionCeilingCR(), 175);
        nhi.setValue(0.6 ether);
        assertEq(vault.redemptionCeilingCR(), 225);
        (spread, eta) = parameters.pendingRedemptionSpread();
        assertEq(spread, 0);
        assertEq(eta, 0);
    }

    function test_spreadBoundsCannotBeWidenedByGovernor() public {
        vm.expectRevert();
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(24);
        vm.expectRevert();
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(101);
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionSpread(100);
        vm.warp(parameters.pendingEta());
        parameters.applyPending();
        assertEq(vault.redemptionCeilingCR(), 250);
        assertEq(vault.mat(), 150);
    }

    function test_treasuryOnlyLetsItsVaultReleaseIMD() public {
        _fundReserve(10 ether);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.redeemIMD(REDEEMER, 1 ether);
        vm.expectRevert(Treasury.Unauthorized.selector);
        vm.prank(APPROVED_OPERATOR);
        treasury.redeemIMD(REDEEMER, 1 ether);
        assertEq(imd.balanceOf(address(treasury)), 10 ether);
    }

    function test_workMintedCompConsumesDebtOnlyForCollateralItReceives() public {
        _open(ALICE, 180 ether, 100 ether);
        uint256 ceiling = vault.workCeiling();
        vm.prank(REDEEMER);
        vault.mintFromWork(10 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        vm.prank(REDEEMER);
        vault.redeem(10 ether, payout, ALICE);
        _assertPosition(ALICE, 180 ether - payout, 90 ether);
        assertEq(comp.balanceOf(ALICE), 100 ether);
        assertEq(comp.balanceOf(REDEEMER), 0);
        assertEq(vault.totalWorkMinted(), 10 ether);
        assertEq(vault.workCeiling(), ceiling - 2.5 ether);
    }

    function test_reserveRedemptionCannotWorsenBackingAfterPermittedDebtUnwind() public {
        _registerImdReserve(10_000);
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        assertEq(vault.reserveValue(), 100 ether);
        assertEq(comp.totalSupply(), 250 ether);
        assertEq(vault.redemptionFeeBps(10 ether), 150);
        // Every borrower is gone: 100 of reserve stands behind 250 of supply and nothing else does,
        // so a COMP is backed at 0.4. Par would pay 9.85 and worsen the ratio, which is what the
        // old halt refused; the cap pays 40% of that instead and cannot.
        assertEq(vault.backingPerUnit(), 0.4 ether, "100 of reserve, 250 of supply");
        assertEq(_parQuote(10 ether, 1 ether), 9.85 ether, "what par would have paid");
        assertEq(_quote(10 ether, 1 ether), 3.94 ether, "40% of par, less the 150 bps fee");
        assertEq(_expectCapped(10 ether, address(0)), 3.94 ether);
        assertGt(vault.backingPerUnit(), 0.4 ether, "and the fee leaves it strictly better");
    }

    function test_reserveRedemptionAllowsExactlyUnchangedBacking() public {
        _registerImdReserve(10_000);
        _fundReserve(246.25 ether);
        _mintWorkAndUnwind();
        uint256 assetsBefore = vault.reserveValue();
        uint256 supplyBefore = comp.totalSupply();
        // 246.25 of reserve against 250 of supply was the level at which a PAR payout of 9.85 left
        // backing EXACTLY unchanged — the equality the old guard allowed. The payout now tracks
        // backing (0.985 of par) rather than sitting at par, so the same burn pays less and backing
        // comes out strictly BETTER. The boundary stops being a boundary, which is the point.
        assertEq(_parQuote(10 ether, 1 ether), 9.85 ether, "par at the old equality point");
        uint256 payout = _expectCapped(10 ether, address(0));
        assertGt(
            vault.reserveValue() * supplyBefore,
            assetsBefore * comp.totalSupply(),
            "strictly better, where par was exactly neutral"
        );
        assertEq(comp.totalSupply(), 240 ether);
        assertEq(imd.balanceOf(REDEEMER), payout);
    }

    function test_reserveRedemptionRefusesBackingOneWeiBelowBoundary() public {
        _registerImdReserve(10_000);
        _fundReserve(246.25 ether - 1);
        _mintWorkAndUnwind();
        uint256 assetsBefore = vault.reserveValue();
        uint256 supplyBefore = comp.totalSupply();
        // One wei below the boundary a PAR payout crosses the exact ratio line, which is what the
        // old guard refused. The capped payout does not cross it here or anywhere else, so there
        // is no longer a cliff one wei either side of 246.25.
        assertLt(
            (assetsBefore - _parQuote(10 ether, 1 ether)) * supplyBefore,
            assetsBefore * (supplyBefore - 10 ether),
            "one wei of backing crosses the exact ratio boundary at par"
        );
        assertGe(
            (assetsBefore - _quote(10 ether, 1 ether)) * supplyBefore,
            assetsBefore * (supplyBefore - 10 ether),
            "the capped payout stays on the right side of it"
        );
        _expectCapped(10 ether, address(0));
    }

    function test_borrowerRedemptionCannotWorsenAggregateBackingDespiteImprovingPosition() public {
        _assertUnderbackedBorrowerRedemptionRejected(0);
    }

    function test_mixedRedemptionCannotWorsenAggregateBackingDespiteImprovingPosition() public {
        _assertUnderbackedBorrowerRedemptionRejected(1 ether);
    }

    function test_tinyReserveRedemptionCannotHideBackingLossInValuationRounding() public {
        _price(0.2 ether);
        _registerImdReserve(10_000);
        _fundReserve(9);
        _open(ALICE, 120, 16);
        vm.prank(REDEEMER);
        vault.mintFromWork(4);
        vm.startPrank(ALICE);
        vault.wipe(16);
        vault.free(120);
        vm.stopPrank();
        assertEq(comp.totalSupply(), 4);
        assertEq(vault.reserveValue(), 1);
        // 9 IMD wei at 0.2 floors to 1 wei of value behind 4 of supply, so a COMP is backed at a
        // quarter and the burn is paid 1 wei, not the 4 par would pay. Paying 4 is the loss the
        // rounding hides: 5 of 9 still floors to 1, while the exact fraction falls from 9/4 to 5/3.
        assertEq(vault.backingPerUnit(), 0.25 ether, "1 of value, 4 of supply");
        assertEq(_parQuote(1, 0.2 ether), 4, "par would have paid four times that");
        assertEq(Math.mulDiv(9 - 4, 0.2 ether, 1 ether), 1, "rounded remaining backing would hide the loss");
        assertLt(uint256((9 - 4) * 4), uint256(9 * (4 - 1)), "exact underlying backing would fall");
        assertEq(_expectCapped(1, address(0)), 1, "a quarter of par, less the fee, floored");
        assertEq(imd.balanceOf(address(treasury)), 8);
        assertGt(uint256(8 * 4), uint256(9 * 3), "8/3 beats 9/4 even in exact arithmetic");
    }

    function test_haircutReserveRejectsUnsafeBurnAndAllowsFundedBurn() public {
        _registerImdReserve(5000);
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        assertEq(vault.reserveValue(), 50 ether);
        _expectCapped(10 ether, address(0));

        _fundReserve(500 ether);
        uint256 assetsBefore = vault.reserveValue();
        uint256 supplyBefore = comp.totalSupply();
        // The retained factor halves the REGISTERED value, but the guard values the IMD it would
        // actually pay at the redemption price on both sides, so backing clears par and this burn
        // is paid par minus the fee. The haircut is work-ceiling policy, not a redemption discount.
        assertEq(vault.backingPerUnit(), 1e18);
        uint256 payout = _quote(10 ether, 1 ether);
        assertEq(payout, _parQuote(10 ether, 1 ether), "the cap does not bind once the reserve is funded");
        vm.prank(REDEEMER);
        assertEq(vault.redeem(10 ether, payout, address(0)), payout);
        assertGt(vault.reserveValue() * supplyBefore, assetsBefore * comp.totalSupply());
    }

    function test_mixedRedemptionShrinksBothTermsOfWorkCeiling() public {
        ISwarmFeed reserveFeed = vault.usdPriceFeed();
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeReserveAsset(imd, reserveFeed, 10_000);
        vm.warp(parameters.pendingEta());
        parameters.applyPending();
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        _fundReserve(10 ether);
        uint256 reserveValue = vault.reserveValue();
        uint256 backedDebt = vault.backedDebt();
        uint256 ceiling = vault.workCeiling();
        assertEq(reserveValue, 10 ether);
        vm.prank(REDEEMER);
        vault.redeem(20 ether, 0, ALICE);
        assertEq(vault.reserveValue(), 0);
        assertLt(vault.backedDebt(), backedDebt);
        assertLt(vault.workCeiling(), ceiling - reserveValue);
    }

    function test_staleAndDivergentPricesRefuseReserveAndBorrowerPayouts() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        _fundReserve(1 ether);
        bytes32 before = _state(ALICE);
        primary.setStale(true);
        _expectPricingFailure();
        primary.setStale(false);
        nhi.setStale(true);
        _expectPricingFailure();
        nhi.setStale(false);
        spot.setStale(true);
        _expectPricingFailure();
        spot.setStale(false);
        usd.setStale(true);
        _expectPricingFailure();
        usd.setStale(false);
        spot.setValue(1.1 ether);
        _expectPricingFailure();
        assertEq(_state(ALICE), before);
    }

    function test_zeroBurnAndZeroRoundedPayoutAreRefused() public {
        _open(ALICE, 180 ether, 100 ether);
        _giveStable(50 ether);
        _fundReserve(1 ether);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(0, 0, ALICE);
        _price(100 ether);
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(1, 0, address(0));
        assertEq(comp.balanceOf(REDEEMER), 50 ether);
    }

    function testFuzz_mixedRedemptionConservesBalancesAndNeverWorsensRatio(
        uint256 priceSeed,
        uint256 amountSeed,
        uint256 reserveSeed
    ) public {
        uint256 price = bound(priceSeed, 0.05 ether, 50 ether);
        uint256 debt = 10_000 ether;
        uint256 collateral = Math.mulDiv(debt, 1.8 ether, price, Math.Rounding.Ceil);
        _price(price);
        _open(ALICE, collateral, debt);
        uint256 amount = bound(amountSeed, 1e6, debt);
        _giveStable(amount);
        uint256 payout = _quote(amount, price);
        uint256 reserveOut = bound(reserveSeed, 0, payout);
        uint256 canceled = reserveOut == payout ? 0 : amount - Math.mulDiv(reserveOut, price, _payoutScale(amount));
        _fundReserve(reserveOut);

        vm.prank(REDEEMER);
        assertEq(vault.redeem(amount, payout, ALICE), payout);

        (uint256 remainingCollateral, uint256 remainingDebt) = vault.positions(ALICE);
        assertEq(comp.totalSupply(), debt - amount);
        assertEq(comp.balanceOf(REDEEMER), 0);
        assertEq(imd.balanceOf(REDEEMER), payout);
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(remainingDebt, debt - canceled);
        assertEq(vault.totalDebt(), remainingDebt);
        assertEq(comp.totalSupply(), vault.totalDebt() + vault.totalWorkMinted() - vault.totalNonPrincipalRedeemed());
        assertEq(remainingCollateral, collateral - (payout - reserveOut));
        assertEq(imd.balanceOf(address(vault)), remainingCollateral);
        assertGe(remainingCollateral * debt, collateral * remainingDebt, "exact ratio, before integer CR rounding");
    }

    // --- revision: findings 8936befa, 998ff6b2, fcd5b261, b952037a and b8aa4a98 ----------------------

    function test_debtFreeDepositIsNotBackingWhetherOrNotItIsInTheSameTransaction() public {
        _registerImdReserve(10_000);
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        assertEq(comp.totalSupply(), 250 ether);
        // Smaller burns than the old version used: those reverted and left the redeemer's COMP
        // alone, and these actually spend it.
        _expectCapped(50 ether, address(0));

        // Across transactions: a debt-free deposit, then the same burn.
        vm.prank(BOB);
        vault.lock(1000 ether);
        _expectCapped(50 ether, address(0));

        // Inside one transaction: deposit, burn, withdraw. No longer refused — the payout is capped
        // at the backing the call FOUND, so the deposit buys the redeemer nothing. The defence is
        // the same one, expressed as a price rather than as a revert.
        AtomicRedeemer atomic = new AtomicRedeemer();
        vm.prank(REDEEMER);
        comp.transfer(address(atomic), 100 ether);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(atomic), 1000 ether);
        uint256 quoted = _quote(100 ether, 1 ether);
        uint256 treasuryBefore = imd.balanceOf(address(treasury));
        (bool ok, uint256 out) = atomic.run(vault, imd, 1000 ether, 0, 100 ether, address(0));
        assertTrue(ok, "a capped payout replaces the refusal");
        assertEq(out, quoted, "the in-call deposit did not raise the payout by one wei");
        assertEq(imd.balanceOf(address(treasury)), treasuryBefore - quoted, "only the capped payout left");
        assertEq(comp.totalSupply(), 50 ether);
    }

    function test_oneWeiOfDebtDoesNotTurnADepositIntoBacking() public {
        _registerImdReserve(10_000);
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        _open(BOB, 1000 ether, 1);
        bytes32 before = _state(BOB);
        _expectCapped(100 ether, address(0));
    }

    function test_collateralCountsAtMostMinCRTimesPriorPrincipal() public {
        // 1500 against 1000 is fully backed, so the same burn is allowed once real debt stands
        // behind the collateral; 3000 against the same debt counts for no more than 1500 does.
        _registerImdReserve(10_000);
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        _open(BOB, 3000 ether, 1000 ether);
        uint256 snapshot = vm.snapshotState();
        vm.prank(REDEEMER);
        uint256 first = vault.redeem(100 ether, 0, address(0));
        assertTrue(vm.revertToState(snapshot));
        vm.prank(BOB);
        vault.free(1500 ether);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(100 ether, 0, address(0)), first);
        // Supply 1250 against secured backing 1500 + 100: a burn of 100 may remove at most 128 of
        // value and removes about 97; a burn of 150 may remove 192 and removes about 145. The
        // uncounted 1500 of surplus never enters the comparison, which the ineligible 300% candidate
        // shows: the reserve route needs no candidate, so its backing is what the guard measures.
        assertEq(vault.collateralRatio(BOB), 150);
    }

    function test_unregisteredReserveIsValuedAtTheRedemptionPriceOnBothSides() public {
        _fundReserve(100 ether);
        _mintWorkAndUnwind();
        assertEq(vault.reserveValue(), 0, "unlisted, as at launch");
        assertEq(vault.redemptionReserve(), 100 ether);
        // Unlisted, so `reserveValue` reads zero — but the guard values this IMD at the redemption
        // price on BOTH sides, which is the whole point of finding 998ff6b2, so backing is 100/250.
        assertEq(vault.backingPerUnit(), 0.4 ether, "valued at the redemption price, not the register");
        uint256 firstPayout = _expectCapped(10 ether, ALICE);

        // Recapitalizing to the old boundary level raises the cap; the burn is still paid below par
        // because 246.25 against 240 of supply is still short of it.
        _fundReserve(146.25 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        assertGt(payout, firstPayout, "a larger reserve pays the same burn more");
        vm.prank(REDEEMER);
        assertEq(vault.redeem(10 ether, payout, address(0)), payout);
    }

    function test_registeredFactorDoesNotChangeHowTheGuardValuesIMD() public {
        // A retained factor is work-ceiling policy. The IMD leaving and the IMD held are the same
        // asset, and the guard values both at the redemption price: a zero factor used to make the
        // reserve route invisible to it, exactly as an empty register did.
        _registerImdReserve(0);
        _fundReserve(246.25 ether - 1);
        _mintWorkAndUnwind();
        assertEq(vault.reserveValue(), 0);
        // Zero retained factor, but the guard still sees the Treasury's IMD at the redemption price
        // on both sides, so backing is NOT zero and the payout is capped at it rather than refused.
        assertGt(vault.backingPerUnit(), 0.9 ether, "a zero factor does not blind the guard to IMD");
        assertLt(vault.backingPerUnit(), 1e18, "but the reserve is a hair short of par");
        _expectCapped(10 ether, address(0));
        _fundReserve(1);
        uint256 payout = _quote(10 ether, 1 ether);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(10 ether, payout, address(0)), payout);
    }

    function test_sameTransactionMintCannotDiluteTheFee() public {
        _open(ALICE, 3000 ether, 1000 ether);
        // Funded past the cap up front. This test pins FEE figures, and a capped payout would
        // confound every one of them; the backing cap has its own cases above. The old version
        // opened with an under-reserved run asserting the burn was refused outright, which is the
        // one half of it the cap replaces rather than preserves.
        _fundReserve(10_000 ether);
        assertEq(vault.redemptionFeeBps(100 ether), 300);
        AtomicRedeemer atomic = new AtomicRedeemer();
        _giveStable(100 ether);
        vm.prank(REDEEMER);
        comp.transfer(address(atomic), 100 ether);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(atomic), 13_500 ether);
        assertEq(vault.backingPerUnit(), 1e18, "the cap is not what this test measures");
        // The fee is the one a tenth of the supply that existed BEFORE the call pays, and that is
        // the base the next redeemer inherits: the 9000 minted inside the call do not dilute it.
        (bool ok, uint256 out) = atomic.run(vault, imd, 13_500 ether, 9000 ether, 100 ether, address(0));
        assertTrue(ok);
        assertEq(out, 97 ether, "a same-transaction mint bought a cheaper fee");
        assertEq(vault.redemptionBaseRate(), 0.025 ether);
        assertEq(comp.totalSupply(), 900 ether);
        assertEq(imd.balanceOf(address(atomic)), 13_500 ether + 97 ether);
    }

    function test_burnBeyondPriorSupplySaturatesInsteadOfDividingByZero() public {
        // Nothing existed before this call; the increase saturates at the cap rather than reverting.
        _fundReserve(1000 ether);
        AtomicRedeemer atomic = new AtomicRedeemer();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(atomic), 300 ether);
        (bool ok, uint256 out) = atomic.run(vault, imd, 300 ether, 200 ether, 100 ether, address(0));
        assertTrue(ok);
        assertEq(out, 95 ether);
        assertEq(vault.redemptionBaseRate(), 0.045 ether);
    }

    function test_freshPrincipalIsChargedButDoesNotMoveTheRateOthersPay() public {
        _open(ALICE, 380 ether, 200 ether);
        uint256 start = block.timestamp;
        _open(BOB, 160 ether, 100 ether);
        vm.prank(BOB);
        comp.transfer(REDEEMER, 100 ether);
        assertEq(vault.redemptionFeeBps(100 ether), 500, "a third of supply quotes the cap");
        vm.prank(REDEEMER);
        assertEq(vault.redeem(100 ether, 0, BOB), 95 ether, "and is charged it");
        assertEq(vault.redemptionBaseRate(), 0, "but fresh principal moves nothing");
        assertEq(vault.redemptionFeeBps(0), 50);
        _assertPosition(BOB, 65 ether, 0);

        // ALICE's principal ages out one half-life after it was minted, and then counts in full.
        _giveStable(20 ether);
        vm.warp(start + 12 hours - 1);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        // While the principal is fresh, only the cancelled stability fees move the rate.
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(fees, 1 ether, 200 ether) / 4);
        vm.warp(start + 12 hours);
        uint256 decayed = vault.decayedRedemptionBaseRate();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), decayed + Math.mulDiv(10 ether, 1 ether, 190 ether) / 4);
    }

    function test_oneWeiTopUpsCannotKeepPrincipalFresh() public {
        _open(ALICE, 1800 ether, 1000 ether);
        // Three days of one-wei top-ups, each a minute inside the window: none re-dates the record.
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 12 hours - 60);
            vm.prank(ALICE);
            vault.draw(1);
        }
        _giveStable(100 ether);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        // At most the few wei minted inside the window are excluded; the tenth of supply counts.
        assertApproxEqAbs(vault.redemptionBaseRate(), Math.mulDiv(100 ether, 1 ether, supply) / 4, 10);
        assertEq(vault.redemptionFeeBps(0), 300);
    }

    function test_aTopUpMovesTheRecordByItsShareOfThePrincipal() public {
        _open(ALICE, 1800 ether, 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 12 hours - 60);
        vm.prank(ALICE);
        vault.draw(1);
        _giveStable(100 ether);
        // One wei moves the record by a second at most, so eleven hours later the 1000 has aged out.
        vm.warp(start + 23 hours);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(100 ether, 1 ether, supply) / 4);
    }

    function test_equalTranchesAgeOutAtTheirAverageAge() public {
        _open(ALICE, 3800 ether, 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 6 hours);
        vm.prank(ALICE);
        vault.draw(1000 ether);
        _giveStable(20 ether);
        // Two equal tranches six hours apart are dated three hours after the first: fresh until
        // fifteen hours, the same principal-time as the whole amount held for twelve.
        vm.warp(start + 15 hours - 1);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(fees, 1 ether, supply) / 4);
        vm.warp(start + 15 hours);
        uint256 decayed = vault.decayedRedemptionBaseRate();
        supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), decayed + Math.mulDiv(10 ether, 1 ether, supply) / 4);
    }

    function test_cancelledFeesAreNeverFresh() public {
        _open(ALICE, 1800 ether, 1000 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(ALICE);
        vault.draw(100 ether);
        vm.warp(block.timestamp + 6 hours);
        _giveStable(50 ether);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        assertGt(fees, 0);
        uint256 supply = comp.totalSupply();
        // The burn cancels fees first, then fresh principal: only the fees move the rate.
        vm.prank(REDEEMER);
        vault.redeem(50 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(fees, 1 ether, supply) / 4);
    }

    function test_onlyTheFreshPartOfACancelledBurnIsExcluded() public {
        _open(ALICE, 1800 ether, 1000 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(ALICE);
        vault.draw(50 ether);
        _giveStable(200 ether);
        // 100 burned, 50 of it fresh: the rate rises by 50 / 1050 / 4, not 100 / 1050 / 4.
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(50 ether, 1 ether, 1050 ether) / 4);
        // Retired fresh principal stays retired: a later burn against the same position counts whole.
        uint256 decayed = vault.decayedRedemptionBaseRate();
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), decayed + Math.mulDiv(100 ether, 1 ether, 950 ether) / 4);
    }

    function test_repaymentRetiresFreshPrincipalBeforeRedemptionDoes() public {
        _open(ALICE, 1800 ether, 1000 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(ALICE);
        vault.draw(100 ether);
        // REVISION (finding 5ee3f2bc): the whole burn retires the record, fees included. Repayment
        // pays accrued fees first, and retiring only the principal part left a fee-sized remainder of
        // the new tranche fresh after every mint/repay pair; converting a fee obligation into
        // principal adds no exposure, so nothing of the 100 is fresh once 100 has been repaid.
        uint256 fees = vault.stabilityFeeOf(ALICE);
        assertGt(fees, 0);
        vm.prank(ALICE);
        vault.wipe(100 ether);
        _giveStable(100 ether);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(100 ether, 1 ether, supply) / 4);
    }

    // --- revision: findings 7cd5035c and 5ee3f2bc -------------------------------------------------

    function test_debtFreeDepositHeldAcrossTransactionsIsNotBackingWhenPositionsAreBelowMinCR() public {
        // The reviewer's scenario: 550 of listed reserve, ALICE 1500 / 1000, the whole 800 work
        // ceiling minted, then IMD halves. Collateral 750 and reserve 275 back 1800 COMP (0.569 each),
        // so a 100 COMP burn paying 98.11 is refused: it would take more than its 56.9 share.
        _registerImdReserve(10_000);
        _fundReserve(550 ether);
        _open(ALICE, 1500 ether, 1000 ether);
        assertEq(vault.workCeiling(), 800 ether);
        vm.prank(REDEEMER);
        vault.mintFromWork(800 ether);
        _price(0.5 ether);
        assertEq(vault.collateralRatio(ALICE), 75);
        _expectCapped(100 ether, ALICE);

        // A debt-free deposit in its own transaction used to fill the gap between what ALICE holds
        // (750) and the cap (1500): it is not in the transient tally, bears no debt and comes back
        // the next transaction. Bounded per position, it contributes nothing.
        // Now that the consequence is a capped payout rather than a refusal, "contributes nothing"
        // is DIRECTLY measurable: the same burn is quoted at exactly the same figure either side of
        // the deposit. That is a stronger statement than the old revert, which only said the burn
        // was somewhere past a threshold.
        uint256 quotedBefore = _quote(100 ether, 0.5 ether);
        vm.prank(BOB);
        vault.lock(1500 ether);
        assertEq(vault.securedCollateral(), 1500 ether, "only ALICE's collateral is secured");
        assertEq(_quote(100 ether, 0.5 ether), quotedBefore, "1500 idle IMD bought the redeemer nothing");
        _expectCapped(100 ether, ALICE);
        // One wei of debt contributes one wei's worth of IMD, not the deposit.
        vm.prank(BOB);
        vault.draw(1);
        assertEq(vault.securedCollateral(), 1500 ether + 4, "two wei of USD at half a dollar");
        _expectCapped(100 ether, ALICE);

        // The variant without a price move: the operator withdraws reserve and NHI falls to 0.60.
        _price(1 ether);
        vm.prank(BOB);
        vault.wipe(1);
        // Half of what is actually left, not a literal 400: the three burns above now PAY (they
        // used to revert and leave the reserve at its initial 550), so a fixed figure overdraws it.
        // Read FIRST: a view inside the argument list consumes the prank (this reverted
        // Unauthorized once already), so the balance is hoisted out of the pranked call.
        uint256 half = imd.balanceOf(address(treasury)) / 2;
        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(imd, APPROVED_OPERATOR, half);
        nhi.setValue(0.6 ether);
        assertEq(vault.mat(), 200);
        // The cap does NOT bind here, and that is the correct reading rather than a weaker test: the
        // price is back at 1 and mat 200 lets twice ALICE's principal count, so her whole 1500
        // qualifies and a COMP is backed to par. The burn is paid par minus the fee.
        assertEq(vault.backingPerUnit(), 1e18, "a higher mat lets all of ALICE's collateral count");
        uint256 parPayout = _quote(100 ether, 1 ether);
        assertEq(parPayout, _parQuote(100 ether, 1 ether));
        uint256 backingWas = _econBacking();
        vm.prank(REDEEMER);
        assertEq(vault.redeem(100 ether, parPayout, ALICE), parPayout);
        assertGe(_econBacking(), backingWas, "a redemption must not worsen backing");
        // BOB's 1500 was never backing, so he can still take all of it back out.
        vm.prank(BOB);
        vault.free(1500 ether);
        // Still the full 1500: the reserve covered the whole payout, so ALICE's position never
        // funded it and her secured term is untouched.
        assertEq(vault.securedCollateral(), 1500 ether, "only ALICE's collateral, and all of it");
    }

    function test_securedCollateralIsBoundedPerPositionAndRepricedWhenTouched() public {
        _open(ALICE, 3000 ether, 1000 ether);
        assertEq(vault.securedCollateral(), 2000 ether, "twice the principal at one dollar");
        vm.prank(BOB);
        vault.lock(500 ether);
        assertEq(vault.securedCollateral(), 2000 ether, "a debt-free position adds nothing");
        vm.prank(ALICE);
        vault.free(1500 ether);
        assertEq(vault.securedCollateral(), 1500 ether, "inside the bound, collateral counts whole");
        // A fall in price raises the IMD the bound buys; the term is re-priced only when touched.
        _price(0.5 ether);
        assertEq(vault.securedCollateral(), 1500 ether);
        vm.prank(ALICE);
        vault.lock(1500 ether);
        assertEq(vault.securedCollateral(), 3000 ether, "4000 IMD of bound at half a dollar");
        _price(1 ether);
        vm.prank(ALICE);
        vault.wipe(500 ether);
        assertEq(vault.securedCollateral(), 1000 ether, "re-priced and re-bounded by the repayment");
        vm.prank(ALICE);
        vault.wipe(500 ether);
        assertEq(vault.securedCollateral(), 0, "no principal, no term");
        (uint256 collateral,) = vault.positions(ALICE);
        assertEq(collateral, 3000 ether, "the collateral itself is untouched");
    }

    function test_healthyPositionCountsWholeAtAnyPrice() public {
        // The bound is converted at the price, so a 180% position is inside it at five cents as at
        // a dollar. Counting principal in dollars against collateral in IMD would have made this
        // position look ten percent backed and refused every burn.
        _price(0.05 ether);
        _open(ALICE, 36_000 ether, 1000 ether);
        assertEq(vault.collateralRatio(ALICE), 180);
        assertEq(vault.securedCollateral(), 36_000 ether);
        _giveStable(100 ether);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(100 ether, 0, ALICE), 1940 ether);
    }

    function test_mintRepayRoundTripsCannotKeepPrincipalFresh() public {
        _open(ALICE, 1800 ether, 1000 ether);
        // Three days: every six hours, five mint/repay pairs that change nothing on net. The old
        // record retired each pair at its mean age, leaving the 1000 younger every time.
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 6 hours);
            vm.startPrank(ALICE);
            for (uint256 j; j < 5; ++j) {
                vault.draw(190 ether);
                vault.wipe(190 ether);
            }
            vm.stopPrank();
        }
        _giveStable(100 ether);
        uint256 supply = comp.totalSupply();
        assertEq(vault.redemptionFeeBps(100 ether), 300);
        vm.prank(REDEEMER);
        vault.redeem(100 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(100 ether, 1 ether, supply) / 4, "nothing is fresh");
        assertEq(vault.redemptionFeeBps(0), 300);
    }

    function test_aRoundTripReturnsTheRecordToWhereItWas() public {
        _open(ALICE, 1800 ether, 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 6 hours);
        vm.startPrank(ALICE);
        vault.draw(190 ether);
        vault.wipe(190 ether);
        vm.stopPrank();
        _giveStable(20 ether);
        // Still fresh a second before the 1000 would have aged out on its own...
        vm.warp(start + 12 hours - 1);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(fees, 1 ether, supply) / 4);
        // ...and aged out exactly when it would have: the pair neither re-dated nor re-aged it.
        vm.warp(start + 12 hours);
        uint256 decayed = vault.decayedRedemptionBaseRate();
        supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), decayed + Math.mulDiv(10 ether, 1 ether, supply) / 4);
    }

    function test_repayingPartOfAFreshRecordKeepsItsPrincipalTime() public {
        // 1000 then 500 more six hours later: the record is dated two hours after the first (see
        // test_equalTranchesAgeOutAtTheirAverageAge). Repaying 250 retires the youngest 250, so the
        // remaining 1250 carries the whole record's principal-time: 1500 x 4h / 1250 = 4.8h at the
        // repayment, and the record ages out at 13h12m rather than 14h.
        _open(ALICE, 2400 ether, 1000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 6 hours);
        vm.startPrank(ALICE);
        vault.draw(500 ether);
        vault.wipe(250 ether);
        vm.stopPrank();
        assertLt(vault.collateralRatio(ALICE), 200, "eligible");
        _giveStable(20 ether);
        vm.warp(start + 13 hours + 12 minutes - 1);
        uint256 fees = vault.stabilityFeeOf(ALICE);
        uint256 supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), Math.mulDiv(fees, 1 ether, supply) / 4, "fresh at 13h12m - 1");
        vm.warp(start + 13 hours + 12 minutes);
        uint256 decayed = vault.decayedRedemptionBaseRate();
        supply = comp.totalSupply();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
        assertEq(vault.redemptionBaseRate(), decayed + Math.mulDiv(10 ether, 1 ether, supply) / 4, "aged out at 13h12m");
    }

    function test_feeRoundsFractionalBasisPointsAgainstTheRedeemer() public {
        _open(ALICE, 1800 ether, 1000 ether);
        vm.warp(block.timestamp + 12 hours);
        _giveStable(1 ether);
        // 0.39 / 1000 / 4 is 0.975 of a basis point: charged as one, never as zero.
        assertEq(vault.redemptionFeeBps(0.39 ether), 51);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(0.39 ether, 0, ALICE), 0.388011 ether);
        assertEq(vault.redemptionBaseRate(), 9.75e13, "the exact fraction is still carried");
    }

    function _open(address owner, uint256 collateral, uint256 debt) private {
        vm.startPrank(owner);
        vault.lock(collateral);
        vault.draw(debt);
        vm.stopPrank();
    }

    function _giveStable(uint256 amount) private {
        vm.prank(ALICE);
        comp.transfer(REDEEMER, amount);
    }

    function _fundReserve(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(treasury), amount);
    }

    function _registerImdReserve(uint256 retainedFactor) private {
        ISwarmFeed reserveFeed = vault.usdPriceFeed();
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeReserveAsset(imd, reserveFeed, retainedFactor);
        vm.warp(parameters.pendingEta());
        parameters.applyPending();
    }

    function _mintWorkAndUnwind() private {
        _open(ALICE, 1500 ether, 1000 ether);
        // isolate=true makes the work mint a later transaction, when the debt counts toward its ceiling.
        vm.prank(REDEEMER);
        vault.mintFromWork(250 ether);
        vm.startPrank(ALICE);
        vault.wipe(1000 ether);
        vault.free(1500 ether);
        vm.stopPrank();
        _assertPosition(ALICE, 0, 0);
    }

    function _assertUnderbackedBorrowerRedemptionRejected(uint256 reserveOut) private {
        _registerImdReserve(10_000);
        if (reserveOut != 0) _fundReserve(reserveOut);
        _mintWorkAndUnwind();
        _open(BOB, 180 ether, 100 ether);
        uint256 payout = _quote(10 ether, 1 ether);
        uint256 canceled = 10 ether - Math.mulDiv(reserveOut, 1 ether, _payoutScale(10 ether));
        uint256 assetsBefore = 180 ether + reserveOut;
        assertEq(comp.totalSupply(), 350 ether);
        assertGt(
            (180 ether - (payout - reserveOut)) * 100 ether,
            180 ether * (100 ether - canceled),
            "the candidate's own ratio would improve"
        );
        // The candidate's own ratio improves, which the ratio guard allows, and under a PAR payout
        // the aggregate would still worsen — that gap is exactly what RedemptionWorsensBacking was
        // for. The capped payout closes it by arithmetic: par worsens the aggregate, this does not.
        assertLt(
            (assetsBefore - _parQuote(10 ether, 1 ether)) * 350 ether,
            assetsBefore * 340 ether,
            "a par payout would worsen aggregate backing"
        );
        assertGe((assetsBefore - payout) * 350 ether, assetsBefore * 340 ether, "the capped payout does not");
        bytes32 before = _state(BOB);

        _expectCapped(10 ether, BOB);
    }

    function _price(uint256 price) private {
        primary.setValue(price);
        spot.setValue(price);
    }

    /// @dev Mirrors the vault: par minus the fee, then capped at what actually backs a COMP.
    function _payoutScale(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(vault.backingPerUnit(), 10_000 - vault.redemptionFeeBps(amount), 10_000);
    }

    function _quote(uint256 amount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(amount, _payoutScale(amount), price);
    }

    /// @dev A burn the old `RedemptionWorsensBacking` halt refused. It now goes through at a payout
    /// capped at backing per COMP: strictly below par minus the fee, exact to the wei, improving
    /// economic backing, and leaving a state that actually moved. Replaces an `expectRevert` plus a
    /// `_state` fingerprint asserting nothing changed — which asserted the halt, not the property.
    function _expectCapped(uint256 amount, address candidate) private returns (uint256 payout) {
        (uint256 price,) = vault.usdPriceFeed().latestValue();
        payout = _quote(amount, price);
        assertLt(payout, _parQuote(amount, price), "the cap binds below par minus the fee");
        uint256 backingWas = _econBacking();
        bytes32 stateWas = _state(candidate);
        vm.prank(REDEEMER);
        assertEq(vault.redeem(amount, payout, candidate), payout, "paid exactly the capped figure");
        assertGe(_econBacking(), backingWas, "a redemption must not worsen backing");
        assertNotEq(_state(candidate), stateWas, "a successful burn moves the state");
    }

    function _assertPosition(address owner, uint256 collateral, uint256 debt) private view {
        (uint256 actualCollateral, uint256 actualDebt) = vault.positions(owner);
        assertEq(actualCollateral, collateral);
        assertEq(actualDebt, debt);
    }

    function _state(address owner) private view returns (bytes32) {
        (uint256 collateral, uint256 debt) = vault.positions(owner);
        return keccak256(
            abi.encode(
                collateral,
                debt,
                vault.totalDebt(),
                comp.totalSupply(),
                comp.balanceOf(REDEEMER),
                imd.balanceOf(REDEEMER),
                imd.balanceOf(address(vault)),
                imd.balanceOf(address(treasury)),
                treasury.totalReceived(imd),
                treasury.lastSynced(imd),
                vault.redemptionBaseRate(),
                vault.lastRedemptionAt(),
                vault.totalFeesMinted(),
                vault.totalNonPrincipalRedeemed()
            )
        );
    }

    function _expectPricingFailure() private {
        vm.expectRevert();
        vm.prank(REDEEMER);
        vault.redeem(10 ether, 0, ALICE);
    }

    /// @notice Collateral plus reserve, per COMP, in the vault's unit — the ECONOMIC backing figure.
    /// @dev Deliberately NOT `vault.backingPerUnit()`, which counts only collateral with mat times
    /// its value in principal behind it and therefore FALLS when a redemption cancels debt (it
    /// disqualifies mat of collateral to retire one COMP of supply). That measure is not monotone
    /// and must not be asserted as if it were. This one is, under a pro-rata payout, and it is read
    /// from balances rather than from the vault so it can disagree with it.
    function _econBacking() private view returns (uint256) {
        uint256 supply = comp.totalSupply();
        if (supply == 0) return type(uint256).max;
        (uint256 price,) = vault.usdPriceFeed().latestValue();
        uint256 others = vault.reserveValue() - treasury.reserveValueOf(IERC20(address(imd)));
        uint256 backing = others
            + Math.mulDiv(imd.balanceOf(address(treasury)) + imd.balanceOf(address(vault)), price, 1e18);
        return Math.mulDiv(backing, 1e18, supply);
    }

    /// @dev What the payout would be with no backing cap: par minus the fee.
    function _parQuote(uint256 amount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(amount, (10_000 - vault.redemptionFeeBps(amount)) * 1e14, price);
    }
}
