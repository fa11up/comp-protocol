// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry panel audit 2026-10-07 (vault, job 3226aaed): the panel's reproduction of a medium (one bank date for both sides, re-dated by every decrease),
// kept as it was written apart from reading the lag through laggedNow(). It failed on 973369e and passes on the fix.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract BeFeed is ISwarmFeed {
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

contract BeMirror is ISwarmFeed {
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

contract BeAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice CDPVault._bank: one `bankAt` for both banks, re-dated by every decrease that costs the lag anything
/// (line 922), and the expiry test (line 910) runs only when the bank OF THE SIDE BEING CHANGED is nonzero.
/// So (1) a one-wei-a-day decrease keeps a bank of any size alive indefinitely, and (2) a decrease on one
/// side revives the other side's expired bank. The NatSpec at 902-903 promises that "a position that stays
/// smaller for a day forfeits the bank and warms again like any new capital".
contract BankExpiryTest is Test {
    function _ld() private view returns (uint256 d) { (d,) = vault.laggedNow(); }
    function _ls() private view returns (uint256 x) { (, x) = vault.laggedNow(); }
    address private constant BORROWER = address(0xB0B);
    address private constant HELPER = address(0x4E1);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new BeAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        BeFeed primary = new BeFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        BeFeed health = new BeFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new BeMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 4_000 ether);
        imd.mint(HELPER, 201 ether);
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(HELPER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// @dev Trickle: a wei of principal a day keeps a 500 bank alive past its day.
    function test_aDailyWeiOfRepaymentKeepsTheBankAlivePastItsDay() public {
        vm.startPrank(BORROWER);
        vault.lock(4_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.startPrank(HELPER);
        vault.lock(200 ether);
        vault.draw(50 ether);
        stable.transfer(BORROWER, 50 ether); // fee money
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        vm.prank(HELPER);
        vault.lock(1); // a checkpoint: the lag is warm in storage
        assertEq(_ld(), 1_050 ether);

        // Day 0: 500 leaves and is banked.
        vm.prank(BORROWER);
        vault.wipe(500 ether);
        assertEq(_ld(), vault.totalDebt(), "a decrease counts at once");
        // Days 1, 2, 3: a repayment just above the day's fee, each one re-dating the bank.
        for (uint256 day = 1; day <= 3; ++day) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(BORROWER);
            vault.wipe(1 ether);
        }
        uint256 before = _ld();
        // Day 3, same block: the 500 that left three days ago comes back.
        vm.prank(BORROWER);
        vault.draw(500 ether);
        // EXPECTED (NatSpec 902-903): forfeited after a day away; the lag rises by at most the few imdUSD
        // the trickle retired within the last day. ACTUAL: it rises by 500 at once.
        assertLt(_ld() - before, 10 ether, "warmth banked three days ago must not be credited back");
    }

    /// @dev Cross-side: a one-wei principal repayment revives a month-old collateral bank.
    function test_aOneWeiRepaymentRevivesAnExpiredCollateralBank() public {
        vm.startPrank(BORROWER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        // The term is collateral-bound (2,000 < 2 x 1,000): free 290 lowers it to 1,710 and banks 290.
        vm.prank(BORROWER);
        vault.free(290 ether);
        (, uint256 lagSecured) = vault.laggedNow();
        assertEq(lagSecured, 1_710 ether);
        assertEq(_ls(), 1_710 ether);

        vm.warp(block.timestamp + 30 days);
        // Debt-side decrease of one wei of principal: bankDebt == 0, so no expiry test runs, and bankAt is re-dated.
        uint256 oneWeiOfPrincipal = vault.stabilityFeeOf(BORROWER) + 1;
        vm.prank(BORROWER);
        vault.wipe(oneWeiOfPrincipal);
        vm.prank(BORROWER);
        vault.lock(290 ether);
        // EXPECTED: the 290, away for a month, warms from zero: laggedSecured stays about 1,710.
        // ACTUAL: 2,000 - 2 wei: the month-old bank is credited in full.
        assertLe(_ls(), 1_711 ether, "an expired bank must not be revived by the other side");
    }
}