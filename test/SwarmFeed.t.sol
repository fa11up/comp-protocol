// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {PriceFeed} from "src/PriceFeed.sol";
import {NhiFeed} from "src/NhiFeed.sol";
import {SpotFeed} from "src/SpotFeed.sol";
import {CDPVault} from "src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {ConfigurableSwarmFeed} from "./helpers/ConfigurableSwarmFeed.sol";
import {
    APPROVED_OPERATOR,
    FEE_RECIPIENT,
    ORACLE_ATTESTER,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE
} from "src/DeploymentConfig.sol";
import {SeedablePriceFeed, SeedableNhiFeed, SeedableSpotFeed} from "./helpers/SeedableFeeds.sol";

abstract contract SwarmFeedTest is Test {
    address private constant BORROWER = address(0xA);
    address private constant LIQUIDATOR = address(0xB);
    uint256 private constant SIGNER_KEY = 0x12345;
    bytes32 private constant QUESTION = keccak256("collateral price");
    SwarmFeed private feed;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(this), 1, 1, 1 hours, 1000);
    }

    function test_deviationAtLimitAcceptedAndBeyondRejectedAtomically() public {
        _seed(1 ether);
        _seed(1 ether);
        _seed(1 ether);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        _seed(1.1 ether + 1);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        _seed(0.9 ether - 1);
        _seed(1.1 ether);
        _seed(1.1 ether);
        _seed(1.1 ether);
        (uint256 value,) = feed.latestValue();
        assertEq(value, 1.1 ether);
    }

    /// @dev Renamed: it used to put a pending reporter round in the way and assert the attestation
    /// discarded it. There are no rounds to discard, so what is left is the half that still means
    /// something — the signed figure is published verbatim, and the same request cannot be used twice.
    function test_attestationPublishesSignedFigureAndRejectsReplay() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        // Submitted by the relayer this fixture pins, which is the test contract.
        feed.submitAttestation(a, sig);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, a.figure);
        assertEq(updatedAt, a.issuedAt);
        assertTrue(feed.usedRequests(a.requestId));
        vm.expectRevert(SwarmFeed.ReplayedAttestation.selector);
        feed.submitAttestation(a, sig);
    }

    function test_attestationRejectsWrongDomainSignerAndTamperedFigure() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _signWithDomain(a, SIGNER_KEY, keccak256("unrelated domain"));
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        sig = _sign(a, SIGNER_KEY + 1);
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        sig = _sign(a, SIGNER_KEY);
        ++a.figure;
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
    }

    function test_attestationAcceptsSuccessiveQuestionHashesAndEmitsAcceptedHash() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectEmit(true, false, false, true, address(feed));
        emit SwarmFeed.AttestationAccepted(a.requestId, a.questionHash);
        feed.submitAttestation(a, sig);

        vm.warp(block.timestamp + 1);
        a = _attestation();
        a.requestId = keccak256("request-2");
        a.questionHash = keccak256("same question with a new pinned block window");
        a.figure = 1.1 ether;
        sig = _sign(a, SIGNER_KEY);
        vm.expectEmit(true, false, false, true, address(feed));
        emit SwarmFeed.AttestationAccepted(a.requestId, a.questionHash);
        feed.submitAttestation(a, sig);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, a.figure);
        assertEq(updatedAt, a.issuedAt);
        assertTrue(feed.usedRequests(keccak256("request-1")));
        assertTrue(feed.usedRequests(a.requestId));
    }

    function test_attestationRelayerGateProtectsFirstValueAndStaleReanchor() public {
        address relayer = address(0xCAFE);
        feed = _deployFeed(vm.addr(SIGNER_KEY), relayer, 1, 1, 1 hours, 1000);
        // Deliberately unseeded: the point is that the gate protects the FIRST value, so the feed has
        // to start without one. The old version reported a vote that never reached quorum, which left
        // the feed valueless by a route that no longer exists.
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(vm.addr(SIGNER_KEY));
        vm.expectRevert(SwarmFeed.UnauthorizedRelayer.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());

        vm.prank(relayer);
        feed.submitAttestation(a, sig);
        assertTrue(feed.usedRequests(a.requestId));
        assertFalse(feed.isStale());

        vm.warp(block.timestamp + 1 hours + 1);
        a = _attestation();
        a.requestId = keccak256("request-2");
        a.figure = 1.2 ether; // inside the stale bound: 2 x the 10% cap
        sig = _sign(a, SIGNER_KEY);
        vm.prank(address(0xD00D)); // any caller that is not the pinned relayer
        vm.expectRevert(SwarmFeed.UnauthorizedRelayer.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
        (uint256 value,) = feed.latestValue();
        assertEq(value, 1 ether);
        vm.prank(relayer);
        feed.submitAttestation(a, sig);
        (value,) = feed.latestValue();
        assertEq(value, a.figure);
        assertFalse(feed.isStale());
    }

    /// @dev A zero relayer used to mean "anyone may submit", and that was the hole the audit found:
    /// with nothing identifying WHICH question an attestation answers, anyone who can buy a signature
    /// for this feed's domain sets its price. It is now unconstructable without a pinned question.
    /// test/QuestionBinding.t.sol covers the configuration that replaces it.
    function test_aZeroRelayerIsRefusedWithoutAPinnedQuestion() public {
        vm.expectRevert(SwarmFeed.UnboundQuestionNeedsRelayer.selector);
        _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, 1 hours, 1000);
    }

    function test_attestationRejectsSignedWrongChainOrTypeThenAcceptsConfiguredPolicy() public {
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(this), 10, 2, 1 hours, 1000);
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.chainId = block.chainid;
        a.answerType = 2;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidAttestationChain.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());

        a.chainId = 10;
        a.answerType = 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidAnswerType.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());

        a.answerType = 2;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertTrue(feed.usedRequests(a.requestId));
        (uint256 value,) = feed.latestValue();
        assertEq(value, a.figure);
    }

    function test_attestationDomainBindsDeploymentChainAndFeed() public {
        assertEq(feed.DOMAIN_SEPARATOR(), _domain(block.chainid, address(feed)));
        SwarmFeed.OracleAttestation memory a = _attestation();
        _assertInvalidSignature(a, _signWithDomain(a, SIGNER_KEY, _domain(1, address(0))));
        _assertInvalidSignature(a, _signWithDomain(a, SIGNER_KEY, _domain(1, address(feed))));

        bytes memory sig = _sign(a, SIGNER_KEY);
        SwarmFeed originalFeed = feed;
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(this), 1, 1, 1 hours, 1000);
        assertNotEq(feed.DOMAIN_SEPARATOR(), originalFeed.DOMAIN_SEPARATOR());
        _assertInvalidSignature(a, sig);
        originalFeed.submitAttestation(a, sig);
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertTrue(originalFeed.usedRequests(a.requestId));
        assertTrue(feed.usedRequests(a.requestId));
    }

    function test_attestationDomainRemainsBoundToDeploymentChain() public {
        bytes32 deploymentDomain = _domain(block.chainid, address(feed));
        vm.chainId(1);
        assertEq(feed.DOMAIN_SEPARATOR(), deploymentDomain);
        SwarmFeed.OracleAttestation memory a = _attestation();
        _assertInvalidSignature(a, _signWithDomain(a, SIGNER_KEY, _domain(block.chainid, address(feed))));
        feed.submitAttestation(a, _signWithDomain(a, SIGNER_KEY, deploymentDomain));
        assertTrue(feed.usedRequests(a.requestId));
    }

    function test_attestationRejectsTamperedQuestionExpiredFutureAndStaleData() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.questionHash = keccak256("wrong question");
        bytes memory sig = _sign(a, SIGNER_KEY);
        a.questionHash = QUESTION;
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.expiresAt = uint64(block.timestamp - 1);
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExpiredAttestation.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.issuedAt = uint64(block.timestamp + 1);
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidTimestamp.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.issuedAt = uint64(block.timestamp - 1 hours - 1);
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.StaleAttestation.selector);
        feed.submitAttestation(a, sig);
    }

    function test_expiryEqualityAcceptedWithoutExtendingIssueTimeFreshness() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.issuedAt = uint64(block.timestamp - 1 hours);
        a.expiresAt = uint64(block.timestamp);
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertFalse(feed.isStale());
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale());
    }

    /// @dev Deliberately uses the real deployment artifacts rather than ConfigurableSwarmFeed: the
    /// point is the vault's grace window against the feeds it will actually hold. They pin their own
    /// reporter, so every report() below speaks as that reporter instead of as the test contract.
    function test_realFeedsExpireDuringGraceAndMustRefreshBeforeLiquidation() public {
        address operator = APPROVED_OPERATOR;
        SeedablePriceFeed price = new SeedablePriceFeed(1 hours, 10000);
        SeedableNhiFeed nhi = new SeedableNhiFeed(1 hours, 10000);
        price.seed(1.5 ether);
        nhi.seed(0.85 ether);
        vm.stopPrank();
        MockIMD imd = new MockIMD();
        ImdUSD comp = new ImdUSD(address(0));
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(price));
        CDPVault vault =
            new BaselineVault(address(imd), address(comp), address(0), address(price), address(nhi), address(spot));
        vm.startPrank(operator);
        comp.setVault(address(vault));
        imd.mint(BORROWER, 140 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        imd.approve(address(vault), 140 ether);
        vault.lock(140 ether);
        vault.draw(100 ether);
        comp.transfer(LIQUIDATOR, 100 ether);
        vm.stopPrank();
        price.seed(1 ether);
        vault.bark(BORROWER);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.bite(BORROWER, 100 ether);
        price.seed(1 ether);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.bite(BORROWER, 100 ether);
        nhi.seed(0.85 ether);
        vm.prank(LIQUIDATOR);
        vault.bite(BORROWER, 100 ether);
        assertEq(imd.balanceOf(LIQUIDATOR), 118 ether, "liquidator receives principal plus 90% of bonus");
        assertEq(imd.balanceOf(address(this)), 2 ether, "distinct marker receives 10% of bonus");
        assertEq(imd.balanceOf(LIQUIDATOR) + imd.balanceOf(address(this)), 120 ether);
        assertEq(comp.totalSupply(), 0);
        (uint256 remaining, uint256 debt) = vault.positions(BORROWER);
        assertEq(remaining, 20 ether);
        assertEq(debt, 0);
    }

    function test_constructorRejectsInvalidConfiguration() public {
        address attester = vm.addr(SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(address(0), address(0), 1, 1, 1 hours, 1000);
        // Was InvalidConfiguration when the constructor also validated reporters and quorum. With
        // those gone, a zero relayer on a feed that pins no question is the error that remains — and
        // it is the pairing the HIGH audit finding established, so it is the right one to assert.
        vm.expectRevert(SwarmFeed.UnboundQuestionNeedsRelayer.selector);
        _deployFeed(attester, address(0), 1, 1, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, 0, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, 1 hours, 10001);
    }

    function test_attestationDeviationRejectedAtomicallyAndBoundaryAccepted() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        _seed(1 ether);
        uint64 initialTime = a.issuedAt;
        vm.warp(block.timestamp + 1);
        a = _attestation();
        a.requestId = keccak256("request-2");
        a.figure = 1.1 ether + 1;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);
        a.figure = 0.9 ether - 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, 1 ether);
        assertEq(updatedAt, initialTime);
        assertFalse(feed.usedRequests(a.requestId));
        a.figure = 0.9 ether;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        (value, updatedAt) = feed.latestValue();
        assertEq(value, a.figure);
        assertEq(updatedAt, a.issuedAt);
        assertTrue(feed.usedRequests(a.requestId));
    }

    /// @dev The internal audit's high finding (2026-10-06): a stale feed used to accept ANY value. Now the
    /// epoch that opens on a stale value allows STALE_DEVIATION_MULTIPLE x the cap from it, and nothing
    /// accepted for the next maxAge may leave that band, so a large genuine move is followed one epoch at
    /// a time and a manipulated one moves the price at most the allowance per hour.
    function test_staleValueReanchorsOnlyWithinTheWidenedBound() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        uint256 cap = feed.maxDeviationBps();
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(feed.isStale());

        a = _attestation();
        a.requestId = keccak256("request-2");
        a.figure = 10 ether;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);

        uint256 widest = 1 ether + 1 ether * cap * feed.STALE_DEVIATION_MULTIPLE() / 10_000;
        a.figure = widest + 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);

        a.figure = widest;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, widest);
        assertEq(updatedAt, block.timestamp);
        assertFalse(feed.isStale());

        // The epoch's allowance is spent: within the hour nothing above `widest` is accepted, not even by
        // one wei, because the bound is measured from the anchor (1 ether), not from the last value.
        a = _attestation();
        a.requestId = keccak256("request-3");
        a.figure = widest + 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);
        (uint256 anchor, uint64 openedAt, uint256 allowance) = feed.epoch();
        assertEq(anchor, 1 ether);
        assertEq(openedAt, block.timestamp);
        assertEq(allowance, cap * feed.STALE_DEVIATION_MULTIPLE());
        // A move back inside the band is fine.
        a.figure = 1 ether;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        // An hour on, the next acceptance opens a new epoch from the current value with the plain cap.
        vm.warp(block.timestamp + 1 hours);
        a = _attestation();
        a.requestId = keccak256("request-4");
        a.figure = 1 ether + 1 ether * cap / 10_000 + 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        feed.submitAttestation(a, sig);
        a.figure = 1 ether + 1 ether * cap / 10_000;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        (anchor, openedAt, allowance) = feed.epoch();
        assertEq(anchor, 1 ether, "the new epoch is anchored where the feed stood, not at the new value");
        assertEq(openedAt, block.timestamp);
        assertEq(allowance, cap);
    }

    /// @dev Internal audit 2026-10-06, follow-up: measured against the LAST value, six attestations
    /// relayed back to back (one relayMany call) walked a 20% cap from 1.0 to 3.48 in one block. Against
    /// the anchor, the second one is refused: an hour moves the price by the allowance and no more,
    /// however many attestations are bought.
    function test_chainedAttestationsCannotWalkPastTheEpochBound() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        uint256 cap = feed.maxDeviationBps();
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(feed.isStale());

        uint256 value = 1 ether + 1 ether * cap * feed.STALE_DEVIATION_MULTIPLE() / 10_000;
        a = _attestation();
        a.requestId = keccak256("chain-1");
        a.figure = value;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        // Every further step in the same block, each within the cap of the LAST value, is refused.
        for (uint256 i = 2; i <= 6; ++i) {
            value += value * cap / 10_000;
            a = _attestation();
            a.requestId = keccak256(abi.encode("chain", i));
            a.figure = value;
            bytes memory sig = _sign(a, SIGNER_KEY);
            vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
            feed.submitAttestation(a, sig);
        }
        (uint256 got,) = feed.latestValue();
        assertEq(got, 1 ether + 1 ether * cap * feed.STALE_DEVIATION_MULTIPLE() / 10_000);
    }

    function test_attestationRejectsOlderIssueTimeWithoutConsumingRequest() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        a.requestId = keccak256("request-2");
        --a.issuedAt;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.StaleAttestation.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        ++a.issuedAt;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertTrue(feed.usedRequests(a.requestId), "equal issue times are valid for distinct requests");
    }

    function test_attestationRejectsMalformedAndMalleableSignatures() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        _assertInvalidSignature(a, bytes(""));
        _assertInvalidSignature(a, new bytes(64));
        _assertInvalidSignature(a, new bytes(66));
        _assertInvalidSignature(a, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        bytes memory sig = _sign(a, SIGNER_KEY);
        uint8 originalV = uint8(sig[64]);
        sig[64] = bytes1(uint8(29));
        _assertInvalidSignature(a, sig);
        bytes32 r;
        bytes32 s;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        _assertInvalidSignature(
            a, abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(originalV == 27 ? 28 : 27))
        );
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertTrue(feed.usedRequests(a.requestId), "invalid signatures must not consume the request");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_attestationRejectsTamperedSignedPayload(uint8 field) public {
        field = uint8(bound(field, 0, 10));
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        if (field == 0) a.chainId += 1;
        else if (field == 1) a.answerType += 1;
        else if (field == 2) a.answer = bytes("changed answer");
        else if (field == 3) a.figure += 1;
        else if (field == 4) a.fromBlock += 1;
        else if (field == 5) a.toBlock += 1;
        else if (field == 6) a.blockHash = keccak256("changed block");
        else if (field == 7) a.panelJobId = keccak256("changed panel");
        else if (field == 8) a.requestId = keccak256("changed request");
        else if (field == 9) a.issuedAt -= 1;
        else a.expiresAt += 1;
        if (field == 0 || field == 1) {
            vm.expectRevert(
                field == 0 ? SwarmFeed.InvalidAttestationChain.selector : SwarmFeed.InvalidAnswerType.selector
            );
            feed.submitAttestation(a, sig);
            assertFalse(feed.usedRequests(a.requestId));
            assertTrue(feed.isStale());
        } else {
            _assertInvalidSignature(a, sig);
        }
    }

    function _assertInvalidSignature(SwarmFeed.OracleAttestation memory a, bytes memory sig) private {
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
    }

    function _deployFeed(
        address attester,
        address relayer,
        uint256 attestationChainId,
        uint8 attestationAnswerType,
        uint256 maxAge,
        uint256 maxDeviationBps
    ) internal virtual returns (SwarmFeed);

    /// @dev What `_report` became. There is no account to prank: the reporter fallback is gone, so a
    /// test puts a value in through the seeding door the Configurable/Seedable helpers expose. The
    /// distinction the old helper encoded — WHO may set a value — no longer exists, because nobody may.
    function _seed(uint256 value) private {
        ConfigurableSwarmFeed(address(feed)).seed(value);
    }

    function _attestation() private view returns (SwarmFeed.OracleAttestation memory a) {
        a.requestId = keccak256("request-1");
        a.chainId = 1;
        a.questionHash = QUESTION;
        a.answerType = 1;
        a.answer = bytes("one");
        a.figure = 1 ether;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("panel");
        // Attestation v2: signed panel figures. Set at or above the feed's floors so these tests
        // exercise the guard each one is about rather than tripping the panel check first.
        a.panelSize = 30;
        a.quorum = 10;
        a.agreed = 20;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(SwarmFeed.OracleAttestation memory a, uint256 key) private view returns (bytes memory) {
        return _signWithDomain(a, key, feed.DOMAIN_SEPARATOR());
    }

    function _domain(uint256 chainId, address consumer) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                chainId,
                consumer
            )
        );
    }

    function _signWithDomain(SwarmFeed.OracleAttestation memory a, uint256 key, bytes32 domain)
        private
        pure
        returns (bytes memory)
    {
        bytes32 body = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
                    ),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure
                ),
                abi.encode(
                    a.fromBlock,
                    a.toBlock,
                    a.blockHash,
                    a.panelJobId,
                    a.panelSize,
                    a.quorum,
                    a.agreed,
                    a.issuedAt,
                    a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, body)));
        return abi.encodePacked(r, s, v);
    }
}

/// @dev The mechanics above are SwarmFeed's, not a leaf's: deviation,
/// replay and signature recovery all live in the base. They used to run twice, once through
/// PriceFeed and once through NhiFeed, because the base is abstract and those were the only
/// concrete leaves. Both leaves now pin their authority in source (DeploymentConfig), so neither can
/// be handed the test reporters or the test attester key this suite needs, and running the suite
/// through a test leaf is the only option. What the two runs uniquely proved — that each leaf wires
/// its arguments through to the base unchanged — is now PinnedAuthorityTest's job, and it proves
/// more: that the arguments cannot be wrong because they are no longer arguments.
/// forge-config: default.fuzz.runs = 1000
contract SwarmFeedMechanicsTest is SwarmFeedTest {
    function _deployFeed(
        address attester,
        address relayer,
        uint256 attestationChainId,
        uint8 attestationAnswerType,
        uint256 maxAge,
        uint256 maxDeviationBps
    ) internal override returns (SwarmFeed) {
        return new ConfigurableSwarmFeed(
            attester,
            relayer,
            attestationChainId,
            attestationAnswerType,
            maxAge,
            maxDeviationBps
        );
    }
}

/// @dev The deployment artifacts take no authority argument, so this is all there is to check: the
/// values they were compiled with are the values they report. A template substitution of the kind
/// that made launch 519's feeds permanently inert has nowhere to land — the only way to change any
/// of these is to edit DeploymentConfig.sol, which shows up in a diff.
contract PinnedAuthorityTest is Test {
    PriceFeed private priceFeed;
    NhiFeed private nhiFeed;
    SpotFeed private spotFeed;

    function setUp() public {
        vm.chainId(11155111);
        priceFeed = new PriceFeed(1 hours, 1000);
        nhiFeed = new NhiFeed(1 days, 2000);
        spotFeed = new SpotFeed(30 minutes, 1000);
    }

    function test_bothArtifactsReportTheSourcePinnedAuthority() public {
        SwarmFeed[3] memory feeds = [SwarmFeed(priceFeed), SwarmFeed(nhiFeed), SwarmFeed(spotFeed)];
        for (uint256 i; i < feeds.length; ++i) {
            assertEq(feeds[i].attester(), ORACLE_ATTESTER, "attester");
            assertEq(feeds[i].relayer(), ATTESTATION_RELAYER, "relayer");
            // Four assertions used to pin WHO could report. The authority itself is gone, so what
            // is pinned now is its absence: no deployed feed answers the fallback's selector.
            (bool reported,) =
                address(feeds[i]).call(abi.encodeWithSelector(bytes4(keccak256("report(uint256)")), uint256(1)));
            assertFalse(reported, "a shipped feed has no reporter fallback");
            assertEq(feeds[i].attestationAnswerType(), ATTESTATION_ANSWER_TYPE, "answerType");
            assertEq(feeds[i].attestationChainId(), ATTESTATION_CHAIN_ID, "payload chainId");
        }
    }

    /// @dev 519's two fatal values, named. answerType 1 is `address`, and a uint256 figure carries 3;
    /// and with the reporter fallback deleted there is no key that can seed or re-anchor a feed at all.
    function test_theTwoValuesThatBrokeLaunch519CannotRecur() public view {
        assertTrue(priceFeed.attestationAnswerType() != 1, "answerType must not be the address enum");
        assertTrue(priceFeed.relayer() == ATTESTATION_RELAYER, "relayer must be an address we operate");
        // The separation this used to assert — that whoever sets the price is not whoever collects
        // the fee — is now structural rather than configured. There is no price setter: the reporter
        // fallback is deleted, so no key can seed or re-anchor a feed and there is nobody for the fee
        // recipient to be distinct FROM. What remains to assert is that the relayer, the only address
        // still named on the attestation path, does not collect the fee either.
        assertTrue(ATTESTATION_RELAYER != FEE_RECIPIENT, "the relayer must not collect the fee");
    }

    /// @dev The risk bounds stay arguments because they are the values that legitimately differ per
    /// feed, and a wrong one is loud: it bounds freshness, it cannot capture authority.
    function test_onlyTheRiskBoundsVaryPerFeed() public view {
        assertEq(priceFeed.maxAge(), 1 hours);
        assertEq(nhiFeed.maxAge(), 1 days);
        assertEq(priceFeed.maxDeviationBps(), 1000);
        assertEq(nhiFeed.maxDeviationBps(), 2000);
    }

    /// @dev The per-feed EIP-712 domain still separates them, so an attestation relayed to one feed
    /// is not replayable on the other even though every pinned value above is identical.
    function test_sharedAuthorityDoesNotShareTheConsumerDomain() public view {
        assertTrue(priceFeed.DOMAIN_SEPARATOR() != nhiFeed.DOMAIN_SEPARATOR());
        assertTrue(priceFeed.DOMAIN_SEPARATOR() != spotFeed.DOMAIN_SEPARATOR());
        assertTrue(nhiFeed.DOMAIN_SEPARATOR() != spotFeed.DOMAIN_SEPARATOR());
    }

    /// @dev The manifest names a deployment by its contract name and has no alias field, so the
    /// vault's three feeds must be three distinct artifacts. Deploying PriceFeed twice is what
    /// parked workflow be84ca8c. A separate type is the only representable answer.
    function test_spotIsItsOwnArtifactSoAManifestCanNameIt() public view {
        assertTrue(address(spotFeed) != address(priceFeed), "spot must not be the primary");
        assertNotEq(
            keccak256(address(spotFeed).code), keccak256(address(priceFeed).code), "distinct artifacts"
        );
    }
}
