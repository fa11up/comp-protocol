// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CDPVault} from "src/CDPVault.sol";

/// @dev Older mechanics suites use CDPVault subclasses to pin zero/ten-percent economics.
/// Give their work mints the same 2500-bps debt backing required by the launch vault, through
/// actual deposits and borrowing. A distinct account preserves the worker's debt-free semantics.
/// Ghost contributions keep every pre-existing supply/custody assertion exact and independently
/// account for the additional borrower's principal; no ceiling, rights or vault state is mocked.
abstract contract LegacyWorkBacking is Test {
    address internal constant WORK_BACKER = address(0xBACCED);
    mapping(address => uint256) internal backingPrincipal;
    mapping(address => uint256) internal backingCollateral;

    function _establishWorkBacking(CDPVault target, uint256 amount) internal {
        uint256 needed = (target.totalEarned() + amount) * 4;
        uint256 debt = target.totalDebt();
        if (debt < needed) {
            uint256 extra = needed - debt;
            (uint256 price,) = target.priceFeed().latestValue();
            uint256 deposit = Math.mulDiv(extra, 3 ether, price, Math.Rounding.Ceil);
            IERC20 token = target.imdToken();
            deal(address(token), WORK_BACKER, token.balanceOf(WORK_BACKER) + deposit, true);
            vm.startPrank(WORK_BACKER);
            token.approve(address(target), deposit);
            target.lock(deposit);
            target.draw(extra);
            vm.stopPrank();
            backingPrincipal[address(target)] += extra;
            backingCollateral[address(target)] += deposit;
        }
        assertGe(target.totalDebt() / 4, target.totalEarned() + amount, "work backed before mint");
    }
}
