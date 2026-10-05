// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../src/Treasury.sol";
import {ILaunchFeeShare} from "../src/interfaces/ILaunchFeeShare.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {APPROVED_OPERATOR, FEE_RECIPIENT} from "../src/DeploymentConfig.sol";

/// @dev A vault that pays the protocol a share, so the treasury has something to receive.
contract PayingVault is CDPVault {
    constructor(address imd, address price, address nhi, address spot)
        CDPVault(imd, address(0), address(0), price, nhi, spot)
    {}

    function cut() public pure override returns (uint256) {
        return 3_333;
    }

    function duty() public pure override returns (uint256) {
        return 0;
    }
}

/// @dev Pays like Uniswap-launch `PoolFees._send`: a bare call forwarding all gas, success read back.
contract FeePayer {
    function pay(address to, uint256 amount) external returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
    }

    function payWithStipend(address payable to, uint256 amount) external {
        to.transfer(amount); // 2,300 gas: an empty receive() must still accept it
    }

    receive() external payable {}
}

/// @dev Re-enters syncNative while receiving a withdrawal, to try to count the remainder twice.
contract ReenteringRecipient {
    Treasury private immutable treasury;
    uint256 public creditedDuringCall;

    constructor(Treasury treasury_) {
        treasury = treasury_;
    }

    receive() external payable {
        creditedDuringCall = treasury.syncNative();
    }
}

/// @dev The requester-share rules of an IdentityMD launch factory (PoolFees.setRequester), verbatim.
contract MockLaunchFactory {
    error NotRequester(uint64 launchNumber);
    error ZeroRequester();

    mapping(uint64 launchNumber => address) public requesterOf;

    function open(uint64 launchNumber, address requester) external {
        requesterOf[launchNumber] = requester;
    }

    function setRequester(uint64 launchNumber, address next) external {
        address current = requesterOf[launchNumber];
        if (current == address(0) || msg.sender != current) revert NotRequester(launchNumber);
        if (next == address(0)) revert ZeroRequester();
        requesterOf[launchNumber] = next;
    }
}

/// @dev Refuses ETH, so a failed withdrawal can be observed.
contract Refuser {}

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
        Treasury live = Treasury(payable(FEE_RECIPIENT));

        TestSwarmFeed price = new TestSwarmFeed(1 ether);
        TestSwarmFeed spot = new TestSwarmFeed(1 ether);
        TestSwarmFeed nhi = new TestSwarmFeed(0.6 ether); // mat 200, grace 0
        PayingVault vault = new PayingVault(address(imd), address(price), address(nhi), address(spot));
        ImdUSD comp = vault.stablecoin();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 300 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(300 ether);
        vault.draw(150 ether); // CR 200 exactly
        comp.transfer(KEEPER, 150 ether);
        vm.stopPrank();

        price.setValue(0.9 ether); // underwater at mat 200
        spot.setValue(0.9 ether);
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        vm.prank(KEEPER);
        vault.bite(BORROWER, 50 ether);

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

    // --- native ETH ---------------------------------------------------------------------------

    /// @dev Why it exists: a launch pool pays its requester's LP fees in both currencies, possibly ETH,
    /// through a bare call. Without receive() that payout fails and is owed forever to an address
    /// that can never take it.
    function test_acceptsALaunchPoolFeePayout() public {
        FeePayer payer = new FeePayer();
        vm.deal(address(payer), 3 ether);
        assertTrue(payer.pay(address(treasury), 2 ether), "a PoolFees-style payout succeeds");
        payer.payWithStipend(payable(address(treasury)), 1 ether);
        assertEq(address(treasury).balance, 3 ether);
    }

    function test_syncNativeCreditsArrivalsIncludingForcedOnesAndNothingTwice() public {
        (bool ok,) = address(treasury).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(treasury.totalReceived(treasury.NATIVE()), 0, "arrival alone records nothing");
        assertEq(treasury.syncNative(), 2 ether);
        assertEq(treasury.syncNative(), 0, "a second sync credits nothing");

        vm.deal(address(treasury), address(treasury).balance + 1 ether); // forced: no receive() call
        vm.prank(STRANGER);
        assertEq(treasury.syncNative(), 1 ether, "anyone may record it");
        assertEq(treasury.totalReceived(treasury.NATIVE()), 3 ether);
    }

    function test_nativeWithdrawalIsOperatorOnlyAndKeepsTheEarnings() public {
        vm.deal(address(treasury), 5 ether);
        treasury.syncNative();

        vm.prank(STRANGER);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.withdrawNative(payable(DESTINATION), 1 ether);

        vm.prank(APPROVED_OPERATOR);
        treasury.withdrawNative(payable(DESTINATION), 3 ether);
        assertEq(DESTINATION.balance, 3 ether);
        assertEq(treasury.totalReceived(treasury.NATIVE()), 5 ether, "earnings are a running total");
        assertEq(treasury.syncNative(), 0, "the withdrawal is not fresh revenue");
    }

    function test_nativeWithdrawalCreditsAnUnsyncedArrivalFirst() public {
        vm.deal(address(treasury), 4 ether); // never synced
        vm.prank(APPROVED_OPERATOR);
        treasury.withdrawNative(payable(DESTINATION), 1 ether);
        assertEq(treasury.totalReceived(treasury.NATIVE()), 4 ether, "the arrival was not lost to the withdrawal");
    }

    function test_nativeWithdrawalRefusesDegenerateCallsAndSurfacesAFailedSend() public {
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.withdrawNative(payable(address(0)), 1);
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.withdrawNative(payable(address(treasury)), 1);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdrawNative(payable(DESTINATION), 0);
        address refuser = address(new Refuser());
        vm.expectRevert(Treasury.NativeTransferFailed.selector);
        treasury.withdrawNative(payable(refuser), 1);
        vm.expectRevert(Treasury.NativeTransferFailed.selector);
        treasury.withdrawNative(payable(DESTINATION), 2 ether); // more than it holds
        vm.stopPrank();
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_reenteringSyncDuringANativeWithdrawalCreditsNothingTwice() public {
        vm.deal(address(treasury), 10 ether);
        treasury.syncNative();
        ReenteringRecipient recipient = new ReenteringRecipient(treasury);
        vm.prank(APPROVED_OPERATOR);
        treasury.withdrawNative(payable(address(recipient)), 4 ether);
        assertEq(recipient.creditedDuringCall(), 0, "the baseline moved before the call");
        assertEq(treasury.totalReceived(treasury.NATIVE()), 10 ether);
        assertEq(treasury.syncNative(), 0);
    }

    function testFuzz_nativeRecordNeverExceedsWhatArrived(uint96 a, uint96 b, uint96 out) public {
        vm.deal(address(treasury), uint256(a));
        treasury.syncNative();
        vm.deal(address(treasury), uint256(a) + uint256(b));
        uint256 w = bound(uint256(out), 0, uint256(a) + uint256(b));
        if (w > 0) {
            vm.prank(APPROVED_OPERATOR);
            treasury.withdrawNative(payable(DESTINATION), w);
        }
        treasury.syncNative();
        assertEq(treasury.totalReceived(treasury.NATIVE()), uint256(a) + uint256(b));
    }

    // --- launch fee share ---------------------------------------------------------------------

    function test_operatorHandsTheLaunchFeeShareOn() public {
        MockLaunchFactory factory = new MockLaunchFactory();
        factory.open(7, address(treasury));
        vm.prank(APPROVED_OPERATOR);
        treasury.handOffLaunchFees(ILaunchFeeShare(address(factory)), 7, DESTINATION);
        assertEq(factory.requesterOf(7), DESTINATION, "future fees now go to the new address");
    }

    function test_onlyTheOperatorMayHandOffLaunchFees() public {
        MockLaunchFactory factory = new MockLaunchFactory();
        factory.open(7, address(treasury));
        vm.prank(STRANGER);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.handOffLaunchFees(ILaunchFeeShare(address(factory)), 7, STRANGER);
        assertEq(factory.requesterOf(7), address(treasury));
    }

    function test_handOffRefusesDegenerateDestinations() public {
        MockLaunchFactory factory = new MockLaunchFactory();
        factory.open(7, address(treasury));
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.handOffLaunchFees(ILaunchFeeShare(address(factory)), 7, address(0));
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.handOffLaunchFees(ILaunchFeeShare(address(factory)), 7, address(treasury));
        vm.stopPrank();
    }

    /// @dev The factory, not the Treasury, decides who the requester is: a launch the Treasury does not
    /// hold cannot be redirected through it.
    function test_handOffOfALaunchTheTreasuryDoesNotHoldFails() public {
        MockLaunchFactory factory = new MockLaunchFactory();
        factory.open(7, STRANGER);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(MockLaunchFactory.NotRequester.selector, uint64(7)));
        treasury.handOffLaunchFees(ILaunchFeeShare(address(factory)), 7, DESTINATION);
    }
}
