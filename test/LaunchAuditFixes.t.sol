// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkBackingFixture} from "./helpers/WorkBackingFixture.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @dev Reads the redemption fee, mints from work, and reads it again, all in ONE transaction.
contract EarnThenQuote {
    function run(ParameterizedVault vault, uint256 earned, uint256 redeem)
        external
        returns (uint256 before, uint256 afterEarn)
    {
        before = vault.redemptionFeeBps(redeem);
        vault.earn(earned);
        afterEarn = vault.redemptionFeeBps(redeem);
    }
}

/// @notice Regressions for the 2026-10-05 launch audit that need the work-backing fixture.
contract LaunchAuditFixesTest is WorkBackingFixture {
    /// @dev F8 (vault panel, low). Drawn principal minted this transaction was netted out of the supply
    /// the fee base is measured against; work-minted imdUSD was not, so earning and then redeeming in
    /// one transaction diluted the fee. Both are netted now: the quote does not move.
    function test_earningThenRedeemingInOneTransactionDoesNotDiluteTheFee() public {
        _openDebt(1000 ether);
        EarnThenQuote caller = new EarnThenQuote();
        vm.prank(APPROVED_OPERATOR);
        workOracle.grantRights(address(caller), 200 ether);
        (uint256 before, uint256 afterEarn) = caller.run(backedVault, 200 ether, 50 ether);
        assertEq(before, 300, "50 of 1,000 supply at divisor 2: 0.5% floor + 2.5%");
        assertEq(afterEarn, before, "the 200 imdUSD earned in the same transaction does not dilute it");
    }

    /// @dev F9 (governance panel). A listed source answering an absurd price made the valuation revert
    /// (mulDiv overflow), taking reserveValueUsd, earnLine, backingPerUnit and cash down with it,
    /// contrary to the promise that a bad source counts for nothing. It now counts for nothing.
    function test_anAbsurdListedPriceCountsForNothingInsteadOfReverting() public {
        _register(asset, reservePrice, 10_000);
        asset.mint(address(reserve), 1e30);
        reservePrice.setValue(type(uint256).max / 1e6);
        assertEq(reserve.reserveValueOf(asset), 0, "counts for nothing");
        assertEq(reserve.reserveValueUsd(), 0, "and the sum does not revert");
        backedVault.earnLine(); // nor anything that reads it
    }
}
