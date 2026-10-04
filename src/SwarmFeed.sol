// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable attested numeric feed. Attestations are the only way a value is ever set.
/// @dev THERE IS NO REPORTER FALLBACK, and removing it was the point. `report()` let an allowlisted
/// key set the value directly, bounded by `maxDeviationBps` only while the current value was still
/// fresh — past `maxAge` the bound lifted and the next accepted value re-anchored the band to
/// anything. On a testnet that was a convenience. On mainnet it is one key holding custody of every
/// position that consumes this feed, which is not a fallback but a second, weaker price oracle nobody
/// asked for.
///
/// The cost is accepted deliberately: a freshly deployed feed is INERT until its first attestation,
/// and a feed that goes stale cannot be walked back to market without buying one. That is the
/// behaviour mainnet has, so it is the behaviour a testnet should have too — a reporter fallback let
/// us test a protocol we were never going to deploy.
///
/// There is no admin or setter. Values are scaled by 1e18; consumers enforce any application bounds.
/// Zero is rejected on both paths: it is never a valid scaled figure and would pin the relative bound at
/// zero. The deviation bound applies while the last accepted value is fresh; once that value has aged
/// past maxAge the feed is stale and consumers already fail safe, so the next accepted value re-anchors
/// the band instead of leaving an immutable feed permanently unable to follow a genuine large move.
abstract contract SwarmFeed is ISwarmFeed {
    struct OracleAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    error InvalidConfiguration();
    error ZeroValue();
    error ExcessDeviation();
    error InvalidSignature();
    error UnauthorizedRelayer();
    error WrongQuestion(bytes32 expected, bytes32 given);
    error WindowSpanOutOfRange(uint64 span);
    error WindowNotAdvancing(uint64 toBlock, uint64 lastAccepted);
    error InvalidWindow();
    error UnboundQuestionNeedsRelayer();
    error QuestionNeedsWindowBounds();
    error InvalidAttestationChain();
    error InvalidAnswerType();
    error InvalidTimestamp();
    error ExpiredAttestation();
    error StaleAttestation();
    error ReplayedAttestation();
    error PanelTooSmall();
    error NotEnoughAgreement();

    event ValueUpdated(uint256 value, uint64 updatedAt);
    event AttestationAccepted(bytes32 indexed requestId, bytes32 questionHash);

    /// @notice Smallest panel this feed accepts, read from the signed attestation.
    /// @dev Attestation v2 signs panelSize/quorum/agreed, so the CONSUMER sets the real bar instead of
    /// trusting the request's own quorum. A request may therefore ask for a low quorum so that it
    /// attests at all, while this contract still refuses anything thinner than these floors.
    uint16 public constant MIN_PANEL_SIZE = 25;
    /// @notice Smallest number of members that must have given the signed answer.
    uint16 public constant MIN_AGREED = 15;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable attester;
    address public immutable relayer;

    /// @notice Closing block of the last accepted attestation window; only ever moves forward.
    uint64 public lastToBlock;
    uint256 public immutable attestationChainId;
    uint8 public immutable attestationAnswerType;
    uint256 public immutable maxAge;
    uint256 public immutable maxDeviationBps;

    mapping(bytes32 requestId => bool consumed) public usedRequests;
    uint256 private _value;
    uint64 private _updatedAt;
    bool private _hasValue;

    /// @param relayer_ Sole attestation submitter, or zero for permissionless relay.
    /// @param attestationChainId_ Required data chain in the signed payload, independent of the consumer chain.
    /// @param attestationAnswerType_ Required answer type in the signed payload.
    /// @param maxAge_ Maximum accepted age in seconds, strictly positive.
    /// @param maxDeviationBps_ Maximum change from the last accepted value, from 0 to 10,000 bps.
    constructor(
        address attester_,
        address relayer_,
        uint256 attestationChainId_,
        uint8 attestationAnswerType_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    ) {
        if (attester_ == address(0) || maxAge_ == 0 || maxDeviationBps_ > 10_000) revert InvalidConfiguration();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
        // The pairing that the HIGH audit finding turned on: a feed that cannot verify WHICH question
        // an attestation answers has only its relayer standing between a bought signature and its
        // price, so it may not be deployed without one. A feed that pins its question needs no
        // relayer, and must pin a window span too — an unbounded span would let the same question be
        // answered over one block or over a month.
        (bytes memory prefix_, uint64 minSpan_, uint64 maxSpan_) = questionPolicy();
        if (prefix_.length == 0) {
            if (relayer_ == address(0)) revert UnboundQuestionNeedsRelayer();
        } else if (minSpan_ == 0 || maxSpan_ < minSpan_) {
            revert QuestionNeedsWindowBounds();
        }
        attester = attester_;
        relayer = relayer_;
        attestationChainId = attestationChainId_;
        attestationAnswerType = attestationAnswerType_;
        maxAge = maxAge_;
        maxDeviationBps = maxDeviationBps_;
    }

    function latestValue() external view override returns (uint256 value, uint64 updatedAt) {
        return (_value, _updatedAt);
    }

    function isStale() external view override returns (bool) {
        return !_hasValue || _tooOld(_updatedAt);
    }

    /// @notice Accept an IdentityMD EIP-712 attestation through the configured relayer, or anyone if zero.
    /// @dev Uses the signed issue time, so delayed delivery cannot extend freshness. requestId is the
    /// replay nonce. The immutable consumer domain binds the deployment chain and this feed, stopping
    /// cross-feed replay without identifying the question. questionHash binds a changing pinned block
    /// window, so this contract cannot verify WHICH question an attestation answers FROM THE HASH ALONE.
    /// The deviation guard bounds a wrong-question figure once seeded while the previous value is fresh;
    /// a nonzero relayer covers the unseeded first value and stale re-anchors. A feed that pins its
    /// question document (questionPolicy) verifies the question directly and needs no relayer at all.
    /// Payload chainId and answerType must match the configured policy. Zero figures revert.
    function submitAttestation(OracleAttestation calldata a, bytes calldata sig) external {
        if (relayer != address(0) && msg.sender != relayer) revert UnauthorizedRelayer();
        if (a.chainId != attestationChainId) revert InvalidAttestationChain();
        if (a.panelSize < MIN_PANEL_SIZE) revert PanelTooSmall();
        if (a.agreed < MIN_AGREED || a.agreed > a.panelSize) revert NotEnoughAgreement();
        if (a.answerType != attestationAnswerType) revert InvalidAnswerType();
        if (block.timestamp > a.expiresAt) revert ExpiredAttestation();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (_tooOld(a.issuedAt) || (_hasValue && a.issuedAt < _updatedAt)) revert StaleAttestation();
        if (usedRequests[a.requestId]) revert ReplayedAttestation();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _attestationHash(a)));
        if (_recover(digest, sig) != attester) revert InvalidSignature();
        usedRequests[a.requestId] = true;
        _requireQuestion(a);
        _accept(a.figure, a.issuedAt);
        emit AttestationAccepted(a.requestId, a.questionHash);
    }

    /// @notice The question document this feed accepts answers to, and the window span it allows.
    /// @dev An empty prefix disables question binding, which is only safe behind a trusted relayer —
    /// the constructor enforces that pairing. A production feed overrides this with the canonical
    /// question-document prefix emitted by oracle/question-prefix.mjs. It is a SOURCE CONSTANT for the
    /// same reason every other authority here is: whoever controls the question controls the price, so
    /// it must never be a constructor argument a launch manifest could substitute.
    function questionPolicy() internal pure virtual returns (bytes memory prefix, uint64 minSpan, uint64 maxSpan) {
        return ("", 0, 0);
    }

    /// @dev Decimal ASCII of a uint64, because the document the attester hashed is JSON text and the
    /// window's two numbers appear in it as digits. Written here rather than imported: this repository's
    /// OpenZeppelin checkout carries only the few utils it needs, and a string helper is not worth
    /// widening it for.
    function _decimal(uint64 value) private pure returns (bytes memory) {
        if (value == 0) return "0";
        uint64 digits;
        for (uint64 v = value; v != 0; v /= 10) ++digits;
        bytes memory out = new bytes(digits);
        for (uint64 v = value; v != 0; v /= 10) out[--digits] = bytes1(uint8(48 + (v % 10)));
        return out;
    }

    /// @notice The questionHash this feed will accept for a given window, or zero if it pins no
    /// question and therefore accepts any.
    /// @dev Public so an operator can check, from the chain, that a feed agrees with the payload they
    /// are about to pay for. Buying a request whose question document differs by one character means
    /// an attestation this feed refuses, and the 0.5 IMD is already spent by then.
    function expectedQuestionHash(uint64 fromBlock, uint64 toBlock) public pure returns (bytes32) {
        (bytes memory prefix,,) = questionPolicy();
        if (prefix.length == 0) return bytes32(0);
        return keccak256(
            abi.encodePacked(prefix, _decimal(fromBlock), ',"toBlock":', _decimal(toBlock), "}}")
        );
    }

    /// @notice Rebuild the control plane's question document and refuse an answer to another question.
    /// @dev The document is canonicalised as an RFC 8785 subset, so its keys are sorted and "window"
    /// sorts last. The only part that differs between two otherwise identical requests is therefore a
    /// SUFFIX, and the attestation carries that suffix's two numbers as SIGNED fields. So the feed
    /// splices them into a pinned prefix and recomputes the very hash the attester signed over.
    ///
    /// Two further bounds, because answering the right question is not yet answering it honestly:
    ///   - the span is bounded, so the question cannot be answered over a single block (a point read
    ///     dressed up as a window median) nor over a month (which smooths away a real move);
    ///   - toBlock must advance, so a freshly signed attestation cannot answer over an ANCIENT window
    ///     in which the price was whatever the buyer needed it to be.
    function _requireQuestion(OracleAttestation calldata a) private {
        (bytes memory prefix, uint64 minSpan, uint64 maxSpan) = questionPolicy();
        if (prefix.length == 0) return;
        if (a.toBlock < a.fromBlock) revert InvalidWindow();
        uint64 span = a.toBlock - a.fromBlock;
        if (span < minSpan || span > maxSpan) revert WindowSpanOutOfRange(span);
        if (a.toBlock <= lastToBlock) revert WindowNotAdvancing(a.toBlock, lastToBlock);
        bytes32 expected = expectedQuestionHash(a.fromBlock, a.toBlock);
        if (a.questionHash != expected) revert WrongQuestion(expected, a.questionHash);
        lastToBlock = a.toBlock;
    }

    /// @dev Split across two `abi.encode` calls and concatenated: every field is a static
    /// single-word type, so this is byte-identical to encoding all sixteen at once, and it keeps the
    /// function off a stack-too-deep without turning on viaIR.
    function _attestationHash(OracleAttestation calldata a) private pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
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
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
    }

    /// @notice Refuse a value this feed should not accept. Zero always; a move larger than
    /// `maxDeviationBps` while the current value is still fresh.
    /// @dev VIRTUAL, and the reason is that the bound assumes the value is a PRICE. It is the right
    /// guard for one: a price moves continuously, so a large jump is evidence of a bad figure rather
    /// than of a fast market. It is the wrong guard for a value with no magnitude — a Merkle root is a
    /// uniformly random 256-bit number, so two consecutive honest roots differ wildly and this would
    /// reject almost all of them.
    ///
    /// A subclass that carries such a value overrides this and keeps the zero check. What it gives up
    /// is real and must be stated where it is given up: the deviation bound is one of the things
    /// standing between a wrong figure and the consumers of this feed. What remains is question
    /// binding, the attester signature and the panel floors — which, per the HIGH finding of audit
    /// c71449d1, are what actually guard a feed, the deviation bound having been the fallback for a
    /// feed that pinned no question.
    function _checkValue(uint256 value) internal view virtual {
        if (value == 0) revert ZeroValue();
        if (_hasValue && !_tooOld(_updatedAt)) {
            uint256 change = value > _value ? value - _value : _value - value;
            if (change > Math.mulDiv(_value, maxDeviationBps, 10_000)) revert ExcessDeviation();
        }
    }

    /// @dev INTERNAL rather than private, so a subclass can accept a value without an attestation.
    /// That is a deliberate, narrow door and it is worth being exact about what it does and does not
    /// guarantee. The docstring above says attestations are the only way a value is ever set; with
    /// this visibility that is a property of THE CONTRACTS THIS REPOSITORY SHIPS — `PriceFeed`,
    /// `NhiFeed`, `SpotFeed` and `SwarmWorkOracle` expose no path to it — rather than a property the
    /// base enforces on every conceivable subclass.
    ///
    /// It exists because the test suite has to set values, and with the reporter fallback gone the
    /// alternative is signing as the pinned attester, whose key is the oracle service's and not ours.
    /// The difference from the fallback it replaces is the one that matters: a reporter was an
    /// authority held by a KEY on a DEPLOYED contract, reachable by whoever held it. This is reachable
    /// only by writing a new subclass and deploying it, which is a code review rather than a
    /// transaction. Any new subclass under src/ must be read with that in mind.
    function _accept(uint256 value, uint64 updatedAt) internal {
        _checkValue(value);
        _value = value;
        _updatedAt = updatedAt;
        _hasValue = true;
        emit ValueUpdated(value, updatedAt);
    }

    function _tooOld(uint64 timestamp) private view returns (bool) {
        return block.timestamp > timestamp && block.timestamp - timestamp > maxAge;
    }
}
