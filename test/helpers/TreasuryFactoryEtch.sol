// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {TREASURY_FACTORY} from "src/DeploymentConfig.sol";

/// @notice Puts TreasuryFactory's code at TREASURY_FACTORY, where every ParameterizedVault asks for its
/// Treasury. On a real chain it is a deployment prerequisite; a test chain starts without it.
library TreasuryFactoryEtch {
    function etch(Vm vm) internal {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
    }
}
