// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Retry2 panel audit 2026-10-08 (vault, job a2640621): the panel's reproduction of the medium F3 (cold principal, held one block or repaid in the redeeming call, diluted the fee),
// kept as written. It failed on 24337a2 and passes on the fix.

// The lagged fee base lags decreases of warm principal only: an increase counts at once, so a cold draw held
// for one block (or repaid in the same call as the redemption) dilutes the fee and the stored base rate.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {SmallFloorVault} from "test/helpers/SmallFloorVault.sol"; // the 1,000 floor these figures assume
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract FdlFeed is ISwarmFeed {
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

contract FdlMirror is ISwarmFeed {
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

contract FdlAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract FdlActor {
    ParameterizedVault private immutable vault;

    constructor(ParameterizedVault vault_, MockIMD imd_) {
        vault = vault_;
        imd_.approve(address(vault_), type(uint256).max);
    }

    function lockDraw(uint256 c, uint256 d) external {
        vault.lock(c);
        vault.draw(d);
    }

    function wipeThenCash(uint256 w, uint256 a) external returns (uint256) {
        vault.wipe(w);
        return vault.cash(a, 0, address(0));
    }

    function wipe(uint256 w) external {
        vault.wipe(w);
    }

    function cash(uint256 a) external returns (uint256) {
        return vault.cash(a, 0, address(0));
    }
}

contract FeeDilutionTest is Test {
    address private constant HOLDER = address(0x401D);
    address private constant OTHER = address(0x07E);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    FdlActor private actor;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new FdlAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        FdlFeed primary = new FdlFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        FdlFeed health = new FdlFeed(0.85 ether); // mat 170, gap 50
        vault = new SmallFloorVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new FdlMirror(primary))
        );
        stable = vault.stablecoin();
        actor = new FdlActor(vault, imd);
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(address(actor), 100_000 ether);
        imd.mint(OTHER, 10_000 ether);
        imd.mint(address(vault.treasury()), 10_000 ether); // reserve-funded redemptions
        vm.stopPrank();
        vm.prank(OTHER);
        imd.approve(address(vault), type(uint256).max);
        // A warm supply of 1,000, held by HOLDER.
        vm.startPrank(OTHER);
        vault.lock(3_000 ether);
        vault.draw(1_000 ether);
        stable.transfer(HOLDER, 1_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        assertEq(stable.totalSupply(), 1_000 ether);
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// Honest: redeeming 90 of a 1,000 warm supply is a 4.5% increase (the cap).
    function test_honestFeeForNinetyOfAThousand() public {
        assertEq(vault.redemptionFeeBps(90 ether), 500);
        vm.prank(HOLDER);
        vault.cash(90 ether, 0, address(0));
        assertEq(vault.redemptionBaseRate(), 0.045e18);
    }

    /// A draw one block before the redemption, repaid one block after: the fee is quoted against 10,000.
    /// EXPECTED: the cold 9,000 does not dilute the fee (quoted 500 bps, base about 0.045e18; a fix that cools
    /// the cold principal for the 12 seconds it lived may read a hair under). ACTUAL: 95 bps, base 0.0045e18.
    function test_coldDrawOneBlockEarlierDilutesTheFee() public {
        actor.lockDraw(17_000 ether, 9_000 ether); // 90% of the resulting supply, zero seconds old
        _next();
        uint256 quoted = vault.redemptionFeeBps(90 ether);
        vm.prank(HOLDER);
        vault.cash(90 ether, 0, address(0));
        uint256 base = vault.redemptionBaseRate();
        _next();
        actor.wipe(9_000 ether);
        emit log_named_uint("quoted fee bps (honest 500)", quoted);
        emit log_named_uint("base rate after (honest 0.045e18)", base);
        assertApproxEqAbs(stable.totalSupply(), 910 ether, 1e16, "supply is 910 after the churn (fee dust aside)");
        assertGe(quoted, 495, "cold principal must not dilute the fee");
        assertGe(base, 0.0445e18, "cold principal must not depress the base rate");
    }

    /// Same transaction: repay the cold principal and redeem in one call. The NatSpec says a repayment of cold
    /// principal counts at once; `_laggedSupplyFrom` floors at the pre-wipe supply, so it does not.
    function test_wipeOfColdPrincipalThenCashInOneTransactionReadsThePreWipeSupply() public {
        actor.lockDraw(17_000 ether, 9_000 ether);
        _next();
        vm.prank(HOLDER);
        stable.transfer(address(actor), 90 ether);
        actor.wipeThenCash(9_000 ether, 90 ether);
        uint256 base = vault.redemptionBaseRate();
        emit log_named_uint("base rate after (honest 0.045e18)", base);
        assertApproxEqAbs(stable.totalSupply(), 910 ether, 1e15, "supply is 910 after the churn");
        assertGe(base, 0.0445e18, "cold principal repaid in the same call must count at once");
    }
}