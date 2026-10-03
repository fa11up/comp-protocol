// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../src/Treasury.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";

/// @dev A vault that pays the protocol a share, so the treasury has something to receive.
contract PayingVault is CDPVault {
    constructor(address imd, address price, address nhi, address spot)
        CDPVault(imd, address(0), address(0), price, nhi, spot)
    {}

    function protocolBonusShareBps() public pure override returns (uint256) {
        return 3_333;
    }

    function stabilityFeeBps() public pure override returns (uint256) {
        return 0;
    }
}

contract TreasuryTest is Test {
    address private constant STRANGER = address(0x5174);
    address private constant DESTINATION = address(0xD35);
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);

    Treasury private treasury;
    MockIMD private imd;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        treasury = new Treasury();
        imd = new MockIMD();
    }

    function _fund(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(address(treasury), amount);
    }

    function test_syncCreditsWhatArrivedAndNothingTwice() public {
        _fund(100 ether);
        assertEq(treasury.totalReceived(IERC20(address(imd))), 0, "a transfer alone records nothing");
        assertEq(treasury.sync(IERC20(address(imd))), 100 ether);
        assertEq(treasury.totalReceived(IERC20(address(imd))), 100 ether);
        assertEq(treasury.sync(IERC20(address(imd))), 0, "a second sync credits nothing");
        _fund(50 ether);
        assertEq(treasury.sync(IERC20(address(imd))), 50 ether, "only the new arrival");
        assertEq(treasury.totalReceived(IERC20(address(imd))), 150 ether);
    }

    function test_anyoneMaySync() public {
        _fund(10 ether);
        vm.prank(STRANGER);
        assertEq(treasury.sync(IERC20(address(imd))), 10 ether, "recording what arrived takes nothing from anyone");
    }

    /// @dev totalReceived answers "what has the protocol earned", so a withdrawal must not reduce it,
    /// and must not later read back as fresh revenue.
    function test_aWithdrawalLowersTheBalanceButNotTheEarnings() public {
        _fund(100 ether);
        treasury.sync(IERC20(address(imd)));
        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(IERC20(address(imd)), DESTINATION, 60 ether);

        assertEq(imd.balanceOf(DESTINATION), 60 ether);
        assertEq(imd.balanceOf(address(treasury)), 40 ether);
        assertEq(treasury.totalReceived(IERC20(address(imd))), 100 ether, "earnings are a running total");
        assertEq(treasury.sync(IERC20(address(imd))), 0, "the withdrawal is not fresh revenue");
        _fund(5 ether);
        assertEq(treasury.sync(IERC20(address(imd))), 5 ether);
        assertEq(treasury.totalReceived(IERC20(address(imd))), 105 ether);
    }

    /// @dev Syncing is open; moving money is not.
    function test_onlyTheOperatorMayWithdraw() public {
        _fund(10 ether);
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? STRANGER : BORROWER);
            vm.expectRevert(Treasury.Unauthorized.selector);
            treasury.withdraw(IERC20(address(imd)), DESTINATION, 1);
        }
        assertEq(imd.balanceOf(address(treasury)), 10 ether);
    }

    function test_withdrawalRefusesDegenerateDestinations() public {
        _fund(10 ether);
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.withdraw(IERC20(address(imd)), address(0), 1);
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.withdraw(IERC20(address(imd)), address(treasury), 1);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdraw(IERC20(address(imd)), DESTINATION, 0);
        vm.stopPrank();
    }

    function test_theTreasuryHasNoOtherAuthority() public {
        // It cannot be made to do anything else: there is no owner, no upgrade and no sweep-to-self.
        (bool ok,) = address(treasury).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner");
        (ok,) = address(treasury).call(abi.encodeWithSignature("upgradeTo(address)", DESTINATION));
        assertFalse(ok, "no upgrade path");
    }

    /// @dev The reason it exists: a liquidation's protocol share must actually arrive here. The
    /// vault pays FEE_RECIPIENT, a source constant, so the treasury is placed at that address rather
    /// than the constant being bent to the test.
    function test_aLiquidationsProtocolShareArrivesAndSyncRecordsIt() public {
        vm.etch(FEE_RECIPIENT, address(treasury).code);
        Treasury live = Treasury(FEE_RECIPIENT);

        TestSwarmFeed price = new TestSwarmFeed(1 ether);
        TestSwarmFeed spot = new TestSwarmFeed(1 ether);
        TestSwarmFeed nhi = new TestSwarmFeed(0.6 ether); // minCR 200, grace 0
        PayingVault vault = new PayingVault(address(imd), address(price), address(nhi), address(spot));
        CompToken comp = vault.compToken();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 300 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(300 ether);
        vault.mintCOMP(150 ether); // CR 200 exactly
        comp.transfer(KEEPER, 150 ether);
        vm.stopPrank();

        price.setValue(0.9 ether); // underwater at minCR 200
        spot.setValue(0.9 ether);
        vm.prank(KEEPER);
        vault.markUnderwater(BORROWER);
        vm.prank(KEEPER);
        vault.liquidate(BORROWER, 50 ether);

        uint256 arrived = imd.balanceOf(FEE_RECIPIENT);
        assertGt(arrived, 0, "the protocol share must reach the treasury");
        uint256 px = 0.9 ether;
        uint256 repaid = 50 ether;
        uint256 seized = repaid * 110 * 1e16 / px;
        uint256 bonus = seized - repaid * 1e18 / px;
        assertEq(arrived, bonus * 3_333 / 10_000, "exactly the configured share of the bonus");

        assertEq(live.totalReceived(IERC20(address(imd))), 0, "arrival alone records nothing");
        assertEq(live.sync(IERC20(address(imd))), arrived, "sync turns the balance into a receipt");
        assertEq(live.totalReceived(IERC20(address(imd))), arrived);
    }
}
