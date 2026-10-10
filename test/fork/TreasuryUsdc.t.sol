// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../../src/Treasury.sol";
import {TreasuryFactory} from "../../src/TreasuryFactory.sol";
import {APPROVED_OPERATOR} from "../../src/DeploymentConfig.sol";

interface IFiatToken {
    function isBlacklisted(address) external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice The Treasury takes real USDC (the peg hook's surcharge arrives in it) and the governor can move it.
///   forge test --match-path test/fork/TreasuryUsdc.t.sol --fork-url $MAINNET_RPC_URL
contract TreasuryUsdcForkTest is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    Treasury treasury;

    // A Treasury answers its vault for gem() and stablecoin(); this test is the vault.
    function gem() external pure returns (address) {
        return address(0x51);
    }

    function stablecoin() external pure returns (address) {
        return address(0x52);
    }

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        treasury = new TreasuryFactory().create(); // created by this contract, as the vault creates its own
    }

    function test_realUsdcArrivesIsRecordedAndOnlyTheGovernorMovesIt() public {
        assertFalse(IFiatToken(address(USDC)).paused(), "USDC is not paused");
        assertFalse(IFiatToken(address(USDC)).isBlacklisted(address(treasury)), "USDC does not block the Treasury");

        deal(address(USDC), address(this), 1_000e6);
        assertTrue(USDC.transfer(address(treasury), 1_000e6));
        assertEq(USDC.balanceOf(address(treasury)), 1_000e6, "plain transfer: no hook needed on the receiving side");
        assertEq(treasury.sync(USDC), 1_000e6, "recorded as revenue");

        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.withdraw(USDC, address(this), 1);

        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(USDC, APPROVED_OPERATOR, 400e6);
        assertEq(USDC.balanceOf(APPROVED_OPERATOR), 400e6, "the governor can move it");
        assertEq(USDC.balanceOf(address(treasury)), 600e6);
    }
}
