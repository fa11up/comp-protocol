// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPreflight} from "../script/DeployPreflight.sol";
import {SwarmRelay} from "src/SwarmRelay.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ReserveUsdAggregator} from "./helpers/WorkBackingFixture.sol";
import {ATTESTATION_RELAYER, CHAINLINK_ETH_USD, TREASURY_FACTORY, ETH_USD_MAX_AGE} from "src/DeploymentConfig.sol";

contract PreflightHarness is DeployPreflight {
    function check() external view {
        _preflight();
    }
}

/// @notice F5 (launch audit, oracle panel). The chain constants as committed name Sepolia contracts;
/// compiled unchanged for mainnet they would deploy feeds nobody can submit to and a USD leg that is
/// stale forever, with no error anywhere. The deploy scripts now refuse before broadcasting.
contract DeployPreflightTest is Test {
    PreflightHarness private harness;

    function setUp() public {
        vm.warp(10 days);
        harness = new PreflightHarness();
    }

    function _etchAll(uint256 updatedAt) private {
        vm.etch(ATTESTATION_RELAYER, address(new SwarmRelay()).code);
        vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new ReserveUsdAggregator()).code);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).setDecimals(8);
        ReserveUsdAggregator(CHAINLINK_ETH_USD).set(2_500e8, updatedAt);
    }

    function test_passesWhenEveryConstantHasCodeAndChainlinkIsFresh() public {
        _etchAll(block.timestamp);
        harness.check();
    }

    function test_refusesARelayWithNoCode() public {
        _etchAll(block.timestamp);
        vm.etch(ATTESTATION_RELAYER, "");
        vm.expectRevert(bytes("preflight: ATTESTATION_RELAYER has no code on this chain"));
        harness.check();
    }

    function test_refusesATreasuryFactoryWithNoCode() public {
        _etchAll(block.timestamp);
        vm.etch(TREASURY_FACTORY, "");
        vm.expectRevert(bytes("preflight: TREASURY_FACTORY has no code on this chain"));
        harness.check();
    }

    function test_refusesAChainlinkAddressWithNoCode() public {
        _etchAll(block.timestamp);
        vm.etch(CHAINLINK_ETH_USD, "");
        vm.expectRevert(bytes("preflight: CHAINLINK_ETH_USD has no code on this chain"));
        harness.check();
    }

    function test_refusesAStaleChainlinkAnswer() public {
        _etchAll(block.timestamp - ETH_USD_MAX_AGE - 1);
        vm.expectRevert(bytes("preflight: CHAINLINK_ETH_USD is stale"));
        harness.check();
    }
}
