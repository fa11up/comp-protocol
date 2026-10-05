// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {CDPVault} from "src/CDPVault.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice Can the redemption base rate be pinned, at either end, for gas?
/// @dev Round 5's review found the fee design pinnable BOTH ways, which between them would have
/// removed the mechanism entirely:
///
///   - at the CAP, because redeeming against a position the redeemer controls was free, moving the
///     peg floor from 0.995 to 0.95 for anyone willing to pay gas;
///   - at the FLOOR, because principal minted inside a twelve-hour window was excluded from moving
///     the stored rate, and that exclusion could be kept alive indefinitely.
///
/// Both FLOOR bypasses were reported against an intermediate revision, and the contracts node then
/// changed `draw` to amount-weight `mintedAt` and `_reduceDebt` to conserve principal-time
/// rounding OLDER. This file replays the reported reproductions against the DELIVERED code, because a
/// finding record that still reads "unresolved" is not evidence either way — and the answer turned out
/// to be that both are closed.
///
/// It also pins the other end, which the exclusion is what defends: a redemption against a freshly
/// minted position of one's own does not move the stored rate, so the fee cannot be walked to its cap
/// by anyone willing to pay gas. That makes the exclusion load-bearing rather than redundant — worth
/// knowing before anyone proposes deleting it, which is exactly what this repository had planned.
contract RedemptionFeePinningTest is WorkBackingFixture {
    address private constant HOLDER = address(0xDEED);

    /// @dev Reproduction, verbatim from the finding: "a borrower who mints one wei every 11h59m keeps
    /// an arbitrarily large principal 'fresh' indefinitely for one wei of debt per half-day", so a
    /// redemption routed through that position "never moves the rate anyone else pays".
    function test_oneWeiEveryTwelveHoursCannotPinTheRateAtTheFloor() public {
        _setVaultPrice(1 ether);
        _open(BORROWER, 1800 ether, 1000 ether);
        vm.prank(BORROWER);
        stable.transfer(HOLDER, 100 ether);

        // Three days of dust mints, each just inside the window.
        for (uint256 i; i < 6; ++i) {
            vm.warp(vm.getBlockTimestamp() + 11 hours + 59 minutes);
            _refreshEthUsd();
            vm.prank(BORROWER);
            backedVault.draw(1);
        }

        uint256 before = backedVault.redemptionBaseRate();
        uint256 out = _quote(100 ether);
        vm.prank(HOLDER);
        backedVault.redeem(100 ether, out, BORROWER);

        // The brief requires the burned fraction of supply over four to reach the stored rate. If the
        // exclusion were still bypassable the rate would not move at all.
        assertGt(backedVault.redemptionBaseRate(), before, "a redemption must move the rate it leaves behind");
        assertGt(backedVault.redemptionFeeBps(0), backedVault.REDEMPTION_FEE_FLOOR_BPS(), "the next redeemer must pay more than the floor");
    }

    /// @dev The second reproduction: "Minting X and repaying X in a row therefore leaves the original
    /// principal F dated a*F/(F+X) old instead of a... Repeating the pair multiplies the age down
    /// geometrically." Twenty pairs every six hours, for gas, with no net change to debt or balance.
    function test_mintThenRepayRoundTripsCannotWashTheRecordYoung() public {
        _setVaultPrice(1 ether);
        _open(BORROWER, 1800 ether, 1000 ether);
        vm.prank(BORROWER);
        stable.transfer(HOLDER, 100 ether);

        for (uint256 cycle; cycle < 6; ++cycle) {
            vm.warp(vm.getBlockTimestamp() + 6 hours);
            _refreshEthUsd();
            for (uint256 i; i < 20; ++i) {
                vm.startPrank(BORROWER);
                backedVault.draw(190 ether);
                stable.approve(address(backedVault), 190 ether);
                backedVault.wipe(190 ether);
                vm.stopPrank();
            }
        }

        uint256 before = backedVault.redemptionBaseRate();
        uint256 out = _quote(100 ether);
        vm.prank(HOLDER);
        backedVault.redeem(100 ether, out, BORROWER);

        assertGt(backedVault.redemptionBaseRate(), before, "round trips must not keep the record fresh");
        assertGt(backedVault.redemptionFeeBps(0), backedVault.REDEMPTION_FEE_FLOOR_BPS(), "the next redeemer must pay more than the floor");
    }

    /// @dev The other end, measured directly rather than by walking to the cap: does a redemption
    /// against one's OWN position move the rate everyone else then pays? If it does, the fee is
    /// walkable to its 500 bps cap by anyone willing to pay the fee and gas, and the peg floor drops
    /// from 0.995 to 0.95 for every holder. (A loop to the cap is not the right probe — the position
    /// prices itself out of eligibility after a few redemptions, which is the borrower opt-out
    /// working as designed.)
    function test_selfRedemptionDoesNotMoveTheRateOthersPay() public {
        _setVaultPrice(1 ether);
        _open(BORROWER, 1800 ether, 1000 ether);

        uint256 before = backedVault.redemptionBaseRate();
        uint256 feeBefore = backedVault.redemptionFeeBps(0);
        uint256 out = _quote(50 ether);
        vm.prank(BORROWER);
        backedVault.redeem(50 ether, out, BORROWER);

        emit log_named_uint("base rate before", before);
        emit log_named_uint("base rate after ", backedVault.redemptionBaseRate());
        emit log_named_uint("fee bps before  ", feeBefore);
        emit log_named_uint("fee bps after   ", backedVault.redemptionFeeBps(0));
        assertEq(
            backedVault.redemptionBaseRate(),
            before,
            "a redemption against one's own position must not move the rate others pay"
        );
    }

    function _open(address who, uint256 c, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(who, c);
        vm.startPrank(who);
        collateral.approve(address(backedVault), c);
        backedVault.lock(c);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    /// @dev Mirrors the vault: par minus the fee, then capped at what actually backs a COMP.
    function _quote(uint256 amount) private view returns (uint256) {
        (uint256 price,) = backedVault.usdPriceFeed().latestValue();
        uint256 scale = Math.mulDiv(backedVault.backingPerUnit(), 10_000 - backedVault.redemptionFeeBps(amount), 10_000);
        return Math.mulDiv(amount, scale, price);
    }
}
