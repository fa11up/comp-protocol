// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwarmFeed} from "./SwarmFeed.sol";
import {SwarmRelay} from "./SwarmRelay.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {
    INTAKE,
    ORACLE_ACTION,
    ATTESTATION_RELAYER,
    POOL_MANAGER,
    IMD_POOL_ID,
    ASK_MIN_INTERVAL,
    ASK_TIMEOUT,
    ASK_MAX_PRICE,
    ARM_DELAY_BLOCKS,
    ARM_WINDOW_BLOCKS,
    STALE_AT_BPS,
    WIDE_ALLOWANCE_BPS,
    DRIFT_FALL_TRIGGER_OF_CAP_BPS,
    DRIFT_RISE_TRIGGER_OF_CAP_BPS
} from "./DeploymentConfig.sol";

interface IPoolManagerExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice Buys this protocol's feed updates through the swarm's on-chain Intake, paid in IMD the
/// Treasury streams to it, and only when the chain itself shows an update is needed.
/// @dev Anyone may call `ask`, and that is the point: no keeper key decides when protocol money is
/// spent. What decides it is on chain:
///
///   - STALENESS, for feeds configured to be kept alive (NHI: daily, and cheap). A feed whose value is
///     STALE_AT_BPS of the way to its maxAge (or has none yet) may be asked for. This needs no arming:
///     nobody can make a feed age faster. Price feeds are NOT kept fresh on a clock; their one-hour
///     life would cost ~$37k a year per feed. Between updates price actions pause, never misprice.
///   - DRIFT. A feed that quotes IMD/ETH may be asked for when IMD's own Uniswap v4 pool has FALLEN
///     below the feed by more than a quarter of the feed's deviation cap (DRIFT_FALL_TRIGGER_OF_CAP_BPS):
///     a fall over-values collateral, a rise only under-values it, so the Treasury pays for falls and
///     not for rises (DRIFT_RISE_TRIGGER_OF_CAP_BPS is zero, which means never). Drift
///     must be ARMED and still present ARM_DELAY_BLOCKS later, so one push-and-restore inside a single
///     transaction cannot trigger a paid update. Two such pushes five blocks apart can (launch audit,
///     low): accepted, because each pays the pool's 1% fee both ways, the result is only an honest
///     attestation, and the Treasury's spend is capped by the daily budget.
///
/// Anyone may also `askPaid`: the caller pays the Intake's price in IMD and an update is bought for any
/// feed at any time, with none of the need checks, because no protocol money is spent. That is how a
/// borrower who finds the price stale gets one (~$4.25) instead of waiting for the market to move.
///
/// Treasury spending is bounded four ways: one request in flight per feed (until delivered or ASK_TIMEOUT), at most
/// one paid request per feed per ASK_MIN_INTERVAL, a price ceiling per request, and the Treasury's
/// daily budget, which is all this contract can ever hold. Exhausting the budget does NOT freeze the
/// oracle: anyone can still buy an attestation off chain and relay it through SwarmRelay.
///
/// Delivery goes through SwarmRelay, so each feed keeps its one relayer and a keeper can still bundle
/// a relay with a liquidation. The callback never reverts on a refused or duplicate relay: it clears the
/// feed's in-flight slot either way and reports whether it relayed. An answer it could not deliver stays
/// public, and anyone can relay it by hand.
contract OracleAsker {
    using SafeERC20 for IERC20;

    struct Feed {
        bytes32 bodyHash; // keccak256 of the oracle.request body the feed's pinned question needs
        bool tracksPool; // quotes IMD in ETH, so pool drift applies
        bool keepAlive; // the Treasury pays to refresh it on staleness
        uint64 lastAsk; // timestamp of the last paid request
        uint64 armedAt; // block a drift was armed at; zero when unarmed
        uint64 inFlightAt; // timestamp the request in flight was sent; zero when none
        bytes32 inFlight; // the Intake's id for that request
    }

    /// @notice What the Intake is paid in (IMD).
    IERC20 public immutable payToken;
    mapping(address feed => Feed) public feeds;
    mapping(bytes32 requestId => address feed) public feedOf;

    event Armed(address indexed feed, uint256 atBlock, uint256 driftBps);
    event Asked(address indexed feed, bytes32 indexed requestId, uint256 price, bool forStaleness);
    event AskedPaid(address indexed feed, bytes32 indexed requestId, address indexed payer, uint256 price);
    event Delivered(address indexed feed, bytes32 indexed requestId, bool relayed);

    error UnknownFeed(address feed);
    error WrongBody();
    error InFlight(bytes32 requestId);
    error TooSoon(uint256 nextAt);
    error NotNeeded();
    error NotArmed();
    error PriceTooHigh(uint256 price);
    error NotSold();
    error EmptyBatch();
    error NothingToAsk();
    error NotTheIntake();
    error UnknownRequest(bytes32 requestId);
    error IntakeMissing();
    error BadConfiguration();

    /// @param feeds_ The feeds this asker buys for; fixed for its lifetime.
    /// @param bodyHashes keccak256 of each feed's oracle.request body. The body itself is passed to
    /// `ask` as calldata and checked against this, so it is never stored and never changeable.
    /// EACH BODY MUST USE A RELATIVE WINDOW ({"hours": N}), which the service resolves afresh per request.
    /// A literal {fromBlock, toBlock} pinned here could be answered once: every later answer would repeat
    /// a window the feed has passed and be refused (adversarial review 2026-10-05). A constructor cannot
    /// read JSON, so this is checked at deploy time against the frozen payloads (runbook section 6).
    /// @param tracksPool Whether each feed quotes IMD/ETH and so may be asked for on pool drift.
    /// @param keepAlive Whether the Treasury's IMD refreshes each feed when it nears its maxAge.
    constructor(
        IERC20 payToken_,
        address[] memory feeds_,
        bytes32[] memory bodyHashes,
        bool[] memory tracksPool,
        bool[] memory keepAlive
    ) {
        if (INTAKE.code.length == 0) revert IntakeMissing();
        if (address(payToken_).code.length == 0) revert BadConfiguration();
        if (
            feeds_.length == 0 || feeds_.length != bodyHashes.length || feeds_.length != tracksPool.length
                || feeds_.length != keepAlive.length
        ) {
            revert BadConfiguration();
        }
        payToken = payToken_;
        for (uint256 i; i < feeds_.length; ++i) {
            if (feeds_[i].code.length == 0 || bodyHashes[i] == bytes32(0) || feeds[feeds_[i]].bodyHash != 0) {
                revert BadConfiguration();
            }
            feeds[feeds_[i]] = Feed(bodyHashes[i], tracksPool[i], keepAlive[i], 0, 0, 0, bytes32(0));
        }
    }

    // --- the trigger ------------------------------------------------------------------------------

    /// @notice Record that a feed has drifted from IMD's pool. Anyone may call it. Arming a feed that
    /// is already armed and still inside its window changes nothing.
    function arm(address feed) external {
        Feed storage f = _feed(feed);
        if (!f.tracksPool) revert NotNeeded();
        uint256 drift = driftBps(feed);
        if (!_drifted(feed, drift)) revert NotNeeded();
        if (f.armedAt != 0 && block.number <= f.armedAt + ARM_WINDOW_BLOCKS) return;
        f.armedAt = uint64(block.number);
        emit Armed(feed, block.number, drift);
    }

    /// @notice Buy an update for `feed`, paying the Intake from this contract's IMD. Anyone may call it;
    /// it pays only when a keep-alive feed is near stale, when any feed's allowance has widened with
    /// staleness to WIDE_ALLOWANCE_BPS (`wideOpen`), or when an armed drift is still present.
    function ask(address feed, bytes calldata body) external returns (bytes32 requestId) {
        Feed storage f = _feed(feed);
        if (keccak256(body) != f.bodyHash) revert WrongBody();
        if (f.inFlight != bytes32(0) && block.timestamp < uint256(f.inFlightAt) + ASK_TIMEOUT) {
            revert InFlight(f.inFlight);
        }
        if (f.lastAsk != 0 && block.timestamp < uint256(f.lastAsk) + ASK_MIN_INTERVAL) {
            revert TooSoon(uint256(f.lastAsk) + ASK_MIN_INTERVAL);
        }
        bool forStaleness = (f.keepAlive && nearStale(feed)) || wideOpen(feed);
        if (!forStaleness) {
            if (!f.tracksPool) revert NotNeeded();
            uint256 armedAt = f.armedAt;
            if (armedAt == 0 || block.number < armedAt + ARM_DELAY_BLOCKS || block.number > armedAt + ARM_WINDOW_BLOCKS) {
                revert NotArmed();
            }
            if (!_drifted(feed, driftBps(feed))) revert NotNeeded();
        }
        uint256 price = _price(ASK_MAX_PRICE);
        // Effects before the external calls; the request id is only known after `request` returns.
        f.lastAsk = uint64(block.timestamp);
        f.armedAt = 0;
        requestId = _request(feed, f, body, price);
        emit Asked(feed, requestId, price, forStaleness);
    }

    /// @notice Buy an update for `feed` with the caller's own IMD: the Intake's price, at most `maxPrice`,
    /// pulled from the caller (approve this contract first). No need check and no interval, because no
    /// protocol money is spent; only one request may be in flight per feed, so a paid ask waits behind
    /// one that is already on its way.
    function askPaid(address feed, bytes calldata body, uint256 maxPrice) external returns (bytes32 requestId) {
        Feed storage f = _feed(feed);
        if (keccak256(body) != f.bodyHash) revert WrongBody();
        if (f.inFlight != bytes32(0) && block.timestamp < uint256(f.inFlightAt) + ASK_TIMEOUT) {
            revert InFlight(f.inFlight);
        }
        uint256 price = _price(maxPrice);
        payToken.safeTransferFrom(msg.sender, address(this), price);
        requestId = _request(feed, f, body, price);
        emit AskedPaid(feed, requestId, msg.sender, price);
    }

    /// @notice Buy updates for several feeds in one transaction with the caller's own IMD: each at the Intake's
    /// price, at most `maxPriceEach`, pulled per request (approve this contract for the total first). The
    /// terminal uses it to buy the primary and the spot together, because they must agree: refreshing only the
    /// primary after a move larger than the vault's allowed divergence would pause price actions until the
    /// spot followed. A feed whose update is already on its way is skipped and not charged, so the caller
    /// still gets the others; the call reverts only if it bought nothing. Each answer still arrives on its
    /// own, minutes apart.
    function askPaidMany(address[] calldata feeds_, bytes[] calldata bodies, uint256 maxPriceEach)
        external
        returns (bytes32[] memory requestIds)
    {
        if (feeds_.length == 0 || feeds_.length != bodies.length) revert EmptyBatch();
        uint256 price = _price(maxPriceEach);
        requestIds = new bytes32[](feeds_.length);
        uint256 bought;
        for (uint256 i; i < feeds_.length; ++i) {
            Feed storage f = _feed(feeds_[i]);
            if (keccak256(bodies[i]) != f.bodyHash) revert WrongBody();
            // In flight (including a feed named twice in this batch): skipped, not charged.
            if (f.inFlight != bytes32(0) && block.timestamp < uint256(f.inFlightAt) + ASK_TIMEOUT) continue;
            payToken.safeTransferFrom(msg.sender, address(this), price);
            requestIds[i] = _request(feeds_[i], f, bodies[i], price);
            ++bought;
            emit AskedPaid(feeds_[i], requestIds[i], msg.sender, price);
        }
        if (bought == 0) revert NothingToAsk();
    }

    /// @notice What one update costs right now, in `payToken`: the Intake's listed price. Zero when the
    /// Intake does not sell this action for this token. `askPaid` pulls exactly this much.
    function price() external view returns (uint256) {
        return IIntake(INTAKE).priceOf(ORACLE_ACTION, address(payToken));
    }

    function _price(uint256 ceiling) private view returns (uint256 price) {
        price = IIntake(INTAKE).priceOf(ORACLE_ACTION, address(payToken));
        if (price == 0) revert NotSold();
        if (price > ceiling) revert PriceTooHigh(price);
    }

    /// @dev Pays the Intake exactly `price` and records the request as this feed's one in flight.
    function _request(address feed, Feed storage f, bytes calldata body, uint256 price)
        private
        returns (bytes32 requestId)
    {
        // A timed-out request keeps its feedOf entry: the Intake may still deliver it, and that paid answer
        // is relayed like any other (the feed refuses it itself if its window no longer advances). Deleting
        // the entry here made the late delivery revert UnknownRequest and the answer was lost (second-half
        // review 2026-10-07, low). The in-flight slot below is what a superseded request no longer holds.
        f.inFlightAt = uint64(block.timestamp);
        payToken.forceApprove(INTAKE, price);
        requestId = IIntake(INTAKE).request(
            ORACLE_ACTION, body, IIntake.Callback(address(this), this.onOracleResult.selector), address(payToken), price
        );
        payToken.forceApprove(INTAKE, 0);
        f.inFlight = requestId;
        feedOf[requestId] = feed;
    }

    // --- delivery ---------------------------------------------------------------------------------

    /// @notice The Intake's callback for an `oracle.request` this contract made. Hands the attestation
    /// to SwarmRelay, which submits it to the feed; the feed checks the attester's signature and its
    /// own question, so this contract and the Intake add no trust to the price.
    function onOracleResult(bytes32 requestId, SwarmFeed.OracleAttestation calldata a, bytes calldata signature)
        external
    {
        if (msg.sender != INTAKE) revert NotTheIntake();
        address feed = feedOf[requestId];
        if (feed == address(0)) revert UnknownRequest(requestId);
        delete feedOf[requestId];
        Feed storage f = feeds[feed];
        // The live request, or one that timed out and was replaced; the latter clears nothing.
        bool live = f.inFlight == requestId;
        if (live) {
            f.inFlight = bytes32(0);
            f.inFlightAt = 0;
        }
        // Never revert past this point (launch audit, oracle panel, medium). If the answer was already
        // relayed by hand, or the feed refuses it, a reverting callback would roll back the clearing
        // above and hold the feed's in-flight slot for ASK_TIMEOUT, refusing ask and askPaid for two
        // hours. The slot is cleared either way; `relayed` says whether this delivery landed.
        bool relayed;
        try SwarmRelay(ATTESTATION_RELAYER).relay(SwarmFeed(feed), a, signature) {
            relayed = true;
        } catch {
            // BACK OFF (adversarial review 2026-10-05, medium). A refused answer must not be bought again
            // ten minutes later, and again, until the day's budget is gone: the next Treasury-paid ask for
            // this feed waits the full ASK_TIMEOUT. Written into lastAsk, which shares the storage slot
            // cleared just above, so the refusal path costs no extra slot. askPaid is unaffected: its
            // caller pays. A superseded request's refusal says nothing about the feed's state now (its
            // window has been overtaken), so it does not hold the Treasury back.
            if (live) f.lastAsk = uint64(block.timestamp + ASK_TIMEOUT - ASK_MIN_INTERVAL);
        }
        emit Delivered(feed, requestId, relayed);
    }

    // --- what the chain says ----------------------------------------------------------------------

    /// @notice True once a feed's value is STALE_AT_BPS of the way to its maxAge, or it has none.
    function nearStale(address feed) public view returns (bool) {
        (uint256 value, uint64 updatedAt) = SwarmFeed(feed).latestValue();
        if (value == 0 || updatedAt == 0) return true;
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        return age * 10_000 >= SwarmFeed(feed).maxAge() * STALE_AT_BPS;
    }

    /// @notice True while a feed has been silent for a whole lifetime — its value stale and no epoch
    /// live — and its allowance has widened with that silence to WIDE_ALLOWANCE_BPS or more, so the next
    /// accepted value could sit that far from its anchor (or it has no value yet). Such a feed may be
    /// asked for without arming, whatever its policy: the honest value lands first and the epoch it opens
    /// holds every later value to the cap around it (final review 2026-10-07; SwarmFeed._epochFirst).
    /// @dev Silent, not merely wide, and not merely stale. The epoch an honest refresh opens keeps its
    /// wide allowance for a lifetime, and reading that alone kept this true after the refresh, letting
    /// anyone make the Treasury pay every ASK_MIN_INTERVAL for the rest of the hour (review of cc4103f,
    /// 2026-10-07). Staleness alone was not enough either: it runs from the attestation's signed issuedAt,
    /// the epoch from the block it was relayed in, so inside the refresh's own epoch the value could read
    /// stale while the wide bound still stood, and the Treasury paid once more per silence (second-half
    /// review, docs/AUDIT-FINAL-2-2026-10-07.md, low). `epoch()` reports openedAt == block.timestamp
    /// exactly when no stored epoch is live, which is what "silent for a lifetime" means on chain; an
    /// unseeded feed reads that way too.
    function wideOpen(address feed) public view returns (bool) {
        SwarmFeed f = SwarmFeed(feed);
        if (!f.isStale()) return false;
        (, uint64 openedAt, uint256 allowance) = f.epoch();
        return openedAt == block.timestamp && allowance >= WIDE_ALLOWANCE_BPS;
    }

    /// @notice How far IMD's v4 pool sits from the feed, in basis points of the feed's value. Zero when
    /// either side is unreadable, which reads as "no drift": no pool, no paid drift update.
    function driftBps(address feed) public view returns (uint256) {
        (uint256 value,) = SwarmFeed(feed).latestValue();
        uint256 spot = poolPrice();
        if (value == 0 || spot == 0) return 0;
        uint256 gap = spot > value ? spot - value : value - spot;
        return Math.mulDiv(gap, 10_000, value);
    }

    /// @notice IMD's price in wei of ETH per 1e18 raw IMD, from the pool's current sqrtPriceX96. The
    /// pool's currency0 is native ETH and currency1 IMD, so the pool's own price is IMD per ETH and
    /// this inverts it: 1e18 * 2^192 / sqrtP^2, computed in two steps so nothing overflows.
    function poolPrice() public view returns (uint256) {
        if (POOL_MANAGER.code.length == 0) return 0;
        bytes32 slot = keccak256(abi.encode(IMD_POOL_ID, uint256(6)));
        (bool ok, bytes memory data) =
            POOL_MANAGER.staticcall(abi.encodeCall(IPoolManagerExtsload.extsload, (slot)));
        if (!ok || data.length < 32) return 0;
        uint256 sqrtPriceX96 = uint256(abi.decode(data, (bytes32))) & type(uint160).max;
        if (sqrtPriceX96 == 0) return 0;
        return Math.mulDiv(Math.mulDiv(1e18, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @notice The drift, in bps of the feed's value, past which the Treasury pays for an update, by
    /// direction: `fall` when IMD's pool is below the feed (collateral over-valued), `rise` when above.
    /// A zero `rise` means the Treasury never pays for a rise. See DRIFT_*_TRIGGER_OF_CAP_BPS.
    function triggerBps(address feed) public view returns (uint256 fall, uint256 rise) {
        uint256 cap = SwarmFeed(feed).maxDeviationBps();
        return (cap * DRIFT_FALL_TRIGGER_OF_CAP_BPS / 10_000, cap * DRIFT_RISE_TRIGGER_OF_CAP_BPS / 10_000);
    }

    function _drifted(address feed, uint256 drift) private view returns (bool) {
        (uint256 value,) = SwarmFeed(feed).latestValue();
        (uint256 fall, uint256 rise) = triggerBps(feed);
        if (poolPrice() < value) return drift > fall;
        return rise != 0 && drift > rise;
    }

    function _feed(address feed) private view returns (Feed storage f) {
        f = feeds[feed];
        if (f.bodyHash == bytes32(0)) revert UnknownFeed(feed);
    }
}
