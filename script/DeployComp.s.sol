// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";

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
    // Signer of every IdentityMD oracle attestation, read from live attestations.
    address constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    // Answer-type enum, recovered empirically: bool=0, address=1, bytes32=2, uint256=3.
    uint8 constant ANSWER_TYPE_UINT256 = 3;

    // The data chain a question is asked about. Our price question targets Ethereum mainnet,
    // because the oracle serves no Sepolia RPC. This is the payload's `chainId` field, NOT the
    // EIP-712 domain — the domain is block.chainid + address(this), set in SwarmFeed's constructor.
    uint256 constant ATTESTATION_CHAIN_ID = 1;

    uint256 constant MAX_AGE = 86_400; // also bounds CDPVault.liquidationWindow()
    uint256 constant MAX_DEVIATION_BPS = 2_000;
    uint8 constant QUORUM = 1;

    // Attestation v2 signs panelSize/quorum/agreed, so the CONSUMER sets the real bar. A request can
    // therefore ask for a low quorum — so that it attests at all — while the feed still refuses
    // anything under these. The dev's own example is panelSize >= 5 && agreed >= 4.
    uint16 constant MIN_PANEL_SIZE = 25; // mirrors SwarmFeed.MIN_PANEL_SIZE
    uint16 constant MIN_AGREED = 15;     // mirrors SwarmFeed.MIN_AGREED

    function run() external {
        address operator = vm.envAddress("OPERATOR");
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

        PriceFeed priceFeed = new PriceFeed(
            ATTESTER, operator, ATTESTATION_CHAIN_ID, ANSWER_TYPE_UINT256,
            operator, address(0), address(0), QUORUM, MAX_AGE, MAX_DEVIATION_BPS
        );
        NhiFeed nhiFeed = new NhiFeed(
            ATTESTER, operator, ATTESTATION_CHAIN_ID, ANSWER_TYPE_UINT256,
            operator, address(0), address(0), QUORUM, MAX_AGE, MAX_DEVIATION_BPS
        );
        // compToken_ = 0 and oracle_ = 0 put the vault in self-contained mode: it creates and
        // permanently binds its own CompToken and MockWorkOracle, so no post-deploy call exists.
        CDPVault vault = new CDPVault(imd, address(0), address(0), address(priceFeed), address(nhiFeed));

        vm.stopBroadcast();

        console2.log("PriceFeed          ", address(priceFeed));
        console2.log("NhiFeed            ", address(nhiFeed));
        console2.log("CDPVault           ", address(vault));
        console2.log("CompToken   (inner)", address(vault.compToken()));
        console2.log("MockWorkOracle(in) ", address(vault.oracle()));

        verify(vault, priceFeed, nhiFeed, imd, operator);
        console2.log("\nAll authority checks passed.");
    }

    /// @dev Fails the run if any immutable did not land on us. 519 would have failed this.
    function verify(CDPVault vault, PriceFeed priceFeed, NhiFeed nhiFeed, address imd, address operator)
        internal
        view
    {
        require(address(vault.imdToken()) == imd, "vault: wrong collateral");
        require(address(vault.priceFeed()) == address(priceFeed), "vault: wrong price feed");
        require(address(vault.nhiFeed()) == address(nhiFeed), "vault: wrong nhi feed");
        require(address(priceFeed) != address(nhiFeed), "feeds must differ");

        CompToken comp = vault.compToken();
        require(comp.vault() == address(vault), "comp: not bound to vault");
        require(comp.totalSupply() == 0, "comp: nonzero opening supply");

        PriceFeed[2] memory feeds = [priceFeed, PriceFeed(address(nhiFeed))];
        for (uint256 i = 0; i < feeds.length; ++i) {
            require(feeds[i].attester() == ATTESTER, "feed: wrong attester");
            require(feeds[i].relayer() == operator, "feed: relayer is not the operator");
            require(feeds[i].isReporter(operator), "feed: operator cannot report");
            require(feeds[i].attestationAnswerType() == ANSWER_TYPE_UINT256, "feed: answerType must be 3 (uint256)");
            require(feeds[i].attestationChainId() == ATTESTATION_CHAIN_ID, "feed: wrong payload chainId");
            require(feeds[i].maxAge() == MAX_AGE, "feed: wrong maxAge");
            require(feeds[i].MIN_PANEL_SIZE() == MIN_PANEL_SIZE, "feed: panel floor changed");
            require(feeds[i].MIN_AGREED() == MIN_AGREED, "feed: agreement floor changed");
            require(feeds[i].isStale(), "feed: must open unseeded");
        }
    }
}
