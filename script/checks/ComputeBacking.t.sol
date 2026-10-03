// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CDPVault} from "../../src/CDPVault.sol";
import {ParameterizedVault} from "../../src/ParameterizedVault.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {Treasury} from "../../src/Treasury.sol";
import {UsdPriceFeed} from "../../src/UsdPriceFeed.sol";
import {CompToken} from "../../src/CompToken.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {MockWorkOracle} from "../../src/MockWorkOracle.sol";
import {ISwarmFeed} from "../../src/interfaces/ISwarmFeed.sol";
import {
    APPROVED_OPERATOR,
    CHAINLINK_ETH_USD,
    ETH_USD_MAX_AGE,
    FEE_RECIPIENT,
    PROTOCOL_BONUS_SHARE_BPS,
    STABILITY_FEE_BPS,
    WORK_RATIO_BPS
} from "../../src/DeploymentConfig.sol";

/// @dev Controllable feed: value, timestamp and staleness set independently.
contract CheckFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;
    bool private stale;

    constructor(uint256 initial) {
        setValue(initial);
    }

    function setValue(uint256 next) public {
        value = next;
        updatedAt = uint64(block.timestamp);
    }

    function setStale(bool next) external {
        stale = next;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external view returns (bool) {
        return stale;
    }
}

/// @dev Stands in for Chainlink ETH/USD. Etched at the pinned address, so decimals is a constant
/// rather than constructor-set state (etched code keeps no constructor storage).
contract MockAggregator {
    int256 private answer;
    uint256 private updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev A stablecoin-shaped token, to prove the register prices by the token's own decimals.
contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The compute-backing increment, end to end on the governed vault: the Treasury the vault
/// creates and routes revenue to, the USD feed, the governed reserve register, and the work ceiling.
/// @dev Run like the other files in this directory:
/// FOUNDRY_TEST=script/checks forge test --offline --match-contract ComputeBackingTest
/// Prices are chosen so the arithmetic is legible: the primary feed says 1 IMD = 1 COMP, the ETH/USD
/// mock says $2, so IMD is $2. Chainlink is stood in for by code etched at the pinned address.
contract ComputeBackingTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);
    address private constant STRANGER = address(0x5747);

    MockIMD private imd;
    ParameterizedVault private vault;
    Parameters private params;
    Treasury private treasury;
    UsdPriceFeed private usd;
    CompToken private comp;
    MockWorkOracle private oracle;
    CheckFeed private price;
    CheckFeed private spot;
    CheckFeed private nhi;
    MockAggregator private ethUsd;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        price = new CheckFeed(1 ether);
        spot = new CheckFeed(1 ether);
        nhi = new CheckFeed(0.6 ether); // minCR 200, grace 0
        vault = new ParameterizedVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        params = vault.parameters();
        treasury = vault.treasury();
        usd = vault.usdPriceFeed();
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));

        vm.etch(CHAINLINK_ETH_USD, address(new MockAggregator()).code);
        ethUsd = MockAggregator(CHAINLINK_ETH_USD);
        ethUsd.set(2e8, block.timestamp);

        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 10_000 ether);
        oracle.grantRights(KEEPER, type(uint128).max);
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
    }

    // --- helpers ----------------------------------------------------------------------------------

    function _borrow(uint256 collateral, uint256 debt) private {
        vm.startPrank(BORROWER);
        vault.depositCollateral(collateral);
        if (debt != 0) vault.mintCOMP(debt);
        vm.stopPrank();
    }

    function _fundTreasury(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(treasury), amount);
    }

    /// @dev Waits out the delay and applies as a stranger. The ETH/USD mock is re-dated afterwards:
    /// 48 hours is past ETH_USD_MAX_AGE, and a stale leg correctly values the reserve at nothing —
    /// which is what test_aStaleUsdPrice... asserts on purpose, and nothing else here wants by accident.
    function _apply() private {
        vm.warp(block.timestamp + params.TIMELOCK());
        vm.prank(STRANGER);
        params.applyPending();
        ethUsd.set(2e8, block.timestamp);
    }

    function _setReserve(IERC20 asset, ISwarmFeed feed, uint256 haircutBps) private {
        vm.prank(APPROVED_OPERATOR);
        params.proposeReserveAsset(asset, feed, haircutBps);
        _apply();
    }

    function _listImd(uint256 haircutBps) private {
        _setReserve(IERC20(address(imd)), usd, haircutBps);
    }

    // --- the vault creates its treasury and its USD feed ------------------------------------------

    function test_theVaultCreatesItsTreasuryAndUsdFeedWithNothingPassedIn() public {
        assertTrue(address(treasury) != address(0) && address(usd) != address(0));
        assertEq(treasury.vault(), address(vault), "the treasury's creator is the vault");
        assertEq(treasury.registrar(), address(params), "the register answers to the vault's parameters");
        assertEq(treasury.withdrawer(), APPROVED_OPERATOR);
        assertEq(address(usd.imdEthFeed()), address(price), "the IMD leg is the vault's primary feed");
        assertEq(address(usd.ETH_USD()), CHAINLINK_ETH_USD);
        assertEq(vault.feeRecipient(), address(treasury), "revenue is routed to the treasury, not an account");

        assertEq(vault.workRatioBps(), 2_500);
        assertEq(WORK_RATIO_BPS, 2_500);
        assertEq(params.MAX_WORK_RATIO_BPS(), 2_500);
        assertEq(treasury.reserveAssetCount(), 0);
        assertEq(vault.workCeiling(), 0, "nothing backs anything yet");

        // One per vault, never shared, and no post-deploy call anywhere.
        ParameterizedVault other =
            new ParameterizedVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        assertTrue(address(other.treasury()) != address(treasury));
        assertEq(other.treasury().registrar(), address(other.parameters()));
    }

    /// @dev The plain vault is untouched: compiled-in recipient, no ceiling. Covered longhand by the
    /// rest of the suite; pinned here so the split between the two vaults is explicit.
    function test_thePlainVaultStillPaysTheAccountAndHasNoCeiling() public {
        CDPVault plain = new CDPVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        assertEq(plain.feeRecipient(), FEE_RECIPIENT);
        assertEq(plain.workCeiling(), type(uint256).max);
    }

    // --- revenue lands in the treasury ------------------------------------------------------------

    /// @dev One liquidation, both revenue streams: the protocol's share of the bonus in IMD, and the
    /// stability fee the liquidator paid first, minted in COMP. Both arrive in the Treasury, nothing
    /// arrives at FEE_RECIPIENT, and `sync` turns each into a receipt.
    function test_aLiquidationRoutesTheProtocolCutAndTheFeeToTheTreasury() public {
        assertEq(vault.protocolBonusShareBps(), PROTOCOL_BONUS_SHARE_BPS);
        assertEq(vault.stabilityFeeBps(), STABILITY_FEE_BPS);
        _borrow(300 ether, 150 ether); // CR 200 exactly
        vm.prank(BORROWER);
        comp.transfer(KEEPER, 150 ether);

        vm.warp(block.timestamp + 365 days);
        uint256 fee = vault.stabilityFeeOf(BORROWER);
        assertEq(fee, 3 ether, "150 COMP for a year at 200 bps");

        price.setValue(0.9 ether);
        spot.setValue(0.9 ether);
        vm.startPrank(KEEPER);
        vault.markUnderwater(BORROWER);
        vault.liquidate(BORROWER, 50 ether);
        vm.stopPrank();

        uint256 seized = Math.mulDiv(50 ether, 1.1e18, 0.9 ether);
        uint256 bonus = seized - Math.mulDiv(50 ether, 1e18, 0.9 ether);
        uint256 protocolCut = Math.mulDiv(bonus, PROTOCOL_BONUS_SHARE_BPS, 10_000);
        assertGt(protocolCut, 0);

        assertEq(imd.balanceOf(address(treasury)), protocolCut, "the protocol's share of the bonus");
        assertEq(comp.balanceOf(address(treasury)), fee, "the fee paid first out of the 50 COMP");
        assertEq(vault.totalFeesMinted(), fee);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0, "nothing reaches the account");
        assertEq(comp.balanceOf(FEE_RECIPIENT), 0);
        assertEq(imd.balanceOf(KEEPER), seized - protocolCut, "the keeper, who also marked, keeps the rest");

        assertEq(treasury.sync(IERC20(address(imd))), protocolCut);
        assertEq(treasury.sync(IERC20(address(comp))), fee);
        assertEq(treasury.totalReceived(IERC20(address(imd))), protocolCut);
        assertEq(treasury.totalReceived(IERC20(address(comp))), fee);
    }

    // --- the reserve register ---------------------------------------------------------------------

    function test_registeringCompAsReserveIsRefusedWithItsOwnError() public {
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.CompIsNotReserve.selector);
        params.proposeReserveAsset(IERC20(address(comp)), usd, 0);
        assertEq(params.pendingEta(), 0, "a refused listing never occupies the slot");

        vm.expectRevert(Treasury.CompIsNotReserve.selector);
        treasury.validateReserveAsset(IERC20(address(comp)), usd, 5_000);
        // Even as a removal: COMP is refused before anything else is looked at.
        vm.expectRevert(Treasury.CompIsNotReserve.selector);
        treasury.validateReserveAsset(IERC20(address(comp)), ISwarmFeed(address(0)), 0);
    }

    function test_reserveChangesWaitTheDelayAndAnyoneApplies() public {
        vm.prank(APPROVED_OPERATOR);
        params.proposeReserveAsset(IERC20(address(imd)), usd, 5_000);

        (Parameters.Change kind, uint256 eta) = params.pendingChange();
        assertTrue(kind == Parameters.Change.ReserveAsset);
        assertEq(eta, block.timestamp + 48 hours);
        (IERC20 asset, ISwarmFeed feed, uint256 haircut, uint256 at) = params.pendingReserveAsset();
        assertEq(address(asset), address(imd));
        assertEq(address(feed), address(usd));
        assertEq(haircut, 5_000);
        assertEq(at, eta);
        (, uint256 setEta) = params.pendingSet();
        assertEq(setEta, 0, "the five-value view does not claim a register change");

        assertFalse(treasury.isReserveAsset(IERC20(address(imd))), "nothing changes during the delay");
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        params.applyPending();

        vm.warp(eta);
        vm.prank(STRANGER);
        params.applyPending();
        ethUsd.set(2e8, block.timestamp);
        assertTrue(treasury.isReserveAsset(IERC20(address(imd))));
        Treasury.ReserveAsset memory entry = treasury.reserveAsset(IERC20(address(imd)));
        assertEq(address(entry.priceFeed), address(usd));
        assertEq(entry.haircutBps, 5_000);
        assertEq(entry.decimals, 18);
        assertEq(treasury.reserveAssetCount(), 1);

        // balance x price x (1 - haircut): 100 IMD at $2 at a 50% haircut.
        _fundTreasury(100 ether);
        assertEq(treasury.reserveValueUsd(), 100e18);

        // Repricing is the same path, and does not duplicate the entry.
        _listImd(0);
        assertEq(treasury.reserveAssetCount(), 1);
        assertEq(treasury.reserveValueUsd(), 200e18);

        // Delisting: a zero price source. The balance stays; it just counts for nothing.
        _setReserve(IERC20(address(imd)), ISwarmFeed(address(0)), 0);
        assertFalse(treasury.isReserveAsset(IERC20(address(imd))));
        assertEq(treasury.reserveAssetCount(), 0);
        assertEq(treasury.reserveValueUsd(), 0);
        assertEq(imd.balanceOf(address(treasury)), 100 ether);

        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.NotAReserveAsset.selector);
        params.proposeReserveAsset(IERC20(address(imd)), ISwarmFeed(address(0)), 0);
    }

    function test_noOwnerCanTouchTheRegisterDirectly() public {
        address[4] memory callers = [APPROVED_OPERATOR, address(vault), STRANGER, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(Treasury.Unauthorized.selector);
            treasury.setReserveAsset(IERC20(address(imd)), usd, 0);
        }
        assertEq(treasury.reserveAssetCount(), 0);

        // Only the governor may propose, and only through the delay.
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        params.proposeReserveAsset(IERC20(address(imd)), usd, 0);

        // A Treasury created by something with no Parameters has no registrar at all, and refuses
        // even its creator: the register is frozen empty, not open.
        Treasury solo = new Treasury();
        assertEq(solo.vault(), address(this));
        assertEq(solo.registrar(), address(0));
        vm.expectRevert(Treasury.Unauthorized.selector);
        solo.setReserveAsset(IERC20(address(imd)), usd, 0);
    }

    function test_theRegisterRefusesWhatCannotBePriced() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.HaircutOutOfRange.selector, 10_000));
        params.proposeReserveAsset(IERC20(address(imd)), usd, 10_000);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        params.proposeReserveAsset(IERC20(address(imd)), ISwarmFeed(STRANGER), 0);
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        params.proposeReserveAsset(IERC20(STRANGER), usd, 0);
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        params.proposeReserveAsset(IERC20(address(0)), usd, 0);
        vm.stopPrank();
        assertEq(params.pendingEta(), 0);
    }

    /// @dev A 6-decimal dollar token: one whole unit is 1e6, priced at $1, counts for $1.
    function test_theRegisterPricesByTheTokensOwnDecimals() public {
        SixDecimalToken six = new SixDecimalToken();
        CheckFeed dollar = new CheckFeed(1 ether);
        _setReserve(IERC20(address(six)), dollar, 0);
        six.mint(address(treasury), 1_000_000);
        assertEq(treasury.reserveValueUsd(), 1e18);
        assertEq(treasury.reserveAsset(IERC20(address(six))).decimals, 6);
    }

    // --- the USD feed -----------------------------------------------------------------------------

    function test_usdPriceFeedMultipliesTheLegsAndIsStaleIfEitherIs() public {
        (uint256 value, uint64 at) = usd.latestValue();
        assertEq(value, 2e18, "1 IMD = 1 ETH here, and 1 ETH = $2");
        assertEq(at, uint64(block.timestamp));
        assertFalse(usd.isStale());
        assertEq(usd.maxAge(), Math.min(price.maxAge(), ETH_USD_MAX_AGE));

        // The IMD leg.
        price.setStale(true);
        assertTrue(usd.isStale(), "stale IMD/ETH leg");
        price.setStale(false);
        assertFalse(usd.isStale());
        price.setValue(0);
        (value,) = usd.latestValue();
        assertEq(value, 0, "a zero IMD/ETH reading is no price");
        price.setValue(0.5 ether);
        (value,) = usd.latestValue();
        assertEq(value, 1e18);
        price.setValue(1 ether);

        // The USD leg: too old, exactly at the bound, non-positive, and absent.
        vm.warp(block.timestamp + 2 days);
        price.setValue(1 ether);
        ethUsd.set(2e8, block.timestamp - ETH_USD_MAX_AGE - 1);
        assertTrue(usd.isStale(), "stale ETH/USD leg");
        ethUsd.set(2e8, block.timestamp - ETH_USD_MAX_AGE);
        assertFalse(usd.isStale(), "the exact age boundary is still fresh");
        (, at) = usd.latestValue();
        assertEq(at, uint64(block.timestamp - ETH_USD_MAX_AGE), "dated at the older leg");
        ethUsd.set(0, block.timestamp);
        assertTrue(usd.isStale());
        (value,) = usd.latestValue();
        assertEq(value, 0);
        ethUsd.set(-1, block.timestamp);
        assertTrue(usd.isStale());
        ethUsd.set(2500e8, block.timestamp);
        (value,) = usd.latestValue();
        assertEq(value, 2500e18, "8-decimal answer scaled correctly");

        vm.etch(CHAINLINK_ETH_USD, "");
        assertTrue(usd.isStale(), "an unreachable aggregator is stale, not a revert");
        (value, at) = usd.latestValue();
        assertEq(value, 0);
        assertEq(at, 0);
    }

    function test_aStaleUsdPriceValuesTheReserveAtNothingAndOnlyTightensTheCeiling() public {
        _listImd(5_000);
        _fundTreasury(100 ether);
        _borrow(1_000 ether, 400 ether);
        assertEq(vault.workCeiling(), 100e18 + 100e18, "reserve 100 + 25% of 400");

        ethUsd.set(2e8, block.timestamp - ETH_USD_MAX_AGE - 1);
        assertEq(treasury.reserveValueUsd(), 0, "a stale price counts for nothing");
        assertEq(vault.workCeiling(), 100e18, "only the ratio term remains");
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.mintFromWork(100e18 + 1);
        vm.prank(KEEPER);
        vault.mintFromWork(100e18);
    }

    // --- the work ceiling -------------------------------------------------------------------------

    function test_workCeilingIsTheReservePlusARatioOfDebtAndMintFromWorkStopsAtIt() public {
        _listImd(5_000);
        _fundTreasury(100 ether); // $200 at a 50% haircut = 100
        _borrow(1_000 ether, 400 ether); // 25% of 400 = 100
        assertEq(vault.workCeiling(), 200e18);
        assertEq(vault.workCeiling(), treasury.reserveValueUsd() + vault.totalDebt() * vault.workRatioBps() / 10_000);

        vm.startPrank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.mintFromWork(200e18 + 1);
        vault.mintFromWork(150e18);
        vault.mintFromWork(50e18); // exactly to the ceiling
        assertEq(vault.totalWorkMinted(), 200e18);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.mintFromWork(1);
        vm.stopPrank();
        assertEq(oracle.mintingRights(KEEPER), type(uint128).max - 200e18, "a refused mint consumes no rights");

        // Both terms are live. Repayment shrinks the ratio term; a withdrawal from the reserve shrinks
        // the other. What was already minted stays minted — the ceiling gates new supply only.
        vm.prank(BORROWER);
        vault.repayCOMP(200 ether);
        assertEq(vault.workCeiling(), 150e18);
        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(IERC20(address(imd)), STRANGER, 50 ether);
        assertEq(vault.workCeiling(), 100e18);
        assertEq(vault.totalWorkMinted(), 200e18);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.mintFromWork(1);
    }

    function test_withNothingBackingItTheWorkChannelMintsNothing() public {
        assertEq(vault.workCeiling(), 0);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.mintFromWork(1);

        // The first collateral-backed debt opens a quarter of itself to the work channel.
        _borrow(1_000 ether, 100 ether);
        assertEq(vault.workCeiling(), 25e18);
        vm.prank(KEEPER);
        vault.mintFromWork(25e18);
        assertEq(comp.totalSupply(), 125e18, "supply = principal + work-minted");
    }

    /// @dev The ratio with an empty reserve bounds worst-case backing at (minCR x D) / (D + rD): at
    /// minCR 150 and r = 0.25 that is 1.2, and at r = 0.5 it is exactly 1. The cap keeps governance
    /// on the right side of that cliff.
    function test_theWorkRatioIsBoundedAt2500ByTheContract() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.WorkRatioTooHigh.selector, 2_501));
        params.proposeWorkRatio(2_501);
        vm.expectRevert(abi.encodeWithSelector(Parameters.WorkRatioTooHigh.selector, 5_000));
        params.proposeWorkRatio(5_000);
        params.proposeWorkRatio(2_500); // the bound itself is allowed
        params.cancel();
        params.proposeWorkRatio(1_000);
        vm.stopPrank();

        (Parameters.Change kind,) = params.pendingChange();
        assertTrue(kind == Parameters.Change.WorkRatio);
        (uint256 bps, uint256 eta) = params.pendingWorkRatio();
        assertEq(bps, 1_000);
        assertEq(eta, params.pendingEta());
        assertEq(vault.workRatioBps(), 2_500, "the old ratio is live for the whole delay");

        _apply();
        assertEq(vault.workRatioBps(), 1_000);
        _borrow(1_000 ether, 400 ether);
        assertEq(vault.workCeiling(), 40e18);
    }

    // --- the three kinds share one slot and the economics path is unchanged ----------------------

    function test_theEconomicsPathIsUnchangedAndOneChangeWaitsAtATime() public {
        Parameters.ParamSet memory next = Parameters.ParamSet(500 ether, 2_000, 400, 800, 1_500);
        vm.startPrank(APPROVED_OPERATOR);
        params.propose(next);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.proposeWorkRatio(1_000);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.proposeReserveAsset(IERC20(address(imd)), usd, 0);
        vm.stopPrank();

        (Parameters.Change kind,) = params.pendingChange();
        assertTrue(kind == Parameters.Change.Economics);
        (Parameters.ParamSet memory pendingNext, uint256 eta) = params.pendingSet();
        assertEq(pendingNext.debtCeiling, 500 ether);
        assertEq(pendingNext.markerShareBps, 1_500);
        assertEq(eta, params.pendingEta());
        (uint256 ratio, uint256 ratioEta) = params.pendingWorkRatio();
        assertEq(ratio + ratioEta, 0, "the other views claim nothing");

        _apply();
        assertEq(vault.debtCeiling(), 500 ether);
        assertEq(vault.stabilityFeeBps(), 400);
        assertEq(vault.workRatioBps(), 2_500, "an economics change leaves the ratio alone");
        assertEq(treasury.reserveAssetCount(), 0, "and the register");
    }
}
