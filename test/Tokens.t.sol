// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";

/// @dev Stands in for a vault that creates its COMP token from its own constructor.
contract ImdUSDCreator {
    ImdUSD public immutable token;

    constructor() {
        token = new ImdUSD(address(this));
    }

    function mint(address account, uint256 amount) external {
        token.mint(account, amount);
    }
}

contract TokensTest is ProtocolFixture {
    function test_metadataAndZeroGenesisSupply() public {
        MockIMD freshIMD = new MockIMD();
        ImdUSD freshCOMP = new ImdUSD(address(0));
        assertEq(freshIMD.name(), "Identity MD");
        assertEq(freshIMD.symbol(), "IMD");
        assertEq(freshIMD.decimals(), 18);
        assertEq(freshIMD.totalSupply(), 0);
        assertEq(freshIMD.deployer(), OPERATOR);
        assertEq(freshCOMP.name(), "imdUSD");
        assertEq(freshCOMP.symbol(), "imdUSD");
        assertEq(freshCOMP.decimals(), 18);
        assertEq(freshCOMP.totalSupply(), 0);
        assertEq(freshCOMP.vault(), address(0));
    }

    function test_imdMintOnlyDeployerAndZeroRecipientRejected() public {
        vm.prank(alice);
        vm.expectRevert(MockIMD.Unauthorized.selector);
        imd.mint(alice, 1);
        vm.startPrank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        imd.mint(address(0), 1);
        imd.mint(alice, 50 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 1050 ether);
        assertEq(imd.totalSupply(), 2050 ether);
    }

    function test_setVaultDeployerOnlyAndIrreversible() public {
        ImdUSD fresh = new ImdUSD(address(0));
        CDPVault freshVault = new BaselineVault(
            address(imd), address(fresh), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.prank(alice);
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        fresh.setVault(address(freshVault));
        vm.startPrank(OPERATOR);
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        fresh.setVault(address(0));
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        fresh.setVault(alice);
        // A vault bound to a different COMP token, and contracts without stablecoin(), are rejected
        // without consuming the one-time initialization authority.
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        fresh.setVault(address(vault));
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        fresh.setVault(address(imd));
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        fresh.setVault(address(oracle));
        assertEq(fresh.vault(), address(0));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit ImdUSD.VaultSet(address(freshVault));
        fresh.setVault(address(freshVault));
        assertEq(fresh.vault(), address(freshVault));
        vm.expectRevert(ImdUSD.AlreadyInitialized.selector);
        fresh.setVault(address(freshVault));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ImdUSD.AlreadyInitialized.selector);
        fresh.setVault(address(0));
    }

    function test_constructorVaultIsValidatedAndLockedImmediately() public {
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        new ImdUSD(alice);
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        new ImdUSD(address(vault));
        vm.expectRevert(ImdUSD.InvalidVault.selector);
        new ImdUSD(address(imd));
        // The creating contract may bind itself while it is still under construction.
        ImdUSDCreator creator = new ImdUSDCreator();
        ImdUSD created = creator.token();
        assertEq(created.vault(), address(creator));
        vm.prank(OPERATOR);
        vm.expectRevert(ImdUSD.AlreadyInitialized.selector);
        created.setVault(address(vault));
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        created.mint(alice, 1);
        creator.mint(alice, 5);
        assertEq(created.balanceOf(alice), 5);
    }

    function test_compMintAndBurnOnlyVaultBeforeAndAfterInitialization() public {
        ImdUSD fresh = new ImdUSD(address(0));
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        fresh.mint(alice, 1);
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        fresh.burn(alice, 1);
        _open(alice, 170 ether, 100 ether);
        address[4] memory callers = [address(this), OPERATOR, alice, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(ImdUSD.Unauthorized.selector);
            comp.mint(callers[i], 1);
            vm.expectRevert(ImdUSD.Unauthorized.selector);
            comp.burn(alice, 1);
            vm.stopPrank();
        }
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(comp.balanceOf(alice), 100 ether);
    }

    function test_vaultMintBurnERC20Validation() public {
        vm.startPrank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        comp.mint(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        comp.burn(address(0), 1);
        comp.mint(alice, 7);
        comp.burn(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 4, 5));
        comp.burn(alice, 5);
        vm.stopPrank();
        assertEq(comp.balanceOf(alice), 4);
        assertEq(comp.totalSupply(), 4);
    }

    function test_standardTransfersAllowancesAndFailuresOnBothTokens() public {
        _open(alice, 170 ether, 100 ether);
        _checkERC20(imd);
        _checkERC20(comp);
    }

    function _checkERC20(ERC20 token) private {
        uint256 supply = token.totalSupply();
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10));
        assertEq(token.balanceOf(alice), aliceBefore - 10);
        assertEq(token.balanceOf(bob), bobBefore + 10);
        vm.prank(alice);
        assertTrue(token.approve(bob, 7));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 5));
        assertEq(token.allowance(alice, bob), 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 2, 3));
        token.transferFrom(alice, bob, 3);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, aliceBefore - 15, aliceBefore)
        );
        token.transfer(bob, aliceBefore);
        assertTrue(token.transfer(alice, 1));
        assertTrue(token.transfer(bob, 0));
        token.approve(bob, type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(alice), aliceBefore - 16);
        assertEq(token.balanceOf(bob), bobBefore + 16);
    }

    function test_noCommonAdministrationSelectors() public {
        string[7] memory selectors = [
            "owner()",
            "transferOwnership(address)",
            "setMinter(address)",
            "pause()",
            "upgradeTo(address)",
            "rescue(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool tokenOK,) = address(comp).call(abi.encodeWithSignature(selectors[i], address(this)));
            (bool vaultOK,) = address(vault).call(abi.encodeWithSignature(selectors[i], address(this)));
            assertFalse(tokenOK);
            assertFalse(vaultOK);
        }
    }
}
