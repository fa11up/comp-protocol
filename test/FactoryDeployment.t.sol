// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";

/// @dev Models both factory creation modes; deliberately has no application-call capability.
contract ApplicationConstructionFactory {
    function deploy(bool useCreate2)
        external
        returns (MockIMD imd, CompToken comp, CDPVault vault, MockWorkOracle oracle)
    {
        if (useCreate2) {
            imd = new MockIMD{salt: bytes32(uint256(1))}();
            comp = new CompToken{salt: bytes32(uint256(2))}();
            vault = new CDPVault{salt: bytes32(uint256(3))}(address(imd), address(comp), address(0));
            oracle = new MockWorkOracle{salt: bytes32(uint256(4))}(address(vault));
        } else {
            imd = new MockIMD();
            comp = new CompToken();
            vault = new CDPVault(address(imd), address(comp), address(0));
            oracle = new MockWorkOracle(address(vault));
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

    function setUp() public {
        factory = new ApplicationConstructionFactory();
        // Neither the factory, the submitting caller nor the transaction origin is the operator.
        vm.prank(RELAYER, ORIGIN);
        (imd, comp, vault, oracle) = factory.deploy(false);
    }

    function test_factoryDeploymentSupportsFullOperatorAndBorrowerWorkflow() public {
        _exerciseWorkflow();
    }

    function test_create2DeploymentSupportsFullOperatorAndBorrowerWorkflow() public {
        vm.prank(RELAYER, ORIGIN);
        (imd, comp, vault, oracle) = factory.deploy(true);
        _exerciseWorkflow();
    }

    function _exerciseWorkflow() private {
        assertEq(imd.deployer(), OPERATOR);
        assertEq(oracle.deployer(), OPERATOR);
        assertEq(comp.vault(), address(0));
        assertEq(address(vault.oracle()), address(0));
        assertEq(oracle.vault(), address(vault));
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        imd.mint(BORROWER, 150 ether);
        oracle.grantRights(BORROWER, 100 ether);
        vm.stopPrank();

        vm.startPrank(BORROWER);
        imd.approve(address(vault), 150 ether);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        assertEq(vault.collateralRatio(BORROWER), 150);
        assertEq(comp.balanceOf(BORROWER), 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(oracle.mintingRights(BORROWER), 0);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();

        (uint256 collateral, uint256 debt) = vault.positions(BORROWER);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(comp.totalSupply(), 0);
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
        assertEq(address(vault.oracle()), address(0));
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
        vm.expectRevert(CDPVault.Unauthorized.selector);
        vault.setOracle(address(oracle));
        vm.expectRevert(MockIMD.Unauthorized.selector);
        imd.mint(BORROWER, 1);
        vm.expectRevert(MockWorkOracle.Unauthorized.selector);
        oracle.grantRights(BORROWER, 1);
    }

    function test_operatorLosesInitializationAuthorityAndCannotMintBurnOrConsume() public {
        vm.startPrank(OPERATOR);
        comp.setVault(address(vault));
        vault.setOracle(address(oracle));
        vm.expectRevert(CompToken.AlreadyInitialized.selector);
        comp.setVault(address(factory));
        vm.expectRevert(CDPVault.AlreadyInitialized.selector);
        vault.setOracle(address(factory));
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
