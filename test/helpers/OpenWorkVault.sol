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

    /// @dev Fully warmed capital, for the fee curve too: only principal minted in the current transaction is
    /// new in the fee base (CDPVault._feeBase). The production vault's cold exclusion, which reaches back
    /// hours, is tested in test/retry-panel/ and test/LaggedBacking.t.sol.
    function _coldPrincipal() internal view override returns (uint256) {
        return _principalMintedThisTransaction();
    }

    /// @dev No floor: the suites built on WorkBackingFixture check the fee curve on supplies of a few hundred.
    function _feeBaseFloor() internal pure override returns (uint256) {
        return 0;
    }

    /// @notice The supply a redemption's fee increase is measured against (CDPVault._laggedSupply), for the
    /// invariant suite's model of the fee curve.
    function redemptionSupply() external view returns (uint256) {
        return _feeBase();
    }
}
