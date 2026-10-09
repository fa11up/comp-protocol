// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry panel audit 2026-10-07 (vault, job 3226aaed): the panel's reproduction of the high (warmth inherited by debt drawn BEFORE a warm position is cancelled),
// kept as it was written apart from reading the lag through laggedNow(). It failed on 973369e and passed on the fix.
// The lag it targeted was replaced on 2026-10-08 by the paced figures (CDPVault._pace); the attack is kept and
// asserted against what it was after (the work ceiling, the backing a redemption is paid), not the lag's internals.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {Parameters} from "src/Parameters.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract WfoFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        value = v;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract WfoMirror is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(ISwarmFeed p) {
        primary = p;
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}

contract WfoAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev The attacker is a contract so several vault calls can share one transaction.
contract WfoAttacker {
    ParameterizedVault private immutable vault;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function lockDraw(uint256 collateral, uint256 debt) external {
        vault.lock(collateral);
        vault.draw(debt);
    }

    function cash(uint256 amount, address candidate) external {
        vault.cash(amount, 0, candidate);
    }

    /// Draw FIRST, cancel the honest borrower's warm debt SECOND, then mint work: one transaction.
    function drawCancelEarn(uint256 collateral, uint256 debt, address candidate, uint256 work) external {
        vault.lock(collateral);
        vault.draw(debt);
        vault.cash(debt, 0, candidate);
        vault.earn(work);
    }
}

/// @notice CDPVault._bank: warmth is banked on the position that shrank only by what the lag LOST to the
/// decrease. When another borrower's fresh debt has already been drawn, the honest borrower's cancellation
/// costs the lag nothing, so nothing is banked and the lag stays at the honest level for debt that is zero
/// seconds old. Cancel-then-draw warms from zero (the fix); draw-then-cancel does not (this test).
contract WarmthFollowsOrderingTest is Test {
    address private constant HONEST = address(0x4043);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    MockWorkOracle private oracle;
    WfoAttacker private attacker;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new WfoAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        // 1 IMD = 1/2000 ETH and 1 ETH = $2000: the vault prices IMD at exactly $1.
        WfoFeed primary = new WfoFeed(uint256(1 ether) * 1e18 / 2000 ether);
        WfoFeed health = new WfoFeed(0.85 ether); // mat 170, gap 50: redeemable below 220%
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new WfoMirror(primary))
        );
        stable = vault.stablecoin();
        oracle = MockWorkOracle(address(vault.oracle()));
        attacker = new WfoAttacker(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(HONEST, 2_000 ether);
        imd.mint(address(attacker), 2_000 ether);
        oracle.grantRights(address(attacker), 1_000 ether);
        vm.stopPrank();
        vm.startPrank(HONEST);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(2_000 ether); // 200%: inside the redeemable band
        vault.draw(1_000 ether);
        stable.transfer(address(attacker), 1_000 ether);
        vm.stopPrank();
        // Minting from work switched on the governed way.
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0.01 ether);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        // Three quiet days: the honest debt is in the paced supply.
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.backedDebt(), 1_000 ether, "the honest debt counts");
    }

    function _nextBlock() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// Transaction 1: the attacker opens 1,800 / 1,000. Transaction 2: cash 1,000 against the honest
    /// position. The only principal left is the attacker's, zero seconds old, and the lag still reads 1,000.
    /// Under the paced figures the ceiling is an aggregate: the swap leaves no ceiling that was not there before it, and
    /// the redemption against the honest position is paid no more than the backing that stood before the draw.
    function test_drawThenCancelAcrossTransactionsKeepsTheLagWarmForFreshDebt() public {
        uint256 lineBefore = vault.earnLine();
        uint256 backingBefore = vault.backingPerUnit();
        attacker.lockDraw(1_800 ether, 1_000 ether);
        attacker.cash(1_000 ether, HONEST);
        assertLt(vault.debtOf(HONEST), 1 ether, "the honest principal is cancelled (a fee residue remains)");
        _nextBlock();
        // Plus the paced debt's allowance for the 12 seconds that passed (10% an hour of the 100,000 floor, a quarter of it).
        assertLe(vault.earnLine(), lineBefore + 1 ether, "zero-second debt must not add to the work ceiling");
        assertLe(vault.backingPerUnit(), backingBefore, "nor lift the backing");
        vm.prank(address(attacker));
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(lineBefore + 1 ether + 1);
    }

    /// The whole round trip in one transaction: lock, draw, cash, earn. The draw clamps the paced debt to what the
    /// transaction began with less what it cancelled, so the earn is refused.
    function test_drawThenCancelThenEarnInOneTransactionIsRefused() public {
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        attacker.drawCancelEarn(1_800 ether, 1_000 ether, HONEST, 250 ether);
        assertEq(vault.totalEarned(), 0, "no work-minted imdUSD against zero-second debt");
    }
}