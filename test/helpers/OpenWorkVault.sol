// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ParameterizedVault} from "src/ParameterizedVault.sol";

/// @notice Test-only: a ParameterizedVault whose work channel is open at any wage, with the lag off.
/// @dev The production vault opens `earn` only while the wage is nonzero, and the wage turns the lagged
/// work ceiling on with it (final panel audits 2026-10-07, medium). The suites built on
/// WorkBackingFixture grant rights through the MockWorkOracle faucet and test the CEILING ARITHMETIC,
/// reserve valuation and redemption accounting at exact figures; with the lag on, every one of those
/// figures would carry a day's warm-up. This vault is that arithmetic for fully warmed capital, which
/// is what the production ceiling converges to. The gate and the lag themselves are tested against the
/// production vault (test/LaggedBacking.t.sol). Nothing under src/ or script/
/// references this contract.
contract OpenWorkVault is ParameterizedVault {
    constructor(address gem_, address stablecoin_, address oracle_, address price_, address nhi_, address spot_)
        ParameterizedVault(gem_, stablecoin_, oracle_, price_, nhi_, spot_)
    {}

    function _earnOpen() internal pure override returns (bool) {
        return true;
    }

    /// @notice The supply a redemption's fee increase is measured against (CDPVault._laggedSupply), for the
    /// invariant suite's model of the fee curve.
    function redemptionSupply() external view returns (uint256) {
        return _laggedSupplyFrom(_supplyStart());
    }

    /// @notice Principal repaid with its backing left behind, still counted in the supply backing per imdUSD is
    /// measured against (CDPVault._moveExcess), for the invariant suite's model of the payout.
    function excessSupply() external view returns (uint256) {
        return _excessNow();
    }
}
