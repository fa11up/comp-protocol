// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {Parameters} from "src/Parameters.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

/// @dev A borrower that is a contract, so a wipe and a redraw can share one transaction.
contract Churner {
    ParameterizedVault private immutable vault;
    MockIMD private immutable imd;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd = imd_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function open(uint256 collateral, uint256 debt) external {
        vault.lock(collateral);
        vault.draw(debt);
    }

    function wipeAndRedraw(uint256 amount) external {
        vault.wipe(amount);
        vault.draw(amount);
    }

    function freeAndRelock(uint256 amount) external {
        vault.free(amount);
        vault.lock(amount);
    }

    function wipe(uint256 amount) external {
        vault.wipe(amount);
    }

    function draw(uint256 amount) external {
        vault.draw(amount);
    }
}

contract LagFeed is ISwarmFeed {
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

contract LagMirror is ISwarmFeed {
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

contract LagAggregator {
    /// @dev A pure constant: `vm.etch` copies code only, so a storage initializer would read as zero.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}


/// @notice D1 (launch audit 2026-10-05, vault panel, medium): capital that arrived in an earlier
/// transaction counted in full toward the work ceiling and the redemption backing cap, so borrow ->
/// earn/cash -> unwind across adjacent transactions minted unbacked imdUSD or redeemed at par while
/// backing was 0.4. The fix is lagged capital (CDPVault.laggedNow): increases warm up over a day,
/// decreases count at once. It is DORMANT until the wage is raised, so these tests raise it through
/// governance; the faucet oracle supplies rights directly, as in the judge's proof.
contract LaggedBackingTest is Test {
    address private constant WORKER = address(0xCA);
    address private constant ATTACKER = address(0xBAD);
    address private constant HELPER = address(0x4E1);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    MockWorkOracle private oracle;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new LagAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        // 1 IMD = 1/2000 ETH and 1 ETH = $2000, so the vault prices IMD at exactly $1.
        LagFeed primary = new LagFeed(uint256(1 ether) * 1e18 / 2000 ether);
        LagFeed health = new LagFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new LagMirror(primary))
        );
        stable = vault.stablecoin();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        oracle.grantRights(WORKER, 1_000 ether);
        imd.mint(WORKER, 2_000 ether);
        imd.mint(ATTACKER, 2_000 ether);
        imd.mint(HELPER, 200 ether);
        vm.stopPrank();
        vm.prank(HELPER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(WORKER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(ATTACKER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// @dev Minting from work switched on the governed way: propose a wage, wait out the timelock, apply.
    function _workMintingOn() private {
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0.01 ether);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        assertGt(params.wage(), 0);
    }

    /// @dev imdUSD for the stability fee a borrower accrued, borrowed by an unrelated position (the only
    /// way imdUSD exists beyond what the borrower drew).
    function _feeMoney(address to) private {
        vm.startPrank(HELPER);
        vault.lock(200 ether);
        vault.draw(50 ether);
        stable.transfer(to, 50 ether);
        vm.stopPrank();
    }

    function _nextBlock() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_dormantWhileTheWageIsZero() public {
        assertEq(vault.parameters().wage(), 0, "launch configuration");
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        // The lag is tracked from deployment, but backing reads the live figures while it is dormant.
        (uint256 lagDebt,) = vault.laggedNow();
        assertEq(lagDebt, 0, "tracked: no time has passed");
        assertEq(vault.earnLine(), 250 ether, "dormant: the ceiling reads live debt, as before the fix");
    }

    /// @dev The judge's attack, one block apart instead of one transaction apart. Fails without the fix.
    function test_withWorkMintingOnAdjacentTransactionDebtAuthorisesNoWork() public {
        _workMintingOn();
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        _nextBlock();
        assertLt(vault.earnLine(), 0.1 ether, "debt one block old earns about 0.014% of its credit");
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(250 ether);
        _feeMoney(WORKER);
        vm.startPrank(WORKER);
        vault.wipe(vault.debtOf(WORKER));
        vault.free(2_000 ether);
        vm.stopPrank();
        assertEq(vault.totalEarned(), 0, "no work-minted imdUSD outlives the debt");
    }

    function test_heldCapitalWarmsUpOverADay() public {
        _workMintingOn();
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(vault.earnLine(), 125 ether, 1e9, "half the warm-up, half the credit");
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(vault.earnLine(), 250 ether, 1e9, "a day held earns full credit");
        vm.prank(WORKER);
        vault.earn(250 ether);
        assertEq(vault.totalEarned(), 250 ether);
    }

    function test_aDecreaseCountsAtOnce() public {
        _workMintingOn();
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(vault.earnLine(), 250 ether, 1e9);
        vm.prank(WORKER);
        vault.wipe(500 ether);
        (uint256 lagDebt,) = vault.laggedNow();
        assertLe(lagDebt, vault.totalDebt(), "the lag never stands above the live debt");
        assertLe(vault.earnLine(), Math.mulDiv(vault.totalDebt(), 2_500, 10_000) + 1, "repaid debt stops counting at once");
    }

    /// @dev The redemption half of D1: an attacker's fresh capital must not lift backing per imdUSD (and
    /// so the redemption payout) the block after it arrives.
    function test_withWorkMintingOnFreshCapitalDoesNotLiftBackingPerUnit() public {
        _workMintingOn();
        // An honest borrower backs a day of work, then leaves: 250 work-minted imdUSD remain, backed by nothing.
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(WORKER);
        vault.earn(250 ether);
        stable.transfer(ATTACKER, 250 ether);
        vm.stopPrank();
        _feeMoney(WORKER);
        vm.startPrank(WORKER);
        vault.wipe(vault.debtOf(WORKER));
        vault.free(2_000 ether);
        vm.stopPrank();
        uint256 before = vault.backingPerUnit();

        // The attacker brings real capital for one block.
        vm.startPrank(ATTACKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        _nextBlock();
        assertLt(vault.backingPerUnit(), before + 0.01e18, "capital one block old does not lift backing");
    }

    // --- final panel audits 2026-10-07 ---------------------------------------------------------------

    /// @dev Vault and governance panels, medium. Rights are priced at claim and outlived the wage, so at
    /// wage 0 they stayed spendable through earn with the lag off. earn is now refused at wage 0, before
    /// and after a wage cycle, and works again (with the lag on) the moment a wage is set.
    function test_earnIsRefusedAtWageZeroEvenWithRightsInHand() public {
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.expectRevert(CDPVault.WorkMintingOff.selector);
        vault.earn(1);
        vm.stopPrank();
        _workMintingOn();
        vm.warp(block.timestamp + 3 days);
        vm.prank(WORKER);
        vault.earn(1 ether);
        assertEq(vault.totalEarned(), 1 ether, "on with a wage, lagged");
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWage(0);
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        assertGt(oracle.mintingRights(WORKER), 0, "the rights are still there");
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkMintingOff.selector);
        vault.earn(1);
    }

    /// @dev Governance panel, medium (the griefing half): one earn(1) during a pending proposeWorkOracle
    /// made totalEarned nonzero and the replacement unapplyable for good. It can no longer happen.
    function test_aRightsHolderCannotBlockAnOracleReplacement() public {
        MockWorkOracle next = new MockWorkOracle(address(vault));
        Parameters params = vault.parameters();
        vm.prank(APPROVED_OPERATOR);
        params.proposeWorkOracle(address(next));
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.expectRevert(CDPVault.WorkMintingOff.selector);
        vault.earn(1);
        vm.stopPrank();
        vm.warp(block.timestamp + params.TIMELOCK());
        params.applyPending();
        assertEq(address(vault.oracle()), address(next), "the replacement applied");
    }

    /// @dev Vault panel, medium. A borrower's atomic wipe-and-redraw clamped the lagged backing to the
    /// low point and it only warmed back over a day. The clamp is now netted per transaction.
    function test_anAtomicWipeAndRedrawLeavesTheLagWhereItWas() public {
        _workMintingOn();
        Churner churner = new Churner(vault, imd);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(churner), 2_000 ether);
        churner.open(2_000 ether, 1_000 ether);
        vm.warp(block.timestamp + 3 days);
        _feeMoney(address(churner)); // a checkpoint, and imdUSD for the fees
        (uint256 debtBefore, uint256 securedBefore) = vault.laggedNow();
        uint256 backingBefore = vault.backingPerUnit();
        assertGt(debtBefore, 0);
        churner.wipeAndRedraw(500 ether);
        assertEq(vault.laggedDebt(), debtBefore, "debt that left and came back in one transaction did not leave");
        assertEq(vault.laggedSecured(), securedBefore, "nor did the collateral");
        assertEq(vault.backingPerUnit(), backingBefore, "and redeemers are paid against the same backing");
        churner.freeAndRelock(100 ether);
        assertEq(vault.laggedSecured(), securedBefore, "free-and-relock in one transaction likewise");
        // Across two transactions it is a decrease that lasted, and it re-warms as before.
        churner.wipe(500 ether);
        churner.draw(500 ether);
        assertLt(vault.laggedDebt(), debtBefore, "a decrease across transactions still counts at once");
    }

    /// @dev Oracle panel, low. A reverting ETH/USD leg read as price 0 and an ungated wipe wrote a zero
    /// secured term that outlived the outage, shutting cash for a day. The term is now kept.
    function test_aDeadLegNeitherZeroesTheSecuredTermNorTheLag() public {
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        _feeMoney(WORKER);
        uint256 secured = vault.securedCollateral();
        (, uint256 laggedBefore) = vault.laggedNow();
        uint256 backing = vault.backingPerUnit();
        assertGt(secured, 0);
        vm.mockCallRevert(CHAINLINK_ETH_USD, abi.encodeWithSignature("latestRoundData()"), "dead");
        vm.prank(WORKER);
        vault.wipe(1 ether);
        assertEq(vault.securedCollateral(), secured, "the term is kept while the price cannot be read");
        assertEq(vault.laggedSecured(), laggedBefore, "and the lag is not clamped down");
        vm.clearMockedCalls();
        assertEq(vault.backingPerUnit(), backing, "so redemption is whole the moment the leg is back");
    }

    /// @dev Vault panel, low. At whole seconds a tranche that dwarfed the fresh record rounded its weighted
    /// date to the present, and draw/wipe pairs kept seasoned principal fresh forever, so a redemption
    /// against it never raised the base rate. Dated in 1e18-scaled seconds, the record keeps its age.
    function test_drawAndWipePairsDoNotKeepSeasonedDebtFresh() public {
        address holder = address(0x401D);
        vm.prank(APPROVED_OPERATOR);
        imd.mint(WORKER, 1_000_000 ether);
        vm.startPrank(WORKER);
        vault.lock(800_000 ether);
        vault.draw(10 ether);
        stable.transfer(holder, 1 ether);
        vm.stopPrank();
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 3; ++i) {
            vm.warp(t0 + i * 11 hours);
            vm.startPrank(WORKER);
            vault.draw(400_000 ether);
            vault.wipe(400_000 ether);
            vm.stopPrank();
        }
        // Down to 200%, below mat + gap, so it is a redemption candidate.
        uint256 debt = vault.debtOf(WORKER);
        (uint256 held,) = vault.positions(WORKER);
        vm.prank(WORKER);
        vault.free(held - debt * 2);
        assertEq(vault.redemptionBaseRate(), 0);
        vm.prank(holder);
        vault.cash(1 ether, 0, WORKER);
        assertGt(vault.redemptionBaseRate(), 0, "principal outstanding for 33 hours is seasoned, so the base rate rises");
    }
}
