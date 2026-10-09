// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ParameterizedVault} from "src/ParameterizedVault.sol";

/// @notice Test-only: a ParameterizedVault whose work channel is open at any wage, with the follow limit off.
/// @dev The production vault opens `earn` only while the wage is nonzero (final panel audits 2026-10-07,
/// medium), and its work ceiling and fee base follow the live debt and supply at a paced rate. The suites built on
/// WorkBackingFixture grant rights through the MockWorkOracle faucet and test the CEILING ARITHMETIC,
/// reserve valuation and redemption accounting at exact figures; with the follow limit on, every one of
/// those figures would carry hours of pacing. This vault is that arithmetic once the paced figures have
/// caught up, which is what the production ceiling converges to. The gate and the pacing themselves are
/// tested against the production vault (test/LaggedBacking.t.sol, test/PacedFigures.t.sol). Nothing under src/ or script/
/// references this contract.
contract OpenWorkVault is ParameterizedVault {
    constructor(address gem_, address stablecoin_, address oracle_, address price_, address nhi_, address spot_)
        ParameterizedVault(gem_, stablecoin_, oracle_, price_, nhi_, spot_)
    {}

    function _earnOpen() internal pure override returns (bool) {
        return true;
    }

    /// @dev No follow limit: the fee base, the work ceiling and the payout price follow the live supply, debt and
    /// price at once (CDPVault._followRateLimited), so the suites check that arithmetic at exact figures. The paced
    /// backing still applies, as on the deployed vault. The paced supply, debt and payout price are tested against
    /// the production vault (test/PacedFigures.t.sol and the kept panel proofs).
    function _followRateLimited() internal pure override returns (bool) {
        return false;
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
