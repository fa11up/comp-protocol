# Launch audit — oracle panel (2026-10-05)

Job `f6faeaf9-0d86-44af-8a08-6d80d9f15a96` (order 47565722), `template: audit` at `e52a025`: four specialists and a judge, accepted; models claude-fable-5-1. Raw submissions: `audit-oracle-2026-10-05` json beside this file.

**Kept: 1 high.**

## Judge's summary

partial review: the turn budget ran out with 1 finding(s) written.


## 1. [high] SwarmFeed never compares the signed window with the chain head: an answer signed now over a window that closed hours or days ago is accepted and dated now

`src/SwarmFeed.sol:240`

Function: SwarmFeed._requireQuestion, reached from submitAttestation and inherited by PriceFeed, SpotFeed, NhiFeed and SwarmWorkOracle. Merges four specialist reports of this defect (three high, one low) and the separate low report about windows beyond the head.

The window is checked for span (line 239) and for toBlock > lastToBlock (line 240), and for nothing else. No line relates fromBlock/toBlock to block.number, to issuedAt or to the signed blockHash. Freshness is taken from issuedAt (line 177) and _accept(a.figure, a.issuedAt) dates the value at signing time. So every window that closed after the last accepted one is acceptable, however long ago it closed, and its figure reads as fresh for maxAge. The comment at lines 232-233 ('toBlock must advance, so a freshly signed attestation cannot answer over an ANCIENT window in which the price was whatever the buyer needed it to be'), README.md:99-100, DeploymentConfig.sol:36 ('never mispriced') and docs/PARAMETERS-2026-10-05.md ('Positions are never priced off a stale figure') all claim the opposite. The claim holds only for windows at or before lastToBlock.

Reachable with the constants as committed, for three reasons.
1. Price and spot feeds are deliberately not kept alive (DeploymentConfig.sol:32-38, PRICE_MAX_AGE = SPOT_MAX_AGE = 1 hour), so lastToBlock is routinely hours or days behind the head, and once the value is older than maxAge the deviation bound is lifted (line 299). ATTESTATION_CHAIN_ID is 1, so on mainnet the feed runs on the chain the window is about and could check it.
2. The attester signs windows the buyer pins. The request schema takes window:{fromBlock,toBlock} (oracle/nhi-composite-quote.json, oracle/vwap-oracle-quote.json), and the repository's own threat model assumes this buyer (test/QuestionBinding.t.sol:94-96). I also read the service's public request list on 2026-10-05 (GET api.imd.fun/oracle/requests, the endpoint oracle/question-prefix.mjs --verify uses; this is outside the pinned tree): request 26778b1f-ceda-47b0-a7ac-78d5f8adebfd, chainId 1, was created at 06:45:21Z with window 26122900..26122901. Mainnet block 26122901 has timestamp 1791163955 (01:32:35Z) and the attestation's issuedAt is 1791182787, so the attester signed 5 h 14 min, about 1,569 blocks, after the window closed. In the same list, 96 chain-read requests created within two minutes cover 16 different back-to-back windows spanning about 188,000 blocks of another chain. The service does sign old windows, dated now.
3. The consumer domain is named by the requester and SwarmRelay admits everyone, so the buyer needs no privilege: copy the pinned question, replace window:{hours:N} with explicit blocks, name the feed as consumer.

Call sequence (unprivileged, about 1 IMD): (a) the primary and spot feeds last accepted windows closing near block B0, then nobody bought an update for some hours or days (normal); (b) the attacker buys the pinned primary question over [W, W+300..1200] and the pinned spot question with toBlock in the same period, B0 < toBlock, choosing the period since B0 whose price suits them. Windows may overlap and need only advance by one block, so one favourable hour supplies as many attestations as wanted; (c) SwarmRelay.relayMany([primary, spot], ...) and the vault action in one transaction. Both feeds read fresh, they agree within SKEW_BPS because both windows come from the same period, and the vault acts on that period's price.

What the vault then does, reproduced through ParameterizedVault and SwarmRelay with question-bound leaves (ETH at $2,500, IMD at $10 now):
- cash at a past low. With a three-day-old $9 window as the price, burning 1,000 imdUSD (5% of supply, fee 300 bps) paid 107.78 IMD, worth $1,077.78 at the live price, taken from a borrower at 180% who had $1,000 of debt cancelled. Any upward drift since the last update larger than the redemption fee is taken this way, from the Treasury's reserve first and then from any position inside mat + gap at the stal

**Reproduction**

test/scratch/WindowRecency.t.sol (attached), a leaf with PriceFeed's policy (span 300..1200, maxAge 1 hour, 5000 bps) on chain 1, block 26,100,000. An honest attestation over [26,099,380, 26,099,980] is accepted. Warp 3 days, roll 21,600 blocks: isStale() is true. Submit a validly signed attestation with issuedAt = now, fromBlock 26,099,981, toBlock 26,100,581 (closed 21,019 blocks, about 70 hours, before the head), figure half the honest price, questionHash = expectedQuestionHash(26099981, 26100581). Expected: revert. Actual: accepted; latestValue() is the three-day-old figure dated now and isStale() is false for the next hour. Second test: fromBlock head + 999,400, toBlock head + 1,000,000. Expected: revert. Actual: accepted, lastToBlock == 27,100,000. Both fail on this commit ('a window that closed three days before the head was accepted', 'a window that has not happened yet was accepted'); the control (signed over a window that closed 20 blocks ago, relayed 10 minutes later) passes. All three pass with the fix above, with the maxSpan variant and with the blockhash variant, each tried on a patched copy. The three specialist proofs for this finding were also run and fail the same way. Vault figures above come from a second scratch test (StaleWindowVault.t.sol, not attached) driving ParameterizedVault.cash and draw after SwarmRelay.relayMany.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";

/// @dev A question-bound leaf with PriceFeed's policy (span 300..1200 blocks, one-hour lifetime, the
/// deploy scripts' 5000 bps), on the chain its question is about (chain 1), which is the mainnet
/// launch: the data chain and the consumer chain are the same, so `block.number` is comparable to
/// the signed window. The attester is a test key because the shipped leaves pin the oracle service's
/// key; the check under test, `SwarmFeed._requireQuestion`, is the code all four leaves inherit.
contract WindowBoundLeaf is SwarmFeed {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 1 hours, 5000) {}

    function questionPolicy() internal pure override returns (bytes memory, uint64, uint64) {
        return ('{"answerType":"uint256","chainId":1,"question":"q","v":1,"window":{"fromBlock":', 300, 1200);
    }
}

/// @notice `_requireQuestion` compares the signed window with the last ACCEPTED window only, never
/// with the block the feed is running in. An attestation signed now is therefore accepted over any
/// window that closed after the last update, however long ago, and dated now.
///
/// The first two tests FAIL on the code as committed and pass once the window is bound to the chain
/// head. The third passes before and after: an honest attestation, relayed ten minutes after it was
/// signed over a window that had just closed, must stay acceptable.
contract WindowRecencyTest is Test {
    uint256 private constant ATTESTER_KEY = 0xA11CE;
    uint256 private constant HONEST_PRICE = 3_000_000_000_000_000; // 0.003 ETH per IMD

    WindowBoundLeaf private feed;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_791_000_000);
        vm.roll(26_100_000);
        feed = new WindowBoundLeaf(vm.addr(ATTESTER_KEY));

        // An honest update: a two-hour window that closed 20 blocks before the head, signed now.
        SwarmFeed.OracleAttestation memory a = _attestation(26_099_380, 26_099_980, HONEST_PRICE);
        feed.submitAttestation(a, _sign(a));
        assertEq(feed.lastToBlock(), 26_099_980);
    }

    /// @dev Three days pass with no update, which is the design for a price feed (bought on demand,
    /// never on a clock). A buyer then has the pinned question answered over the window that opened
    /// right after the last accepted one, i.e. one that closed three days ago, and relays it.
    function test_aWindowThatClosedThreeDaysBeforeTheHeadIsRefused() public {
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 21_600);
        assertTrue(feed.isStale(), "the feed lapsed, so the deviation bound no longer applies");

        // Half the honest price: what the market read three days ago, in this example.
        SwarmFeed.OracleAttestation memory old_ = _attestation(26_099_981, 26_100_581, HONEST_PRICE / 2);
        bytes memory sig = _sign(old_);
        assertEq(block.number - old_.toBlock, 21_019, "the window closed 21,019 blocks (about 70 hours) ago");

        bool accepted;
        try feed.submitAttestation(old_, sig) {
            accepted = true;
        } catch {}

        assertFalse(accepted, "a window that closed three days before the head was accepted");
        (uint256 value,) = feed.latestValue();
        assertEq(value, HONEST_PRICE, "a three-day-old reading became the feed's value");
        assertTrue(feed.isStale(), "a three-day-old reading reads as fresh for the next hour");
    }

    /// @dev The other direction of the same missing comparison. `lastToBlock` only moves forward and
    /// the feed has no admin, so one accepted window beyond the head refuses every honest attestation
    /// until the chain reaches that block.
    function test_aWindowBeyondTheHeadIsRefused() public {
        uint64 future = uint64(block.number) + 1_000_000;
        SwarmFeed.OracleAttestation memory ahead = _attestation(future - 600, future, HONEST_PRICE);
        bytes memory sig = _sign(ahead);

        bool accepted;
        try feed.submitAttestation(ahead, sig) {
            accepted = true;
        } catch {}

        assertFalse(accepted, "a window that has not happened yet was accepted");
        assertEq(feed.lastToBlock(), 26_099_980, "lastToBlock moved past the head and cannot come back");
    }

    /// @dev Control. Signed now over a window that closed 20 blocks ago, relayed 10 minutes later.
    function test_control_anHonestAttestationRelayedTenMinutesLateIsAccepted() public {
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 600);

        uint64 to = uint64(block.number) - 20;
        SwarmFeed.OracleAttestation memory a = _attestation(to - 600, to, HONEST_PRICE * 101 / 100);
        bytes memory sig = _sign(a);

        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + 50);
        feed.submitAttestation(a, sig);

        (uint256 value, uint64 updatedAt) = feed.latestValue();
        assertEq(value, HONEST_PRICE * 101 / 100);
        assertEq(updatedAt, a.issuedAt, "freshness is counted from the signing time");
        assertFalse(feed.isStale());
    }

    function _attestation(uint64 fromBlock, uint64 toBlock, uint256 figure)
        private
        view
        returns (SwarmFeed.OracleAttestation memory a)
    {
        a.requestId = keccak256(abi.encode(fromBlock, toBlock, figure));
        a.chainId = 1;
        a.questionHash = feed.expectedQuestionHash(fromBlock, toBlock);
        a.answerType = 3;
        a.answer = abi.encode(figure);
        a.figure = figure;
        a.fromBlock = fromBlock;
        a.toBlock = toBlock;
        // What the service signs: the hash of the window's closing block. Inside the EVM's 256-block
        // horizon that is what `blockhash` returns; outside it the chain can no longer vouch for it.
        bytes32 closing = blockhash(toBlock);
        a.blockHash = closing != bytes32(0) ? closing : keccak256(abi.encode("block", toBlock));
        a.panelJobId = keccak256("panel");
        a.panelSize = 60;
        a.quorum = 20;
        a.agreed = 20;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(SwarmFeed.OracleAttestation memory a) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    feed.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ATTESTER_KEY, keccak256(abi.encodePacked("\x19\x01", feed.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }
}
```
