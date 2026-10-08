// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final vault panel audit 2026-10-08 (job 45bf3777), low F6: while most supply is new the warm fee base is
// near zero, and a dust redemption right after launch stored the 4.5% cap as everyone's base rate for days.
// The fee base is floored at 1,000 imdUSD (CDPVault._feeBaseFloor).

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";
import {AbFeed, AbMirror, AbAggregator} from "test/retry-panel/AdjacentTxBurn.t.sol";

contract FeeBaseFloorTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant DUSTER = address(0xD057);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new AbAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        AbFeed primary = new AbFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        AbFeed health = new AbFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new AbMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 400_000 ether);
        imd.mint(address(vault.treasury()), 1_000 ether); // the redemption is reserve-funded
        vm.stopPrank();
    }

    function test_aDustRedemptionRightAfterLaunchDoesNotStoreTheCap() public {
        // Launch: the first loan is all the supply there is, and all of it is new.
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(400_000 ether);
        vault.draw(100_000 ether);
        stable.transfer(DUSTER, 5 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 12);
        vm.prank(DUSTER);
        vault.cash(5 ether, 0, address(0));
        // 5 against the 1,000 floor at divisor 2 is 25 bps of base, not the 450 bps cap.
        assertLe(vault.redemptionBaseRate(), 0.0025e18 + 1, "dust must not store the cap for everyone");
        assertLt(vault.redemptionFeeBps(0), 100, "and the next redeemer pays near the floor");
    }
}
