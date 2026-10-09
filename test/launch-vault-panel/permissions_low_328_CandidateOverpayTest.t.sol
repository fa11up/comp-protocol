// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Launch vault panel audit 2026-10-08 (job 5383ced0, pinned 9bd5f59): a proof the panel attached, kept as a regression
// test against the paced figures that replaced the per-position lag (CDPVault._pace). Changes from the panel's
// text: laggedNow() (removed) reads the live figures, and a "no lift" bound allows the paced backing's rise since the
// honest reading (BACKING_RISE_PER_HOUR), which is the guarantee the paced figures make. On 9bd5f59 it failed as reported.

// BACKING_HALF_LIFE's accepted case (delta panel #3) is bounded in its NatSpec by "at most the gap to par on the
// Treasury's reserve, since a position-funded payout stays pro rata". RedemptionWorsensRatio bounds the payout by
// the CANDIDATE'S collateral per unit of its debt, not by the book's backing: a candidate above par in the eligible
// band pays the lifted figure in full. So the same lift takes the gap to par from every eligible borrower's
// collateral as well, and the stated bound does not hold.

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract CoFeed is ISwarmFeed {
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

contract CoMirror is ISwarmFeed {
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

contract CoAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

contract CandidateOverpayTest is Test {
    address private constant UNDERWATER = address(0x0DD);
    address private constant CANDIDATE = address(0xCA1D);
    address private constant NEWCOMER = address(0xC0DE);

    uint256 private constant DOLLAR = uint256(1 ether) * 1e18 / 2000 ether; // IMD/ETH at $1

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    CoFeed private primary;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new CoAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        primary = new CoFeed(DOLLAR);
        CoFeed health = new CoFeed(0.85 ether); // mat 170
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new CoMirror(primary))
        );
        stable = vault.stablecoin();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(UNDERWATER, 170_000 ether);
        imd.mint(CANDIDATE, 30_000 ether);
        imd.mint(NEWCOMER, 2_000_000 ether);
        vm.stopPrank();
        // No Treasury sIMD at all: the reserve route is empty, so the only source is a candidate.
    }

    function _next() private {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _open(address who, uint256 collateral, uint256 debt) private {
        vm.startPrank(who);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(collateral);
        vault.draw(debt);
        vm.stopPrank();
    }

    function test_liftedFigureIsPaidFromABandCandidateNotOnlyTheReserve() public {
        _open(UNDERWATER, 170_000 ether, 100_000 ether); // 170%
        _open(CANDIDATE, 30_000 ether, 10_000 ether); // 300%
        vm.warp(block.timestamp + 2 days);
        _next();
        // IMD halves: UNDERWATER at 85%, CANDIDATE at 150% (eligible: under mat + gap = 220), book below par.
        primary.set(DOLLAR / 2);
        _next();
        uint256 honest = vault.backingPerUnit();
        uint256 honestAt = block.timestamp;
        emit log_named_uint("honest backing (85,000 + 15,000) / 110,000", honest);
        assertLt(honest, 1e18, "the scenario needs a book below par");
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        uint256 feeBps = vault.redemptionFeeBps(5_000 ether);
        uint256 honestPay = Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);

        // The accepted mechanism, exactly as the NatSpec states it: a loan several times the warm book, held for
        // minutes. (k = 500,000 / 110,000, about 4.5; fifteen minutes of warmed fraction reaches par.)
        _open(NEWCOMER, 2_000_000 ether, 500_000 ether); // 200% at $0.50
        vm.warp(block.timestamp + 15 minutes);
        _next();
        uint256 lifted = vault.backingPerUnit();
        emit log_named_uint("after the newcomer, fifteen minutes later", lifted);

        // The fee is quoted at the payout: the paced supply (the fee base) moved its allowed step meanwhile.
        feeBps = vault.redemptionFeeBps(5_000 ether);
        honestPay = Math.mulDiv(Math.mulDiv(5_000 ether, honest, 1e18) * (10_000 - feeBps) / 10_000, 1e18, price);
        // The newcomer redeems against the CANDIDATE, with an empty reserve.
        vm.prank(NEWCOMER);
        uint256 paid = vault.cash(5_000 ether, 0, CANDIDATE);
        emit log_named_uint("paid from the candidate for 5,000 imdUSD (raw IMD)", paid);
        emit log_named_uint("honest payout at most (raw IMD)", honestPay);
        // The newcomer unwinds at once; the candidate keeps the loss.
        vm.startPrank(NEWCOMER);
        vault.wipe(495_000 ether);
        vm.stopPrank();

        assertLe(paid, Math.mulDiv(honestPay, honest + _rise(honestAt), honest) + 1, "a position-funded redemption was paid the lifted figure, above the honest backing");
    }

    /// @dev The paced backing's allowed rise since `since` (CDPVault.BACKING_RISE_PER_HOUR): what the paced figures permit
    /// a figure to have climbed over the honest one, however much capital arrived in the meantime.
    function _rise(uint256 since) internal view returns (uint256) {
        return vault.BACKING_RISE_PER_HOUR() * (block.timestamp - since) / 1 hours;
    }
}
