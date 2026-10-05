// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WorkBackingFixture, ReserveTestToken} from "./helpers/WorkBackingFixture.sol";
import {Treasury} from "src/Treasury.sol";
import {Parameters} from "src/Parameters.sol";
import {Governed} from "src/Governed.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, REDEMPTION_DIVISOR} from "src/DeploymentConfig.sol";

/// @notice The governed redemption divisor, the operator stream, and what the operator may not
/// withdraw: the reserve, the collateral, and the imdUSD realized bad debt still needs.
contract TreasuryGuardsTest is WorkBackingFixture {
    address private constant KEEPER = address(0xBEEF);
    address private constant STRANGER = address(0x5757);
    address private constant PAYEE = address(0x9A7EE);

    event StreamPaid(address indexed payee, uint256 amount, uint256 paidToday);

    function _open(address who, uint256 amount, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(backedVault), amount);
        backedVault.lock(amount);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    /// @dev KEEPER holds imdUSD to fund the Treasury with (standing in for collected stability fees).
    function _keeperWithImdUSD() private {
        _open(KEEPER, 450 ether, 250 ether);
    }

    function _fundTreasury(uint256 amount) private {
        vm.prank(KEEPER);
        stable.transfer(address(reserve), amount);
    }

    /// @dev A realized bad debt, made the vault's way: crash, mark, liquidate to empty. Returns it.
    function _drain() private returns (uint256 bad) {
        _open(BORROWER, 170 ether, 100 ether);
        _keeperWithImdUSD();
        _setVaultPrice(0.5 ether);
        backedVault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _refreshEthUsd();
        uint256 repayable = uint256(170 ether) * 0.5 ether / ((100 + backedVault.CHOP_PERCENT()) * 1e16);
        vm.prank(KEEPER);
        backedVault.bite(BORROWER, repayable);
        bad = backedVault.totalBadDebt();
        assertGt(bad, 0);
        _setVaultPrice(1 ether);
    }

    function _setStream(address payee, uint256 perDay) private {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeStream(payee, perDay);
        _apply();
    }

    // --- the redemption divisor -------------------------------------------------------------------

    function test_theDivisorStartsAtTheShippedValueOnBothSides() public view {
        assertEq(parameters.redemptionDivisor(), REDEMPTION_DIVISOR);
        assertEq(backedVault.redemptionDivisor(), REDEMPTION_DIVISOR);
    }

    function test_onlyTheGovernorProposesADivisorAndOnlyInsideItsBounds() public {
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeRedemptionDivisor(4);
        vm.startPrank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Parameters.RedemptionDivisorOutOfRange.selector, 0));
        parameters.proposeRedemptionDivisor(0);
        vm.expectRevert(abi.encodeWithSelector(Parameters.RedemptionDivisorOutOfRange.selector, 9));
        parameters.proposeRedemptionDivisor(9);
        vm.stopPrank();
    }

    /// @dev The change waits the timelock, is public while it waits, and then moves the vault's fee.
    function test_aGovernedDivisorChangesTheVaultsFeeCurveAfterTheTimelock() public {
        _openDebt(100 ether); // 100 imdUSD of supply
        // 1% of supply at divisor 2: floor 50 + ceil(0.01 / 2 in bps) = 100.
        assertEq(backedVault.redemptionFeeBps(1 ether), 100);

        vm.prank(APPROVED_OPERATOR);
        parameters.proposeRedemptionDivisor(4);
        (uint256 next, uint256 eta) = parameters.pendingRedemptionDivisor();
        assertEq(next, 4);
        assertEq(eta, vm.getBlockTimestamp() + parameters.TIMELOCK());
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, eta));
        parameters.applyPending();
        assertEq(backedVault.redemptionFeeBps(1 ether), 100, "nothing changes while it waits");

        vm.warp(eta);
        vm.prank(STRANGER); // application is permissionless once due
        parameters.applyPending();
        assertEq(backedVault.redemptionDivisor(), 4);
        assertEq(backedVault.redemptionFeeBps(1 ether), 75, "the same burn now moves the base half as far");
        (next, eta) = parameters.pendingRedemptionDivisor();
        assertEq(next, 0);
        assertEq(eta, 0);
    }

    // --- the operator stream ----------------------------------------------------------------------

    function test_theStreamIsOffAtLaunch() public {
        assertEq(parameters.streamPayee(), address(0));
        assertEq(parameters.streamPerDay(), 0);
        vm.expectRevert(Treasury.NoStream.selector);
        reserve.payStream();
    }

    function test_theStreamIsGovernedAndBounded() public {
        vm.prank(STRANGER);
        vm.expectRevert(Governed.NotGovernor.selector);
        parameters.proposeStream(PAYEE, 1 ether);
        vm.startPrank(APPROVED_OPERATOR);
        uint256 cap = parameters.MAX_STREAM_PER_DAY();
        vm.expectRevert(abi.encodeWithSelector(Parameters.StreamTooHigh.selector, cap + 1));
        parameters.proposeStream(PAYEE, cap + 1);
        vm.expectRevert(Parameters.StreamPayeeMissing.selector);
        parameters.proposeStream(address(0), 1 ether);
        parameters.proposeStream(PAYEE, cap); // the cap itself is allowed
        vm.stopPrank();
        (address payee, uint256 perDay, uint256 eta) = parameters.pendingStream();
        assertEq(payee, PAYEE);
        assertEq(perDay, cap);
        assertEq(eta, vm.getBlockTimestamp() + parameters.TIMELOCK());
        _apply();
        assertEq(parameters.streamPayee(), PAYEE);
        assertEq(parameters.streamPerDay(), cap);

        _setStream(address(0), 0); // and it can be turned off again
        vm.expectRevert(Treasury.NoStream.selector);
        reserve.payStream();
    }

    /// @dev Anyone may trigger it; only the payee is paid; at most the daily amount per UTC day; a day
    /// left unclaimed is not carried over; a short balance pays what it can.
    function test_theStreamPaysThePayeeUpToItsDailyAmount() public {
        _keeperWithImdUSD();
        _setStream(PAYEE, 10 ether);
        _fundTreasury(25 ether);

        vm.expectEmit(address(reserve));
        emit StreamPaid(PAYEE, 10 ether, 10 ether);
        vm.prank(STRANGER);
        assertEq(reserve.payStream(), 10 ether);
        assertEq(stable.balanceOf(PAYEE), 10 ether);
        assertEq(stable.balanceOf(STRANGER), 0, "the caller is paid nothing");
        assertEq(reserve.payStream(), 0, "nothing more today");

        vm.warp(vm.getBlockTimestamp() + 2 days); // a day goes unclaimed
        assertEq(reserve.payStream(), 10 ether, "one day's amount, not two");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(reserve.payStream(), 5 ether, "a short balance pays what it holds");
        assertEq(reserve.streamPaid(), 5 ether);
        assertEq(reserve.payStream(), 0, "and nothing once it is empty");
        assertEq(stable.balanceOf(PAYEE), 25 ether);
    }

    function test_theStreamNeverSpendsWhatBadDebtStillNeeds() public {
        uint256 bad = _drain();
        _setStream(PAYEE, 10 ether);
        uint256 held = stable.balanceOf(address(reserve));
        _fundTreasury(bad + 3 ether - held);
        assertEq(reserve.payStream(), 3 ether, "only what is spare above the outstanding loss");
        assertEq(stable.balanceOf(address(reserve)), bad);
        assertEq(reserve.payStream(), 0, "the rest is held for cover");

        backedVault.cover(BORROWER, bad);
        _fundTreasury(10 ether);
        assertEq(reserve.payStream(), 7 ether, "once covered, the rest of today's amount flows");
    }

    // --- withdraw protection ----------------------------------------------------------------------

    function test_theOperatorCannotWithdrawTheCollateral() public {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), 10 ether);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ReserveProtected.selector, address(collateral)));
        reserve.withdraw(IERC20(address(collateral)), APPROVED_OPERATOR, 1);
    }

    function test_aListedReserveAssetLeavesOnlyAfterADelisting() public {
        _fundReserve(10 ether);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ReserveProtected.selector, address(asset)));
        reserve.withdraw(asset, APPROVED_OPERATOR, 1 ether);

        _register(asset, ISwarmFeed(address(0)), 0); // delisted, visible for 48 hours first
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(asset, APPROVED_OPERATOR, 1 ether);
        assertEq(asset.balanceOf(APPROVED_OPERATOR), 1 ether);
    }

    function test_imdUSDLeavesOnlyAboveWhatBadDebtStillNeeds() public {
        uint256 bad = _drain();
        uint256 held = stable.balanceOf(address(reserve));
        _fundTreasury(bad + 5 ether - held);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(IERC20(address(stable)), APPROVED_OPERATOR, 5 ether); // down to exactly the loss
        assertEq(stable.balanceOf(address(reserve)), bad);
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Treasury.BadDebtFirst.selector, bad));
        reserve.withdraw(IERC20(address(stable)), APPROVED_OPERATOR, 1);

        backedVault.cover(BORROWER, bad);
        _fundTreasury(1 ether);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(IERC20(address(stable)), APPROVED_OPERATOR, 1 ether); // nothing owed: free to move
    }

    function test_imdUSDWithNoBadDebtIsTheOperatorsToDeploy() public {
        _keeperWithImdUSD();
        _fundTreasury(20 ether);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(IERC20(address(stable)), PAYEE, 20 ether);
        assertEq(stable.balanceOf(PAYEE), 20 ether);
    }

    function test_unrelatedTokensAndNativeETHAreUnaffected() public {
        ReserveTestToken other = new ReserveTestToken(6);
        other.mint(address(reserve), 1e6);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdraw(IERC20(address(other)), PAYEE, 1e6);
        assertEq(other.balanceOf(PAYEE), 1e6);

        vm.deal(address(reserve), 1 ether);
        vm.prank(APPROVED_OPERATOR);
        reserve.withdrawNative(payable(PAYEE), 1 ether);
        assertEq(PAYEE.balance, 1 ether);
    }

    function test_withdrawStillBelongsToTheOperatorAlone() public {
        _keeperWithImdUSD();
        _fundTreasury(1 ether);
        vm.prank(STRANGER);
        vm.expectRevert(Treasury.Unauthorized.selector);
        reserve.withdraw(IERC20(address(stable)), STRANGER, 1 ether);
    }
}
