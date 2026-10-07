// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// OpenWorkVault: the production vault with its work channel open at wage 0 and the lag off, so these
// checks keep testing the ceiling and backing arithmetic at exact figures (test/helpers/OpenWorkVault.sol).
import {OpenWorkVault} from "../../test/helpers/OpenWorkVault.sol";
import {TreasuryFactoryEtch} from "../../test/helpers/TreasuryFactoryEtch.sol";
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
import {ImdUSD} from "../../src/ImdUSD.sol";
import {MockIMD} from "../../src/MockIMD.sol";
import {MockWorkOracle} from "../../src/MockWorkOracle.sol";
import {ISwarmFeed} from "../../src/interfaces/ISwarmFeed.sol";
import {
    APPROVED_OPERATOR,
    CHAINLINK_ETH_USD,
    ETH_USD_MAX_AGE,
    FEE_RECIPIENT,
    CUT_BPS,
    DUTY_BPS,
    EARN_MAT_BPS
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

/// @dev A token claiming more decimal places than 10 ** places can hold.
contract WideToken is ERC20 {
    constructor() ERC20("Wide", "WIDE") {}

    function decimals() public pure override returns (uint8) {
        return 78;
    }
}

/// @dev Has code and answers isStale(), but not latestValue().
contract HalfFeed {
    function isStale() external pure returns (bool) {
        return false;
    }
}

/// @dev A feed that passes validation and can be made to revert on every read afterwards.
contract BreakableFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    bool private broken;

    constructor(uint256 initial) {
        value = initial;
    }

    function setBroken(bool next) external {
        broken = next;
    }

    function latestValue() external view returns (uint256, uint64) {
        require(!broken, "broken");
        return (value, uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        require(!broken, "broken");
        return false;
    }
}

/// @dev A rights holder with transient capital, doing a borrow / work-mint / repay / withdraw round
/// trip inside one transaction. Each entry point is one transaction from the test's point of view.
contract RoundTripper {
    ParameterizedVault private immutable vault;
    MockIMD private immutable imd;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd = imd_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function borrow(uint256 collateral, uint256 debt) external returns (uint256 ceiling, uint256 backed) {
        vault.lock(collateral);
        vault.draw(debt);
        return (vault.earnLine(), vault.backedDebt());
    }

    function roundTrip(uint256 collateral, uint256 debt, uint256 work) external {
        vault.lock(collateral);
        vault.draw(debt);
        vault.earn(work);
        vault.wipe(debt);
        vault.free(collateral);
    }

    function repayThenMint(uint256 repay, uint256 mint) external returns (uint256 backed) {
        vault.wipe(repay);
        vault.draw(mint);
        return vault.backedDebt();
    }
}

/// @notice The compute-backing increment, end to end on the governed vault: the Treasury the vault
/// creates and routes revenue to, the USD feed, the governed reserve register, and the work ceiling.
/// @dev Run like the other files in this directory:
/// FOUNDRY_TEST=script/checks forge test --offline --match-contract ComputeBackingTest
/// Prices are chosen so the arithmetic is legible: the primary feed says 1 IMD = 1 COMP, the ETH/USD
/// mock says $2, so IMD is $2. Chainlink is stood in for by code etched at the pinned address.
/// The vault's unit is the primary feed's (one COMP of debt is one ETH-worth of IMD), so a USD
/// reserve figure is halved on its way into `earnLine`: `reserveValueUsd` 200 is `reserveValue` 100.
contract ComputeBackingTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);
    address private constant STRANGER = address(0x5747);

    MockIMD private imd;
    ParameterizedVault private vault;
    Parameters private params;
    Treasury private treasury;
    UsdPriceFeed private usd;
    ImdUSD private comp;
    MockWorkOracle private oracle;
    CheckFeed private price;
    CheckFeed private spot;
    CheckFeed private nhi;
    MockAggregator private ethUsd;

    function setUp() public {
        TreasuryFactoryEtch.etch(vm);
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        price = new CheckFeed(1 ether);
        spot = new CheckFeed(1 ether);
        nhi = new CheckFeed(0.6 ether); // mat 200, grace 0
        vault =
            new OpenWorkVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        params = vault.parameters();
        treasury = vault.treasury();
        usd = vault.usdPriceFeed();
        comp = vault.stablecoin();
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
        vault.lock(collateral);
        if (debt != 0) vault.draw(debt);
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

        assertEq(vault.earnMat(), 2_500);
        assertEq(EARN_MAT_BPS, 2_500);
        assertEq(params.MAX_EARN_MAT_BPS(), 2_500);
        assertEq(treasury.reserveAssetCount(), 0);
        assertEq(vault.earnLine(), 0, "nothing backs anything yet");

        // One per vault, never shared, and no post-deploy call anywhere.
        ParameterizedVault other =
            new OpenWorkVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        assertTrue(address(other.treasury()) != address(treasury));
        assertEq(other.treasury().registrar(), address(other.parameters()));
    }

    /// @dev The plain vault is untouched: compiled-in recipient, no ceiling. Covered longhand by the
    /// rest of the suite; pinned here so the split between the two vaults is explicit.
    function test_thePlainVaultStillPaysTheAccountAndHasNoCeiling() public {
        CDPVault plain = new CDPVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        assertEq(plain.feeRecipient(), FEE_RECIPIENT);
        assertEq(plain.earnLine(), type(uint256).max);
    }

    // --- revenue lands in the treasury ------------------------------------------------------------

    /// @dev One liquidation, both revenue streams: the protocol's share of the bonus in IMD, and the
    /// stability fee the liquidator paid first, minted in COMP. Both arrive in the Treasury, nothing
    /// arrives at FEE_RECIPIENT, and `sync` turns each into a receipt.
    function test_aLiquidationRoutesTheProtocolCutAndTheFeeToTheTreasury() public {
        assertEq(vault.cut(), CUT_BPS);
        assertEq(vault.duty(), DUTY_BPS);
        _borrow(300 ether, 150 ether); // CR 200 exactly
        vm.prank(BORROWER);
        comp.transfer(KEEPER, 150 ether);

        vm.warp(block.timestamp + 365 days);
        uint256 fee = vault.stabilityFeeOf(BORROWER);
        assertEq(fee, 3 ether, "150 COMP for a year at 200 bps");

        price.setValue(0.9 ether);
        spot.setValue(0.9 ether);
        vm.startPrank(KEEPER);
        vault.bark(BORROWER);
        vault.bite(BORROWER, 50 ether);
        vm.stopPrank();

        uint256 seized = Math.mulDiv(50 ether, 1.1e18, 0.9 ether);
        uint256 bonus = seized - Math.mulDiv(50 ether, 1e18, 0.9 ether);
        uint256 protocolCut = Math.mulDiv(bonus, CUT_BPS, 10_000);
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
        vm.expectRevert(Treasury.StablecoinIsNotReserve.selector);
        params.proposeReserveAsset(IERC20(address(comp)), usd, 0);
        assertEq(params.pendingEta(), 0, "a refused listing never occupies the slot");

        vm.expectRevert(Treasury.StablecoinIsNotReserve.selector);
        treasury.validateReserveAsset(IERC20(address(comp)), usd, 5_000);
        // Even as a removal: COMP is refused before anything else is looked at.
        vm.expectRevert(Treasury.StablecoinIsNotReserve.selector);
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

        // balance x price x haircut: 100 IMD at $2 at a 50% retained-value factor.
        _fundTreasury(100 ether);
        assertEq(treasury.reserveValueUsd(), 100e18);

        // Repricing is the same path, and does not duplicate the entry.
        _listImd(10_000);
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
        Treasury solo = new Treasury(address(this));
        assertEq(solo.vault(), address(this));
        assertEq(solo.registrar(), address(0));
        vm.expectRevert(Treasury.Unauthorized.selector);
        solo.setReserveAsset(IERC20(address(imd)), usd, 0);
    }

    function test_theRegisterRefusesWhatCannotBePriced() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.HaircutOutOfRange.selector, 10_001));
        params.proposeReserveAsset(IERC20(address(imd)), usd, 10_001);
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
        _setReserve(IERC20(address(six)), dollar, 10_000);
        six.mint(address(treasury), 1_000_000);
        assertEq(treasury.reserveValueUsd(), 1e18);
        assertEq(treasury.reserveAsset(IERC20(address(six))).decimals, 6);
    }

    function test_zeroHaircutCountsForNothingAndCannotBackWorkMinting() public {
        _listImd(0);
        _fundTreasury(100 ether);
        assertTrue(treasury.isReserveAsset(IERC20(address(imd))), "zero factor is not a delisting");
        assertEq(treasury.reserveValueUsd(), 0);
        assertEq(vault.earnLine(), 0);

        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
        assertEq(vault.totalEarned(), 0);
        assertEq(oracle.mintingRights(KEEPER), type(uint128).max);
    }

    function test_tenThousandHaircutCountsInFullAndBacksWorkMinting() public {
        _listImd(10_000);
        _fundTreasury(100 ether);
        assertEq(treasury.reserveValueUsd(), 200e18);
        assertEq(vault.reserveValue(), 100e18, "100 IMD at a primary price of 1, in the vault's unit");
        assertEq(vault.earnLine(), 100e18);

        vm.startPrank(KEEPER);
        vault.earn(100e18);
        assertEq(vault.totalEarned(), 100e18);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
        vm.stopPrank();
    }

    function testFuzz_reserveValueUsesTheHaircutAsARetainedValueFactor(uint256 haircutBps) public {
        haircutBps = bound(haircutBps, 0, 10_000);
        _listImd(haircutBps);
        _fundTreasury(100 ether);
        uint256 expected = 200e18 * haircutBps / 10_000;
        assertEq(treasury.reserveValueUsd(), expected);
        assertEq(vault.reserveValue(), expected / 2);
        assertEq(vault.earnLine(), expected / 2);
    }

    // --- the reserve term is in the vault's unit (revision, finding 9366455) ----------------------

    /// @dev The register answers in USD; the vault's debt is in the primary feed's unit, wei of ETH
    /// per IMD. The ceiling converts the reserve at the ETH/USD leg, so for IMD that leg cancels and
    /// 100 IMD in the Treasury backs exactly what 100 IMD of collateral is worth to the vault — not
    /// ETH/USD times that, which is what adding the USD figure to debt unconverted did.
    function test_theReserveTermIsConvertedIntoTheVaultsUnit() public {
        _listImd(10_000);
        _fundTreasury(100 ether);
        assertEq(treasury.reserveValueUsd(), 200e18, "the register still answers in USD");
        assertEq(usd.ethUsdPrice(), 2e18);
        assertEq(vault.reserveValue(), 100e18);
        assertEq(vault.earnLine(), 100e18);

        // ETH at $2000 instead of $2 moves the USD figure a thousandfold and the ceiling not at all.
        ethUsd.set(2000e8, block.timestamp);
        assertEq(treasury.reserveValueUsd(), 200_000e18);
        assertEq(vault.reserveValue(), 100e18, "the ETH/USD leg cancels for IMD");

        // A primary move does: at 0.5 ETH per IMD the same 100 IMD is worth 50 to the vault.
        price.setValue(0.5 ether);
        spot.setValue(0.5 ether);
        assertEq(vault.reserveValue(), 50e18);

        // And the reserve never authorises more than the vault itself would lend against the same
        // IMD at 100% CR: a borrower posting 100 IMD can mint at most 50 COMP at mat 200 here.
        price.setValue(1 ether);
        spot.setValue(1 ether);
        _borrow(100 ether, 50 ether);
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.draw(1);
        assertLe(vault.reserveValue(), 100e18);
    }

    /// @dev A reserve asset priced straight in USD converts at ETH/USD: a $1 token is half an
    /// ETH-unit when ETH is $2. Without a fresh ETH/USD price the USD figure cannot be brought into
    /// the vault's unit and counts for nothing, even though the asset's own feed is fine.
    function test_aDollarAssetIsWorthItsEthValueToTheCeiling() public {
        SixDecimalToken six = new SixDecimalToken();
        CheckFeed dollar = new CheckFeed(1 ether);
        _setReserve(IERC20(address(six)), dollar, 10_000);
        six.mint(address(treasury), 10_000_000); // $10
        assertEq(treasury.reserveValueUsd(), 10e18);
        assertEq(vault.reserveValue(), 5e18);
        assertEq(vault.earnLine(), 5e18);

        ethUsd.set(2e8, block.timestamp - ETH_USD_MAX_AGE - 1);
        assertEq(treasury.reserveValueUsd(), 10e18, "the dollar feed itself is unaffected");
        assertEq(usd.ethUsdPrice(), 0, "no fresh ETH/USD price");
        assertEq(vault.reserveValue(), 0, "so the USD figure cannot be converted and counts for nothing");
        assertEq(vault.earnLine(), 0);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
    }

    // --- debt created in the same transaction backs nothing (revision, finding 4d30331c) ----------

    function test_debtCreatedInTheSameTransactionBacksNoWorkMinting() public {
        RoundTripper tripper = new RoundTripper(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(address(tripper), 300 ether);
        oracle.grantRights(address(tripper), 25 ether);
        vm.stopPrank();

        // Inside the transaction that created it, the debt counts for nothing.
        (uint256 ceiling, uint256 backed) = tripper.borrow(300 ether, 100 ether);
        assertEq(backed, 0, "debt minted in this transaction is not backing");
        assertEq(ceiling, 0);

        // Once it has survived its transaction it counts in full. The ceiling is point-in-time from
        // here, by design: this debt is real capital in an open position, not a flash of it.
        assertEq(vault.backedDebt(), 100e18);
        assertEq(vault.earnLine(), 25e18);
        vm.prank(address(tripper));
        vault.earn(25 ether);
        assertEq(vault.totalEarned(), 25e18);
    }

    function test_theOneTransactionRoundTripIsRefusedAtTheWorkMint() public {
        RoundTripper tripper = new RoundTripper(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(address(tripper), 300 ether);
        oracle.grantRights(address(tripper), 25 ether);
        vm.stopPrank();

        // deposit 300, mint 100 (mat 200 exactly), mint 25 of work against it, repay, withdraw.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        tripper.roundTrip(300 ether, 100 ether, 25 ether);
        assertEq(vault.totalEarned(), 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(oracle.mintingRights(address(tripper)), 25 ether, "nothing consumed");
        assertEq(imd.balanceOf(address(tripper)), 300 ether);
    }

    /// @dev The cap is the debt level at the start of the transaction, not the first change: repaying
    /// and re-minting inside one transaction credits what stood before it and nothing more, and a
    /// repayment alone lowers the backed figure at once.
    function test_theBackedFigureIsCappedAtTheDebtTheTransactionBeganWith() public {
        RoundTripper tripper = new RoundTripper(vault, imd);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(tripper), 600 ether);
        tripper.borrow(600 ether, 100 ether);
        assertEq(vault.backedDebt(), 100e18);

        assertEq(tripper.repayThenMint(50 ether, 130 ether), 100e18, "180 outstanding, 100 stood before");
        assertEq(vault.backedDebt(), 180e18, "and all of it afterwards");
        assertEq(tripper.repayThenMint(100 ether, 20 ether), 100e18, "100 outstanding, below the 180 cap");
    }

    // --- principal whose collateral is gone backs nothing (revision, finding e3888b1e) -------------

    /// @dev Grace is zero at NHI 0.6, so a mark is actionable at once. BORROWER posts 200 IMD against
    /// 100 COMP (mat 200 exactly); the price halves; the largest coverable liquidation seizes all
    /// but two wei of it, which a second one-wei liquidation takes (the remainder is then swept),
    /// leaving about 9 COMP of principal and no collateral.
    function _drainBorrower() private returns (uint256 residualPrincipal) {
        _borrow(200 ether, 100 ether);
        vm.prank(BORROWER);
        comp.transfer(KEEPER, 100 ether);
        vm.warp(block.timestamp + 30 days);
        ethUsd.set(2e8, block.timestamp);
        price.setValue(0.5 ether);
        spot.setValue(0.5 ether);
        uint256 repay = Math.mulDiv(200 ether, 0.5e18, 1.1e18);
        vm.startPrank(KEEPER);
        vault.bark(BORROWER);
        vault.bite(BORROWER, repay);
        (uint256 left,) = vault.positions(BORROWER);
        assertEq(left, 2, "two wei, too small to sweep, large enough to seize for one wei of debt");
        vault.bite(BORROWER, 1);
        vm.stopPrank();
        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, 0, "drained");
        residualPrincipal = vault.totalDebt();
        assertGt(residualPrincipal, 9e18);
        assertGe(vault.totalBadDebt(), residualPrincipal, "recorded with its accrued fee");
    }

    function test_residualPrincipalOfADrainedPositionBacksNoWorkMinting() public {
        _drainBorrower();
        assertEq(vault.backedDebt(), 0);
        assertEq(vault.earnLine(), 0, "no surplus collateral stands behind that principal");
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);

        // The protocol's cut of the liquidation did land in the Treasury, but IMD is not listed here.
        assertGt(imd.balanceOf(address(treasury)), 0);
        assertEq(treasury.reserveValueUsd(), 0);
    }

    /// @dev totalBadDebt is accrued debt (fees included) and totalDebt is principal, so the
    /// subtraction over-counts by the bad position's unpaid fees — in the tightening direction only.
    function test_healthyDebtNextToBadDebtCountsNetOfIt() public {
        uint256 residual = _drainBorrower();
        assertEq(vault.totalBadDebt(), residual, "the liquidator paid the fees first, so the record is principal");

        // Fees keep accruing on the drained principal and enter the record at its next update, which
        // then exceeds the principal in totalDebt by exactly those fees.
        vm.warp(block.timestamp + 30 days);
        ethUsd.set(2e8, block.timestamp);
        vm.prank(KEEPER);
        comp.transfer(BORROWER, 1);
        vm.prank(BORROWER);
        vault.wipe(1);
        uint256 overcount = vault.totalBadDebt() - vault.totalDebt();
        assertGt(overcount, 0, "30 days of fee on the drained principal");

        address other = address(0xD0D0);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(other, 1_000 ether);
        vm.startPrank(other);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(1_000 ether);
        vault.draw(100 ether); // 500 IMD-worth at 0.5 against 100: CR 500
        vm.stopPrank();

        assertEq(vault.totalDebt(), residual + 100e18);
        assertEq(vault.backedDebt(), 100e18 - overcount, "the healthy debt, less the unpaid fees on the bad");
        assertEq(vault.earnLine(), (100e18 - overcount) / 4);

        // Once the bad debtor's fees are paid the record is principal again, and it moves together
        // with totalDebt from then on: the healthy debt counts in full and the bad still for nothing.
        vm.prank(KEEPER);
        comp.transfer(BORROWER, 5 ether);
        vm.prank(BORROWER);
        vault.wipe(5 ether);
        assertEq(vault.totalBadDebt(), vault.totalDebt() - 100e18);
        assertEq(vault.backedDebt(), 100e18);
    }

    // --- the work mint is a price-dependent action here (revision, finding aba99865) ---------------

    function test_mintFromWorkIsRefusedWhileTheFeedsDisagreeOrSpotIsStale() public {
        _listImd(10_000);
        _fundTreasury(100 ether);
        assertEq(vault.earnLine(), 100e18);

        spot.setValue(0.5 ether); // 50% off, against a 5% bound
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.earn(1);
        spot.setValue(1 ether);
        spot.setStale(true);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.earn(1);
        spot.setStale(false);
        vm.prank(KEEPER);
        vault.earn(1);

        // The plain vault's unlimited ceiling reads no price, so its work channel stays open through
        // a divergence halt, as the earlier increment pinned.
        CDPVault plain = new CDPVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        MockWorkOracle plainOracle = MockWorkOracle(address(plain.oracle()));
        vm.prank(APPROVED_OPERATOR);
        plainOracle.grantRights(KEEPER, 1);
        spot.setValue(0.5 ether);
        vm.prank(KEEPER);
        plain.earn(1);
        assertEq(plain.totalEarned(), 1);
    }

    // --- a listing the register could not read is refused, and never bricks the view (finding 21a2b135)

    function test_theRegisterRefusesAPriceSourceItCouldNotRead() public {
        ISwarmFeed half = ISwarmFeed(address(new HalfFeed()));
        IERC20 wide = IERC20(address(new WideToken()));
        vm.startPrank(APPROVED_OPERATOR);
        // Has code, answers neither read: the COMP token named as a SOURCE (not as the asset).
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        params.proposeReserveAsset(IERC20(address(imd)), ISwarmFeed(address(comp)), 5_000);
        // Answers isStale() and nothing else.
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        params.proposeReserveAsset(IERC20(address(imd)), half, 5_000);
        // A token whose 10 ** decimals does not fit a word.
        vm.expectRevert(Treasury.InvalidReserveAsset.selector);
        params.proposeReserveAsset(wide, usd, 10_000);
        vm.stopPrank();
        assertEq(params.pendingEta(), 0, "none occupied the slot");
    }

    function test_aListedSourceThatStopsAnsweringCountsForNothingInsteadOfReverting() public {
        BreakableFeed feed = new BreakableFeed(2 ether);
        _setReserve(IERC20(address(imd)), feed, 10_000);
        _fundTreasury(100 ether);
        _borrow(1_000 ether, 100 ether);
        assertEq(treasury.reserveValueUsd(), 200e18);
        assertEq(vault.earnLine(), 100e18 + 25e18);

        feed.setBroken(true);
        assertEq(treasury.reserveValueOf(IERC20(address(imd))), 0, "a source that reverts counts for nothing");
        assertEq(treasury.reserveValueUsd(), 0);
        assertEq(vault.earnLine(), 25e18, "only the ratio term remains, and the view still answers");
        vm.prank(KEEPER);
        vault.earn(25e18);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
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
        assertEq(vault.earnLine(), 50e18 + 100e18, "reserve 50 (100 IMD at half factor) + 25% of 400");

        ethUsd.set(2e8, block.timestamp - ETH_USD_MAX_AGE - 1);
        assertEq(treasury.reserveValueUsd(), 0, "a stale price counts for nothing");
        assertEq(vault.earnLine(), 100e18, "only the ratio term remains");
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(100e18 + 1);
        vm.prank(KEEPER);
        vault.earn(100e18);
    }

    // --- the work ceiling -------------------------------------------------------------------------

    function test_workCeilingIsTheReservePlusARatioOfDebtAndMintFromWorkStopsAtIt() public {
        _listImd(5_000);
        _fundTreasury(100 ether); // $200 at a 50% factor = $100 = 50 in the vault's unit
        _borrow(1_000 ether, 400 ether); // 25% of 400 = 100
        assertEq(vault.earnLine(), 150e18);
        assertEq(vault.earnLine(), vault.reserveValue() + vault.backedDebt() * vault.earnMat() / 10_000);
        assertEq(vault.reserveValue(), treasury.reserveValueUsd() * 1e18 / usd.ethUsdPrice());
        assertEq(vault.backedDebt(), vault.totalDebt());

        vm.startPrank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(150e18 + 1);
        vault.earn(100e18);
        vault.earn(50e18); // exactly to the ceiling
        assertEq(vault.totalEarned(), 150e18);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
        vm.stopPrank();
        assertEq(oracle.mintingRights(KEEPER), type(uint128).max - 150e18, "a refused mint consumes no rights");

        // Both terms are live. Repayment shrinks the ratio term; a withdrawal from the reserve shrinks
        // the other. What was already minted stays minted — the ceiling gates new supply only.
        vm.prank(BORROWER);
        vault.wipe(200 ether);
        assertEq(vault.earnLine(), 100e18);
        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(IERC20(address(imd)), STRANGER, 50 ether);
        assertEq(vault.earnLine(), 75e18);
        assertEq(vault.totalEarned(), 150e18);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);
    }

    function test_withNothingBackingItTheWorkChannelMintsNothing() public {
        assertEq(vault.earnLine(), 0);
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);

        // The first collateral-backed debt opens a quarter of itself to the work channel.
        _borrow(1_000 ether, 100 ether);
        assertEq(vault.earnLine(), 25e18);
        vm.prank(KEEPER);
        vault.earn(25e18);
        assertEq(comp.totalSupply(), 125e18, "supply = principal + work-minted");
    }

    /// @dev The ratio with an empty reserve bounds worst-case backing at (mat x D) / (D + rD): at
    /// mat 150 and r = 0.25 that is 1.2, and at r = 0.5 it is exactly 1. The cap keeps governance
    /// on the right side of that cliff.
    function test_theWorkRatioIsBoundedAt2500ByTheContract() public {
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.EarnMatTooHigh.selector, 2_501));
        params.proposeEarnMat(2_501);
        vm.expectRevert(abi.encodeWithSelector(Parameters.EarnMatTooHigh.selector, 5_000));
        params.proposeEarnMat(5_000);
        params.proposeEarnMat(2_500); // the bound itself is allowed
        params.cancel();
        params.proposeEarnMat(1_000);
        vm.stopPrank();

        (Parameters.Change kind,) = params.pendingChange();
        assertTrue(kind == Parameters.Change.EarnMat);
        (uint256 bps, uint256 eta) = params.pendingEarnMat();
        assertEq(bps, 1_000);
        assertEq(eta, params.pendingEta());
        assertEq(vault.earnMat(), 2_500, "the old ratio is live for the whole delay");

        _apply();
        assertEq(vault.earnMat(), 1_000);
        _borrow(1_000 ether, 400 ether);
        assertEq(vault.earnLine(), 40e18);
    }

    // --- the three kinds share one slot and the economics path is unchanged ----------------------

    function test_theEconomicsPathIsUnchangedAndOneChangeWaitsAtATime() public {
        Parameters.ParamSet memory next = Parameters.ParamSet(500 ether, 2_000, 400, 800, 1_500);
        vm.startPrank(APPROVED_OPERATOR);
        params.propose(next);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.proposeEarnMat(1_000);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.proposeReserveAsset(IERC20(address(imd)), usd, 0);
        vm.stopPrank();

        (Parameters.Change kind,) = params.pendingChange();
        assertTrue(kind == Parameters.Change.Economics);
        (Parameters.ParamSet memory pendingNext, uint256 eta) = params.pendingSet();
        assertEq(pendingNext.line, 500 ether);
        assertEq(pendingNext.chip, 1_500);
        assertEq(eta, params.pendingEta());
        (uint256 ratio, uint256 ratioEta) = params.pendingEarnMat();
        assertEq(ratio + ratioEta, 0, "the other views claim nothing");

        _apply();
        assertEq(vault.line(), 500 ether);
        assertEq(vault.duty(), 400);
        assertEq(vault.earnMat(), 2_500, "an economics change leaves the ratio alone");
        assertEq(treasury.reserveAssetCount(), 0, "and the register");
    }
}
