// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {CDPVault} from "src/CDPVault.sol";
import {TenPercentFeeVault} from "./helpers/BaselineVault.sol";
import {StabilityFeeFixture} from "./StabilityFee.t.sol";
import {ProtocolFixture} from "./ProtocolFixture.sol";

/// @dev Reads the Principal(owner, debt) stream out of recorded logs, the way the off-chain points
/// engine reads it from a block explorer.
abstract contract PrincipalLogReader {
    bytes32 internal constant PRINCIPAL_TOPIC = keccak256("Principal(address,uint256)");

    function _principalEvents(Vm vm_, address owner) internal returns (uint256 count, uint256 last) {
        Vm.Log[] memory logs = vm_.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 2 || logs[i].topics[0] != PRINCIPAL_TOPIC) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != owner) continue;
            ++count;
            last = abi.decode(logs[i].data, (uint256));
        }
    }
}

/// @notice At a 10% rate, so repayments split between fees and principal: the case the event exists for.
contract PrincipalEventFeeTest is StabilityFeeFixture, PrincipalLogReader {
    function _deployVault() internal override returns (CDPVault) {
        return new TenPercentFeeVault(
            address(collateral), address(0), address(0), address(primary), address(nhi), address(spot)
        );
    }

    function test_drawEmitsTheNewPrincipal() public {
        vm.recordLogs();
        _open(BORROWER, 100 ether);
        (uint256 count, uint256 last) = _principalEvents(vm, BORROWER);
        assertEq(count, 1);
        assertEq(last, 100 ether);

        vm.recordLogs();
        vm.prank(BORROWER);
        vault.draw(5 ether);
        (, last) = _principalEvents(vm, BORROWER);
        assertEq(last, 105 ether, "the event carries the total, not the increment");
    }

    /// @notice Why the event exists: a repayment pays fees first, and Wipe(amount) does not say how it
    /// split. 30 repaid after a year at 10% on 100 is 10 of fee and 20 of principal.
    function test_aRepaymentEmitsPrincipalNetOfTheFeesItPaidFirst() public {
        _open(BORROWER, 100 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.stabilityFeeOf(BORROWER), 10 ether);

        vm.recordLogs();
        vm.prank(BORROWER);
        vault.wipe(30 ether);
        (uint256 count, uint256 last) = _principalEvents(vm, BORROWER);
        assertEq(count, 1);
        assertEq(last, 80 ether, "principal fell by 20, not by the 30 repaid");
        assertEq(last, vault.totalDebt(), "and matches the vault's own principal");
    }

    function test_aRepaymentThatOnlyPaysFeesEmitsNothing() public {
        _open(BORROWER, 100 ether);
        vm.warp(block.timestamp + 365 days);
        vm.recordLogs();
        vm.prank(BORROWER);
        vault.wipe(4 ether); // less than the 10 of fees owed
        (uint256 count,) = _principalEvents(vm, BORROWER);
        assertEq(count, 0, "principal did not move");
        assertEq(vault.totalDebt(), 100 ether);
    }

    /// @notice Replaying only the Principal stream reproduces principal after every step of any
    /// draw / wait / repay sequence: what the points engine relies on.
    function testFuzz_thePrincipalStreamTracksPrincipalExactly(uint256 seed) public {
        _open(BORROWER, 100 ether);
        vm.prank(BORROWER);
        vault.lock(10_000 ether); // ample room, so every random draw stays safe
        uint256 tracked = 100 ether;
        for (uint256 step; step < 12; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            vm.warp(block.timestamp + (seed % 90 days));
            vm.recordLogs();
            if (seed & 1 == 0) {
                uint256 amount = bound(seed >> 8, 1, 20 ether);
                vm.prank(BORROWER);
                vault.draw(amount);
            } else {
                // Fees are owed but never minted to the borrower, so repay within what they hold.
                uint256 owed = vault.debtOf(BORROWER);
                uint256 held = comp.balanceOf(BORROWER);
                uint256 cap = owed / 2 + 1 < held ? owed / 2 + 1 : held;
                if (cap == 0) continue;
                uint256 amount = bound(seed >> 8, 1, cap);
                vm.prank(BORROWER);
                vault.wipe(amount);
            }
            (uint256 count, uint256 last) = _principalEvents(vm, BORROWER);
            if (count != 0) tracked = last;
            assertEq(tracked, vault.totalDebt(), "the stream's latest value is the principal");
        }
    }
}

/// @notice Liquidation repays through the same path, so the liquidated owner's principal is emitted too.
contract PrincipalEventLiquidationTest is ProtocolFixture, PrincipalLogReader {
    function test_aLiquidationEmitsTheOwnersRemainingPrincipal() public {
        priceFeed.setValue(2 ether);
        _open(alice, 130 ether, 100 ether);
        vm.prank(alice);
        comp.transfer(bob, 100 ether);
        priceFeed.setValue(1 ether);
        vault.bark(alice);
        (uint256 markedAt, uint256 grace,,) = vault.liquidationMarks(alice);
        vm.warp(markedAt + grace);

        vm.recordLogs();
        vm.prank(bob);
        vault.bite(alice, 50 ether);
        (uint256 count, uint256 last) = _principalEvents(vm, alice);
        assertEq(count, 1);
        assertEq(last, 50 ether);
        assertEq(last, vault.totalDebt());
    }
}
