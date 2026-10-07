// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Parameters} from "src/Parameters.sol";
import {Treasury} from "src/Treasury.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {ReserveUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {MockShareVault} from "./helpers/MockShareVault.sol";
import {
    APPROVED_OPERATOR,
    CHAINLINK_ETH_USD,
    ORACLE_ASKER,
    ORACLE_BUDGET_PER_DAY,
    MAX_ORACLE_BUDGET_PER_DAY
} from "src/DeploymentConfig.sol";

/// @notice The Treasury's keyless way out: a governed daily stream of IMD to the oracle asker,
/// unwrapped from sIMD on the way so the asker only ever holds what the Intake is paid in.
contract OracleBudgetTest is Test {
    address private constant STRANGER = address(0x5174);
    uint256 private constant IMD_ETH = 0.001 ether;
    /// @dev 1e18 raw shares = 1.25e12 raw IMD (1 whole sIMD = 1.25 IMD), as in ShareCollateral.t.sol.
    uint256 private constant RATE = 1.25e12;

    MockIMD private imd;
    MockShareVault private share;
    ParameterizedVault private vault;
    Treasury private treasury;
    Parameters private params;

    function setUp() public {
        TreasuryFactoryEtch.etch(vm);
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        share = new MockShareVault(imd, RATE);
        vm.etch(CHAINLINK_ETH_USD, address(new ReserveUsdAggregator()).code);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).setDecimals(8);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).set(2_000e8, block.timestamp);
        vault = _vault(address(share));
        treasury = vault.treasury();
        params = vault.parameters();
        vm.etch(ORACLE_ASKER, hex"00"); // any code: the asker exists
    }

    function _vault(address collateral) private returns (ParameterizedVault) {
        TestSwarmFeed primary = new TestSwarmFeed(IMD_ETH);
        return new ParameterizedVault(
            collateral, address(0), address(0), address(primary), address(new TestSwarmFeed(0.9 ether)),
            address(new MirroredSwarmFeed(address(primary)))
        );
    }

    /// @dev Shares in the treasury worth `assets` IMD, deposited the honest way.
    function _shares(Treasury to, uint256 assets) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(this), assets);
        imd.approve(address(share), assets);
        share.deposit(assets, address(to));
        vm.roll(block.number + 1);
    }

    function test_theDefaultBudgetIsTheSourceConstant() public view {
        assertEq(params.oracleBudget(), ORACLE_BUDGET_PER_DAY);
    }

    function test_sendsIMDUnwrappedFromSharesUpToTheDailyBudget() public {
        _shares(treasury, 50 ether);
        vm.prank(STRANGER);
        uint256 sent = treasury.fundOracle();
        assertEq(sent, ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY, "the asker holds IMD");
        assertEq(share.balanceOf(ORACLE_ASKER), 0, "and never shares");
        assertEq(treasury.oracleSpent(), ORACLE_BUDGET_PER_DAY);

        assertEq(treasury.fundOracle(), 0, "nothing more today");
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY);

        // Next day: the asker still holds yesterday's unspent budget, so it is topped up, not added to.
        vm.warp(block.timestamp + 1 days);
        assertEq(treasury.fundOracle(), 0, "a full asker is not topped up past one day's budget");
        // Once it spends some, the next top-up restores exactly that much.
        vm.prank(ORACLE_ASKER);
        imd.transfer(address(0xDEAD), 4 ether);
        assertEq(treasury.fundOracle(), 4 ether, "the top-up replaces what was spent");
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY);
    }

    /// @dev Launch audit (oracle panel, medium): the asker has no way to return IMD, so funding it a
    /// full day's budget regardless of what it held piled the reserve up in a contract nothing can
    /// withdraw from. It is now topped up to one day's budget and never past it.
    function test_theAskerIsToppedUpNeverPiledUp() public {
        _shares(treasury, 500 ether);
        for (uint256 day; day < 5; ++day) {
            treasury.fundOracle();
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY, "five idle days hold one day's budget, not five");
    }

    function test_sendsOnlyWhatTheTreasuryHas() public {
        _shares(treasury, 3 ether);
        uint256 sent = treasury.fundOracle();
        assertApproxEqAbs(sent, 3 ether, 1, "capped by maxWithdraw, not the budget");
        assertEq(imd.balanceOf(ORACLE_ASKER), sent);
        // The rest of today's budget is still there when more arrives.
        _shares(treasury, 50 ether);
        assertEq(treasury.fundOracle(), ORACLE_BUDGET_PER_DAY - sent);
    }

    function test_anEmptyTreasurySendsNothing() public {
        assertEq(treasury.fundOracle(), 0);
        assertEq(treasury.oracleSpent(), 0, "an empty call spends no budget");
    }

    /// @dev The share balance leaving is a withdrawal, not lost revenue: what arrived before is still
    /// credited, the baseline lands on the balance after, and a sync afterwards credits nothing.
    function test_accountingCreditsArrivalsAndNotTheWithdrawal() public {
        _shares(treasury, 50 ether);
        uint256 arrived = share.balanceOf(address(treasury));
        treasury.fundOracle();
        IERC20 s = IERC20(address(share));
        assertEq(treasury.totalReceived(s), arrived, "the arrival is credited once");
        assertEq(treasury.lastSynced(s), share.balanceOf(address(treasury)));
        assertEq(treasury.sync(s), 0, "and a later sync credits nothing");
    }

    /// @dev Final panel audit (governance, low). With a share collateral, fundOracle paid only from shares,
    /// so plain IMD revenue (launch-pool fees) never funded the oracle while the runbook said it took over.
    function test_plainIMDHeldByTheTreasuryFundsTheOracleFirst() public {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(treasury), 100 ether);
        _shares(treasury, 50 ether);
        uint256 sharesBefore = share.balanceOf(address(treasury));
        uint256 sent = treasury.fundOracle();
        assertEq(sent, ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY, "the asker holds IMD");
        assertEq(imd.balanceOf(address(treasury)), 100 ether - ORACLE_BUDGET_PER_DAY, "taken from the plain IMD");
        assertEq(share.balanceOf(address(treasury)), sharesBefore, "no share was unwrapped");
    }

    function test_plainIMDAndSharesTogetherMakeUpTheBudget() public {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(treasury), 5 ether);
        _shares(treasury, 50 ether);
        assertEq(treasury.fundOracle(), ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(address(treasury)), 0, "all the plain IMD first");
    }

    function test_refusesAnAskerWithNoCode() public {
        vm.etch(ORACLE_ASKER, "");
        _shares(treasury, 50 ether);
        vm.expectRevert(Treasury.OracleAskerMissing.selector);
        treasury.fundOracle();
    }

    function test_plainIMDCollateralIsSentAsIs() public {
        ParameterizedVault plain = _vault(address(imd));
        Treasury t = plain.treasury();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(t), 50 ether);
        assertEq(t.fundOracle(), ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(ORACLE_ASKER), ORACLE_BUDGET_PER_DAY);
        assertEq(imd.balanceOf(address(t)), 50 ether - ORACLE_BUDGET_PER_DAY);
    }

    function test_aTreasuryNotMadeByAVaultRefuses() public {
        Treasury bare = new Treasury(address(this)); // created by this test, not a vault
        vm.expectRevert(Treasury.InvalidReserveAsset.selector); // no vault behind it, so no collateral to name: InvalidReserveAsset
        bare.fundOracle();
    }

    // --- governance -------------------------------------------------------------------------------

    function test_theBudgetIsGovernedBehindTheTimelock() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        params.proposeOracleBudget(20 ether);

        vm.prank(APPROVED_OPERATOR);
        params.proposeOracleBudget(20 ether);
        (uint256 pending, uint256 eta) = params.pendingOracleBudget();
        assertEq(pending, 20 ether);
        assertEq(eta, block.timestamp + params.TIMELOCK());

        vm.warp(eta - 1);
        vm.expectRevert();
        params.applyPending();
        vm.warp(eta);
        vm.prank(STRANGER);
        params.applyPending();
        assertEq(params.oracleBudget(), 20 ether);

        _shares(treasury, 50 ether);
        assertEq(treasury.fundOracle(), 20 ether, "the Treasury reads the governed value");
    }

    function test_theBudgetHasAHardCeiling() public {
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.OracleBudgetTooHigh.selector, MAX_ORACLE_BUDGET_PER_DAY + 1));
        params.proposeOracleBudget(MAX_ORACLE_BUDGET_PER_DAY + 1);
    }

    function test_aZeroBudgetTurnsTheStreamOff() public {
        vm.prank(APPROVED_OPERATOR);
        params.proposeOracleBudget(0);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        _shares(treasury, 50 ether);
        assertEq(treasury.fundOracle(), 0);
    }
}
