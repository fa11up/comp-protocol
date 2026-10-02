// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {PriceFeed} from "src/PriceFeed.sol";
import {NhiFeed} from "src/NhiFeed.sol";
import {CDPVault} from "src/CDPVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";
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
} from "src/DeploymentConfig.sol";

abstract contract SwarmFeedTest is Test {
    uint256 private constant SIGNER_KEY = 0x12345;
    bytes32 private constant QUESTION = keccak256("collateral price");
    address private constant REPORTER_A = address(0xA);
    address private constant REPORTER_B = address(0xB);
    address private constant REPORTER_C = address(0xC);
    SwarmFeed private feed;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
    }

    function test_quorumMedianRoundAndFreshnessBoundary() public {
        assertTrue(feed.isStale());
        _report(REPORTER_A, 1.1 ether);
        vm.expectRevert(SwarmFeed.AlreadyReported.selector);
        _report(REPORTER_A, 1 ether);
        vm.expectRevert(SwarmFeed.UnauthorizedReporter.selector);
        feed.report(1 ether);
        _report(REPORTER_B, 0.9 ether);
        (uint256 unpublished,) = feed.latestValue();
        assertEq(unpublished, 0);
        uint256 startedAt = block.timestamp;
        vm.warp(startedAt + 15 minutes);
        _report(REPORTER_C, 1 ether);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, 1 ether);
        assertEq(updatedAt, startedAt, "later quorum votes cannot renew the oldest vote");
        assertEq(feed.round(), 2);
        assertFalse(feed.isStale());
        vm.warp(startedAt + 1 hours);
        assertFalse(feed.isStale());
        vm.warp(startedAt + 1 hours + 1);
        assertTrue(feed.isStale());
    }

    function test_expiredIncompleteRoundDiscardsOldVotes() public {
        _report(REPORTER_A, 100 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        _report(REPORTER_B, 3 ether);
        _report(REPORTER_C, 2 ether);
        assertTrue(feed.isStale());
        _report(REPORTER_A, 1 ether);
        (uint256 value,) = feed.latestValue();
        assertEq(value, 2 ether);
    }

    function test_pendingQuorumCompletesAtExactMaxAgeWithoutRenewingFreshness() public {
        uint256 startedAt = block.timestamp;
        _report(REPORTER_A, 1.1 ether);
        _report(REPORTER_B, 0.9 ether);
        vm.warp(startedAt + 1 hours);
        _report(REPORTER_C, 1 ether);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, 1 ether);
        assertEq(updatedAt, startedAt);
        assertFalse(feed.isStale());
        assertEq(feed.reportCount(), 0);
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale());
    }

    function test_deviationAtLimitAcceptedAndBeyondRejectedAtomically() public {
        _report(REPORTER_A, 1 ether);
        _report(REPORTER_B, 1 ether);
        _report(REPORTER_C, 1 ether);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        _report(REPORTER_A, 1.1 ether + 1);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        _report(REPORTER_A, 0.9 ether - 1);
        assertEq(feed.reportCount(), 0);
        _report(REPORTER_A, 1.1 ether);
        _report(REPORTER_B, 1.1 ether);
        _report(REPORTER_C, 1.1 ether);
        (uint256 value,) = feed.latestValue();
        assertEq(value, 1.1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_threeReporterMedian(uint128 a, uint128 b, uint128 c) public {
        a = uint128(bound(a, 1, type(uint128).max));
        b = uint128(bound(b, 1, type(uint128).max));
        c = uint128(bound(c, 1, type(uint128).max));
        _report(REPORTER_A, a);
        _report(REPORTER_B, b);
        _report(REPORTER_C, c);
        (uint256 actual,) = feed.latestValue();
        uint256 lo = a < b ? a : b;
        if (c < lo) lo = c;
        uint256 hi = a > b ? a : b;
        if (c > hi) hi = c;
        assertEq(actual, uint256(a) + b + c - lo - hi);
    }

    function test_zeroReportAndAttestationRevertWithoutConsumingRoundOrRequest() public {
        vm.expectRevert(SwarmFeed.ZeroValue.selector);
        _report(REPORTER_A, 0);
        assertEq(feed.reportCount(), 0);
        assertTrue(feed.isStale());
        // The failed vote must not prevent the same reporter from submitting a valid value.
        _report(REPORTER_A, 1 ether);
        assertEq(feed.reportCount(), 1);

        SwarmFeed.OracleAttestation memory a = _attestation();
        a.figure = 0;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.ZeroValue.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertEq(feed.reportCount(), 1, "failed attestation preserves pending votes");
        assertTrue(feed.isStale());
        a.figure = 1 ether;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        assertTrue(feed.usedRequests(a.requestId));
        assertFalse(feed.isStale());
    }

    function test_evenQuorumMeanDoesNotOverflow() public {
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, REPORTER_A, REPORTER_B, address(0), 2, 1 hours, 1000);
        _report(REPORTER_A, type(uint256).max);
        _report(REPORTER_B, type(uint256).max - 1);
        (uint256 value,) = feed.latestValue();
        assertEq(value, type(uint256).max - 1);
    }

    function test_attestationPublishesSignedFigureDiscardsPendingRoundAndRejectsReplay() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        _report(REPORTER_A, 99 ether);
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(address(0xCAFE));
        feed.submitAttestation(a, sig);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, a.figure);
        assertEq(updatedAt, a.issuedAt);
        assertEq(feed.reportCount(), 0, "primary update discards unfinished fallback round");
        assertTrue(feed.usedRequests(a.requestId));
        vm.expectRevert(SwarmFeed.ReplayedAttestation.selector);
        feed.submitAttestation(a, sig);
    }

    function test_attestationDiscardedVotesCannotCompleteNextRound() public {
        _report(REPORTER_A, 99 ether);
        _report(REPORTER_B, 99 ether);
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        vm.warp(block.timestamp + 1);
        uint256 newRoundStartedAt = block.timestamp;
        _report(REPORTER_C, 1.1 ether);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, a.figure, "discarded votes cannot publish another value");
        assertEq(updatedAt, a.issuedAt);
        assertEq(feed.reportCount(), 1);
        _report(REPORTER_A, 1.1 ether);
        vm.expectRevert(SwarmFeed.AlreadyReported.selector);
        _report(REPORTER_A, 1.1 ether);
        _report(REPORTER_B, 1.1 ether);
        (value, updatedAt) = feed.latestValue();
        assertEq(value, 1.1 ether);
        assertEq(updatedAt, newRoundStartedAt);
        assertEq(feed.reportCount(), 0);
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
        assertEq(feed.round(), 3);
    }

    function test_attestationRelayerGateProtectsFirstValueAndStaleReanchor() public {
        address relayer = address(0xCAFE);
        feed = _deployFeed(vm.addr(SIGNER_KEY), relayer, 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
        _report(REPORTER_A, 1 ether);
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(vm.addr(SIGNER_KEY));
        vm.expectRevert(SwarmFeed.UnauthorizedRelayer.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertEq(feed.reportCount(), 1);
        assertEq(feed.round(), 1);
        assertTrue(feed.isStale());

        vm.prank(relayer);
        feed.submitAttestation(a, sig);
        assertTrue(feed.usedRequests(a.requestId));
        assertEq(feed.reportCount(), 0);
        assertFalse(feed.isStale());

        vm.warp(block.timestamp + 1 hours + 1);
        a = _attestation();
        a.requestId = keccak256("request-2");
        a.figure = 10 ether;
        sig = _sign(a, SIGNER_KEY);
        vm.prank(REPORTER_A);
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

    function test_attestationZeroRelayerAllowsDifferentSubmitters() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(address(0xCAFE));
        feed.submitAttestation(a, sig);
        a.requestId = keccak256("request-2");
        sig = _sign(a, SIGNER_KEY);
        vm.prank(address(0xBEEF));
        feed.submitAttestation(a, sig);
        assertTrue(feed.usedRequests(keccak256("request-1")));
        assertTrue(feed.usedRequests(a.requestId));
        assertEq(feed.round(), 3);
    }

    function test_attestationRejectsSignedWrongChainOrTypeThenAcceptsConfiguredPolicy() public {
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 10, 2, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.chainId = block.chainid;
        a.answerType = 2;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidAttestationChain.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
        assertEq(feed.round(), 1);

        a.chainId = 10;
        a.answerType = 1;
        sig = _sign(a, SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidAnswerType.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
        assertEq(feed.round(), 1);

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
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
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
        PriceFeed price = new PriceFeed(1 hours, 10000);
        NhiFeed nhi = new NhiFeed(1 hours, 10000);
        vm.startPrank(FEED_REPORTER_0);
        price.report(1.5 ether);
        nhi.report(0.85 ether);
        vm.stopPrank();
        MockIMD imd = new MockIMD();
        CompToken comp = new CompToken(address(0));
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(price));
        CDPVault vault =
            new CDPVault(address(imd), address(comp), address(0), address(price), address(nhi), address(spot));
        vm.startPrank(operator);
        comp.setVault(address(vault));
        imd.mint(REPORTER_A, 140 ether);
        vm.stopPrank();
        vm.startPrank(REPORTER_A);
        imd.approve(address(vault), 140 ether);
        vault.depositCollateral(140 ether);
        vault.mintCOMP(100 ether);
        comp.transfer(REPORTER_B, 100 ether);
        vm.stopPrank();
        vm.prank(FEED_REPORTER_0);
        price.report(1 ether);
        vault.markUnderwater(REPORTER_A);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(REPORTER_B);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(REPORTER_A, 100 ether);
        vm.prank(FEED_REPORTER_0);
        price.report(1 ether);
        vm.prank(REPORTER_B);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(REPORTER_A, 100 ether);
        vm.prank(FEED_REPORTER_0);
        nhi.report(0.85 ether);
        vm.prank(REPORTER_B);
        vault.liquidate(REPORTER_A, 100 ether);
        assertEq(imd.balanceOf(REPORTER_B), 109 ether, "liquidator receives principal plus 90% of bonus");
        assertEq(imd.balanceOf(address(this)), 1 ether, "distinct marker receives 10% of bonus");
        assertEq(imd.balanceOf(REPORTER_B) + imd.balanceOf(address(this)), 110 ether);
        assertEq(comp.totalSupply(), 0);
        (uint256 remaining, uint256 debt) = vault.positions(REPORTER_A);
        assertEq(remaining, 30 ether);
        assertEq(debt, 0);
    }

    function test_constructorRejectsInvalidConfiguration() public {
        address attester = vm.addr(SIGNER_KEY);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(address(0), address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 0, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, address(0), address(0), 2, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, address(0), address(0), address(0), 1, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 0, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 10001);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_A, REPORTER_C, 2, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_A, 2, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.InvalidConfiguration.selector);
        _deployFeed(attester, address(0), 1, 1, REPORTER_A, REPORTER_B, REPORTER_B, 2, 1 hours, 1000);
    }

    function test_singleReporterQuorumAllowsNewRoundAndRejectsUnlistedReporter() public {
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, REPORTER_A, address(0), address(0), 1, 1 hours, 1000);
        vm.expectRevert(SwarmFeed.UnauthorizedReporter.selector);
        _report(REPORTER_B, 1 ether);
        _report(REPORTER_A, 1 ether);
        (uint256 value,) = feed.latestValue();
        assertEq(value, 1 ether);
        assertEq(feed.round(), 2);
        _report(REPORTER_A, 1.1 ether);
        (value,) = feed.latestValue();
        assertEq(value, 1.1 ether);
        assertEq(feed.round(), 3);
        assertEq(feed.reportCount(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_evenQuorumFloorsMean(uint256 a, uint256 b) public {
        feed = _deployFeed(vm.addr(SIGNER_KEY), address(0), 1, 1, REPORTER_A, REPORTER_B, address(0), 2, 1 hours, 1000);
        a = bound(a, 1, type(uint256).max);
        b = bound(b, 1, type(uint256).max);
        _report(REPORTER_B, b);
        (uint256 unpublished,) = feed.latestValue();
        assertEq(unpublished, 0);
        _report(REPORTER_A, a);
        (uint256 actual,) = feed.latestValue();
        assertEq(actual, a / 2 + b / 2 + (a % 2 + b % 2) / 2);
    }

    function test_reportRejectsUnrepresentableTimestampWithoutConsumingVote() public {
        vm.warp(uint256(type(uint64).max) + 1);
        vm.expectRevert(SwarmFeed.InvalidTimestamp.selector);
        _report(REPORTER_A, 1 ether);
        assertEq(feed.reportCount(), 0);
        assertEq(feed.lastReportedRound(REPORTER_A), 0);
        assertTrue(feed.isStale());
    }

    function test_staleValueCanReanchorThroughReporterQuorum() public {
        _report(REPORTER_A, 1 ether);
        _report(REPORTER_B, 1 ether);
        _report(REPORTER_C, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        _report(REPORTER_A, 3 ether);
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale());
        _report(REPORTER_A, 3 ether);
        _report(REPORTER_B, 3 ether);
        assertTrue(feed.isStale());
        _report(REPORTER_C, 3 ether);
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, 3 ether);
        assertEq(updatedAt, block.timestamp);
        assertFalse(feed.isStale());
    }

    function test_attestationDeviationRejectedAtomicallyAndBoundaryAccepted() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        _report(REPORTER_A, 1 ether);
        uint256 pendingRound = feed.round();
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
        assertEq(feed.reportCount(), 1);
        assertEq(feed.round(), pendingRound);
        a.figure = 0.9 ether;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        (value, updatedAt) = feed.latestValue();
        assertEq(value, a.figure);
        assertEq(updatedAt, a.issuedAt);
        assertTrue(feed.usedRequests(a.requestId));
        assertEq(feed.reportCount(), 0);
        assertEq(feed.round(), pendingRound + 1);
    }

    function test_staleValueCanReanchorThroughFreshAttestation() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(feed.isStale());
        a = _attestation();
        a.requestId = keccak256("request-2");
        a.figure = 10 ether;
        feed.submitAttestation(a, _sign(a, SIGNER_KEY));
        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, 10 ether);
        assertEq(updatedAt, block.timestamp);
        assertFalse(feed.isStale());
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
            assertEq(feed.round(), 1);
        } else {
            _assertInvalidSignature(a, sig);
        }
    }

    function _assertInvalidSignature(SwarmFeed.OracleAttestation memory a, bytes memory sig) private {
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
        assertEq(feed.round(), 1);
    }

    function _deployFeed(
        address attester,
        address relayer,
        uint256 attestationChainId,
        uint8 attestationAnswerType,
        address reporter0,
        address reporter1,
        address reporter2,
        uint8 quorum,
        uint256 maxAge,
        uint256 maxDeviationBps
    ) internal virtual returns (SwarmFeed);

    function _report(address reporter, uint256 value) private {
        vm.prank(reporter);
        feed.report(value);
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

/// @dev The mechanics above are SwarmFeed's, not a leaf's: quorum, median, rounds, deviation,
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
        address reporter0,
        address reporter1,
        address reporter2,
        uint8 quorum,
        uint256 maxAge,
        uint256 maxDeviationBps
    ) internal override returns (SwarmFeed) {
        return new ConfigurableSwarmFeed(
            attester,
            relayer,
            attestationChainId,
            attestationAnswerType,
            reporter0,
            reporter1,
            reporter2,
            quorum,
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

    function setUp() public {
        vm.chainId(11155111);
        priceFeed = new PriceFeed(1 hours, 1000);
        nhiFeed = new NhiFeed(1 days, 2000);
    }

    function test_bothArtifactsReportTheSourcePinnedAuthority() public view {
        SwarmFeed[2] memory feeds = [SwarmFeed(priceFeed), SwarmFeed(nhiFeed)];
        for (uint256 i; i < feeds.length; ++i) {
            assertEq(feeds[i].attester(), ORACLE_ATTESTER, "attester");
            assertEq(feeds[i].relayer(), ATTESTATION_RELAYER, "relayer");
            assertEq(feeds[i].reporter0(), FEED_REPORTER_0, "reporter0");
            assertEq(feeds[i].reporter1(), FEED_REPORTER_1, "reporter1");
            assertEq(feeds[i].reporter2(), FEED_REPORTER_2, "reporter2");
            assertEq(feeds[i].quorum(), FEED_QUORUM, "quorum");
            assertEq(feeds[i].attestationAnswerType(), ATTESTATION_ANSWER_TYPE, "answerType");
            assertEq(feeds[i].attestationChainId(), ATTESTATION_CHAIN_ID, "payload chainId");
        }
    }

    /// @dev 519's two fatal values, named. answerType 1 is `address`, and a uint256 figure carries 3;
    /// a relayer nobody holds a key for cannot seed or re-anchor the feed.
    function test_theTwoValuesThatBrokeLaunch519CannotRecur() public view {
        assertTrue(priceFeed.attestationAnswerType() != 1, "answerType must not be the address enum");
        assertTrue(priceFeed.relayer() == APPROVED_OPERATOR, "relayer must be an address we operate");
        assertTrue(priceFeed.isReporter(APPROVED_OPERATOR), "operator must be able to seed manually");
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
    }
}
