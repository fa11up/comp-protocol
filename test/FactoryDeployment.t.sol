// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {FEED_REPORTER_0} from "../src/DeploymentConfig.sol";

/// @dev Models constructor-only deployment, with no application-call capability.
contract ApplicationConstructionFactory {
    function deploy(address imd, address comp, address priceFeed, address nhiFeed, address spotFeed, bool useCreate2)
        external
        returns (CDPVault vault)
    {
        if (useCreate2) {
            vault = new CDPVault{salt: bytes32(uint256(1))}(imd, comp, address(0), priceFeed, nhiFeed, spotFeed);
        } else {
            vault = new CDPVault(imd, comp, address(0), priceFeed, nhiFeed, spotFeed);
        }
    }
}

contract FactoryDeploymentTest is Test {
    address private constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    address private constant RELAYER = address(0x1001);
    address private constant ORIGIN = address(0x1002);
    address private constant BORROWER = address(0x1003);
    ApplicationConstructionFactory private factory;
    MockIMD private imd;
    CompToken private comp;
    CDPVault private vault;
    MockWorkOracle private oracle;
    TestSwarmFeed private priceFeed;
    TestSwarmFeed private nhiFeed;
    MirroredSwarmFeed private spotFeed;

    function setUp() public {
        factory = new ApplicationConstructionFactory();
        imd = new MockIMD();
        comp = new CompToken(address(0));
        priceFeed = new TestSwarmFeed(1e18);
        nhiFeed = new TestSwarmFeed(0.85e18);
        spotFeed = new MirroredSwarmFeed(address(priceFeed));
        _deploy(false);
    }

    function _deploy(bool useCreate2) private {
        // Neither the factory, submitting caller nor transaction origin is the operator.
        vm.prank(RELAYER, ORIGIN);
        vault = factory.deploy(
            address(imd), address(comp), address(priceFeed), address(nhiFeed), address(spotFeed), useCreate2
        );
        oracle = MockWorkOracle(address(vault.oracle()));
    }

    function test_factoryDeploymentSupportsFullOperatorAndBorrowerWorkflow() public {
        _exerciseWorkflow();
    }

    function test_create2DeploymentSupportsFullOperatorAndBorrowerWorkflow() public {
        _deploy(true);
        _exerciseWorkflow();
    }

    function _exerciseWorkflow() private {
        assertEq(imd.deployer(), OPERATOR);
        assertEq(oracle.deployer(), OPERATOR);
        assertEq(address(vault.imdToken()), address(imd));
        assertEq(address(vault.compToken()), address(comp));
        assertEq(address(vault.priceFeed()), address(priceFeed));
        assertEq(address(vault.nhiFeed()), address(nhiFeed));
        assertEq(comp.vault(), address(0));
        assertEq(oracle.vault(), address(vault));
        assertEq(comp.totalSupply(), 0);
        vm.prank(BORROWER);
        vm.expectRevert(CDPVault.NotInitialized.selector);
        vault.mintFromWork(1);

        // The existing COMP token is separately authorized after construction.
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        imd.mint(BORROWER, 150 ether);
        oracle.grantRights(BORROWER, 40 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        imd.approve(address(vault), 150 ether);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        assertEq(vault.collateralRatio(BORROWER), 150);
        assertEq(oracle.mintingRights(BORROWER), 40 ether);
        vault.mintFromWork(40 ether);
        assertEq(comp.balanceOf(BORROWER), 140 ether);
        assertEq(comp.totalSupply(), 140 ether);
        assertEq(vault.totalWorkMinted(), 40 ether);
        assertEq(oracle.mintingRights(BORROWER), 0);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(comp.totalSupply(), vault.totalWorkMinted() + vault.totalFeesMinted());
        assertEq(comp.balanceOf(BORROWER), 40 ether);
        assertEq(imd.balanceOf(BORROWER), 150 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_factoryRelayerAndOriginHaveNoInitializationOrFaucetAuthority() public {
        address[4] memory callers = [address(factory), RELAYER, ORIGIN, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            _expectUnauthorized();
            vm.stopPrank();
        }
        assertEq(comp.vault(), address(0));
        assertEq(MockWorkOracle(address(vault.oracle())).vault(), address(vault));
        assertEq(imd.totalSupply(), 0);
        assertEq(oracle.mintingRights(BORROWER), 0);
    }

    function test_operatorAsTransactionOriginDoesNotAuthorizeAnIntermediary() public {
        vm.startPrank(RELAYER, OPERATOR);
        _expectUnauthorized();
        vm.stopPrank();
    }

    function _expectUnauthorized() private {
        vm.expectRevert(CompToken.Unauthorized.selector);
        comp.setVault(address(vault));
        vm.expectRevert(MockIMD.Unauthorized.selector);
        imd.mint(BORROWER, 1);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.grantRights(BORROWER, 1);
    }

    function test_operatorLosesInitializationAuthorityAndCannotMintBurnOrConsume() public {
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vm.expectRevert(CompToken.AlreadyInitialized.selector);
        comp.setVault(address(factory));
        vm.expectRevert(CompToken.Unauthorized.selector);
        comp.mint(BORROWER, 1);
        vm.expectRevert(CompToken.Unauthorized.selector);
        comp.burn(BORROWER, 1);
        oracle.grantRights(BORROWER, 1);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.consumeRights(BORROWER, 1);
        vm.stopPrank();
        assertEq(comp.vault(), address(vault));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(oracle.mintingRights(BORROWER), 1);
    }
}

/// @dev Exercises the launch's zero/zero constructor path independently of deferred-token fixtures.
contract SelfContainedFactoryDeploymentTest is Test {
    address private constant OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    address private constant RELAYER = address(0x2001);
    address private constant ORIGIN = address(0x2002);
    address private constant BORROWER = address(0x2003);
    // Not a free choice any more: the deployment artifacts pin their reporter in source, so this
    // names the pinned one. Picking any other address here would make _seedFeeds revert.
    address private constant REPORTER = FEED_REPORTER_0;
    ApplicationConstructionFactory private factory;
    MockIMD private imd;
    CompToken private comp;
    CDPVault private vault;
    MockWorkOracle private oracle;
    PriceFeed private priceFeed;
    NhiFeed private nhiFeed;
    MirroredSwarmFeed private spotFeed;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_000_000);
        factory = new ApplicationConstructionFactory();
        imd = new MockIMD();
        priceFeed = new PriceFeed(86400, 2000);
        nhiFeed = new NhiFeed(86400, 2000);
        spotFeed = new MirroredSwarmFeed(address(priceFeed));
    }

    function _deploy(bool useCreate2) private {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CDPVault).creationCode,
                abi.encode(
                    address(imd), address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
                )
            )
        );
        address predicted = vm.computeCreate2Address(bytes32(uint256(1)), initCodeHash, address(factory));
        vm.prank(RELAYER, ORIGIN);
        vault = factory.deploy(
            address(imd), address(0), address(priceFeed), address(nhiFeed), address(spotFeed), useCreate2
        );
        if (useCreate2) assertEq(address(vault), predicted, "CREATE2 uses the factory and zero constructor words");
        comp = vault.compToken();
        oracle = MockWorkOracle(address(vault.oracle()));

        // All links are already live before any reporter, operator or borrower transaction.
        assertGt(address(comp).code.length, 0);
        assertGt(address(oracle).code.length, 0);
        assertEq(comp.vault(), address(vault));
        assertEq(oracle.vault(), address(vault));
        assertEq(address(vault.imdToken()), address(imd));
        assertEq(address(vault.priceFeed()), address(priceFeed));
        assertEq(address(vault.nhiFeed()), address(nhiFeed));
        assertEq(imd.deployer(), OPERATOR);
        assertEq(oracle.deployer(), OPERATOR);
        assertEq(comp.totalSupply(), 0);
        assertEq(vault.totalWorkMinted(), 0);
    }

    function _seedFeeds() private {
        vm.startPrank(REPORTER);
        priceFeed.report(1 ether);
        nhiFeed.report(0.85 ether);
        vm.stopPrank();
        assertFalse(priceFeed.isStale());
        assertFalse(nhiFeed.isStale());
    }

    function test_createBorrowRoundTripWithoutInitialization() public {
        _deploy(false);
        _seedFeeds();
        _roundTrip(150 ether, 100 ether, 40 ether);
    }

    function test_create2BorrowRoundTripWithoutInitialization() public {
        _deploy(true);
        _seedFeeds();
        _roundTrip(150 ether, 100 ether, 40 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_factoryBorrowRoundTripWithoutInitialization(
        bool useCreate2,
        uint128 rawCollateral,
        uint128 rawDebt,
        uint128 rawWork
    ) public {
        _deploy(useCreate2);
        _seedFeeds();
        uint256 collateral = bound(uint256(rawCollateral), 3, type(uint128).max);
        uint256 debt = bound(uint256(rawDebt), 1, collateral * 100 / 150);
        _roundTrip(collateral, debt, bound(uint256(rawWork), 1, type(uint128).max));
    }

    function _roundTrip(uint256 collateral, uint256 debt, uint256 work) private {
        vm.prank(OPERATOR);
        imd.mint(BORROWER, collateral);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        _assertAccounting(collateral, 0, 0);
        assertEq(imd.allowance(BORROWER, address(vault)), 0);
        assertEq(imd.balanceOf(BORROWER), 0);
        // Borrowing works even before the operator has granted any work rights.
        vault.mintCOMP(debt);
        _assertAccounting(collateral, debt, 0);
        assertEq(comp.balanceOf(BORROWER), debt);
        assertEq(oracle.mintingRights(BORROWER), 0);
        assertGe(vault.collateralRatio(BORROWER), vault.minCR());
        vm.stopPrank();

        vm.prank(OPERATOR);
        oracle.grantRights(BORROWER, work);
        vm.startPrank(BORROWER);
        vault.mintFromWork(work);
        _assertAccounting(collateral, debt, work);
        assertEq(comp.balanceOf(BORROWER), debt + work);
        assertEq(oracle.mintingRights(BORROWER), 0);
        // Repayment burns caller COMP without an approval and preserves all earned work supply.
        assertEq(comp.allowance(BORROWER, address(vault)), 0);
        vault.repayCOMP(debt);
        _assertAccounting(collateral, 0, work);
        assertEq(comp.balanceOf(BORROWER), work);
        vault.withdrawCollateral(collateral);
        vm.stopPrank();
        _assertAccounting(0, 0, work);
        assertEq(imd.balanceOf(BORROWER), collateral);
        assertEq(comp.vault(), address(vault));
        assertEq(oracle.vault(), address(vault));
    }

    function _assertAccounting(uint256 collateral, uint256 debt, uint256 work) private view {
        (uint256 actualCollateral, uint256 actualDebt) = vault.positions(BORROWER);
        assertEq(actualCollateral, collateral);
        assertEq(actualDebt - vault.stabilityFeeOf(BORROWER), debt, "principal, excluding accrued fee");
        assertEq(imd.balanceOf(address(vault)), collateral);
        assertEq(vault.totalWorkMinted(), work);
        assertEq(
            comp.totalSupply(),
            actualDebt - vault.stabilityFeeOf(BORROWER) + vault.totalWorkMinted() + vault.totalFeesMinted()
        );
    }

    function test_bothDeploymentModesLockSetVaultForEveryCallerFromGenesis() public {
        for (uint256 mode; mode < 2; ++mode) {
            _deploy(mode == 1);
            address[6] memory callers = [OPERATOR, address(factory), RELAYER, ORIGIN, BORROWER, address(this)];
            address[3] memory targets = [address(vault), address(factory), address(0)];
            for (uint256 i; i < callers.length; ++i) {
                vm.startPrank(callers[i]);
                for (uint256 j; j < targets.length; ++j) {
                    vm.expectRevert(CompToken.AlreadyInitialized.selector);
                    comp.setVault(targets[j]);
                }
                vm.expectRevert(CompToken.Unauthorized.selector);
                comp.mint(BORROWER, 1);
                vm.expectRevert(CompToken.Unauthorized.selector);
                comp.burn(BORROWER, 1);
                vm.expectRevert(MockWorkOracle.Unauthorized.selector);
                oracle.consumeRights(BORROWER, 1);
                vm.stopPrank();
            }
            assertEq(comp.vault(), address(vault));
            assertEq(address(vault.oracle()), address(oracle));
            assertEq(oracle.vault(), address(vault));
            assertEq(comp.totalSupply(), 0);
        }
    }

    function test_operatorOriginDoesNotAuthorizeFactoryRelayerOrBorrower() public {
        for (uint256 mode; mode < 2; ++mode) {
            _deploy(mode == 1);
            address[4] memory callers = [address(factory), RELAYER, ORIGIN, BORROWER];
            for (uint256 i; i < callers.length; ++i) {
                vm.startPrank(callers[i], OPERATOR);
                vm.expectRevert(CompToken.AlreadyInitialized.selector);
                comp.setVault(address(vault));
                vm.expectRevert(MockIMD.Unauthorized.selector);
                imd.mint(BORROWER, 1);
                vm.expectRevert(MockWorkOracle.Unauthorized.selector);
                oracle.grantRights(BORROWER, 1);
                vm.stopPrank();
            }
            assertEq(imd.totalSupply(), 0);
            assertEq(oracle.mintingRights(BORROWER), 0);
        }
    }

    function test_bothDeploymentModesRejectUnsafeBorrowRepayAndWithdrawAtomically() public {
        _seedFeeds();
        for (uint256 mode; mode < 2; ++mode) {
            _deploy(mode == 1);
            vm.prank(OPERATOR);
            imd.mint(BORROWER, 150 ether);
            vm.startPrank(BORROWER);
            imd.approve(address(vault), 150 ether);
            vm.expectRevert(CDPVault.ZeroAmount.selector);
            vault.depositCollateral(0);
            vault.depositCollateral(150 ether);
            vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
            vault.mintCOMP(100 ether + 1);
            _assertAccounting(150 ether, 0, 0);
            vault.mintCOMP(100 ether);
            vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
            vault.withdrawCollateral(1);
            vm.expectRevert(CDPVault.ExcessRepayment.selector);
            vault.repayCOMP(100 ether + 1);
            vm.expectRevert(CDPVault.InsufficientRights.selector);
            vault.mintFromWork(1);
            _assertAccounting(150 ether, 100 ether, 0);
            assertEq(comp.balanceOf(BORROWER), 100 ether);
            vault.repayCOMP(100 ether);
            vault.withdrawCollateral(150 ether);
            vm.expectRevert(CDPVault.InsufficientCollateral.selector);
            vault.withdrawCollateral(1);
            vm.stopPrank();
            _assertAccounting(0, 0, 0);
        }
    }

    function test_seededFeedsMustBothBeFreshButStalenessCannotTrapDebtFreeExit() public {
        _deploy(true);
        _seedFeeds();
        vm.prank(OPERATOR);
        imd.mint(BORROWER, 150 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), 150 ether);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        // Refresh each feed independently so both stale branches are exercised after valid seeding.
        for (uint256 staleFeed; staleFeed < 2; ++staleFeed) {
            vm.warp(block.timestamp + 86401);
            vm.prank(REPORTER);
            if (staleFeed == 0) nhiFeed.report(0.85 ether);
            else priceFeed.report(1 ether);
            vm.startPrank(BORROWER);
            vm.expectRevert(CDPVault.StaleFeed.selector);
            vault.mintCOMP(1);
            vm.expectRevert(CDPVault.StaleFeed.selector);
            vault.mintFromWork(1);
            vm.expectRevert(CDPVault.StaleFeed.selector);
            vault.withdrawCollateral(1);
            vm.stopPrank();
            _assertAccounting(150 ether, 100 ether, 0);
        }
        vm.startPrank(BORROWER);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        _assertAccounting(0, 0, 0);
        assertEq(imd.balanceOf(BORROWER), 150 ether);
    }

    function test_zeroArgumentsDoNotBypassCollateralOrDistinctFeedGuards() public {
        for (uint256 mode; mode < 2; ++mode) {
            vm.startPrank(RELAYER, ORIGIN);
            vm.expectRevert(CDPVault.InvalidToken.selector);
            factory.deploy(address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed), mode == 1);
            vm.expectRevert(CDPVault.InvalidToken.selector);
            factory.deploy(BORROWER, address(0), address(priceFeed), address(nhiFeed), address(spotFeed), mode == 1);
            vm.expectRevert(CDPVault.InvalidToken.selector);
            factory.deploy(address(imd), BORROWER, address(priceFeed), address(nhiFeed), address(spotFeed), mode == 1);
            vm.expectRevert(CDPVault.InvalidToken.selector);
            factory.deploy(
                address(imd), address(imd), address(priceFeed), address(nhiFeed), address(spotFeed), mode == 1
            );
            vm.expectRevert(CDPVault.InvalidFeed.selector);
            factory.deploy(address(imd), address(0), address(0), address(nhiFeed), address(spotFeed), mode == 1);
            vm.expectRevert(CDPVault.InvalidFeed.selector);
            factory.deploy(address(imd), address(0), address(priceFeed), BORROWER, address(spotFeed), mode == 1);
            vm.expectRevert(CDPVault.InvalidFeed.selector);
            factory.deploy(
                address(imd), address(0), address(priceFeed), address(priceFeed), address(spotFeed), mode == 1
            );
            vm.stopPrank();
        }
    }
}
