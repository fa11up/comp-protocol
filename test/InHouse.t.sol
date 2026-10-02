// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {ConfigurableSwarmFeed} from "./helpers/ConfigurableSwarmFeed.sol";
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
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {SwarmFeed} from "../src/SwarmFeed.sol";
import {FEE_RECIPIENT} from "../src/DeploymentConfig.sol";

/// A vault with both knobs switched on, so the ceiling and the fee split are actually exercised.
/// Production turns them on by changing the base defaults; this proves the mechanism either way.
contract CappedFeeVault is CDPVault {
    uint256 private immutable _ceiling;
    uint256 private immutable _shareBps;

    constructor(address imd, uint256 ceiling_, uint256 shareBps_, address priceFeed_, address nhiFeed_)
        CDPVault(imd, address(0), address(0), priceFeed_, nhiFeed_)
    {
        _ceiling = ceiling_;
        _shareBps = shareBps_;
    }

    function debtCeiling() public view override returns (uint256) {
        return _ceiling;
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return _shareBps;
    }
}

/// @notice Fork tests for OUR deployment parameters, against live Sepolia state.
/// @dev The repo's own suite proves the contracts. This proves the constructor arguments — the
/// layer that actually failed on launch 519, where `$owner` and an answerType of 1 were both wrong
/// and immutable. Run with: forge test --match-path test/InHouse.t.sol --fork-url $SEPOLIA_RPC_URL
contract InHouseTest is Test {
    // Aliases, not second copies: a literal repeated here would keep passing after someone edited
    // DeploymentConfig, which is exactly the drift this whole change exists to remove.
    address constant ATTESTER = ORACLE_ATTESTER;
    address constant OPERATOR = APPROVED_OPERATOR;
    address constant LIVE_MOCK_IMD = 0xE44AB81Ce23d34E29383dD158a1DfFEB1c10d439;
    uint8 constant ANSWER_TYPE_UINT256 = ATTESTATION_ANSWER_TYPE;
    uint256 constant MAX_AGE = 86_400;
    uint256 constant MAX_DEVIATION_BPS = 2_000;
    // Native ETH wei per 1e18 raw IMD, from the live Uniswap v4 pool
    // 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3. The v3 WETH pool we first
    // used is drained (liquidity() == 0), so its price was a frozen leftover.
    uint256 constant PRICE = 2_219_784_507_040_719;
    uint16 constant MIN_PANEL_SIZE = 25; // mirrors SwarmFeed.MIN_PANEL_SIZE
    uint16 constant MIN_AGREED = 15;     // mirrors SwarmFeed.MIN_AGREED

    PriceFeed priceFeed;
    NhiFeed nhiFeed;
    CDPVault vault;
    CompToken comp;
    MockIMD imd;

    function setUp() public {
        // Every test here reads live Sepolia state, so the suite is meaningless without --fork-url
        // and used to fail setUp() with InvalidToken() on a plain `forge test`. The swarm runs the
        // suite unforked, so a red test it has no way to make green blocks the whole workflow.
        if (LIVE_MOCK_IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        imd = MockIMD(LIVE_MOCK_IMD);
        // Authority and attestation policy are pinned in DeploymentConfig and are not arguments.
        priceFeed = new PriceFeed(MAX_AGE, MAX_DEVIATION_BPS);
        nhiFeed = new NhiFeed(MAX_AGE, MAX_DEVIATION_BPS);
        vault = new CDPVault(address(imd), address(0), address(0), address(priceFeed), address(nhiFeed));
        comp = vault.compToken();
    }

    /// The faucet authority we actually hold, read from live chain state.
    function test_weControlTheLiveFaucet() public view {
        assertEq(imd.deployer(), OPERATOR, "MockIMD faucet is not ours");
    }

    /// Every authority that launch 519 got wrong — read back against the source that pins them, so
    /// this fails if DeploymentConfig and the deployed artifact ever disagree.
    function test_authoritiesLandOnUs() public view {
        assertTrue(priceFeed.isReporter(OPERATOR), "operator cannot report");
        assertEq(priceFeed.relayer(), OPERATOR, "relayer is not us");
        assertEq(priceFeed.attester(), ORACLE_ATTESTER, "attester is not the live oracle signer");
        assertEq(priceFeed.relayer(), ATTESTATION_RELAYER, "relayer is not the pinned relayer");
        assertEq(priceFeed.reporter0(), FEED_REPORTER_0, "reporter0 is not the pinned reporter");
        assertEq(priceFeed.reporter1(), FEED_REPORTER_1, "reporter1 drifted from source");
        assertEq(priceFeed.reporter2(), FEED_REPORTER_2, "reporter2 drifted from source");
        assertEq(priceFeed.quorum(), FEED_QUORUM, "quorum drifted from source");
        assertEq(priceFeed.attestationChainId(), ATTESTATION_CHAIN_ID, "payload chainId drifted");
        assertEq(priceFeed.attestationAnswerType(), ANSWER_TYPE_UINT256, "answerType must be 3 = uint256");
        assertEq(priceFeed.MIN_PANEL_SIZE(), MIN_PANEL_SIZE, "panel floor changed");
        assertEq(priceFeed.MIN_AGREED(), MIN_AGREED, "agreement floor changed");
        assertEq(nhiFeed.attestationAnswerType(), ANSWER_TYPE_UINT256, "answerType must be 3 = uint256");
        assertTrue(priceFeed.isStale() && nhiFeed.isStale(), "feeds must open unseeded");
        assertEq(comp.vault(), address(vault), "comp not bound");
        assertEq(comp.totalSupply(), 0, "nonzero opening supply");
    }

    /// The struct string must hash to what the live v2 service signs. This constant was obtained by
    /// recovering real attestation signatures, not by reading our own source back to ourselves.
    function test_typehashMatchesLiveV2Service() public view {
        assertEq(
            priceFeed.ATTESTATION_TYPEHASH(),
            0x9c61a909d173aec816b2730e20b6caa3a25ca10c8a084dbf023e026e53874db4,
            "ATTESTATION_TYPEHASH is not the live v2 struct"
        );
    }

    /// The feed must verify the exact domain the oracle signs when a request carries
    /// consumer {chainId: 11155111, verifyingContract: <this feed>}.
    function test_domainSeparatorMatchesConsumerDomain() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(priceFeed)
            )
        );
        assertEq(priceFeed.DOMAIN_SEPARATOR(), expected, "domain will not match a consumer-pinned attestation");
        assertTrue(priceFeed.DOMAIN_SEPARATOR() != nhiFeed.DOMAIN_SEPARATOR(), "feeds must not share a domain");
    }

    /// Full loop through both mint channels at a real, non-unit price.
    function test_seedThenBorrowRepayAtLivePrice() public {
        _seed(PRICE, 0.9e18);
        assertEq(vault.minCR(), 150, "NHI 0.9 should give minCR 150");
        assertEq(vault.gracePeriod(), 6 hours);

        uint256 debt = 1e18;
        uint256 collateral = (debt * 1e18 * 300) / (PRICE * 100); // 300% of minimum
        vm.startPrank(OPERATOR);
        imd.mint(OPERATOR, collateral);
        imd.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        vault.mintCOMP(debt);
        assertEq(comp.balanceOf(OPERATOR), debt, "COMP not minted");

        MockWorkOracle(address(vault.oracle())).grantRights(OPERATOR, debt);
        vault.mintFromWork(debt);
        assertEq(vault.totalWorkMinted(), debt, "work mint not recorded");
        (, uint256 d1) = vault.positions(OPERATOR);
        assertEq(d1, debt, "work mint must not add debt");

        vault.repayCOMP(debt);
        (, uint256 d2) = vault.positions(OPERATOR);
        assertEq(d2, 0, "debt not cleared");
        vm.stopPrank();
        assertEq(comp.totalSupply(), vault.totalWorkMinted(), "supply invariant broken");
    }

    /// The bug that parked launch 493: the payout must be priced, not a flat 110/100.
    /// Opens at 160% so a single in-band (<=20%) price fall puts it under minCR 150.
    function test_liquidationPayoutIsPricedNotFlat() public {
        _seed(PRICE, 0.9e18);
        uint256 debt = 1e18;
        uint256 collateral = (debt * 1e18 * 160) / (PRICE * 100);
        vm.startPrank(OPERATOR);
        imd.mint(OPERATOR, collateral);
        imd.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        vault.mintCOMP(debt);
        vm.stopPrank();

        uint256 fallen = _maxDownStep(PRICE); // the largest single step the band allows
        vm.prank(OPERATOR);
        priceFeed.report(fallen);
        assertLt(vault.collateralRatio(OPERATOR), vault.minCR(), "position should be underwater");

        vault.markUnderwater(OPERATOR);
        skip(6 hours);
        uint256 repay = debt / 2;
        uint256 expected = (repay * 11e17) / fallen; // floor(debtToRepay * 1.1e18 / price)
        assertTrue(expected != repay * 110 / 100, "at a non-unit price the two formulas must differ");

        uint256 before = imd.balanceOf(OPERATOR);
        vm.prank(OPERATOR);
        vault.liquidate(OPERATOR, repay);
        assertEq(imd.balanceOf(OPERATOR) - before, expected, "payout is not floor(repay * 1.1e18 / price)");
    }

    /// OPERATIONAL LIMIT: maxDeviationBps 2000 caps one update at 20% of the last value, and the
    /// bound is floor-based, so the largest legal step is v - floor(v * bps / 10000) exactly — one
    /// wei further reverts. A faster real move must be tracked in successive updates, so the feed
    /// lags a crash. This applies to attested updates too, not only the reporter path.
    function test_deviationCeilingIsExactAndFloorBased() public {
        _seed(PRICE, 0.9e18);
        uint256 floorStep = _maxDownStep(PRICE);

        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        priceFeed.report(floorStep - 1); // one wei past the bound

        vm.prank(OPERATOR);
        priceFeed.report(floorStep); // exactly at the bound is accepted
        (uint256 v,) = priceFeed.latestValue();
        assertEq(v, floorStep);

        // A 36% total fall needs two steps; quorum 1 lets both land in one block.
        vm.prank(OPERATOR);
        priceFeed.report(_maxDownStep(floorStep));
        (uint256 v2,) = priceFeed.latestValue();
        assertLt(v2, floorStep, "second step must move further down");
        assertLt(v2, PRICE * 65 / 100, "two steps should clear a 35% fall");
    }

    function _maxDownStep(uint256 v) private pure returns (uint256) {
        return v - (v * 2_000) / 10_000;
    }

    /// A wrong-question attestation is refused before any signature work.
    function test_attestationGuardsRejectWrongTypeAndChain() public {
        SwarmFeed.OracleAttestation memory a;
        a.chainId = 1;
        a.panelSize = MIN_PANEL_SIZE;
        a.agreed = MIN_AGREED;
        a.answerType = 0; // bool, not uint256
        a.expiresAt = uint64(block.timestamp + 600);
        a.issuedAt = uint64(block.timestamp);
        a.figure = PRICE;
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.InvalidAnswerType.selector);
        priceFeed.submitAttestation(a, new bytes(65));

        a.answerType = ANSWER_TYPE_UINT256;
        a.chainId = 11155111; // Sepolia payload, but our questions are asked about mainnet
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.InvalidAttestationChain.selector);
        priceFeed.submitAttestation(a, new bytes(65));
    }

    /// Only our relayer may submit, which is the whole point of the nonzero relayer.
    function test_onlyOurRelayerMaySubmit() public {
        SwarmFeed.OracleAttestation memory a;
        a.chainId = 1;
        a.panelSize = MIN_PANEL_SIZE;
        a.agreed = MIN_AGREED;
        a.answerType = ANSWER_TYPE_UINT256;
        vm.prank(address(0xBEEF));
        vm.expectRevert(SwarmFeed.UnauthorizedRelayer.selector);
        priceFeed.submitAttestation(a, new bytes(65));
    }

    /// END-TO-END attested update, with an attester key we control, proving SwarmFeed's digest
    /// (typehash field order + domain) and our relay payload agree. The only piece this cannot
    /// cover is whether the live service signs the same struct — that is proven separately by
    /// recovering real attestation signatures, which is how answerType=3 was established.
    function test_attestedUpdateAcceptedFromRelayer() public {
        (address signer, uint256 pk) = makeAddrAndKey("test-attester");
        // PriceFeed pins the live attester, whose key nobody here holds, so this one test leaf is
        // configurable. What it proves is SwarmFeed's digest, which PriceFeed inherits unchanged.
        ConfigurableSwarmFeed f = new ConfigurableSwarmFeed(
            signer, OPERATOR, 1, ANSWER_TYPE_UINT256, OPERATOR, address(0), address(0), 1, MAX_AGE, MAX_DEVIATION_BPS
        );

        SwarmFeed.OracleAttestation memory a = SwarmFeed.OracleAttestation({
            requestId: keccak256("request-1"),
            chainId: 1,
            questionHash: keccak256("imd/weth spot"),
            answerType: ANSWER_TYPE_UINT256,
            answer: abi.encode(PRICE),
            figure: PRICE,
            fromBlock: 26084097,
            toBlock: 26091409,
            blockHash: keccak256("closing"),
            panelJobId: keccak256("panel"),
            panelSize: MIN_PANEL_SIZE,
            quorum: 10,
            agreed: MIN_AGREED,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 3600)
        });
        bytes memory sig = _sign(f, a, pk);

        vm.prank(OPERATOR);
        f.submitAttestation(a, sig);

        (uint256 v,) = f.latestValue();
        assertEq(v, PRICE, "figure not taken as the value");
        assertFalse(f.isStale(), "feed should be fresh after an attested update");

        // The same attestation cannot be replayed.
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.ReplayedAttestation.selector);
        f.submitAttestation(a, sig);
    }

    /// A signature from anyone other than the pinned attester is refused.
    function test_attestedUpdateRejectsForeignSigner() public {
        (address signer,) = makeAddrAndKey("test-attester");
        (, uint256 wrongPk) = makeAddrAndKey("impostor");
        ConfigurableSwarmFeed f = new ConfigurableSwarmFeed(
            signer, OPERATOR, 1, ANSWER_TYPE_UINT256, OPERATOR, address(0), address(0), 1, MAX_AGE, MAX_DEVIATION_BPS
        );
        SwarmFeed.OracleAttestation memory a;
        a.chainId = 1;
        a.panelSize = MIN_PANEL_SIZE;
        a.agreed = MIN_AGREED;
        a.answerType = ANSWER_TYPE_UINT256;
        a.figure = PRICE;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 3600);
        // Build the signature first: _sign staticcalls the feed, and an armed expectRevert
        // would otherwise catch that call instead of submitAttestation.
        bytes memory sig = _sign(f, a, wrongPk);
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        f.submitAttestation(a, sig);
    }

    function _sign(SwarmFeed f, SwarmFeed.OracleAttestation memory a, uint256 pk)
        private
        view
        returns (bytes memory)
    {
        // Split and concatenated for the same reason the contract does it: sixteen words in one
        // abi.encode is a stack-too-deep, and every field is a static single-word type.
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType,
                    keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// v2's point: the contract sets the bar, not the request. A small panel or thin agreement is
    /// refused here even though the service was willing to sign it.
    function test_feedRefusesSmallPanelAndThinAgreement() public {
        SwarmFeed.OracleAttestation memory a;
        a.chainId = 1;
        a.answerType = ANSWER_TYPE_UINT256;
        a.panelSize = MIN_PANEL_SIZE - 1;
        a.agreed = MIN_AGREED;
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.PanelTooSmall.selector);
        priceFeed.submitAttestation(a, new bytes(65));

        a.panelSize = MIN_PANEL_SIZE;
        a.agreed = MIN_AGREED - 1;
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.NotEnoughAgreement.selector);
        priceFeed.submitAttestation(a, new bytes(65));

        // agreed can never exceed the panel it came from
        a.agreed = MIN_PANEL_SIZE + 1;
        vm.prank(OPERATOR);
        vm.expectRevert(SwarmFeed.NotEnoughAgreement.selector);
        priceFeed.submitAttestation(a, new bytes(65));
    }

    /// The ceiling is a hard stop on collateral-backed debt, and it does not touch the work channel.
    function test_debtCeilingStopsMintingAndFreesOnRepay() public {
        CappedFeeVault v = new CappedFeeVault(address(imd), 10 ether, 0, address(priceFeed), address(nhiFeed));
        _seed(PRICE, 0.9e18);
        uint256 collateral = (100 ether * 1e18 * 300) / (PRICE * 100);
        vm.startPrank(OPERATOR);
        imd.mint(OPERATOR, collateral);
        imd.approve(address(v), collateral);
        v.depositCollateral(collateral);

        v.mintCOMP(10 ether);
        assertEq(v.totalDebt(), 10 ether, "totalDebt not tracked");
        vm.expectRevert(CDPVault.DebtCeilingReached.selector);
        v.mintCOMP(1);

        v.repayCOMP(4 ether);
        assertEq(v.totalDebt(), 6 ether, "repay must free headroom");
        v.mintCOMP(4 ether); // the freed headroom is usable again
        assertEq(v.totalDebt(), 10 ether);
        vm.stopPrank();
    }

    /// The protocol's cut comes out of the bonus. The borrower loses exactly the same either way, and
    /// the liquidator is always made whole on the debt it burned.
    function test_feeSplitTakesFromBonusNotPrincipal() public {
        uint256 shareBps = 2_000; // a fifth of the 10% bonus = 2% of the repaid debt
        CappedFeeVault v =
            new CappedFeeVault(address(imd), type(uint256).max, shareBps, address(priceFeed), address(nhiFeed));
        _seed(PRICE, 0.9e18);

        uint256 debt = 1 ether;
        uint256 collateral = (debt * 1e18 * 160) / (PRICE * 100);
        vm.startPrank(OPERATOR);
        imd.mint(OPERATOR, collateral);
        imd.approve(address(v), collateral);
        v.depositCollateral(collateral);
        v.mintCOMP(debt);
        vm.stopPrank();

        uint256 fallen = PRICE - (PRICE * 2_000) / 10_000;
        vm.prank(OPERATOR);
        priceFeed.report(fallen);
        v.markUnderwater(OPERATOR);
        skip(6 hours);

        uint256 seized = (debt * 11e17) / fallen;
        uint256 principal = (debt * 1e18) / fallen;
        uint256 expectedCut = ((seized - principal) * shareBps) / 10_000;
        assertGt(expectedCut, 0, "the split must actually move value");

        // FEE_RECIPIENT is miyagod.eth, which is also OPERATOR here, so the liquidator has to be a
        // different account or the two payouts land in one balance. That is not just a test detail:
        // the fee recipient must never be the party that sets the price or runs liquidations.
        address liquidator = address(0xBEEF);
        // This vault created its own CompToken (compToken_ = 0), so it is not the one from setUp.
        CompToken vComp = v.compToken();
        vm.prank(OPERATOR);
        vComp.transfer(liquidator, debt);

        uint256 feeBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 liqBefore = imd.balanceOf(liquidator);
        (uint256 collBefore,) = v.positions(OPERATOR);

        vm.prank(liquidator);
        v.liquidate(OPERATOR, debt);

        (uint256 collAfter,) = v.positions(OPERATOR);
        assertEq(collBefore - collAfter, seized, "borrower's loss must be unchanged by the fee");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeBefore, expectedCut, "protocol cut wrong");
        assertEq(imd.balanceOf(liquidator) - liqBefore, seized - expectedCut, "liquidator cut wrong");
        assertGt(seized - expectedCut, principal, "liquidator must still clear the principal");
    }

    function _seed(uint256 price, uint256 nhi) private {
        vm.startPrank(OPERATOR);
        priceFeed.report(price);
        nhiFeed.report(nhi);
        vm.stopPrank();
        assertFalse(priceFeed.isStale());
        assertFalse(nhiFeed.isStale());
    }
}
