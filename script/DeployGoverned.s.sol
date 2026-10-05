// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployPreflight} from "./DeployPreflight.sol";
import {Script, console2} from "forge-std/Script.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {SpotFeed} from "../src/SpotFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {ParameterizedVault} from "../src/ParameterizedVault.sol";
import {Parameters, ICheckpointedVault} from "../src/Parameters.sol";
import {Registry} from "../src/Registry.sol";
import {Treasury} from "../src/Treasury.sol";
import {UsdPriceFeed} from "../src/UsdPriceFeed.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {
    APPROVED_OPERATOR,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    CHAINLINK_ETH_USD,
    ORACLE_ATTESTER,
    CHIP_BPS,
    SKEW_BPS,
    CUT_BPS,
    DUTY_BPS,
    EARN_MAT_BPS, PRICE_MAX_AGE, NHI_MAX_AGE, SPOT_MAX_AGE
} from "../src/DeploymentConfig.sol";

/// @notice The governed variant of the stack: same feeds, same vault logic, economics in a contract.
/// @dev A separate script rather than a flag on DeployProtocol, and that is a lesson rather than a
/// preference. A launch manifest identifies a deployment by contract name and cannot represent two
/// shapes of the same stack — conditional deployment inside one script is how round 1 and round 3
/// both parked. One script, one artifact set.
///
/// Running this is a decision, not an upgrade: the live v3 vault is a plain CDPVault with its
/// economics compiled in, and nothing here migrates it. A position in the old vault stays there.
contract DeployGoverned is Script, DeployPreflight {
    uint256 constant MAX_DEVIATION_BPS = 5_000;
    uint16 constant MIN_PANEL_SIZE = 25;
    uint16 constant MIN_AGREED = 15;

    function run() external {
        _preflight();
        address operator = vm.envAddress("OPERATOR");
        // The broadcaster no longer has to be anything in particular. It used to be required to BE
        // the pinned reporter so the script could seed the feeds; with the fallback gone there is
        // nothing to seed with, and on mainnet the broadcaster is a throwaway deployer that is
        // neither the operator nor a reporter.
        address imd = vm.envOr("MOCK_IMD", address(0));

        vm.startBroadcast();

        if (imd == address(0)) {
            imd = address(new MockIMD());
            console2.log("MockIMD        (new)", imd);
        } else {
            require(imd.code.length != 0, "MOCK_IMD has no code on this chain");
            console2.log("MockIMD     (reused)", imd);
        }

        PriceFeed priceFeed = new PriceFeed(PRICE_MAX_AGE, MAX_DEVIATION_BPS);
        NhiFeed nhiFeed = new NhiFeed(NHI_MAX_AGE, MAX_DEVIATION_BPS);
        SpotFeed spotFeed = new SpotFeed(SPOT_MAX_AGE, MAX_DEVIATION_BPS);

        // The vault creates its own Parameters, so there is nothing to deploy first and nothing to
        // bind afterwards. It opens holding exactly the shipped constants, so this changes no
        // economics; see the audit fix note in ParameterizedVault for why it cannot be passed one.
        ParameterizedVault vault = new ParameterizedVault(
            imd, address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        Parameters parameters = vault.parameters();
        // The Treasury is the vault's too, for the same reason: created in the same construction,
        // it is where the vault's revenue lands from the first liquidation, its register answers to
        // this vault's Parameters, and nothing had to be deployed first or pointed at it afterwards.
        Treasury treasury = vault.treasury();

        Registry registry = new Registry(address(treasury), address(vault.oracle()));

        vm.stopBroadcast();

        console2.log("PriceFeed          ", address(priceFeed));
        console2.log("NhiFeed            ", address(nhiFeed));
        console2.log("SpotFeed           ", address(spotFeed));
        console2.log("Parameters         ", address(parameters));
        console2.log("ParameterizedVault ", address(vault));
        console2.log("Registry           ", address(registry));
        console2.log("Treasury    (inner)", address(treasury));
        console2.log("UsdPriceFeed(inner)", address(vault.usdPriceFeed()));
        console2.log("ImdUSD   (inner)", address(vault.stablecoin()));
        console2.log("MockWorkOracle(in) ", address(vault.oracle()));

        verify(vault, parameters, registry, treasury, priceFeed, nhiFeed, spotFeed);
        console2.log("\nAll authority and governance checks passed.");
    }

    /// @dev The compute-backing increment: revenue lands in the vault's own Treasury, the register is
    /// governed by the vault's own Parameters, and the work channel opens with nothing to mint against.
    function verifyBacking(ParameterizedVault vault, Parameters parameters, Treasury treasury, PriceFeed priceFeed)
        internal
        view
    {
        require(treasury.vault() == address(vault), "treasury: not created by this vault");
        require(vault.feeRecipient() == address(treasury), "vault: revenue does not land in its treasury");
        require(treasury.withdrawer() == APPROVED_OPERATOR, "treasury: wrong withdrawer");
        require(
            treasury.registrar() == address(parameters), "treasury: register not governed by the vault's parameters"
        );
        require(treasury.reserveAssetCount() == 0, "treasury: opens with a reserve register");
        require(treasury.reserveValueUsd() == 0, "treasury: opens valuing a reserve it does not hold");

        UsdPriceFeed usd = vault.usdPriceFeed();
        require(address(usd.imdEthFeed()) == address(priceFeed), "usd feed: IMD leg is not the primary feed");
        require(address(usd.ETH_USD()) == CHAINLINK_ETH_USD, "usd feed: ETH/USD leg drifted from source");

        require(vault.earnMat() == EARN_MAT_BPS, "params: work ratio drifted from source");
        require(parameters.MAX_EARN_MAT_BPS() == 2_500, "params: work ratio bound is not 2500");
        require(vault.earnMat() <= parameters.MAX_EARN_MAT_BPS(), "params: shipped ratio above its own bound");
        require(vault.reserveValue() == 0, "vault: values a reserve it does not hold");
        require(vault.backedDebt() == 0, "vault: counts debt nobody has minted");
        require(vault.earnLine() == 0, "vault: work ceiling opens nonzero with nothing backing it");
        require(vault.totalEarned() == 0, "vault: opens with work already minted");
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
        require(vault.line() == type(uint256).max, "params: ceiling is not the shipped default");
        require(vault.duty() == DUTY_BPS, "params: fee drifted from source");
        require(vault.cut() == CUT_BPS, "params: protocol share drifted");
        require(vault.skew() == SKEW_BPS, "params: divergence drifted");
        require(vault.chip() == CHIP_BPS, "params: marker share drifted");
        require(parameters.gap() == 50, "params: redemption spread is not the shipped default");
        require(vault.gap() == parameters.gap(), "vault: wrong redemption spread");
        require(parameters.MIN_GAP() == 25, "params: redemption spread floor changed");
        require(parameters.MAX_GAP() == 100, "params: redemption spread cap changed");
        require(vault.redemptionCeilingCR() == vault.mat() + 50, "vault: redemption ceiling is not derived");
        require(vault.REDEMPTION_FEE_FLOOR_BPS() == 50, "vault: redemption fee floor changed");
        require(vault.REDEMPTION_FEE_CAP_BPS() == 500, "vault: redemption fee cap changed");
        require(vault.redemptionBaseRate() == 0, "vault: redemption base rate opens nonzero");
        require(vault.lastRedemptionAt() == block.timestamp, "vault: redemption checkpoint is not now");

        // Nothing is pending and the delay is what the source says.
        require(parameters.pendingEta() == 0, "params: opens with a pending change");
        require(parameters.TIMELOCK() == 48 hours, "params: timelock is not 48h");
        require(parameters.governor() == APPROVED_OPERATOR, "params: wrong governor");
        require(registry.governor() == APPROVED_OPERATOR, "registry: wrong governor");
        require(registry.pendingEta() == 0, "registry: opens with a pending change");
        require(registry.TIMELOCK() == 48 hours, "registry: timelock is not 48h");

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
        require(
            MockIMD(address(vault.gem())).deployer() == APPROVED_OPERATOR,
            "imd: faucet authority is not the pinned operator"
        );
        require(
            MockWorkOracle(address(vault.oracle())).deployer() == APPROVED_OPERATOR,
            "oracle: faucet authority is not the pinned operator"
        );
        require(MockWorkOracle(address(vault.oracle())).vault() == address(vault), "oracle: not bound to vault");
        require(vault.stablecoin().vault() == address(vault), "comp: not bound to vault");
        require(vault.stablecoin().totalSupply() == 0, "comp: nonzero opening supply");
        require(treasury.totalReceived(vault.stablecoin()) == 0, "treasury: opens with a recorded receipt");

        PriceFeed[3] memory feeds = [priceFeed, PriceFeed(address(nhiFeed)), PriceFeed(address(spotFeed))];
        for (uint256 i = 0; i < feeds.length; ++i) {
            require(feeds[i].attester() == ORACLE_ATTESTER, "feed: wrong attester");
            require(feeds[i].relayer() == ATTESTATION_RELAYER, "feed: relayer is not the pinned one");
            require(feeds[i].relayer() != address(0), "feed: permissionless relay while questionHash is unbound");
            // Five reporter assertions used to stand here. The authority is gone, so the check that
            // replaces them is that nothing answers the fallback's selector on a deployed feed.
            // staticcall, because verify() is a view: a feed with no such function fails either way.
            (bool reported,) = address(feeds[i])
                .staticcall(abi.encodeWithSelector(bytes4(keccak256("report(uint256)")), uint256(1)));
            require(!reported, "feed: a reporter fallback is reachable");
            require(feeds[i].attestationAnswerType() == ATTESTATION_ANSWER_TYPE, "feed: wrong answerType");
            require(feeds[i].attestationChainId() == ATTESTATION_CHAIN_ID, "feed: wrong payload chainId");
            require(feeds[i].maxAge() == (i == 0 ? PRICE_MAX_AGE : i == 1 ? NHI_MAX_AGE : SPOT_MAX_AGE), "feed: wrong maxAge");
            require(feeds[i].maxDeviationBps() == MAX_DEVIATION_BPS, "feed: wrong maxDeviationBps");
            require(feeds[i].MIN_PANEL_SIZE() == MIN_PANEL_SIZE, "feed: panel floor changed");
            require(feeds[i].MIN_AGREED() == MIN_AGREED, "feed: agreement floor changed");
        }
        verifyBacking(vault, parameters, treasury, priceFeed);
    }
}
