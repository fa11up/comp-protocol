// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable attested numeric feed with an allowlisted testnet reporter fallback.
/// @dev Each live oracle request costs IMD, making a per-block attested feed uneconomic on testnet.
/// Production replaces the reporter fallback with scheduled attestations. The testnet configuration
/// uses the deployer as sole reporter with quorum one; the reporter set should widen in production.
/// There is no admin or setter. Values are scaled by 1e18; consumers enforce any application bounds.
/// Zero is rejected on both paths: it is never a valid scaled figure and would pin the relative bound at
/// zero. The deviation bound applies while the last accepted value is fresh; once that value has aged
/// past maxAge the feed is stale and consumers already fail safe, so the next accepted value re-anchors
/// the band instead of leaving an immutable feed permanently unable to follow a genuine large move.
contract SwarmFeed is ISwarmFeed {
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
        uint64 issuedAt;
        uint64 expiresAt;
    }

    error InvalidConfiguration();
    error UnauthorizedReporter();
    error AlreadyReported();
    error ZeroValue();
    error ExcessDeviation();
    error InvalidSignature();
    error InvalidQuestion();
    error InvalidTimestamp();
    error ExpiredAttestation();
    error StaleAttestation();
    error ReplayedAttestation();

    event ValueUpdated(uint256 value, uint64 updatedAt);
    event Reported(uint256 indexed round, address indexed reporter, uint256 value);
    event AttestationAccepted(bytes32 indexed requestId);

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
    );
    // The IdentityMD service uses this domain on every chain, including Sepolia.
    bytes32 public constant DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("IdentityMD Oracle"),
            keccak256("1"),
            uint256(1),
            address(0)
        )
    );
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable attester;
    bytes32 public immutable questionHash;
    address public immutable reporter0;
    address public immutable reporter1;
    address public immutable reporter2;
    uint8 public immutable quorum;
    uint256 public immutable maxAge;
    uint256 public immutable maxDeviationBps;

    uint256 public round = 1;
    uint8 public reportCount;
    mapping(address reporter => uint256 roundNumber) public lastReportedRound;
    mapping(bytes32 requestId => bool consumed) public usedRequests;
    uint256[3] private _reports;
    uint64 private _roundStartedAt;
    uint256 private _value;
    uint64 private _updatedAt;
    bool private _hasValue;

    /// @param reporter0_ First immutable reporter; unused reporter slots may be zero.
    /// @param reporter1_ Second immutable reporter, or zero.
    /// @param reporter2_ Third immutable reporter, or zero.
    /// @param quorum_ Between one and the number of distinct nonzero reporters (at most three).
    /// @param maxAge_ Maximum accepted age in seconds, strictly positive.
    /// @param maxDeviationBps_ Maximum change from the last accepted value, from 0 to 10,000 bps.
    constructor(
        address attester_,
        bytes32 questionHash_,
        address reporter0_,
        address reporter1_,
        address reporter2_,
        uint8 quorum_,
        uint256 maxAge_,
        uint256 maxDeviationBps_
    ) {
        uint256 count = (reporter0_ == address(0) ? 0 : 1) + (reporter1_ == address(0) ? 0 : 1)
            + (reporter2_ == address(0) ? 0 : 1);
        if (
            attester_ == address(0) || quorum_ == 0 || quorum_ > count || maxAge_ == 0 || maxDeviationBps_ > 10_000
                || (reporter0_ != address(0) && (reporter0_ == reporter1_ || reporter0_ == reporter2_))
                || (reporter1_ != address(0) && reporter1_ == reporter2_)
        ) revert InvalidConfiguration();
        attester = attester_;
        questionHash = questionHash_;
        reporter0 = reporter0_;
        reporter1 = reporter1_;
        reporter2 = reporter2_;
        quorum = quorum_;
        maxAge = maxAge_;
        maxDeviationBps = maxDeviationBps_;
    }

    function latestValue() external view override returns (uint256 value, uint64 updatedAt) {
        return (_value, _updatedAt);
    }

    function isStale() external view override returns (bool) {
        return !_hasValue || _tooOld(_updatedAt);
    }

    function isReporter(address account) public view returns (bool) {
        return account != address(0) && (account == reporter0 || account == reporter1 || account == reporter2);
    }

    /// @notice Accept an IdentityMD EIP-712 attestation. Anyone may relay the authorized signature.
    /// @dev Uses the signed issue time, so delayed delivery cannot extend freshness. requestId is the
    /// replay nonce. chainId is signed payload data; the service domain chainId is always literal 1.
    /// The attester must bind the configured question to the intended data chain and numeric answer
    /// semantics; payload chainId and answerType are signed but not filtered here. Zero figures revert.
    function submitAttestation(OracleAttestation calldata a, bytes calldata sig) external {
        if (a.questionHash != questionHash) revert InvalidQuestion();
        if (block.timestamp > a.expiresAt) revert ExpiredAttestation();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (_tooOld(a.issuedAt) || (_hasValue && a.issuedAt < _updatedAt)) revert StaleAttestation();
        if (usedRequests[a.requestId]) revert ReplayedAttestation();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _attestationHash(a)));
        if (_recover(digest, sig) != attester) revert InvalidSignature();
        usedRequests[a.requestId] = true;
        _accept(a.figure, a.issuedAt);
        // A primary update discards any unfinished fallback round based on the preceding value.
        _nextRound();
        emit AttestationAccepted(a.requestId);
    }

    /// @notice Submit one value per reporter per round; reaching quorum publishes the median.
    /// @dev Even-sized quorums use the floor of the two central values' mean. Unfinished rounds
    /// expire after maxAge; the next report then starts a fresh round instead of using old votes.
    /// The accepted timestamp is the oldest contributing report's time, so quorum cannot renew it.
    /// Deviation is bounded per accepted update, not per block or unit of time. A quorum-one reporter
    /// can complete multiple rounds in one block; the fallback therefore trusts that reporter's values.
    function report(uint256 value) external {
        if (!isReporter(msg.sender)) revert UnauthorizedReporter();
        if (block.timestamp > type(uint64).max) revert InvalidTimestamp();
        if (reportCount != 0 && _tooOld(_roundStartedAt)) _nextRound();
        if (lastReportedRound[msg.sender] == round) revert AlreadyReported();
        _checkValue(value);
        if (reportCount == 0) _roundStartedAt = uint64(block.timestamp);
        lastReportedRound[msg.sender] = round;
        _reports[reportCount++] = value;
        emit Reported(round, msg.sender, value);
        if (reportCount == quorum) {
            _accept(_median(), _roundStartedAt);
            _nextRound();
        }
    }

    function _attestationHash(OracleAttestation calldata a) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.issuedAt,
                a.expiresAt
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

    function _checkValue(uint256 value) private view {
        if (value == 0) revert ZeroValue();
        if (_hasValue && !_tooOld(_updatedAt)) {
            uint256 change = value > _value ? value - _value : _value - value;
            if (change > Math.mulDiv(_value, maxDeviationBps, 10_000)) revert ExcessDeviation();
        }
    }

    function _accept(uint256 value, uint64 updatedAt) private {
        _checkValue(value);
        _value = value;
        _updatedAt = updatedAt;
        _hasValue = true;
        emit ValueUpdated(value, updatedAt);
    }

    function _median() private view returns (uint256) {
        uint256 a = _reports[0];
        if (quorum == 1) return a;
        uint256 b = _reports[1];
        if (a > b) (a, b) = (b, a);
        if (quorum == 2) return a + (b - a) / 2;
        uint256 c = _reports[2];
        return c < a ? a : (c > b ? b : c);
    }

    function _nextRound() private {
        ++round;
        reportCount = 0;
    }

    function _tooOld(uint64 timestamp) private view returns (bool) {
        return block.timestamp > timestamp && block.timestamp - timestamp > maxAge;
    }
}
