// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "src/Treasury.sol";
import {MockIMD} from "src/MockIMD.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice Finding: Treasury.withdraw lowers `lastSynced` to the post-withdrawal balance without
/// first crediting what arrived since the last sync, so a receipt that landed between sync and
/// withdraw is never added to `totalReceived`.
contract TreasuryLostReceiptTest is Test {
    Treasury private treasury;
    MockIMD private token;

    function setUp() public {
        // Auditor-supplied proof, preserved verbatim apart from this note. It FAILED against
        // cbd9e609 and PASSES now: the accounting bug it found is fixed, so it is an ungated
        // regression test rather than an outstanding finding.

        treasury = new Treasury(address(this));
        token = new MockIMD();
    }

    function _receive(uint256 amount) private {
        vm.prank(APPROVED_OPERATOR);
        token.mint(address(treasury), amount);
    }

    /// @dev 100 arrives and is synced. 30 more arrives. The operator withdraws 60 before anyone
    /// syncs. Expected: totalReceived == 130 once synced (130 did arrive). Actual: 100, forever.
    function test_aReceiptBetweenSyncAndWithdrawIsCounted() public {
        IERC20 t = IERC20(address(token));
        _receive(100 ether);
        treasury.sync(t);
        assertEq(treasury.totalReceived(t), 100 ether);

        _receive(30 ether); // a liquidation's protocol cut lands, unsynced

        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(t, address(0xD0), 60 ether);
        // balance is 70, lastSynced was clamped from 100 down to 70, the 30 is gone from the record

        treasury.sync(t);
        assertEq(treasury.totalReceived(t), 130 ether, "everything that arrived must be in the running total");
    }
}