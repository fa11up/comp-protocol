// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";

/// @dev Models vault deployment against existing tokens, with no application-call capability.
contract ApplicationConstructionFactory {
    function deploy(address imd, address comp, address priceFeed, address nhiFeed, bool useCreate2)
        external
        returns (CDPVault vault)
    {
        if (useCreate2) {
            vault = new CDPVault{salt: bytes32(uint256(1))}(imd, comp, address(0), priceFeed, nhiFeed);
        } else {
            vault = new CDPVault(imd, comp, address(0), priceFeed, nhiFeed);
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

    function setUp() public {
        factory = new ApplicationConstructionFactory();
        imd = new MockIMD();
        comp = new CompToken(address(0));
        priceFeed = new TestSwarmFeed(1e18);
        nhiFeed = new TestSwarmFeed(0.85e18);
        _deploy(false);
    }

    function _deploy(bool useCreate2) private {
        // Neither the factory, submitting caller nor transaction origin is the operator.
        vm.prank(RELAYER, ORIGIN);
        vault = factory.deploy(address(imd), address(comp), address(priceFeed), address(nhiFeed), useCreate2);
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
        assertEq(comp.totalSupply(), vault.totalWorkMinted());
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
