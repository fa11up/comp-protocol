// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {SpotFeed} from "../src/SpotFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {ParameterizedVault} from "../src/ParameterizedVault.sol";
import {Parameters, ICheckpointedVault} from "../src/Parameters.sol";
import {Registry} from "../src/Registry.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {
    APPROVED_OPERATOR,
    ATTESTATION_RELAYER,
    FEED_REPORTER_0,
    MARKER_SHARE_BPS,
    MAX_DIVERGENCE_BPS,
    PROTOCOL_BONUS_SHARE_BPS,
    STABILITY_FEE_BPS
} from "../src/DeploymentConfig.sol";

/// @notice The governed variant of the stack: same feeds, same vault logic, economics in a contract.
/// @dev A separate script rather than a flag on DeployComp, and that is a lesson rather than a
/// preference. A launch manifest identifies a deployment by contract name and cannot represent two
/// shapes of the same stack — conditional deployment inside one script is how round 1 and round 3
/// both parked. One script, one artifact set.
///
/// Running this is a decision, not an upgrade: the live v3 vault is a plain CDPVault with its
/// economics compiled in, and nothing here migrates it. A position in the old vault stays there.
contract DeployGoverned is Script {
    uint256 constant MAX_AGE = 86_400;
    uint256 constant MAX_DEVIATION_BPS = 5_000;
    uint256 constant SPOT_MAX_AGE = 3_600;
    uint16 constant MIN_PANEL_SIZE = 25;
    uint16 constant MIN_AGREED = 15;

    function run() external {
        address operator = vm.envAddress("OPERATOR");
        require(operator == FEED_REPORTER_0, "OPERATOR cannot report: not the reporter pinned in DeploymentConfig");
        address imd = vm.envOr("MOCK_IMD", address(0));

        vm.startBroadcast();

        if (imd == address(0)) {
            imd = address(new MockIMD());
            console2.log("MockIMD        (new)", imd);
        } else {
            require(imd.code.length != 0, "MOCK_IMD has no code on this chain");
            console2.log("MockIMD     (reused)", imd);
        }

        PriceFeed priceFeed = new PriceFeed(MAX_AGE, MAX_DEVIATION_BPS);
        NhiFeed nhiFeed = new NhiFeed(MAX_AGE, MAX_DEVIATION_BPS);
        SpotFeed spotFeed = new SpotFeed(SPOT_MAX_AGE, MAX_DEVIATION_BPS);

        // Parameters before the vault: the vault's reference to it is immutable, so the order is
        // forced. It opens holding exactly the shipped constants, so deploying it changes nothing.
        Parameters parameters = new Parameters();
        ParameterizedVault vault = new ParameterizedVault(
            imd, address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed), parameters
        );
        // Needs no governor signature: the only vault bindVault accepts is the one already naming
        // this Parameters, so the reporter key can complete the whole stack in one broadcast.
        parameters.bindVault(ICheckpointedVault(address(vault)));

        Treasury treasury = new Treasury();
        Registry registry = new Registry(address(treasury), address(vault.oracle()));

        vm.stopBroadcast();

        console2.log("PriceFeed          ", address(priceFeed));
        console2.log("NhiFeed            ", address(nhiFeed));
        console2.log("SpotFeed           ", address(spotFeed));
        console2.log("Parameters         ", address(parameters));
        console2.log("ParameterizedVault ", address(vault));
        console2.log("Registry           ", address(registry));
        console2.log("Treasury           ", address(treasury));
        console2.log("CompToken   (inner)", address(vault.compToken()));
        console2.log("MockWorkOracle(in) ", address(vault.oracle()));

        verify(vault, parameters, registry, treasury, priceFeed, nhiFeed, spotFeed);
        console2.log("\nAll authority and governance checks passed.");
    }

    /// @dev Read back off chain, not compared to a local copy of the same literal.
    function verify(
        ParameterizedVault vault,
        Parameters parameters,
        Registry registry,
        Treasury treasury,
        PriceFeed priceFeed,
        NhiFeed nhiFeed,
        SpotFeed spotFeed
    ) internal view {
        // The link in both directions, and that it cannot be moved.
        require(address(vault.parameters()) == address(parameters), "vault: wrong parameters source");
        require(address(parameters.vault()) == address(vault), "parameters: not bound to this vault");

        // Governance opens at the status quo: every knob reads the same value it would have had
        // compiled in. A deployment that silently changed the economics would be caught here.
        require(vault.debtCeiling() == type(uint256).max, "params: ceiling is not the shipped default");
        require(vault.stabilityFeeBps() == STABILITY_FEE_BPS, "params: fee drifted from source");
        require(vault.protocolBonusShareBps() == PROTOCOL_BONUS_SHARE_BPS, "params: protocol share drifted");
        require(vault.maxDivergenceBps() == MAX_DIVERGENCE_BPS, "params: divergence drifted");
        require(vault.markerShareBps() == MARKER_SHARE_BPS, "params: marker share drifted");

        // Nothing is pending and the delay is what the source says.
        require(parameters.pendingEta() == 0, "params: opens with a pending change");
        require(parameters.TIMELOCK() == 48 hours, "params: timelock is not 48h");
        require(parameters.governor() == APPROVED_OPERATOR, "params: wrong governor");
        require(registry.governor() == APPROVED_OPERATOR, "registry: wrong governor");
        require(registry.pendingEta() == 0, "registry: opens with a pending change");

        // The index opens unaccrued, so the first fee is charged from this block and not earlier.
        require(vault.indexCheckpoint() == 1e18, "vault: index does not open at scale");
        require(vault.indexCheckpointAt() == block.timestamp, "vault: index checkpoint is not now");

        // The registry agrees with what the feeds were compiled against.
        require(registry.relayer() == ATTESTATION_RELAYER, "registry: relayer disagrees with the feeds");
        require(registry.treasury() == address(treasury), "registry: wrong treasury");
        require(registry.workOracle() == address(vault.oracle()), "registry: wrong work oracle");

        // And the governable surface stops where custody begins: the feeds and the collateral are
        // immutables on the vault, named by neither contract.
        require(address(vault.priceFeed()) == address(priceFeed), "vault: wrong price feed");
        require(address(vault.nhiFeed()) == address(nhiFeed), "vault: wrong nhi feed");
        require(address(vault.spotFeed()) == address(spotFeed), "vault: wrong spot feed");
        require(priceFeed.isStale() && nhiFeed.isStale() && spotFeed.isStale(), "feeds: must open unseeded");
        require(MockWorkOracle(address(vault.oracle())).vault() == address(vault), "oracle: not bound to vault");
        require(vault.compToken().vault() == address(vault), "comp: not bound to vault");
        require(treasury.totalReceived(vault.compToken()) == 0, "treasury: opens with a recorded receipt");
    }
}
