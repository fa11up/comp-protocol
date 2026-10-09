// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// Final audit 2026-10-08: the accepted warm-fraction item (delta panel #3, low) states its bound as "gains at most
// the gap to par on the Treasury's sIMD, since a position-funded payout stays pro rata". RedemptionWorsensRatio
// only forbids a payout above the candidate's own collateral/debt fraction; it pays the lifted figure to any
// candidate whose ratio is at least backing x (1 - fee). So with NO reserve at all, a newcomer's loan lifts the
// lagged figure and a redemption against a 140% candidate takes the candidate's collateral at the lifted figure.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract ClFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        set(v);
    }

    function set(uint256 v) public {
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

contract ClMirror is ISwarmFeed {
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

contract ClAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract CandidateLiftTest is Test {
    address private constant UNDER = address(0x1111);
    address private constant CANDIDATE = address(0x2222);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether;

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    ClFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new ClAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new ClFeed(DOLLAR);
        ClFeed health = new ClFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new ClMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(UNDER, 200_000 ether);
        imd.mint(CANDIDATE, 80_000 ether);
        imd.mint(NEWCOMER, 5_000_000 ether);
        vm.stopPrank();
        // No reserve: the Treasury holds nothing.
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _open(address who, uint256 c, uint256 d) private {
        vm.startPrank(who);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(c);
        vault.draw(d);
        vm.stopPrank();
    }

    function test_candidateRoutePaysTheLiftedFigureWithNoReserve() public {
        _open(UNDER, 200_000 ether, 100_000 ether); // 200%
        _open(CANDIDATE, 80_000 ether, 20_000 ether); // 400%
        vm.warp(block.timestamp + 2 days);
        _next();
        primary.set(DOLLAR * 35 / 100); // IMD to $0.35: UNDER at 70%, CANDIDATE at 140%
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest backing (no reserve)", honest);
        assertLt(honest, 1e18);
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 feeBps = vault.redemptionFeeBps(20_000 ether);
        uint256 honestPay =
            Math.mulDiv(Math.mulDiv(20_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        // The newcomer: an 880,000 loan (LINE) against 5,000,000 IMD, then ten minutes.
        _open(NEWCOMER, 5_000_000 ether, 880_000 ether);
        vm.warp(block.timestamp + 10 minutes);
        _next();
        uint256 lifted = vault.backingPerUnit();
        emit log_named_uint("lifted backing after ten minutes", lifted);

        // The newcomer redeems against the 140% candidate: no reserve is touched.
        vm.prank(NEWCOMER);
        uint256 paid = vault.cash(20_000 ether, 0, CANDIDATE);
        emit log_named_uint("paid against the candidate (raw IMD)", paid);
        emit log_named_uint("honest payout (raw IMD)", honestPay);
        emit log_named_uint("candidate's collateral lost above honest (raw IMD)", paid - honestPay);
        assertLe(paid, Math.mulDiv(honestPay, honest + _rise(honestAt), honest) + 1, "candidate-funded redemption paid above the honest backing");
    }

    /// @dev The paced backing's allowed rise since `since` (CDPVault.BACKING_RISE_PER_HOUR): what the paced figures permit
    /// a figure to have climbed over the honest one, however much capital arrived in the meantime.
    function _rise(uint256 since) internal view returns (uint256) {
        return vault.BACKING_RISE_PER_HOUR() * (block.timestamp - since) / 1 hours;
    }
}
