// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {CDPVault} from "src/CDPVault.sol";
import {CompToken} from "src/CompToken.sol";
import {MockIMD} from "src/MockIMD.sol";

contract SwarmFeedTest is Test {
    uint256 private constant SIGNER_KEY = 0x12345;
    bytes32 private constant QUESTION = keccak256("collateral price");
    address private constant REPORTER_A = address(0xA);
    address private constant REPORTER_B = address(0xB);
    address private constant REPORTER_C = address(0xC);
    SwarmFeed private feed;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        feed = new SwarmFeed(vm.addr(SIGNER_KEY), QUESTION, REPORTER_A, REPORTER_B, REPORTER_C, 3, 1 hours, 1000);
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

    function test_evenQuorumMeanDoesNotOverflow() public {
        feed = new SwarmFeed(vm.addr(SIGNER_KEY), QUESTION, REPORTER_A, REPORTER_B, address(0), 2, 1 hours, 1000);
        _report(REPORTER_A, type(uint256).max);
        _report(REPORTER_B, type(uint256).max - 1);
        (uint256 value,) = feed.latestValue();
        assertEq(value, type(uint256).max - 1);
    }

    function test_attestationAcceptsLiteralMainnetDomainOnSepoliaAndRejectsReplay() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        _report(REPORTER_A, 99 ether);
        bytes memory sig = _sign(a, SIGNER_KEY, 1);
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

    function test_attestationRejectsWrongDomainSignerAndTamperedFigure() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        bytes memory sig = _sign(a, SIGNER_KEY, block.chainid);
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        sig = _sign(a, SIGNER_KEY + 1, 1);
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        sig = _sign(a, SIGNER_KEY, 1);
        ++a.figure;
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        assertFalse(feed.usedRequests(a.requestId));
        assertTrue(feed.isStale());
    }

    function test_attestationRejectsWrongQuestionExpiredFutureAndStaleData() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.questionHash = keccak256("wrong question");
        bytes memory sig = _sign(a, SIGNER_KEY, 1);
        vm.expectRevert(SwarmFeed.InvalidQuestion.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.expiresAt = uint64(block.timestamp - 1);
        sig = _sign(a, SIGNER_KEY, 1);
        vm.expectRevert(SwarmFeed.ExpiredAttestation.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.issuedAt = uint64(block.timestamp + 1);
        sig = _sign(a, SIGNER_KEY, 1);
        vm.expectRevert(SwarmFeed.InvalidTimestamp.selector);
        feed.submitAttestation(a, sig);
        a = _attestation();
        a.issuedAt = uint64(block.timestamp - 1 hours - 1);
        sig = _sign(a, SIGNER_KEY, 1);
        vm.expectRevert(SwarmFeed.StaleAttestation.selector);
        feed.submitAttestation(a, sig);
    }

    function test_expiryEqualityAcceptedWithoutExtendingIssueTimeFreshness() public {
        SwarmFeed.OracleAttestation memory a = _attestation();
        a.issuedAt = uint64(block.timestamp - 1 hours);
        a.expiresAt = uint64(block.timestamp);
        feed.submitAttestation(a, _sign(a, SIGNER_KEY, 1));
        assertFalse(feed.isStale());
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale());
    }

    function test_realFeedsExpireDuringGraceAndMustRefreshBeforeLiquidation() public {
        address operator = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
        SwarmFeed price =
            new SwarmFeed(vm.addr(SIGNER_KEY), QUESTION, address(this), address(0), address(0), 1, 1 hours, 10000);
        SwarmFeed nhi = new SwarmFeed(
            vm.addr(SIGNER_KEY), keccak256("NHI"), address(this), address(0), address(0), 1, 1 hours, 10000
        );
        price.report(1.5 ether);
        nhi.report(0.85 ether);
        MockIMD imd = new MockIMD();
        CompToken comp = new CompToken(address(0));
        CDPVault vault = new CDPVault(address(imd), address(comp), address(0), address(price), address(nhi));
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
        price.report(1 ether);
        vault.markUnderwater(REPORTER_A);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(REPORTER_B);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(REPORTER_A, 100 ether);
        price.report(1 ether);
        vm.prank(REPORTER_B);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.liquidate(REPORTER_A, 100 ether);
        nhi.report(0.85 ether);
        vm.prank(REPORTER_B);
        vault.liquidate(REPORTER_A, 100 ether);
        assertEq(imd.balanceOf(REPORTER_B), 110 ether);
        assertEq(comp.totalSupply(), 0);
        (uint256 remaining, uint256 debt) = vault.positions(REPORTER_A);
        assertEq(remaining, 30 ether);
        assertEq(debt, 0);
    }

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
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(SwarmFeed.OracleAttestation memory a, uint256 key, uint256 domainChainId)
        private
        pure
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("1"),
                domainChainId,
                address(0)
            )
        );
        bytes32 body = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
                    ),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure
                ),
                abi.encode(a.fromBlock, a.toBlock, a.blockHash, a.panelJobId, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, body)));
        return abi.encodePacked(r, s, v);
    }
}
