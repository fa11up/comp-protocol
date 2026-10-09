// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployPreflight} from "./DeployPreflight.sol";
import {SwarmRelay} from "../src/SwarmRelay.sol";
import {WorkOracleFactory} from "../src/WorkOracleFactory.sol";
import {TreasuryFactory} from "../src/TreasuryFactory.sol";
import {SwarmFeed} from "../src/SwarmFeed.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {SpotFeed} from "../src/SpotFeed.sol";
import {OracleAsker} from "../src/OracleAsker.sol";
import {ParameterizedVault} from "../src/ParameterizedVault.sol";
import {Parameters} from "../src/Parameters.sol";
import {Treasury} from "../src/Treasury.sol";
import {SwarmWorkOracle} from "../src/SwarmWorkOracle.sol";
import {SharePriceFeed} from "../src/SharePriceFeed.sol";
import {UsdPriceFeed} from "../src/UsdPriceFeed.sol";
import {
    APPROVED_OPERATOR,
    FEE_RECIPIENT,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    ORACLE_ATTESTER,
    CHAINLINK_ETH_USD,
    WORK_ORACLE_FACTORY,
    WORK_ORACLE_SENTINEL,
    TREASURY_FACTORY,
    INTAKE,
    ORACLE_ASKER,
    PRICE_MAX_AGE,
    NHI_MAX_AGE,
    SPOT_MAX_AGE,
    WORK_ORACLE_MAX_AGE,
    LINE,
    DUTY_BPS,
    CUT_BPS,
    CHIP_BPS,
    SKEW_BPS,
    EARN_MAT_BPS,
    WAGE_WAD,
    REDEMPTION_DIVISOR,
    ASK_MAX_PRICE,
    DRIFT_FALL_TRIGGER_OF_CAP_BPS,
    WIDE_ALLOWANCE_BPS,
    IMD_POOL_ID,
    ORACLE_BUDGET_PER_DAY,
    STREAM_PAYEE,
    STREAM_PER_DAY
} from "../src/DeploymentConfig.sol";

interface IStakedIMD {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
}

/// @notice The mainnet deployment: every contract at a CREATE2 address, the vault's from a salt the
/// source does NOT name.
/// @dev Four contracts are read by others as SOURCE CONSTANTS (DeploymentConfig), so their addresses
/// must be in the bytecode before anything that reads them compiles. CREATE2 through the canonical
/// deterministic deployer makes each address a pure function of initcode and salt, so the whole plan
/// is computable before any transaction, in dependency layers:
///
///   layer 1  SwarmRelay, WorkOracleFactory          -> ATTESTATION_RELAYER, WORK_ORACLE_FACTORY
///   layer 2  PriceFeed, NhiFeed, SpotFeed            (embed ATTESTATION_RELAYER)
///   layer 3  OracleAsker                             -> ORACLE_ASKER  (takes the feeds and the
///            keccak of each Intake body, and each body names its feed as consumer)
///   layer 4  TreasuryFactory                         -> TREASURY_FACTORY (embeds Treasury, which
///            embeds ORACLE_ASKER)
///   layer 5  ParameterizedVault                      (embeds both factories; creates imdUSD,
///            Parameters, its Treasury, SwarmWorkOracle, UsdPriceFeed and SharePriceFeed itself)
///
/// The vault's salt is the operator's secret (`VAULT_SALT`), not a constant here. The canonical deployer
/// binds an address to nothing but (salt, initcode), and the initcode is public once stage one lands: with
/// the salt in this file, anyone could have placed the planned vault between the two stages, live before
/// `verifySeeded`, with a raced first value to draw against (final sweep panel audit 2026-10-08, low).
/// Nothing reads the vault's address as a source constant, so nothing needs the salt before stage two,
/// and stage two is sent through a private relay (MEV Blocker), so the salt is not public before the
/// vault exists. The address is read back into deployment.json.
///
/// No cycle, because `bytecode_hash = "none"`: with a metadata hash, editing ANY constant would change
/// every importer's bytecode and so every address. `check()` computes the plan from the code as
/// compiled and prints the constants it requires; `deploy/mainnet/plan.py` writes them into
/// DeploymentConfig and recompiles until nothing moves (at most five passes, one per layer).
///
/// `run()` refuses to broadcast unless every constant already equals its computed address, so a
/// mistyped address fails the dry run instead of shipping a dead feed. Stage one is resumable: a contract
/// whose address already holds code is skipped, never redeployed. Each stage reads back what it deployed
/// and writes deploy/mainnet/out/deployment.json for the keeper; the vault is recorded only once it exists.
/// Neither stage runs while that record names a deployed vault other than VAULT_SALT's, so a rerun cannot
/// leave a second vault or drop the first from the record.
///
/// The Intake is NOT deployed here: the swarm's developer deploys it. INTAKE is an external address
/// like Chainlink, and OracleAsker's constructor refuses one with no code.
contract DeployMainnet is Script, DeployPreflight {
    // --- deployment choices, part of the deploy commit -------------------------------------------
    bytes32 internal constant SALT_RELAY = keccak256("infer-protocol/mainnet/v1/SwarmRelay");
    bytes32 internal constant SALT_WORK_FACTORY = keccak256("infer-protocol/mainnet/v1/WorkOracleFactory");
    bytes32 internal constant SALT_PRICE = keccak256("infer-protocol/mainnet/v1/PriceFeed");
    bytes32 internal constant SALT_NHI = keccak256("infer-protocol/mainnet/v1/NhiFeed");
    bytes32 internal constant SALT_SPOT = keccak256("infer-protocol/mainnet/v1/SpotFeed");
    bytes32 internal constant SALT_ASKER = keccak256("infer-protocol/mainnet/v1/OracleAsker");
    bytes32 internal constant SALT_TREASURY_FACTORY = keccak256("infer-protocol/mainnet/v1/TreasuryFactory");
    /// @dev A salt that was once committed here. Refused as VAULT_SALT: it is public.
    bytes32 internal constant PUBLIC_VAULT_SALT = keccak256("infer-protocol/mainnet/v1/ParameterizedVault");

    /// @dev Largest move a fresh feed accepts within one epoch (a lifetime from the epoch's anchor), and
    /// the base of the stale allowance: twice this once the value has been stale a whole hour, an eighth
    /// more per further hour (SwarmFeed._allowanceNow). OracleAsker asks on a FALL of a quarter of this (5% at 2000),
    /// never on a rise, and on any feed whose allowance has reached WIDE_ALLOWANCE_BPS.
    uint256 internal constant FEED_MAX_DEVIATION_BPS = 2_000;

    /// @dev The collateral: StakedIMD (ERC-4626 over IMD), and IMD, which the Intake is paid in.
    address internal constant STAKED_IMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant CHAINLINK_ETH_USD_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev The deployment's cost ceiling (the swarm developer's figure, 2026-10-05) and the gas it is
    /// checked against: 26.2M measured on the fork rehearsal, plus margin. At the live base fee plus
    /// MAX_PRIORITY_FEE the whole broadcast must cost at most this, or the script refuses to start —
    /// wait for a cheaper block. Broadcast with `--priority-gas-price` at or below MAX_PRIORITY_FEE.
    uint256 internal constant MAX_DEPLOY_COST = 0.05 ether;
    uint256 internal constant DEPLOY_GAS_BUDGET = 28_000_000;
    uint256 internal constant MAX_PRIORITY_FEE = 0.1 gwei;
    /// @dev EIP-7825: no Ethereum transaction may use more than 2^24 gas. The largest here, the vault,
    /// measured 12.7M; this keeps the script honest if it ever grows.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    string internal constant BODIES = "deploy/mainnet/bodies/";
    string internal constant OUT = "deploy/mainnet/out/";

    struct Plan {
        address relay;
        address workFactory;
        address price;
        address nhi;
        address spot;
        address asker;
        address treasuryFactory;
        address vault; // zero unless VAULT_SALT is set
        bytes priceBody;
        bytes nhiBody;
        bytes spotBody;
    }

    // --- planning ----------------------------------------------------------------------------------

    function plan() public view returns (Plan memory p) {
        p.relay = _at(SALT_RELAY, type(SwarmRelay).creationCode);
        p.workFactory = _at(SALT_WORK_FACTORY, type(WorkOracleFactory).creationCode);
        p.price = _at(SALT_PRICE, _priceInit());
        p.nhi = _at(SALT_NHI, _nhiInit());
        p.spot = _at(SALT_SPOT, _spotInit());
        p.priceBody = _body("price", p.price);
        p.nhiBody = _body("nhi", p.nhi);
        p.spotBody = _body("spot", p.spot);
        p.asker = _at(SALT_ASKER, _askerInit(p));
        p.treasuryFactory = _at(SALT_TREASURY_FACTORY, type(TreasuryFactory).creationCode);
        bytes32 salt = vm.envOr("VAULT_SALT", bytes32(0));
        if (salt != bytes32(0)) p.vault = _at(salt, _vaultInit(p));
    }

    /// @notice Print the plan and every constant it requires. Lines starting `CONFIG ` are what
    /// deploy/mainnet/plan.py reads; it exits nonzero while any of them disagrees with the source.
    function check() external view {
        Plan memory p = plan();
        console2.log("SwarmRelay        ", p.relay);
        console2.log("WorkOracleFactory ", p.workFactory);
        console2.log("PriceFeed         ", p.price);
        console2.log("NhiFeed           ", p.nhi);
        console2.log("SpotFeed          ", p.spot);
        console2.log("OracleAsker       ", p.asker);
        console2.log("TreasuryFactory   ", p.treasuryFactory);
        console2.log("ParameterizedVault", p.vault, p.vault == address(0) ? "(VAULT_SALT unset)" : "");
        _config("ATTESTATION_RELAYER", ATTESTATION_RELAYER, p.relay);
        _config("WORK_ORACLE_FACTORY", WORK_ORACLE_FACTORY, p.workFactory);
        _config("ORACLE_ASKER", ORACLE_ASKER, p.asker);
        _config("TREASURY_FACTORY", TREASURY_FACTORY, p.treasuryFactory);
        _config("CHAINLINK_ETH_USD", CHAINLINK_ETH_USD, CHAINLINK_ETH_USD_MAINNET);
    }

    function _config(string memory name, address current, address wanted) internal pure {
        console2.log(string.concat("CONFIG ", name, " ", vm.toString(wanted), current == wanted ? " ok" : " CHANGE"));
    }

    // --- deployment --------------------------------------------------------------------------------

    /// @notice STAGE ONE: everything but the vault. The feeds are then seeded (runbook 7.1) and checked by
    /// `verifySeeded`, and only then does `runVault` deploy the vault. Deployed in one go, the vault was
    /// live from its constructor while the feeds' first values were still anybody's to relay: whoever
    /// relayed a first value off a pumped pool could draw against it in the same block, before any check
    /// could run (sweep panel audit, oracle, low). The split buys a check the operator runs before THEIR
    /// vault exists; the secret salt and the private relay (see above) keep anyone else's from existing first.
    function run() external {
        Plan memory p = plan();
        _refuseUnlessReady(p);
        _refuseAnotherVault(p);

        vm.startBroadcast();
        _deploy(SALT_RELAY, type(SwarmRelay).creationCode, p.relay);
        _deploy(SALT_WORK_FACTORY, type(WorkOracleFactory).creationCode, p.workFactory);
        _deploy(SALT_PRICE, _priceInit(), p.price);
        _deploy(SALT_NHI, _nhiInit(), p.nhi);
        _deploy(SALT_SPOT, _spotInit(), p.spot);
        _deploy(SALT_ASKER, _askerInit(p), p.asker);
        _deploy(SALT_TREASURY_FACTORY, type(TreasuryFactory).creationCode, p.treasuryFactory);
        vm.stopBroadcast();

        verifyFeeds(p, true);
        _record(p);
        console2.log(
            "\nStage one deployed and verified. Next: runbook 7.1 (buy and relay the first attestations), then"
        );
        console2.log(
            "`--sig verifySeeded()` with REFERENCE_IMD_ETH_WEI and REFERENCE_NHI set, then `--sig runVault()` to deploy the vault."
        );
    }

    /// @notice STAGE TWO: the vault, once the feeds hold their first values and `verifySeeded` passes.
    function runVault() external {
        Plan memory p = plan();
        _refuseUnlessReady(p);
        verifySeeded(p);
        bytes32 salt = vm.envBytes32("VAULT_SALT");
        require(
            salt != bytes32(0) && salt != PUBLIC_VAULT_SALT,
            "VAULT_SALT: set the operator's secret salt, not the public one"
        );
        _refuseAnotherVault(p);

        vm.startBroadcast();
        _deploy(salt, _vaultInit(p), p.vault);
        vm.stopBroadcast();

        // Recorded before it is verified: a vault that exists (ours, or the same initcode placed first by
        // whoever saw the salt) is in deployment.json even when verify then refuses it, so the operator
        // sees what is at the address instead of a stale record (delta panel audit 2026-10-08, low).
        _record(p);
        verify(p);
        console2.log("\nDeployed and verified. Next: runbook section 7 from step 3 (list sIMD, start the keeper).");
    }

    /// @dev Refuses while deployment.json names a deployed vault other than the one VAULT_SALT gives: a rerun
    /// with another salt (or none, for stage one) would deploy a second vault or drop the first from the
    /// record the keeper runs from (delta panel audit 2026-10-08, info).
    function _refuseAnotherVault(Plan memory p) internal view {
        string memory path = string.concat(OUT, "deployment.json");
        if (!vm.exists(path)) return;
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, ".vault")) return;
        address recorded = vm.parseJsonAddress(json, ".vault");
        require(
            recorded.code.length == 0 || recorded == p.vault,
            "deployment.json records a deployed vault: rerun with the VAULT_SALT that deployed it"
        );
    }

    /// @dev Everything that would make the broadcast wrong, checked before it starts.
    function _refuseUnlessReady(Plan memory p) internal view {
        require(block.chainid == 1, "mainnet only (rehearse on an anvil fork of mainnet, chain id 1)");
        require(
            (block.basefee + MAX_PRIORITY_FEE) * DEPLOY_GAS_BUDGET <= MAX_DEPLOY_COST,
            "gas too expensive: the deployment would cost more than 0.05 ETH; wait for a cheaper block"
        );
        _preflightPriceLeg();
        require(CHAINLINK_ETH_USD == CHAINLINK_ETH_USD_MAINNET, "CHAINLINK_ETH_USD is not mainnet's ETH/USD");
        require(ATTESTATION_RELAYER == p.relay, "ATTESTATION_RELAYER != planned SwarmRelay: run deploy/mainnet/plan.py");
        require(WORK_ORACLE_FACTORY == p.workFactory, "WORK_ORACLE_FACTORY != planned factory: run plan.py");
        require(ORACLE_ASKER == p.asker, "ORACLE_ASKER != planned OracleAsker: run plan.py");
        require(TREASURY_FACTORY == p.treasuryFactory, "TREASURY_FACTORY != planned factory: run plan.py");
        require(INTAKE.code.length != 0, "INTAKE has no code: the swarm's Intake is not deployed yet");
        require(CREATE2_FACTORY.code.length != 0, "no deterministic deployer on this chain");

        // Authority: a cold key the source names, never the hot broadcaster.
        address operator = vm.envAddress("OPERATOR");
        require(operator == APPROVED_OPERATOR, "OPERATOR env disagrees with APPROVED_OPERATOR in source");
        require(FEE_RECIPIENT == APPROVED_OPERATOR, "FEE_RECIPIENT must be the cold governance address (runbook 3)");
        require(msg.sender != APPROVED_OPERATOR, "broadcast from a throwaway deployer, not the governance key");

        // The collateral is sIMD over IMD, as the bodies and the asker assume.
        require(IStakedIMD(STAKED_IMD).asset() == IMD, "STAKED_IMD does not wrap IMD");

        // Launch economics, which the vault reads back from Parameters at construction.
        require(WAGE_WAD == 0, "minting from work ships off (runbook 7b)");
        require(STREAM_PAYEE == address(0) && STREAM_PER_DAY == 0, "the operator stream ships off");
    }

    function _deploy(bytes32 salt, bytes memory initcode, address expected) internal {
        if (expected.code.length != 0) {
            console2.log("exists, skipped   ", expected);
            return;
        }
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(bytes.concat(salt, initcode));
        require(before - gasleft() < TX_GAS_CAP, "a deployment exceeds the EIP-7825 per-transaction gas cap");
        require(
            ok && ret.length == 20 && address(bytes20(ret)) == expected, "CREATE2 did not land at the planned address"
        );
        console2.log("deployed          ", expected);
    }

    // --- read back off chain -----------------------------------------------------------------------

    function verify(Plan memory p) public view {
        ParameterizedVault vault = ParameterizedVault(p.vault);
        Parameters parameters = vault.parameters();
        Treasury treasury = vault.treasury();
        UsdPriceFeed usd = vault.usdPriceFeed();
        SharePriceFeed share = SharePriceFeed(address(vault.collateralPriceFeed()));
        SwarmWorkOracle work = SwarmWorkOracle(address(vault.oracle()));

        // Wiring, both directions.
        require(address(vault.gem()) == STAKED_IMD, "vault: collateral is not sIMD");
        require(address(vault.priceFeed()) == p.price, "vault: wrong price feed");
        require(address(vault.nhiFeed()) == p.nhi, "vault: wrong nhi feed");
        require(address(vault.spotFeed()) == p.spot, "vault: wrong spot feed");
        require(vault.stablecoin().vault() == p.vault, "imdUSD: not bound to the vault");
        require(vault.stablecoin().totalSupply() == 0, "imdUSD: nonzero opening supply");
        require(address(parameters.vault()) == p.vault, "parameters: not bound to the vault");
        require(parameters.governor() == APPROVED_OPERATOR, "parameters: wrong governor");
        require(parameters.pendingEta() == 0, "parameters: opens with a pending change");
        require(treasury.vault() == p.vault, "treasury: not the vault's");
        require(vault.feeRecipient() == address(treasury), "vault: revenue does not land in its treasury");
        require(treasury.withdrawer() == APPROVED_OPERATOR, "treasury: wrong withdrawer");
        require(treasury.registrar() == address(parameters), "treasury: register not governed by parameters");
        require(treasury.reserveAssetCount() == 0, "treasury: opens with a reserve register");
        require(address(usd.imdEthFeed()) == p.price, "usd feed: IMD leg is not the price feed");
        require(address(usd.ETH_USD()) == CHAINLINK_ETH_USD_MAINNET, "usd feed: wrong ETH/USD");
        require(share.shareVault() == STAKED_IMD, "share feed: wrong share vault");
        require(address(share.assetFeed()) == address(usd), "share feed: not priced off the USD feed");
        require(work.vault() == p.vault, "work oracle: not the vault's");
        require(work.relayer() == p.relay, "work oracle: wrong relayer");
        require(work.attester() == ORACLE_ATTESTER, "work oracle: wrong attester");
        require(work.maxAge() == WORK_ORACLE_MAX_AGE, "work oracle: wrong maxAge");

        // Economics open at the source values.
        require(vault.line() == LINE, "line drifted from source");
        require(vault.duty() == DUTY_BPS, "duty drifted from source");
        require(vault.cut() == CUT_BPS, "cut drifted from source");
        require(vault.chip() == CHIP_BPS, "chip drifted from source");
        require(vault.skew() == SKEW_BPS, "skew drifted from source");
        require(vault.earnMat() == EARN_MAT_BPS, "earnMat drifted from source");
        require(vault.redemptionDivisor() == REDEMPTION_DIVISOR, "redemption divisor drifted");
        require(parameters.wage() == 0 && work.wage() == 0, "minting from work is not off");
        require(parameters.oracleBudget() == ORACLE_BUDGET_PER_DAY, "oracle budget drifted from source");
        require(parameters.streamPayee() == address(0) && parameters.streamPerDay() == 0, "stream is not off");
        require(vault.totalDebt() == 0 && vault.earnLine() == 0, "vault: opens with debt or a work ceiling");

        verifyFeeds(p, false);
        OracleAsker asker = OracleAsker(p.asker);
        address[3] memory feeds = [p.price, p.nhi, p.spot];
        require(address(asker.payToken()) == IMD, "asker: not paid in IMD");
        bytes[3] memory bodies = [p.priceBody, p.nhiBody, p.spotBody];
        bool[3] memory tracks = [true, false, true];
        bool[3] memory alive = [false, true, false];
        for (uint256 i; i < 3; ++i) {
            (bytes32 bodyHash, bool tracksPool, bool keepAlive,,,,,) = asker.feeds(feeds[i]);
            require(bodyHash == keccak256(bodies[i]), "asker: body hash mismatch");
            require(tracksPool == tracks[i] && keepAlive == alive[i], "asker: wrong trigger policy");
            // The trigger is a property of the feed's cap, not of the policy: a quarter of it on a fall, never a rise.
            (uint256 fall, uint256 rise) = asker.triggerBps(feeds[i]);
            require(
                fall == FEED_MAX_DEVIATION_BPS * DRIFT_FALL_TRIGGER_OF_CAP_BPS / 10_000 && rise == 0,
                "asker: wrong drift trigger (falls only, a quarter of the cap)"
            );
        }
        // The two external links the Treasury-paid path hangs on, which no contract this script deploys
        // can vouch for (final review 2026-10-07, low): the Intake must sell oracle.request for IMD at or
        // under ASK_MAX_PRICE, or every ask() reverts and the NHI keep-alive never fires; and the pool slot
        // must read a price, or drift reads as zero and the Treasury never pays for a fall.
        require(
            asker.price() != 0 && asker.price() <= ASK_MAX_PRICE,
            "asker: the Intake does not sell oracle.request for IMD at or under ASK_MAX_PRICE"
        );
        require(asker.poolPrice() != 0, "asker: the pool slot reads empty (POOL_MANAGER or IMD_POOL_ID wrong)");
        require(WIDE_ALLOWANCE_BPS > FEED_MAX_DEVIATION_BPS * 2, "wide allowance must exceed the stale base");
        require(parameters.workOracle() == address(0), "work-oracle slot is not empty");
        require(vault.gap() == 50, "gap drifted from the Parameters default");
        // poolPrice() != 0 proves IMD_POOL_ID is SOME initialised pool; the pool the asker measures drift
        // against must be the one the pinned price and spot bodies name in their text, or the Treasury
        // pays for falls that did not happen and never for ones that did (second-half review, info).
        bytes memory poolId = bytes(vm.toString(IMD_POOL_ID));
        require(
            _contains(p.priceBody, poolId) && _contains(p.spotBody, poolId),
            "asker: IMD_POOL_ID is not the pool the price and spot bodies name"
        );
        // The fourth SwarmFeed, read back like the other three (same review).
        require(work.expectedQuestionHash(1, 2) != bytes32(0), "work oracle: binds no question");
        require(
            work.attestationChainId() == ATTESTATION_CHAIN_ID
                && work.attestationAnswerType() == ATTESTATION_ANSWER_TYPE,
            "work oracle: wrong data chain or answer type"
        );
        // The Chainlink leg: the broadcast preflight checks it, and a later `--sig verify(...)` must too, or
        // a dead ETH/USD aggregator (every price action StaleFeed) reads as verified (same review).
        _preflightPriceLeg();
    }

    /// @notice Stage one's read-back: the feeds' authority and policy, and the asker's entries. `unseeded`
    /// requires every feed to hold no value yet (fresh from the deploy); `verify` after stage two passes false.
    function verifyFeeds(Plan memory p, bool unseeded) public view {
        address[3] memory feeds = [p.price, p.nhi, p.spot];
        uint256[3] memory ages = [PRICE_MAX_AGE, NHI_MAX_AGE, SPOT_MAX_AGE];
        for (uint256 i; i < 3; ++i) {
            SwarmFeed f = SwarmFeed(feeds[i]);
            require(f.attester() == ORACLE_ATTESTER, "feed: wrong attester");
            require(f.relayer() == p.relay, "feed: wrong relayer");
            require(f.attestationChainId() == ATTESTATION_CHAIN_ID, "feed: wrong data chain");
            require(f.attestationAnswerType() == ATTESTATION_ANSWER_TYPE, "feed: wrong answer type");
            require(f.maxAge() == ages[i], "feed: wrong maxAge");
            require(f.maxDeviationBps() == FEED_MAX_DEVIATION_BPS, "feed: wrong deviation cap");
            if (unseeded) require(f.isStale(), "feed: must open unseeded");
            require(f.expectedQuestionHash(1, 2) != bytes32(0), "feed: binds no question");
            (bool reported,) = feeds[i].staticcall(abi.encodeWithSignature("report(uint256)", uint256(1)));
            require(!reported, "feed: a reporter fallback is reachable");
        }
        OracleAsker asker = OracleAsker(p.asker);
        require(address(asker.payToken()) == IMD, "asker: not paid in IMD");
        if (unseeded) {
            require(
                asker.wideOpen(p.price) && asker.wideOpen(p.nhi) && asker.wideOpen(p.spot),
                "asker: an unseeded feed must read wide open"
            );
        }
    }

    /// @notice Runbook section 7.1, after the first attestations are relayed and BEFORE the vault exists:
    /// refuse a first value someone else raced in. Nothing on chain bounds a feed's first value and the
    /// relay is permissionless, so whoever relays first anchors the feed; a pumped pool attested honestly
    /// is a valid first value two times the market (final panel audit, oracle, low). Every feed must
    /// hold a fresh value, the price and spot feeds within a quarter of the cap (5% at launch) of IMD's
    /// pool as the asker reads it, and of each other within SKEW_BPS, and NHI must lie within the same band
    /// of REFERENCE_NHI (the live index as the operator reads it, 1e18-scaled) and above 0.6e18: a first NHI
    /// at or under 0.6 would open an immutable vault at mat 200 with no grace, and the feed's daily epoch and
    /// 20% allowance would take days to walk it back (payout vault panel 2026-10-09, low). If this fails, do
    /// not deploy the vault: wait for the allowance to widen and relay honest values, then run it again. The
    /// pool itself can be held at the attested level through the check, so the values are also checked
    /// against REFERENCE_IMD_ETH_WEI, a price the operator takes from somewhere the attacker does not control
    /// (the day's observed market, in wei of ETH per 1e18 IMD), and the stage-two deploy refuses to run
    /// without either reference. `forge script script/DeployMainnet.s.sol --sig "verifySeeded()"
    /// --rpc-url <mainnet>` rebuilds the plan from source and checks it.
    function verifySeeded() external view {
        verifySeeded(plan());
    }

    function verifySeeded(Plan memory p) public view {
        OracleAsker asker = OracleAsker(p.asker);
        uint256 pool = asker.poolPrice();
        require(pool != 0, "seeded: the pool slot reads empty");
        uint256 referencePrice = vm.envOr("REFERENCE_IMD_ETH_WEI", uint256(0));
        require(
            referencePrice != 0,
            "seeded: set REFERENCE_IMD_ETH_WEI to the market price from a source the pool cannot be held against"
        );
        uint256 band = FEED_MAX_DEVIATION_BPS * DRIFT_FALL_TRIGGER_OF_CAP_BPS / 10_000;
        (uint256 price, uint256 spot, uint256 nhi) = (_seeded(p.price), _seeded(p.spot), _seeded(p.nhi));
        require(_within(pool, referencePrice, band), "seeded: the pool itself is off the reference price: wait");
        require(
            _within(price, pool, band), "seeded: the price feed's first value is off the pool: do not deploy the vault"
        );
        require(
            _within(spot, pool, band), "seeded: the spot feed's first value is off the pool: do not deploy the vault"
        );
        require(_within(spot, price, SKEW_BPS), "seeded: price and spot disagree beyond SKEW_BPS");
        uint256 referenceNhi = vm.envOr("REFERENCE_NHI", uint256(0));
        require(referenceNhi != 0, "seeded: set REFERENCE_NHI to the live index, 1e18-scaled, as you read it");
        require(nhi <= 1e18, "seeded: NHI above one");
        require(
            nhi > 0.6e18,
            "seeded: NHI at or under 0.6 would open the vault at mat 200 with no grace: do not deploy the vault"
        );
        require(
            _within(nhi, referenceNhi, band),
            "seeded: the NHI feed's first value is off the live index: do not deploy the vault"
        );
        console2.log(
            "Seeded and verified: price, spot and NHI hold fresh values, price and spot on the pool, NHI on the index."
        );
    }

    function _seeded(address feed) internal view returns (uint256 value) {
        SwarmFeed f = SwarmFeed(feed);
        require(!f.isStale(), "seeded: a feed holds no fresh value");
        (value,) = f.latestValue();
        require(value != 0, "seeded: a feed holds zero");
    }

    function _within(uint256 a, uint256 b, uint256 bps) internal pure returns (bool) {
        uint256 d = a > b ? a - b : b - a;
        return d * 10_000 <= b * bps;
    }

    /// @dev Whether `needle` occurs in `hay`. `vm.contains` is not a view, and verify() is.
    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > hay.length) return needle.length == 0;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) ++j;
            if (j == needle.length) return true;
        }
        return false;
    }

    function _record(Plan memory p) internal {
        vm.createDir(string.concat(OUT, "bodies"), true);
        vm.writeFile(string.concat(OUT, "bodies/price.json"), string(p.priceBody));
        vm.writeFile(string.concat(OUT, "bodies/nhi.json"), string(p.nhiBody));
        vm.writeFile(string.concat(OUT, "bodies/spot.json"), string(p.spotBody));
        ParameterizedVault vault = ParameterizedVault(p.vault);
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "block", block.number);
        vm.serializeString(o, "interface", "maker");
        vm.serializeAddress(o, "relay", p.relay);
        vm.serializeAddress(o, "priceFeed", p.price);
        vm.serializeAddress(o, "nhiFeed", p.nhi);
        vm.serializeAddress(o, "spotFeed", p.spot);
        vm.serializeAddress(o, "oracleAsker", p.asker);
        vm.serializeAddress(o, "intake", INTAKE);
        vm.serializeAddress(o, "gem", STAKED_IMD);
        string memory json = vm.serializeAddress(o, "imd", IMD);
        // Stage one records the feeds and the asker, and never the vault's address, which would publish
        // the salt's result before stage two; stage two the vault and what it created.
        if (p.vault.code.length != 0) {
            vm.serializeAddress(o, "vault", p.vault);
            vm.serializeAddress(o, "stablecoin", address(vault.stablecoin()));
            vm.serializeAddress(o, "parameters", address(vault.parameters()));
            vm.serializeAddress(o, "treasury", address(vault.treasury()));
            vm.serializeAddress(o, "usdPriceFeed", address(vault.usdPriceFeed()));
            vm.serializeAddress(o, "collateralPriceFeed", address(vault.collateralPriceFeed()));
            json = vm.serializeAddress(o, "workOracle", address(vault.oracle()));
        }
        vm.writeJson(json, string.concat(OUT, "deployment.json"));
    }

    // --- initcode, one place, used by both the plan and the broadcast ------------------------------

    function _priceInit() internal pure returns (bytes memory) {
        return bytes.concat(type(PriceFeed).creationCode, abi.encode(PRICE_MAX_AGE, FEED_MAX_DEVIATION_BPS));
    }

    function _nhiInit() internal pure returns (bytes memory) {
        return bytes.concat(type(NhiFeed).creationCode, abi.encode(NHI_MAX_AGE, FEED_MAX_DEVIATION_BPS));
    }

    function _spotInit() internal pure returns (bytes memory) {
        return bytes.concat(type(SpotFeed).creationCode, abi.encode(SPOT_MAX_AGE, FEED_MAX_DEVIATION_BPS));
    }

    function _askerInit(Plan memory p) internal pure returns (bytes memory) {
        address[] memory feeds = new address[](3);
        (feeds[0], feeds[1], feeds[2]) = (p.price, p.nhi, p.spot);
        bytes32[] memory hashes = new bytes32[](3);
        (hashes[0], hashes[1], hashes[2]) = (keccak256(p.priceBody), keccak256(p.nhiBody), keccak256(p.spotBody));
        // Price and spot quote IMD/ETH, so pool drift may trigger a Treasury-paid update. Only NHI is
        // kept alive on a clock: a one-hour price kept fresh around the clock costs ~$37k a year.
        bool[] memory tracks = new bool[](3);
        (tracks[0], tracks[2]) = (true, true);
        bool[] memory keepAlive = new bool[](3);
        keepAlive[1] = true;
        return bytes.concat(type(OracleAsker).creationCode, abi.encode(IERC20(IMD), feeds, hashes, tracks, keepAlive));
    }

    function _vaultInit(Plan memory p) internal pure returns (bytes memory) {
        // stablecoin 0: the vault creates imdUSD. WORK_ORACLE_SENTINEL: the real attested work oracle
        // from WORK_ORACLE_FACTORY. Zero would build the test faucet into an immutable vault.
        return bytes.concat(
            type(ParameterizedVault).creationCode,
            abi.encode(STAKED_IMD, address(0), WORK_ORACLE_SENTINEL, p.price, p.nhi, p.spot)
        );
    }

    /// @dev The Intake body for one feed: the frozen template with the feed as its consumer. The
    /// question document excludes `consumer`, so naming the feed does not change the question the feed
    /// pins (deploy/mainnet/check-bodies.mjs proves each template's prefix equals the feed's).
    function _body(string memory name, address feed) internal view returns (bytes memory) {
        string memory template = vm.readFile(string.concat(BODIES, name, ".template.json"));
        return bytes(vm.replace(template, "{{FEED}}", vm.toLowercase(vm.toString(feed))));
    }

    function _at(bytes32 salt, bytes memory initcode) internal pure returns (address) {
        return vm.computeCreate2Address(salt, keccak256(initcode), CREATE2_FACTORY);
    }
}
