// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR} from "../src/DeploymentConfig.sol";

/// @notice A minimal stand-in for a governed parameters source, to prove the seam exists.
/// @dev Deliberately not a proposal for how governance should work: no timelock, no bounds, no
/// access control. It exists to show that every economic knob can be sourced from outside the vault
/// without the vault changing, and that no authority can be.
contract MutableParameters {
    uint256 public ceiling = type(uint256).max;
    uint256 public protocolShare;
    uint256 public feeBps;
    uint256 public divergenceBps = 500;
    uint256 public markerBps = 1_000;

    function set(uint256 c, uint256 p, uint256 f, uint256 d, uint256 m) external {
        ceiling = c;
        protocolShare = p;
        feeBps = f;
        divergenceBps = d;
        markerBps = m;
    }
}

/// @notice A vault that reads its economics from a parameters contract instead of from constants.
/// @dev This is the whole of the change a governed deployment needs: five overrides. The collateral
/// token, the three feeds, the attester and the relayer are not reachable from here, because they are
/// immutables and source constants with no virtual and no setter. That asymmetry is the design.
contract GovernedVault is CDPVault {
    MutableParameters private immutable params;

    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_,
        MutableParameters params_
    ) CDPVault(imdToken_, compToken_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {
        params = params_;
    }

    function debtCeiling() public view override returns (uint256) {
        return params.ceiling();
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return params.protocolShare();
    }

    function stabilityFeeBps() public view override returns (uint256) {
        return params.feeBps();
    }

    function maxDivergenceBps() public view override returns (uint256) {
        return params.divergenceBps();
    }

    function markerShareBps() public view override returns (uint256) {
        return params.markerBps();
    }
}

contract GovernedParametersTest is Test {
    address private constant BORROWER = address(0xB0B);

    MutableParameters private params;
    GovernedVault private vault;
    MockIMD private imd;
    CompToken private comp;
    TestSwarmFeed private price;
    TestSwarmFeed private nhi;
    TestSwarmFeed private spot;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        price = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.9 ether);
        params = new MutableParameters();
        vault = new GovernedVault(
            address(imd), address(0), address(0), address(price), address(nhi), address(spot), params
        );
        comp = vault.compToken();
        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_000 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(1_000 ether);
        vm.stopPrank();
    }

    function test_everyEconomicKnobCanBeSourcedFromOutsideTheVault() public {
        assertEq(vault.debtCeiling(), type(uint256).max);
        assertEq(vault.stabilityFeeBps(), 0);
        params.set(250 ether, 3_333, 200, 400, 1_500);
        assertEq(vault.debtCeiling(), 250 ether, "ceiling follows the parameters contract");
        assertEq(vault.protocolBonusShareBps(), 3_333);
        assertEq(vault.stabilityFeeBps(), 200);
        assertEq(vault.maxDivergenceBps(), 400);
        assertEq(vault.markerShareBps(), 1_500);
    }

    /// @dev The knobs are not decorative: a tightened ceiling binds on the next mint.
    function test_aTightenedCeilingTakesEffectWithoutRedeployingTheVault() public {
        vm.prank(BORROWER);
        vault.mintCOMP(100 ether);
        params.set(100 ether, 0, 0, 500, 1_000);
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        vault.mintCOMP(1);
    }

    /// @dev And a tightened divergence bound starts refusing a gap it used to allow.
    function test_aTightenedDivergenceBoundBindsImmediately() public {
        spot.setValue(1.03 ether); // 300 bps apart: inside 500, outside 200
        vm.prank(BORROWER);
        vault.mintCOMP(1 ether);
        params.set(type(uint256).max, 0, 0, 200, 1_000);
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.PriceDivergence.selector);
        vault.mintCOMP(1 ether);
    }

    /// @dev The asymmetry that makes this safe: what prices the collateral is NOT reachable this way.
    /// The feeds are immutables with no setter, so a parameters source can tune the economics and can
    /// never change the price, the signer, or who may relay.
    function test_parametersCannotReachThePriceSource() public view {
        assertEq(address(vault.priceFeed()), address(price));
        assertEq(address(vault.spotFeed()), address(spot));
        assertEq(address(vault.nhiFeed()), address(nhi));
        assertEq(address(vault.imdToken()), address(imd));
    }
}
