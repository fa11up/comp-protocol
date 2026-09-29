// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenFactoryProbe {
    function deploy() external returns (LaunchToken) {
        return new LaunchToken();
    }
}

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant RECIPIENT = address(0xCAFE);
    address private constant SPENDER = address(0xBEEF);
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndEntireFixedSupplyToDeployer() public view {
        assertEq(token.name(), "COMP Launch");
        assertEq(token.symbol(), "CPL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryReceivesSupplyInsteadOfFactoryCaller() public {
        LaunchTokenFactoryProbe factory = new LaunchTokenFactoryProbe();
        vm.prank(RECIPIENT);
        LaunchToken deployed = factory.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(RECIPIENT), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_transferAndAllowanceMoveExactAmountsWithoutChangingSupply() public {
        assertTrue(token.transfer(RECIPIENT, 100 ether));
        assertEq(token.balanceOf(RECIPIENT), 100 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100 ether);
        assertTrue(token.approve(SPENDER, 20 ether));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), RECIPIENT, 15 ether));
        assertEq(token.allowance(address(this), SPENDER), 5 ether);
        assertEq(token.balanceOf(RECIPIENT), 115 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 115 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFailuresPreserveBalancesAndSupply() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, RECIPIENT, 0, 1));
        token.transfer(SPENDER, 1);
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        token.transferFrom(address(this), RECIPIENT, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintBurnOrAdministrationForDeployerOrStranger() public {
        string[15] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "burn(address,uint256)",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "setVault(address)"
        ];
        address[2] memory callers = [address(this), SPENDER];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < signatures.length; ++j) {
                vm.prank(callers[i]);
                (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[j], RECIPIENT, 1 ether));
                assertFalse(ok, signatures[j]);
                assertEq(token.totalSupply(), SUPPLY);
                assertEq(token.balanceOf(address(this)), SUPPLY);
                assertEq(token.balanceOf(RECIPIENT), 0);
            }
        }
    }

    function test_runtimeBoundedAndNoForbiddenInstructions() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }
}
