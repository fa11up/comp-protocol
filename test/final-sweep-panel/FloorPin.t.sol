// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Final sweep panel audit 2026-10-08 (whole system, job 08a12413), low F1: the panel's proof, kept as written.
// The fee-base floor (CDPVault._feeBaseFloor, then 1,000 imdUSD) closed the launch pin for DUST only. At divisor 2
// any reserve-funded burn of 90 imdUSD or more against the floored base (90 / 1,000 / 2 = 4.5%) still STORED the
// cap as redemptionBaseRate for everyone, for 4.05 imdUSD of fee. It failed on 6085c8a (the stored rate was
// 0.045e18 and the 1 imdUSD quote 18 hours later read 210 bps) and passes with the floor at 100,000.

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract FpFeed is ISwarmFeed {
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

contract FpMirror is ISwarmFeed {
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

contract FpAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract ProofFloorPinTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant PINNER = address(0x919);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new FpAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        FpFeed primary = new FpFeed(uint256(1 ether) * 1e18 / 2000 ether); // IMD = $1
        FpFeed health = new FpFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new FpMirror(primary))
        );
        stable = vault.stablecoin();
        address treasury = address(vault.treasury());
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 400_000 ether);
        imd.mint(treasury, 1_000 ether); // the burn is reserve-funded: no fresh part, the quote is stored unchanged
        vm.stopPrank();
    }

    function test_ninetyImdUsdReserveFundedBurnStoresTheCapForEveryone() public {
        // Launch: the first loan is all the supply there is, and all of it is cold.
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(400_000 ether);
        vault.draw(100_000 ether);
        stable.transfer(PINNER, 90 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 12);
        // Warm supply is about 38.5 imdUSD, so the base is the 1,000 floor: 90 / 1,000 / 2 is the whole cap.
        vm.prank(PINNER);
        vault.cash(90 ether, 0, address(0));
        uint256 cap = (vault.REDEMPTION_FEE_CAP_BPS() - vault.REDEMPTION_FEE_FLOOR_BPS()) * 1e14;
        assertLt(vault.redemptionBaseRate(), cap, "a 90 imdUSD burn must not store the cap as everyone's base rate");
        // Eighteen hours later 7/8 of the supply is warm and the honest increase for 1 imdUSD is under a basis
        // point, so an honest quote is the 50 bps floor plus at most a few bps.
        vm.warp(block.timestamp + 18 hours);
        assertLt(vault.redemptionFeeBps(1 ether), 100, "the stored pin must not still price a 1 imdUSD burn above 1%");
    }
}