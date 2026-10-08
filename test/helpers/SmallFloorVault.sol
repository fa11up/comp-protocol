// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ParameterizedVault} from "src/ParameterizedVault.sol";

/// @notice Test-only: the production vault with the fee base floored at 1,000 imdUSD, as it was at 6085c8a.
/// @dev The floor is 100,000 since the final sweep panel audit (2026-10-08, low F1). The fee-base suites
/// written before it (test/retry-panel/AdjacentTxBurn, test/retry2-panel/FeeBaseErasure and FeeDilution,
/// test/LaggedBacking) prove that cold principal and fresh repayments cannot move the WARM base, at supplies
/// of a few thousand; under the new floor every figure there would read the floor and prove nothing. The
/// floor is a max over that base, so it can only raise the base the suites measure: what holds for the
/// warm base under a 1,000 floor holds under a higher one. Nothing under src/ or script/ references this.
contract SmallFloorVault is ParameterizedVault {
    constructor(address gem_, address stablecoin_, address oracle_, address price_, address nhi_, address spot_)
        ParameterizedVault(gem_, stablecoin_, oracle_, price_, nhi_, spot_)
    {}

    function _feeBaseFloor() internal pure override returns (uint256) {
        return 1_000e18;
    }
}
