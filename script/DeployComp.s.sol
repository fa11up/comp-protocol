// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {
    APPROVED_OPERATOR,
    ORACLE_ATTESTER,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    FEED_REPORTER_0,
    FEED_REPORTER_1,
    FEED_REPORTER_2,
    FEED_QUORUM
} from "../src/DeploymentConfig.sol";

/// @notice In-house deployment of the COMP feed + vault stack, with every authority held by us.
/// @dev Launch 519 deployed the same source through the swarm and is unusable to us for two reasons,
/// both of which this script fixes by passing explicit literals instead of platform placeholders:
///   1. `$owner` in launch.json resolved to 0x09ec3817…, the platform policy owner, so `reporter0`
///      and `relayer` are addresses we do not control and the feeds can never be seeded.
///   2. `attestationAnswerType` was set to 1, which is `address`. A uint256 price attestation carries
///      3, verified by recovering live attestation signatures against candidate uint8 values.
/// Both are immutable, so 519's feeds are permanently inert. Nothing here is upgradeable either —
/// that is the point — so every constant below is checked against chain state by `verify()`.
contract DeployComp is Script {
    // The attester, relayer, reporters, quorum, answer type and payload chainId are no longer
    // written here at all: PriceFeed and NhiFeed take none of them, because every one of them is
    // pinned in src/DeploymentConfig.sol. This script cannot get them wrong, and neither can a
    // launch manifest — there is no argument to substitute. verify() reads them back off chain.

    uint256 constant MAX_AGE = 86_400; // also bounds CDPVault.liquidationWindow()
    uint256 constant MAX_DEVIATION_BPS = 2_000;

    // Attestation v2 signs panelSize/quorum/agreed, so the CONSUMER sets the real bar. A request can
    // therefore ask for a low quorum — so that it attests at all — while the feed still refuses
    // anything under these. The dev's own example is panelSize >= 5 && agreed >= 4.
    uint16 constant MIN_PANEL_SIZE = 25; // mirrors SwarmFeed.MIN_PANEL_SIZE
    uint16 constant MIN_AGREED = 15;     // mirrors SwarmFeed.MIN_AGREED

    function run() external {
        // Kept only to check the broadcasting key against the authority the source pins. A deployer
        // who cannot report cannot seed the feed, which is launch 519's failure by another road.
        // Deliberately NOT required to equal ATTESTATION_RELAYER: relaying is a hot, automated role
        // and is expected to move to its own key, while deploying stays a cold, manual one.
        address operator = vm.envAddress("OPERATOR");
        require(operator == FEED_REPORTER_0, "OPERATOR cannot report: not the reporter pinned in DeploymentConfig");
        // Reused from launch 519: its faucet authority is the hardcoded APPROVED_OPERATOR in
        // DeploymentConfig.sol, so MockIMD.deployer() is already us. Set MOCK_IMD=0x0 to deploy fresh.
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
        PriceFeed spotFeed = new PriceFeed(MAX_AGE, MAX_DEVIATION_BPS);
        // compToken_ = 0 and oracle_ = 0 put the vault in self-contained mode: it creates and
        // permanently binds its own CompToken and MockWorkOracle, so no post-deploy call exists.
        CDPVault vault =
            new CDPVault(imd, address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed));

        vm.stopBroadcast();

        console2.log("PriceFeed          ", address(priceFeed));
        console2.log("NhiFeed            ", address(nhiFeed));
        console2.log("SpotFeed           ", address(spotFeed));
        console2.log("CDPVault           ", address(vault));
        console2.log("CompToken   (inner)", address(vault.compToken()));
        console2.log("MockWorkOracle(in) ", address(vault.oracle()));

        verify(vault, priceFeed, nhiFeed, spotFeed, imd, operator);
        console2.log("\nAll authority checks passed.");
    }

    /// @dev Fails the run if any immutable did not land on us. 519 would have failed this.
    function verify(
        CDPVault vault,
        PriceFeed priceFeed,
        NhiFeed nhiFeed,
        PriceFeed spotFeed,
        address imd,
        address operator
    ) internal view {
        require(MockIMD(imd).deployer() == APPROVED_OPERATOR, "imd: faucet authority is not the pinned operator");
        require(address(vault.imdToken()) == imd, "vault: wrong collateral");
        require(address(vault.priceFeed()) == address(priceFeed), "vault: wrong price feed");
        require(address(vault.nhiFeed()) == address(nhiFeed), "vault: wrong nhi feed");
        require(address(vault.spotFeed()) == address(spotFeed), "vault: wrong spot feed");
        require(address(priceFeed) != address(nhiFeed), "feeds must differ");
        require(address(spotFeed) != address(priceFeed) && address(spotFeed) != address(nhiFeed), "feeds must differ");

        CompToken comp = vault.compToken();
        require(comp.vault() == address(vault), "comp: not bound to vault");
        require(comp.totalSupply() == 0, "comp: nonzero opening supply");
        MockWorkOracle workOracle = MockWorkOracle(address(vault.oracle()));
        require(workOracle.deployer() == APPROVED_OPERATOR, "oracle: faucet authority is not the pinned operator");
        require(workOracle.vault() == address(vault), "oracle: not bound to vault");

        PriceFeed[3] memory feeds = [priceFeed, PriceFeed(address(nhiFeed)), spotFeed];
        for (uint256 i = 0; i < feeds.length; ++i) {
            // Read off chain and compared to source, not to a local copy of the same literal: this
            // is the check that would have failed the 519 deployment instead of discovering it live.
            require(feeds[i].attester() == ORACLE_ATTESTER, "feed: wrong attester");
            require(feeds[i].relayer() == ATTESTATION_RELAYER, "feed: relayer is not the pinned one");
            require(feeds[i].relayer() != address(0), "feed: permissionless relay while questionHash is unbound");
            require(feeds[i].reporter0() == FEED_REPORTER_0, "feed: reporter0 is not the pinned one");
            require(feeds[i].reporter1() == FEED_REPORTER_1, "feed: reporter1 drifted from source");
            require(feeds[i].reporter2() == FEED_REPORTER_2, "feed: reporter2 drifted from source");
            require(feeds[i].quorum() == FEED_QUORUM, "feed: quorum drifted from source");
            require(feeds[i].isReporter(operator), "feed: operator cannot report");
            require(
                feeds[i].attestationAnswerType() == ATTESTATION_ANSWER_TYPE, "feed: answerType must be 3 (uint256)"
            );
            require(feeds[i].attestationAnswerType() != 1, "feed: answerType is the address enum, as on 519");
            require(feeds[i].attestationChainId() == ATTESTATION_CHAIN_ID, "feed: wrong payload chainId");
            require(feeds[i].maxAge() == MAX_AGE, "feed: wrong maxAge");
            require(feeds[i].maxDeviationBps() == MAX_DEVIATION_BPS, "feed: wrong maxDeviationBps");
            require(feeds[i].MIN_PANEL_SIZE() == MIN_PANEL_SIZE, "feed: panel floor changed");
            require(feeds[i].MIN_AGREED() == MIN_AGREED, "feed: agreement floor changed");
            require(feeds[i].isStale(), "feed: must open unseeded");
        }
    }
}
