// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {SwarmFeed} from "../src/SwarmFeed.sol";

contract SelfContainedInvariantFactory {
    function deploy(address imd, address price, address nhi, address spot) external returns (CDPVault) {
        return new CDPVault{salt: bytes32(uint256(42))}(imd, address(0), address(0), price, nhi, spot);
    }
}

/// @dev Exercises the constructor-created token and oracle against real, reporter-seeded feeds.
/// Fixed market values isolate deployment, borrower accounting and the feed freshness boundary;
/// the existing protocol invariant separately exercises market shocks and liquidations.
contract SelfContainedDeploymentHandler is Test {
    address public constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    address private constant RELAYER = address(0xD001);
    address private constant ORIGIN = address(0xD002);
    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;
    uint256 public constant INITIAL_RIGHTS = 1_000_000 ether;

    SelfContainedInvariantFactory public factory;
    MockIMD public imd;
    CDPVault public vault;
    CompToken public comp;
    MockWorkOracle public oracle;
    PriceFeed public priceFeed;
    NhiFeed public nhiFeed;
    address[4] public actors = [address(0xD101), address(0xD102), address(0xD103), address(0xD104)];
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public debtMinted;
    mapping(address => uint256) public workMinted;
    mapping(address => uint256) public repaid;
    mapping(address => uint256) public sent;
    mapping(address => uint256) public received;

    constructor() {
        factory = new SelfContainedInvariantFactory();
        imd = new MockIMD();
        // Authority is pinned in DeploymentConfig; OPERATOR below IS the pinned relayer and reporter.
        priceFeed = new PriceFeed(1 days, 2000);
        nhiFeed = new NhiFeed(1 days, 2000);
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(priceFeed));
        vm.prank(RELAYER, ORIGIN);
        vault = factory.deploy(address(imd), address(priceFeed), address(nhiFeed), address(spot));
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));
        assertEq(comp.vault(), address(vault), "token linked by constructor");
        assertEq(oracle.vault(), address(vault), "oracle linked by constructor");

        // No initialization call. The only privileged transactions seed feeds and fund mock faucets.
        vm.startPrank(OPERATOR);
        priceFeed.report(1 ether);
        nhiFeed.report(0.85 ether);
        for (uint256 i; i < actors.length; ++i) {
            imd.mint(actors[i], INITIAL_BALANCE);
            oracle.grantRights(actors[i], INITIAL_RIGHTS);
        }
        vm.stopPrank();
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            vm.startPrank(actor);
            imd.approve(address(vault), type(uint256).max);
            vault.depositCollateral(300 ether);
            vault.mintCOMP(100 ether);
            vault.mintFromWork(25 ether);
            vm.stopPrank();
            deposited[actor] = 300 ether;
            debtMinted[actor] = 100 ether;
            workMinted[actor] = 25 ether;
        }
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 available = _min(imd.balanceOf(actor), 1000 ether);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.depositCollateral(amount);
        deposited[actor] += amount;
    }

    function mintDebt(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 maximumDebt = collateral * 2 / 3;
        if (maximumDebt <= debt) return;
        amount = bound(amount, 1, _min(maximumDebt - debt, 1000 ether));
        vm.prank(actor);
        vault.mintCOMP(amount);
        debtMinted[actor] += amount;
    }

    function mintWork(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        uint256 rights = oracle.mintingRights(actor);
        if (rights == 0) return;
        amount = bound(amount, 1, _min(rights, 1000 ether));
        vm.prank(actor);
        vault.mintFromWork(amount);
        workMinted[actor] += amount;
    }

    function repay(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (, uint256 debt) = vault.positions(actor);
        uint256 available = _min(debt, comp.balanceOf(actor));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        vault.repayCOMP(amount);
        repaid[actor] += amount;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 requiredCollateral = (debt * 3 + 1) / 2;
        if (collateral <= requiredCollateral) return;
        amount = bound(amount, 1, collateral - requiredCollateral);
        vm.prank(actor);
        vault.withdrawCollateral(amount);
        withdrawn[actor] += amount;
    }

    function transferCOMP(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        amount = bound(amount, 0, comp.balanceOf(from));
        vm.prank(from);
        comp.transfer(to, amount);
        sent[from] += amount;
        received[to] += amount;
    }

    function rejectInvalidBorrowerActions(uint256 seed) external {
        address actor = actors[seed % 4];
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        uint256 rights = oracle.mintingRights(actor);
        bytes32 beforeState = _stateDigest(actor);
        vm.startPrank(actor);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(collateral * 2 / 3 - debt + 1);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(debt + 1);
        vm.expectRevert(CDPVault.InsufficientRights.selector);
        vault.mintFromWork(rights + 1);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(collateral + 1);
        if (debt != 0) {
            vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
            vault.withdrawCollateral(collateral - (debt * 3 + 1) / 2 + 1);
        }
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.depositCollateral(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.mintCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.mintFromWork(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.repayCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.withdrawCollateral(0);
        vm.stopPrank();
        assertEq(_stateDigest(actor), beforeState, "rejected borrower calls are atomic");
    }

    function rejectUnauthorizedActions(uint256 seed) external {
        address actor = actors[seed % 4];
        address[3] memory callers = [OPERATOR, address(factory), actor];
        bytes32 beforeState = _stateDigest(actor);
        vm.startPrank(callers[(seed / 4) % 3], OPERATOR);
        vm.expectRevert(CompToken.AlreadyInitialized.selector);
        comp.setVault(actor);
        vm.expectRevert(CompToken.Unauthorized.selector);
        comp.mint(actor, 1);
        vm.expectRevert(CompToken.Unauthorized.selector);
        comp.burn(actor, 1);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.consumeRights(actor, 1);
        vm.stopPrank();
        vm.startPrank(actor, OPERATOR);
        vm.expectRevert(MockIMD.Unauthorized.selector);
        imd.mint(actor, 1);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.grantRights(actor, 1);
        vm.expectRevert(SwarmFeed.UnauthorizedReporter.selector);
        priceFeed.report(1 ether);
        vm.expectRevert(SwarmFeed.UnauthorizedReporter.selector);
        nhiFeed.report(0.85 ether);
        vm.stopPrank();
        assertEq(_stateDigest(actor), beforeState, "rejected authority calls are atomic");
    }

    function expireAndRefreshFeeds(uint256 seed, bool refreshPriceFirst) external {
        address actor = actors[seed % 4];
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(OPERATOR);
        if (refreshPriceFirst) priceFeed.report(1 ether);
        else nhiFeed.report(0.85 ether);
        bytes32 beforeState = _stateDigest(actor);
        (, uint256 debt) = vault.positions(actor);
        vm.startPrank(actor);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.mintFromWork(1);
        if (debt != 0) {
            vm.expectRevert(CDPVault.StaleFeed.selector);
            vault.withdrawCollateral(1);
        }
        vm.stopPrank();
        assertEq(_stateDigest(actor), beforeState, "one fresh feed cannot authorize borrowing");
        vm.prank(OPERATOR);
        if (refreshPriceFirst) nhiFeed.report(0.85 ether);
        else priceFeed.report(1 ether);
    }

    function _stateDigest(address actor) private view returns (bytes32) {
        (uint256 collateral, uint256 debt) = vault.positions(actor);
        return keccak256(
            abi.encode(
                collateral,
                debt,
                comp.totalSupply(),
                comp.balanceOf(actor),
                vault.totalWorkMinted(),
                oracle.mintingRights(actor),
                imd.totalSupply(),
                imd.balanceOf(actor),
                imd.balanceOf(address(vault))
            )
        );
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SelfContainedDeploymentInvariantTest is StdInvariant, Test {
    SelfContainedDeploymentHandler internal handler;

    function setUp() public {
        handler = new SelfContainedDeploymentHandler();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mintDebt.selector;
        selectors[2] = handler.mintWork.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.transferCOMP.selector;
        selectors[6] = handler.rejectInvalidBorrowerActions.selector;
        selectors[7] = handler.rejectUnauthorizedActions.selector;
        selectors[8] = handler.expireAndRefreshFeeds.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_constructorLinksSupplyRightsAndCustodyRemainConsistent() public view {
        CDPVault vault = handler.vault();
        CompToken comp = handler.comp();
        uint256 debts;
        uint256 work;
        uint256 collateral;
        uint256 walletCOMP;
        uint256 walletIMD;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 c, uint256 d) = vault.positions(actor);
            debts += d;
            collateral += c;
            work += handler.workMinted(actor);
            walletCOMP += comp.balanceOf(actor);
            walletIMD += handler.imd().balanceOf(actor);
            assertEq(c, handler.deposited(actor) - handler.withdrawn(actor), "collateral history");
            assertEq(d, handler.debtMinted(actor) - handler.repaid(actor), "debt history");
            assertEq(
                comp.balanceOf(actor),
                handler.debtMinted(actor) + handler.workMinted(actor) + handler.received(actor) - handler.repaid(actor)
                    - handler.sent(actor),
                "COMP wallet history"
            );
            assertEq(
                handler.imd().balanceOf(actor),
                handler.INITIAL_BALANCE() + handler.withdrawn(actor) - handler.deposited(actor),
                "IMD wallet history"
            );
            assertEq(
                handler.oracle().mintingRights(actor) + handler.workMinted(actor),
                handler.INITIAL_RIGHTS(),
                "consumed work cannot return on repayment"
            );
            assertLe(d * 3, c * 2, "all borrower positions stay collateralized");
        }
        assertGt(work, 0, "work issuance remains part of the supply identity");
        assertEq(vault.totalWorkMinted(), work, "independent work history");
        assertEq(comp.totalSupply(), debts + vault.totalWorkMinted(), "supply equals summed debt plus work");
        assertEq(comp.totalSupply(), walletCOMP, "COMP custody");
        assertEq(handler.imd().balanceOf(address(vault)), collateral, "vault IMD custody");
        assertEq(handler.imd().totalSupply(), walletIMD + collateral, "all IMD accounted for");
        assertEq(address(vault.imdToken()), address(handler.imd()));
        assertEq(address(vault.compToken()), address(comp));
        assertEq(comp.vault(), address(vault), "token remains bound");
        assertEq(address(vault.oracle()), address(handler.oracle()), "oracle remains bound");
        assertEq(handler.oracle().vault(), address(vault), "oracle consumer remains bound");
        assertEq(address(vault.priceFeed()), address(handler.priceFeed()));
        assertEq(address(vault.nhiFeed()), address(handler.nhiFeed()));
    }

    /// @dev Every random sequence can close all debt and redeem every recorded deposit.
    function afterInvariant() public {
        for (uint256 i = 1; i < 4; ++i) {
            handler.transferCOMP(i, 0, type(uint256).max);
        }
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 collateral, uint256 debt) = handler.vault().positions(actor);
            if (debt != 0) {
                if (i != 0) handler.transferCOMP(0, i, debt);
                handler.repay(i, debt);
            }
            if (collateral != 0) handler.withdraw(i, collateral);
            (uint256 remainingCollateral, uint256 remainingDebt) = handler.vault().positions(actor);
            assertEq(remainingCollateral, 0, "all deposits redeemable");
            assertEq(remainingDebt, 0, "all debt repayable");
        }
        assertEq(handler.comp().totalSupply(), handler.vault().totalWorkMinted());
        assertEq(handler.comp().balanceOf(handler.actors(0)), handler.vault().totalWorkMinted());
        assertEq(handler.imd().balanceOf(address(handler.vault())), 0);
        invariant_constructorLinksSupplyRightsAndCustodyRemainConsistent();
    }

    function test_handlerExercisesConstructorOnlyBorrowingFailuresAndFullExit() public {
        handler.deposit(0, 30 ether);
        handler.mintDebt(0, 10 ether);
        handler.mintWork(0, 7 ether);
        handler.transferCOMP(0, 1, 5 ether);
        handler.repay(1, 20 ether);
        handler.withdraw(1, 20 ether);
        handler.rejectInvalidBorrowerActions(0);
        handler.rejectUnauthorizedActions(0);
        handler.rejectUnauthorizedActions(4);
        handler.rejectUnauthorizedActions(8);
        handler.expireAndRefreshFeeds(0, true);
        handler.expireAndRefreshFeeds(1, false);
        invariant_constructorLinksSupplyRightsAndCustodyRemainConsistent();
        afterInvariant();
    }
}
