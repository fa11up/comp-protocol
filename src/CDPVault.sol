// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IShareVault} from "./interfaces/IShareVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {ImdUSD} from "./ImdUSD.sol";
import {MockIMD} from "./MockIMD.sol";
import {MockWorkOracle} from "./MockWorkOracle.sol";
import {WorkOracleFactory} from "./WorkOracleFactory.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {
    FEE_RECIPIENT,
    SKEW_BPS,
    CHIP_BPS,
    DUTY_BPS,
    REDEMPTION_DIVISOR,
    CUT_BPS,
    WORK_ORACLE_FACTORY,
    WORK_ORACLE_SENTINEL,
    WORK_ORACLE_MAX_AGE
} from "./DeploymentConfig.sol";

/// @notice Price-aware imdUSD borrowing and work-backed minting against collateral (sIMD on mainnet).
/// @dev Collateral is priced per 1e18 RAW units and the arithmetic never reads its decimals, so a
/// 24-decimal share (sIMD) and an 18-decimal token are both valued correctly; imdUSD has 18 decimals.
/// NHI alone determines `mat` and `lull`. In this base vault the economic parameters are source
/// constants and there is no parameter admin; ParameterizedVault overrides them from a governed
/// Parameters contract behind a timelock.
/// Zero imdUSD and oracle arguments create permanently bound contracts with no post-deployment setup.
/// The requester has no initialization authority in this mode; the operator retains only the mock faucets.
contract CDPVault is TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 collateral;
        uint256 debt;
        /// @dev `recentlyMinted` is the principal minted within FRESH_DEBT_WINDOW of `mintedAt` and still
        /// outstanding; `mintedAt` is its amount-weighted mint time in 1e18-SCALED seconds
        /// (block.timestamp * 1e18, see `draw` and `_reduceDebt`). Only redemption reads them: see
        /// `_redeemPosition`.
        uint256 recentlyMinted;
        uint256 mintedAt;
        /// @dev This position's term in `securedCollateral`, as last written by `_resecure`.
        uint256 secured;
    }

    struct LiquidationMark {
        uint256 markedAt;
        uint256 grace;
        bool marked;
        address marker;
    }

    /// @notice Passed as the collateral token to ask this vault to deploy a testnet faucet instead.
    /// @dev Deliberately not `address(0)`: see the note in the constructor.
    address internal constant COLLATERAL_FAUCET = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    error InvalidToken();
    error InvalidOracle();
    error InvalidFeed();
    error InvalidPrice();
    error NotInitialized();
    error StaleFeed();
    error ZeroAmount();
    error NoRealizedBadDebt();
    error CoverBelowCollateralValue();
    error NoSurplus();
    error InsufficientCollateral();
    error InsufficientRights();
    error UnsafeCollateralRatio();
    error HealthyPosition();
    error ExcessRepayment();
    error UnexpectedCollateralReceived();
    error CollateralNotWrappable();
    error PositionNotMarked();
    error GracePeriodNotElapsed();
    error MarkExpired();
    error UnderwaterPosition();
    error DebtCeilingReached();
    error PriceDivergence();
    error InvalidBonusShares();
    error InvalidBeneficiary();
    error WorkCeilingReached();
    error IneligibleRedemptionPosition();
    error RedemptionWorsensRatio();
    error MinimumOutNotMet();

    event OracleSet(address indexed oracle);
    event Lock(address indexed account, uint256 amount);
    event Free(address indexed account, uint256 amount);
    event Draw(address indexed account, uint256 amount);
    event Earn(address indexed account, uint256 amount);
    event Wipe(address indexed account, uint256 amount);
    event Bite(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);
    event Bark(address indexed owner, uint256 markedAt, uint256 grace);
    event Heel(address indexed owner);
    event Cover(address indexed owner, uint256 amount, address indexed payer);
    event IndexCheckpointed(uint256 index, uint256 at);
    event Cash(
        address indexed redeemer,
        address indexed candidate,
        uint256 burned,
        uint256 gemOut,
        uint256 reserveOut,
        uint256 debtCancelled,
        uint256 feeBps
    );

    /// @dev 20%, decided 2026-10-05 against IMD's own pool: the liquidator keeps 16% after the marker's
    /// and the protocol's shares, which stays profitable selling up to ~$290k of collateral into a
    /// full-range pool of ~$2.3M per side with a 1% fee (docs/PARAMETERS-2026-10-05.md).
    uint256 public constant CHOP_PERCENT = 20;
    uint256 public constant REDEMPTION_FEE_FLOOR_BPS = 50;
    uint256 public constant REDEMPTION_FEE_CAP_BPS = 500;
    /// @dev floor(1e18 * 2**(-1/43200)): a twelve-hour half-life, with per-second decay.
    uint256 private constant REDEMPTION_SECOND_DECAY = 999983955055097432;
    /// @dev One half-life of the base rate. Cancelling principal younger than this does not move the
    /// rate; see `_redeemPosition`.
    uint256 private constant FRESH_DEBT_WINDOW = 12 hours;
    /// @dev `cover` sweeps collateral worth less than this fraction of the position's debt (`_coverDust`),
    /// and at least less than the seizure for COVER_DUST_MIN_DEBT of it (or a hundredth of the debt, if less).
    uint256 private constant COVER_DUST_DIVISOR = 1_000_000;
    uint256 private constant COVER_DUST_MIN_DEBT = 1e18;
    /// @notice Last redemption's base fee as a fraction scaled by 1e18, capped at 4.5%.
    uint256 public redemptionBaseRate;
    uint256 public lastRedemptionAt = block.timestamp;
    /// @notice Burns against reserve or unminted stability fees, rather than minted principal.
    /// @dev Supply = totalDebt + totalEarned - totalNonPrincipalRedeemed. Work history is never reset.
    uint256 public totalNonPrincipalRedeemed;
    uint256 private constant INDEX_SCALE = 1e18;
    /// @notice When this vault was deployed. NOT the accrual origin: the fee index runs from
    /// `indexCheckpointAt`, which moves. Kept because it is a stable deployment timestamp, and
    /// deliberately not removed — tests anchor elapsed time to it.
    uint256 public immutable deployedAt = block.timestamp;

    /// @notice Debt index as of `indexCheckpointAt`; starts at `INDEX_SCALE` and never decreases.
    uint256 public indexCheckpoint = INDEX_SCALE;

    /// @notice Timestamp the index was last checkpointed at.
    uint256 public indexCheckpointAt = block.timestamp;

    /// @notice Maximum collateral-backed minted principal, in stablecoin units (fees are additional).
    /// @dev Unlimited by default so behaviour is unchanged; a deployment that wants a cap overrides
    /// this. There is no admin, so the value a deployment chooses is permanent for that vault —
    /// raising a ceiling means a new vault and a migration, which is the price of having no keys.
    function line() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Tolerated gap between the primary average price and the spot price, in basis points.
    /// @dev Virtual like every other economic knob here, so a deployment that reads its parameters
    /// from somewhere governed can override it without this contract changing. The default is pinned
    /// in source, and nothing in this contract can move it.
    function skew() public view virtual returns (uint256) {
        return SKEW_BPS;
    }

    /// @notice Share of the liquidation bonus paid to whoever marked the position, in basis points.
    function chip() public view virtual returns (uint256) {
        return CHIP_BPS;
    }

    /// @notice Each redemption raises the base rate by redeemed / fee base / this, the fee base being the
    /// paced supply, floored (`_feeBase`). The base vault reads the source constant; ParameterizedVault
    /// reads its governed Parameters.
    function redemptionDivisor() public view virtual returns (uint256) {
        return REDEMPTION_DIVISOR;
    }

    /// @notice Annual stability fee on open debt, in basis points, accrued through the `chi` index from
    /// its last checkpoint.
    /// @dev Virtual for the same reason line and cut are: a deployment pins
    /// it in source, and a test can hold it at another value without rewriting the source to do it.
    /// This contract has no setter, so the rate is permanent unless a subclass reads it from
    /// somewhere governed — in which case that governor MUST call `drip` in the same
    /// transaction as the change, or the new rate reaches time that has already elapsed.
    function duty() public view virtual returns (uint256) {
        return DUTY_BPS;
    }

    /// @notice Share of the liquidation bonus paid to FEE_RECIPIENT, in basis points of the bonus.
    /// @dev The borrower's loss is identical whatever this is: it splits the existing bonus (CHOP_PERCENT)
    /// rather than seizing more, so raising it never makes liquidation harsher for the borrower.
    function cut() public view virtual returns (uint256) {
        return CUT_BPS;
    }

    /// @notice Where the protocol's revenue lands: its bonus share, in IMD, and paid stability fees,
    /// in imdUSD. The FEE_RECIPIENT account here; ParameterizedVault overrides this with the Treasury
    /// it creates in its own constructor, so no deployment can route protocol revenue to a wallet.
    function feeRecipient() public view virtual returns (address) {
        return FEE_RECIPIENT;
    }

    /// @notice Maximum cumulative imdUSD the work channel may have minted, in imdUSD units.
    /// @dev Unlimited here, exactly as `line` is: this contract has no reserve to read and no
    /// governed ratio, so a bound would be a number pulled from the air. ParameterizedVault overrides
    /// it with reserveValueUsd + backedDebt * earnMat / 10000 (backedDebt: total debt, no more than the
    /// transaction began with nor the paced debt, less bad debt), the bound docs/COMPUTE-BACKING-DESIGN.md
    /// section 3 derives, and `earn` enforces whatever this returns.
    function earnLine() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Ratio points above mat eligible for redemption; governed in ParameterizedVault.
    function gap() public view virtual returns (uint256) {
        return 50;
    }

    function redemptionCeilingCR() public view returns (uint256) {
        return mat() + gap();
    }

    /// @notice Idle IMD available before any borrower is reached. The plain vault has no Treasury.
    function redemptionReserve() public view virtual returns (uint256) {
        return 0;
    }

    function _payRedemptionReserve(uint256) internal virtual {
        revert InsufficientCollateral();
    }

    /// @dev Reserve backing in the unit `price` quotes; the plain vault has no reserve.
    function _redemptionReserveBacking(uint256) internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev What the current transaction has added, in transient storage the EVM clears when it ends:
    /// secured collateral (see `securedCollateral`), principal minted and work minted. Redemption reads them
    /// so that capital which exists only for the length of the call can neither inflate the backing the
    /// guard measures nor dilute the supply the fee is measured against. Capital held across transactions
    /// is the paced figures' to discount (`_pace`).
    /// keccak256("comp.CDPVault.securedCollateralAddedThisTransaction"),
    /// keccak256("comp.CDPVault.principalMintedThisTransaction") and
    /// keccak256("comp.CDPVault.workMintedThisTransaction").
    uint256 private constant SECURED_THIS_TX_SLOT = 0xf45fbc7390d8fe64766790eac1c1a0c998865663167e91e17d360ad63faf32cb;
    uint256 private constant MINTED_THIS_TX_SLOT = 0x7863d18732bd3fc443c44a39552cffecac393d3fbf3094322f7f794631746012;
    uint256 private constant WORK_MINTED_THIS_TX_SLOT =
        0xf427427e9c6fc4311907632705fbeaa6595527cec8a17ee1a7090d960da2ff6d;
    /// @dev keccak256("comp.CDPVault.supplyBurnedThisTransaction"): imdUSD a repayment burned in this transaction
    /// (`wipe`, `bite`, `cover`; not a redemption), added back to the supply backing per imdUSD is measured against.
    uint256 private constant REPAID_THIS_TX_SLOT = 0xbcad9cc89ed804567fe3e103d0426f1858d5c1f9ef8bfda2c4bdf36a0faa0b5d;
    /// @dev 1e18-scaled seconds, the unit of the fresh-debt record's date.
    uint256 private constant WAD = 1e18;
    error WorkMintingOff();

    /// @notice Sum over positions of min(collateral, SECURED_COLLATERAL_MULTIPLE x principal / price),
    /// in IMD, each term at the price in force when that position last changed; a change made while no
    /// price could be read keeps the term, bounded by the collateral and scaled down with any principal
    /// repaid, until the position's next priced checkpoint (`_resecureBounded`).
    /// @dev REVISION (finding 7cd5035c): the backing guard read the vault's whole balance, less what
    /// this transaction deposited, and capped it at mat x prior principal. The cap assumes indebted
    /// positions hold at least that much; whenever they hold less (a price fall, an NHI fall raising
    /// mat) there is a gap, and a debt-free deposit made in an EARLIER transaction filled it: not
    /// in the transient tally, no debt, no health check, withdrawable the next transaction, so it
    /// cost nothing and let a redemption take the reserve above its pro-rata share. Collateral is
    /// now counted per position and bounded by that position's own principal, maintained wherever
    /// either changes, so a position with no debt contributes nothing and one wei of debt contributes
    /// two wei's worth. The multiple is the largest mat, fixed so the sum stays well defined as NHI
    /// moves; the aggregate mat cap in `_securedCollateralValue` still applies on top of it.
    /// Principal is denominated in the unit `_price()` quotes and collateral in IMD, so the bound
    /// needs a price, and a sum cannot be revalued for every position when the feed moves: each
    /// term is fixed at the price its position was last touched at. Positions whose collateral is
    /// inside their bound (at most 200% at that price; redeemable ones run to mat + gap, 220% at launch) are
    /// counted exactly in IMD and revalue with the feed like the balance did. Only the surplus above
    /// 200% is approximated: after a price fall such a position counts for less than it should, which
    /// tightens the guard until the position is touched, and after a rise for more, which the
    /// aggregate cap bounds. A deposit, repayment or any other change re-prices the position's term.
    uint256 public securedCollateral;
    uint256 private constant SECURED_COLLATERAL_MULTIPLE = 2;

    /// @notice Outstanding minted principal, as used by the unchanged debt ceiling.
    /// @dev Accrued, unpaid stability fees are additional obligations returned by debtOf/positions.
    uint256 public totalDebt;

    IERC20 public immutable gem;
    ImdUSD public immutable stablecoin;
    IWorkOracle private immutable _createdOracle;
    ISwarmFeed public immutable priceFeed;
    ISwarmFeed public immutable nhiFeed;
    ISwarmFeed public immutable spotFeed;
    uint256 public totalEarned;
    uint256 public totalFeesMinted;
    /// @notice Recorded residual debt from liquidations that exhausted collateral, at its last update.
    /// @dev A record of REALIZED loss: reduced only when the position's debt is repaid or cancelled
    /// (`wipe`, `cover` with the protocol's surplus imdUSD, which takes a re-lock worth less than the
    /// record at its value, `bite` of re-locked collateral, `cash` against
    /// a drained-then-relocked candidate); adding collateral does not erase it. So a drained borrower
    /// who re-collateralises and keeps a healthy loan open holds that much Treasury imdUSD behind the
    /// bad-debt-first floor until they repay (launch audit, governance panel, accepted: it costs them a
    /// real, fee-paying position). Use badDebtOf for a current-price, accrued view.
    uint256 public totalBadDebt;

    /// @notice PACED FIGURES — the fix for finding D1 (launch audit 2026-10-05, vault panel, medium), as
    /// redesigned on 2026-10-08 after the launch vault panel (job 5383ced0).
    /// @dev Capital brought in for one transaction and taken out a few later must not lift what a redemption
    /// is paid, dilute the fee, or authorise work minting. Three figures are PACED: each has a stored value,
    /// rewritten from the state the transaction found at its first call that moves capital (`_pace`), before
    /// that call changes anything, and the stored value may move only so fast:
    ///   BACKING per imdUSD falls at once to the live figure but rises by at most BACKING_RISE_PER_HOUR of par an
    ///   hour (`_pacedBacking`); a redemption is paid min(live, paced), capped at par.
    ///   SUPPLY follows the live supply, up or down, by at most FOLLOW_BPS_PER_HOUR of itself (or of the fee-base
    ///   floor, when that is larger) per hour of elapsed time, compounding per pacing (about 10.5% an hour paced
    ///   every block, `_pacedSupply`); the redemption fee is measured against it, floored
    ///   (`_feeBase`), so principal drawn for a block cannot dilute the fee and a repayment cannot shrink the base
    ///   to pin it at the cap.
    ///   DEBT falls at once and rises under the same limit as the supply (`_pacedDebt`); the work ceiling counts
    ///   debt only up to it (`ParameterizedVault.backedDebt`), so debt cancelled by a redemption or a liquidation
    ///   and drawn again by someone else counts only as the follow absorbs it, and a position's own repayment
    ///   and redraw in one transaction leaves it where it was (WIPED_THIS_TX_SLOT). It errs low, never high
    ///   (`_tallyPrincipalRetired`).
    /// Elapsed time counts toward a move only up to PACE_INTERVAL between two pacings, so a quiet day cannot bank
    /// a day's rise for one transaction to spend; anyone may pace (`pace`, or any call that moves capital), and
    /// within one transaction the transient tallies exclude the transaction's own capital. So whatever capital
    /// anyone brings, in whatever order across transactions, no one raises a redemption's payout faster than
    /// BACKING_RISE_PER_HOUR, nor moves the fee base or the work ceiling's debt faster than FOLLOW_BPS_PER_HOUR.
    /// The backing is paced only at an agreed, fresh price (`_priceAgrees`): while the feeds are stale or
    /// diverge it holds, so a diverged primary cannot write it either way.
    /// WHAT IT COSTS, all in the direction of paying less: after a real recovery (a price rise, a donation, a
    /// large honest loan) redemptions catch up with the live backing at BACKING_RISE_PER_HOUR, and only while the
    /// vault is paced (hourly pacing recovers in full; a quiet gap recovers one interval). And a fall is paced at
    /// once, however brief: a borrower who withdraws its capital in one transaction and brings it back in the
    /// next leaves the figure where the book stood without it, until it climbs back. The dip exists whenever the
    /// book WITHOUT the leaving position is below par: reserve + min(the remaining positions' secured value,
    /// mat x (debt - bad debt - its principal)) less than the supply without it (`_securedCollateralValue`). A book of healthy positions with slack in the aggregate
    /// cap has no dip; a book carrying an underwater position, realized bad debt or work-minted supply dips to the
    /// backing of what remains, which is near zero when the leaving position was nearly the whole book (paced
    /// vault panel 2026-10-08, medium, correcting an earlier 'below par only'). It is at most the gap between the
    /// book's backing and that figure, lasts (gap / BACKING_RISE_PER_HOUR) paced hours, costs the leaver gas and a
    /// transaction out of the book, and an honest refinance across two transactions triggers it too (in one
    /// transaction it does not). ACCEPTED: it underpays redeemers, never overpays them; the runbook keeps it
    /// rare (liquidate promptly, cover bad debt promptly, refinance in one transaction). Likewise after a price
    /// fall: a debt-bound position's term is fixed at the old price until the position is next touched
    /// (`securedCollateral`), so the live figure reads low and the first pacing after the fall captures that
    /// read; `resecure` lets anyone re-price any position, the keeper does after each update, and the payout
    /// climbs back at BACKING_RISE_PER_HOUR (the paced form of retry2 #6). The mirror, a term fixed at a crash
    /// low read at a recovered price (launch vault panel 2026-10-08, low; paced vault panel, medium), is
    /// re-priced the same way, and until it is can lift the payout no faster than the rise rate, bounded by the
    /// aggregate cap.
    /// History: the per-position lag this replaces (2026-10-05 to 2026-10-08, rounds 7 to 23 of
    /// web/content/docs/reference/audit-history.md) tracked the age of every unit of capital, and each repair of
    /// it opened the next finding. Its proofs are kept and run against the paced figures.
    uint256 public constant BACKING_RISE_PER_HOUR = 0.02e18;
    uint256 public constant FOLLOW_BPS_PER_HOUR = 1000;
    uint256 public constant PACE_INTERVAL = 1 hours;
    /// @dev How fast the price a redemption is PAID at may fall, per hour of elapsed time (compounding per
    /// pacing), for at most PACE_INTERVAL between pacings; it rises at once. THE RATE BOUNDS THE SPEED OF A FALL,
    /// NOT ITS SIZE: a one-step fall of the attested price (the feed's allowance, 20% fresh, 40% after two silent
    /// hours) reaches the payout in full after about 22 paced hours for 20% and 51 for 40%, and a pool held down
    /// pays a redeemer about 1% of the volume redeemed for each paced hour it is held, less the fee. The fee is
    /// what a burn pays against the fee base: a burn of 0.5% of the base pays 0.75% and breaks even after one paced
    /// hour, one at the 5% cap after five; what bounds a sustained drain is the base rate, which the drain's own
    /// burns ratchet to the cap. The rate was 5% an hour, which paid the whole step after five paced hours (payout
    /// vault panel 2026-10-09, high). The protocol bounds the gain per hour of hold; it does not bound the hours.
    /// The cost of a hold that scales with its length is absorbing every arbitrageur and buyer who takes the
    /// held pool's cheap IMD (IMD also trades in other pools and on other chains) (the push and unwind themselves cost about 2% of the IMD moved in pool fees, about $5k for 20% at
    /// launch depth), so whether a hold pays depends on that market, which the code does not enforce (final sweep
    /// panel 3 2026-10-09, medium, ACCEPTED as stated here and in docs/MAINNET-RUNBOOK.md). The rate bounds `cash`
    /// only: `bite` seizes at the attested price (see there).
    /// The cost on the other side is the lag: after an honest 20% fall redeemers are paid at the higher figure,
    /// falling 1% an hour, for about 22 hours; and a pool PUSHED UP writes each window's rise at once (a rise
    /// written slowly would leave the paid price under the market after a real rally, the way in) and underpays
    /// every redemption until it has decayed at 1% a paced hour: about 18 hours for one 20% window, 37 for two
    /// (1.44x), 55 for three, for the cost of the push and its hold (payout vault panel, low, accepted: nobody is
    /// forced to redeem, `minGemOut` lets a redeemer wait, and the direction never overpays).
    uint256 public constant PAYOUT_PRICE_FALL_BPS_PER_HOUR = 100;
    /// @dev Backing per imdUSD as last paced, 1e18-scaled (par at deployment, when there is no supply).
    uint128 private _backingPaced = 1e18;
    /// @dev When the supply and debt were last paced.
    uint64 private _pacedAt = uint64(block.timestamp);
    /// @dev When the backing was last paced AT A USABLE PRICE: a pacing through a stale or diverged window holds
    /// the backing and does not consume its interval (paced vault panel 2026-10-08, low).
    uint64 private _backingPacedAt = uint64(block.timestamp);
    /// @dev The supply as last paced.
    uint256 private _supplyPaced;
    /// @dev Total debt as last paced.
    uint256 private _debtPaced;
    /// @dev The collateral price as last paced for redemption payouts (zero until the first pacing at a usable
    /// price, when it follows the attested price), on the backing's clock.
    uint256 private _pricePaced;
    mapping(address account => Position position) private _positions;
    mapping(address account => uint256 index) public chiOf;
    mapping(address account => uint256 fees) private _stabilityFees;
    mapping(address account => uint256 debt) private _recordedBadDebt;
    mapping(address account => LiquidationMark mark) public liquidationMarks;

    /// @param gem_ Deployed, nonrebasing, fee-free collateral (sIMD on mainnet; COLLATERAL_FAUCET builds a MockIMD for tests).
    /// @param stablecoin_ Zero creates a fresh ImdUSD bound to this vault; otherwise an existing token
    /// to be authorized separately through its reciprocal setVault check.
    /// @param oracle_ Zero creates a fresh MockWorkOracle (the testnet faucet) bound to this vault
    /// during construction; WORK_ORACLE_SENTINEL asks WorkOracleFactory for a real attested
    /// SwarmWorkOracle; anything else is used as given and must already name this vault.
    /// A supplied oracle must already be deployed and, if it exposes vault(), bound to this vault.
    /// @param priceFeed_ Immutable collateral price feed, scaled by 1e18.
    /// @param nhiFeed_ Immutable network health feed, scaled by 1e18.
    /// @param spotFeed_ Immutable spot price feed, used only to bound divergence from the primary average.
    constructor(
        address gem_,
        address stablecoin_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) {
        // An EXPLICIT sentinel, not zero, asks the vault to deploy its own testnet collateral faucet.
        //
        // Why it exists: a launch manifest names a bounded number of contracts, and a deployment that fills
        // them with three feeds and the vault has no slot left for the collateral token. The parked
        // round-4 manifest therefore passed a LITERAL address, which has code only on the chain it was
        // deployed to, and this constructor requires code — so the project could not be constructed
        // anywhere else, which is how the launch failed with "project constructor failed".
        //
        // Why not zero, the convention stablecoin_ and oracle_ use: zero is what an unset field looks
        // like, and a mainnet vault that quietly took a MOCK token as its collateral would accept a
        // worthless asset against real debt. The existing guard refuses zero deliberately and still
        // does; this is an unmistakable opt-in that nobody passes by accident.
        if (gem_ == COLLATERAL_FAUCET) {
            gem_ = address(new MockIMD());
        }
        if (gem_.code.length == 0 || (stablecoin_ != address(0) && stablecoin_.code.length == 0) || gem_ == stablecoin_)
        {
            revert InvalidToken();
        }
        if (
            priceFeed_.code.length == 0 || nhiFeed_.code.length == 0 || spotFeed_.code.length == 0
                || priceFeed_ == nhiFeed_ || spotFeed_ == nhiFeed_ || spotFeed_ == priceFeed_
        ) revert InvalidFeed();
        gem = IERC20(gem_);
        stablecoin = stablecoin_ == address(0) ? new ImdUSD(address(this)) : ImdUSD(stablecoin_);
        priceFeed = ISwarmFeed(priceFeed_);
        nhiFeed = ISwarmFeed(nhiFeed_);
        spotFeed = ISwarmFeed(spotFeed_);
        if (oracle_ == address(0)) {
            oracle_ = address(new MockWorkOracle(address(this)));
        } else if (oracle_ == WORK_ORACLE_SENTINEL) {
            // Ask the pre-deployed factory for a real attested work oracle. It is a factory and not
            // a `new` here only because of a size limit: SwarmWorkOracle's creation code is 16,464
            // bytes and this vault's subclass is already within about 1 KB of the 49,152 EIP-3860 permits.
            // See WorkOracleFactory for why a binding transaction and CREATE2 are both worse.
            // No silent downgrade: an absent factory reverts rather than quietly leaving the vault on
            // the grantRights faucet, which is the shape of the $owner substitution that bricked
            // launch 519. `_validateOracle` below then confirms the oracle names THIS vault.
            if (WORK_ORACLE_FACTORY.code.length == 0) revert InvalidOracle();
            oracle_ = address(WorkOracleFactory(WORK_ORACLE_FACTORY).create(WORK_ORACLE_MAX_AGE));
        }
        _validateOracle(oracle_);
        _createdOracle = IWorkOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function lock(uint256 amount) external nonReentrant {
        uint256 price = _pace();
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = gem.balanceOf(address(this));
        Position storage position = _positions[msg.sender];
        position.collateral += amount;
        _resecure(position, price);
        gem.safeTransferFrom(msg.sender, address(this), amount);
        if (gem.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        _clearIfRecovered(msg.sender, price);
        emit Lock(msg.sender, amount);
    }

    /// @notice Lock collateral by handing over the share vault's UNDERLYING: the vault deposits it into
    /// the share vault on the caller's behalf and credits the shares it receives.
    /// @dev For a collateral token that is an ERC-4626 share (sIMD over IMD), so a borrower holding the
    /// plain token does not need a separate wrapping transaction. The credit is the shares actually
    /// received, measured by balance, not the amount `deposit` reports. Reverts `CollateralNotWrappable`
    /// when the collateral is not a share vault. The vault never redeems shares; see IShareVault.
    function lockIMD(uint256 assets) external nonReentrant {
        uint256 price = _pace();
        if (assets == 0) revert ZeroAmount();
        IERC20 underlying = IERC20(_shareAsset());
        uint256 beforeShares = gem.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        underlying.forceApprove(address(gem), assets);
        IShareVault(address(gem)).deposit(assets, address(this));
        underlying.forceApprove(address(gem), 0);
        uint256 shares = gem.balanceOf(address(this)) - beforeShares;
        if (shares == 0) revert ZeroAmount();
        Position storage position = _positions[msg.sender];
        position.collateral += shares;
        _resecure(position, price);
        _clearIfRecovered(msg.sender, price);
        emit Lock(msg.sender, shares);
    }

    /// @dev The share vault's underlying asset, or `CollateralNotWrappable` if the collateral is not a
    /// share vault. A raw staticcall, so a token without `asset()` reverts with our error, not its own.
    function _shareAsset() private view returns (address asset) {
        (bool ok, bytes memory data) = address(gem).staticcall(abi.encodeCall(IShareVault.asset, ()));
        if (!ok || data.length < 32) revert CollateralNotWrappable();
        asset = abi.decode(data, (address));
        if (asset == address(0) || asset == address(gem)) revert CollateralNotWrappable();
    }

    function free(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = _positions[msg.sender];
        if (amount > position.collateral) revert InsufficientCollateral();
        uint256 remaining = position.collateral - amount;
        // A withdrawal with debt always lowers CR, so it cannot be allowed with stale feeds.
        // Debt-free collateral remains withdrawable: its ratio is infinite and no solvency depends on a feed.
        uint256 debt = debtOf(msg.sender);
        uint256 price;
        if (debt != 0) {
            price = _requireFreshFeeds();
            _requirePriceAgreement();
            uint256 m = mat();
            _paceAt(price, m);
            if (!_healthy(remaining, debt, price, m)) revert UnsafeCollateralRatio();
        } else {
            price = _pace();
        }
        position.collateral = remaining;
        _resecure(position, price);
        _clearMark(msg.sender);
        gem.safeTransfer(msg.sender, amount);
        emit Free(msg.sender, amount);
    }

    function draw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        uint256 m = mat();
        _paceAt(price, m);
        if (stablecoin.vault() != address(this)) revert NotInitialized();
        _accrue(msg.sender);
        Position storage position = _positions[msg.sender];
        uint256 resultingDebt = position.debt + _stabilityFees[msg.sender] + amount;
        if (!_healthy(position.collateral, resultingDebt, price, m)) revert UnsafeCollateralRatio();
        uint256 resultingTotal = totalDebt + amount;
        if (resultingTotal > line()) revert DebtCeilingReached();
        totalDebt = resultingTotal;
        _debtChanged(resultingTotal - amount);
        position.debt += amount;
        _resecure(position, price);
        _transientAdd(MINTED_THIS_TX_SLOT, amount);
        _transientAdd(_mintedBySlot(msg.sender), amount);
        _clampPacedDebt();
        // REVISION (finding 883fa030): a top-up re-dated the whole record, so one wei every twelve
        // hours kept any amount of principal fresh forever. The record's timestamp now moves toward
        // the present by the new principal's share of the total: one wei cannot re-date a large
        // record, a record that has aged out starts over at the present, and principal-time in the
        // band is conserved whatever the tranches. The date is kept in 1e18-scaled seconds: at whole
        // seconds a tranche that dwarfed the record rounded its weighted date to the present, the next
        // repayment then multiplied a zero age, and a large draw/wipe pair every few hours kept seasoned
        // principal fresh, so redemptions against it never raised the base rate (final panel audit,
        // vault, low).
        uint256 fresh = _recentlyMinted(position);
        uint256 nowWad = block.timestamp * WAD;
        position.mintedAt = fresh == 0
            ? nowWad
            : position.mintedAt + Math.mulDiv(nowWad - position.mintedAt, amount, fresh + amount, Math.Rounding.Ceil);
        position.recentlyMinted = fresh + amount;
        _clearMark(msg.sender);
        stablecoin.mint(msg.sender, amount);
        emit Draw(msg.sender, amount);
    }

    /// @notice Mint earned imdUSD by consuming work rights, without collateral or a debt entry.
    /// @dev With this vault as sole minter/burner, supply = outstanding minted principal + totalEarned
    /// - totalNonPrincipalRedeemed. Unpaid fees are claims, not supply. Burning against reserve or
    /// cancelling unminted fees explains the last term. Neither repayment nor redemption restores rights.
    /// Refuses any amount that would carry totalEarned past `earnLine()`: rights say who may
    /// mint, the ceiling says how much backing exists for anyone to mint against.
    function earn(uint256 amount) external nonReentrant {
        _pace();
        if (amount == 0) revert ZeroAmount();
        if (!_earnOpen()) revert WorkMintingOff();
        _requireFreshFeeds();
        if (stablecoin.vault() != address(this)) revert NotInitialized();
        IWorkOracle workOracle = oracle();
        if (workOracle.mintingRights(msg.sender) < amount) revert InsufficientRights();
        uint256 resultingWork = totalEarned + amount;
        uint256 ceiling = earnLine();
        // REVISION (finding aba99865): a finite ceiling is priced off the primary feed —
        // ParameterizedVault values its reserve through it — so minting against one is a
        // price-dependent action and is refused while primary and spot disagree, like every other.
        // The unlimited ceiling here reads no price, and this vault's work channel stays open through
        // a divergence halt exactly as it did before (script/checks/CDPVaultIncrement.t.sol pins it).
        if (ceiling != type(uint256).max) _requirePriceAgreement();
        if (resultingWork > ceiling) revert WorkCeilingReached();
        totalEarned = resultingWork;
        workOracle.consumeRights(msg.sender, amount);
        _transientAdd(WORK_MINTED_THIS_TX_SLOT, amount);
        stablecoin.mint(msg.sender, amount);
        emit Earn(msg.sender, amount);
    }

    /// @notice Repay the caller's debt by burning their imdUSD; no imdUSD approval is required.
    /// @dev Repayment does not restore consumed work credits.
    function wipe(uint256 amount) external nonReentrant {
        uint256 price = _pace();
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        uint256 feePaid = _reduceDebt(msg.sender, amount, price, false);
        _payDebt(amount, feePaid);
        _clearIfRecovered(msg.sender, price);
        emit Wipe(msg.sender, amount);
    }

    /// @notice Cover a drained position's realized bad debt with the protocol's own surplus imdUSD.
    /// @dev Maker's Vow.heal, under a name that is not one letter from `heel`. Anyone may call it: it
    /// only ever cancels debt that no reachable collateral stands behind — a drained position, or one
    /// holding dust (`_coverDust`: worth under about 1.2 imdUSD, or a millionth of a debt above a
    /// million), which is swept to the surplus account first — so it raises backing per imdUSD for every
    /// holder. A re-lock worth less than the position's recorded bad debt is taken too, at its value: the
    /// call must then burn at least that much (`CoverBelowCollateralValue`). Anything worth more is a
    /// borrower rebuilding, and is liquidated, if at all, through `bark` and `bite` like any other position.
    /// The surplus is the Treasury's imdUSD (the stability fees it collected), and
    /// it is spent through the same repayment path as `wipe`, so fees are retired first and the
    /// position's recorded bad debt, totalBadDebt and totalDebt all move together. Reverts on a
    /// position holding collateral a bite could still reach (that is not realized bad debt) and on a
    /// vault with no surplus account.
    function cover(address owner, uint256 amount) external nonReentrant {
        uint256 priceOrZero = _pace();
        if (amount == 0) revert ZeroAmount();
        address payer = _surplus();
        if (payer == address(0)) revert NoSurplus();
        Position storage position = _positions[owner];
        _accrue(owner);
        if (position.collateral != 0) {
            // Dust does not make the debt behind it any less bad: it goes to the surplus account and the
            // shortfall is realized here. Two tests, one without a price: collateral below the seizure for
            // one wei of debt at the LAST price is unreachable by any bite and is swept with no fresh feed,
            // so re-locking one raw unit cannot move cover onto the feed-gated path between purchased
            // attestations (final panel audit, vault, low). Anything larger needs fresh, agreeing feeds, and
            // is swept only if it is dust (`_coverDust`); the rest is bitten first, which a drained position
            // allows at once (sweep panel audit, vault, medium: a sweep of anything worth less than the
            // recorded bad debt took a re-collateralised borrower's whole collateral for one wei of cover).
            uint256 last = priceOrZero;
            if (last == 0 || position.collateral >= _oneWeiSeizure(last)) {
                uint256 price = _requireFreshFeeds();
                _requirePriceAgreement();
                if (position.collateral >= _coverDust(owner, price)) {
                    // A re-lock worth less than the bad debt the position already realized is taken AT ITS
                    // VALUE: the surplus burns at least that much of the position's debt for it. So while the
                    // Treasury holds imdUSD worth the re-lock, holding cover off costs the griefer the whole
                    // re-lock, with no liquidator needed (retry panel audit 2026-10-07, vault, low: the bite
                    // that cleared a $1.20 re-lock paid $0.18), and a borrower rebuilding is paid par for it,
                    // not bitten at a 20% penalty. With less, this reverts and the re-lock waits for a mark,
                    // grace and bite (`_coverDust`).
                    if (!_relockBelowBadDebt(owner, price)) revert NoRealizedBadDebt();
                    if (amount < Math.mulDiv(position.collateral, price, 1e18, Math.Rounding.Ceil)) {
                        revert CoverBelowCollateralValue();
                    }
                }
                last = price;
            }
            priceOrZero = last;
            uint256 dust = position.collateral;
            position.collateral = 0;
            _resecure(position, last);
            _recordBadDebt(owner);
            gem.safeTransfer(payer, dust);
        }
        if (_recordedBadDebt[owner] == 0) revert NoRealizedBadDebt();
        // The surplus account records what arrived before any of it is burned, so revenue landing
        // since its last sync is not lost from its books (launch audit, governance panel, low).
        _syncSurplus(payer);
        uint256 feePaid = _reduceDebt(owner, amount, priceOrZero, true);
        _clampPacedDebt();
        stablecoin.burn(payer, amount);
        _transientAdd(REPAID_THIS_TX_SLOT, amount);
        // Sync again after the burn and before the fees are reminted, so the baseline drops to the
        // burned balance and the reminted fees arrive as new receipts (adversarial review 2026-10-05,
        // low: synced only before, the remint landed below the baseline and was never credited).
        _syncSurplus(payer);
        if (feePaid != 0) {
            totalFeesMinted += feePaid;
            stablecoin.mint(feeRecipient(), feePaid);
        }
        _clearIfRecovered(owner, priceOrZero);
        emit Cover(owner, amount, payer);
    }

    /// @dev A drained position whose collateral, at `price`, is worth less than the bad debt it realized.
    function _relockBelowBadDebt(address owner, uint256 price) private view returns (bool) {
        uint256 recorded = _recordedBadDebt[owner];
        return recorded != 0 && Math.mulDiv(_positions[owner].collateral, price, 1e18) < recorded;
    }

    /// @dev The account whose imdUSD `cover` spends. None for the base vault, whose fee recipient is a
    /// wallet that never agreed to this; ParameterizedVault answers its own Treasury.
    function _surplus() internal view virtual returns (address) {
        return address(0);
    }

    /// @dev Records the surplus account's imdUSD receipts before `cover` burns from it. Nothing for the
    /// base vault; ParameterizedVault calls its Treasury's permissionless `sync`.
    function _syncSurplus(address) internal virtual {}

    /// @dev Raw collateral that one wei of debt plus the bonus seizes at `price`: anything smaller can
    /// never be reached by `bite` through the formula.
    function _oneWeiSeizure(uint256 price) private pure returns (uint256) {
        return Math.mulDiv(1, (100 + CHOP_PERCENT) * 1e16, price);
    }

    /// @dev The largest collateral `cover` sweeps as dust: the seizure for the larger of a millionth of
    /// what the position owes and one imdUSD of it (a hundredth of the debt, for a debt under 100 imdUSD).
    /// Final review 2026-10-07, low: at the one-wei seizure plus one raw unit (about 1e-20 sIMD, worth
    /// nothing) a drained borrower could re-lock for free after every bite and keep its bad debt
    /// uncoverable for a mark-and-grace cycle at a time. A millionth of the debt alone left that re-lock
    /// free in capital too, about $0.001 on a $1,000 debt (second-half review 2026-10-07, low). Swept, the
    /// dust goes to the surplus account; anything larger but worth less than the recorded bad debt is taken
    /// by `cover` at its value, so holding cover off costs the whole re-lock every time the Treasury holds that
    /// much imdUSD; with less, the re-lock waits for a mark and grace and is bitten, at the 20% bonus.
    function _coverDust(address owner, uint256 price) private view returns (uint256) {
        uint256 debt = _positions[owner].debt + _stabilityFees[owner];
        uint256 floor_ = debt / 100 < COVER_DUST_MIN_DEBT ? debt / 100 : COVER_DUST_MIN_DEBT;
        uint256 slice = debt / COVER_DUST_DIVISOR;
        if (slice < floor_) slice = floor_;
        return Math.mulDiv(slice > 1 ? slice : 1, (100 + CHOP_PERCENT) * 1e16, price);
    }

    /// @notice Burn exactly `amount` caller imdUSD for IMD at the higher of the attested price and the paced
    /// payout price (`payoutPrice`), less the capped fee, scaled down by `backingPerUnit` while the protocol is
    /// backed below par.
    /// @dev Treasury IMD is spent first; only the shortfall cancels the named candidate's debt.
    /// No approval, partial fill or fee transfer. All checks and both payouts are atomic.
    function cash(uint256 amount, uint256 minGemOut, address candidate) external nonReentrant returns (uint256 gemOut) {
        if (amount == 0) revert ZeroAmount();
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        uint256 payoutScale;
        uint256 payPrice;
        {
            uint256 m = mat();
            _paceAt(price, m);
            payoutScale = _backingPerUnit(price, m);
            // THE PAYOUT PRICE IS PACED (final sweep panel 2026-10-09, high): the attested price can fall a whole
            // allowance in one step and both feeds read the one pool, so a pool pushed down and held through
            // the median window paid a redeemer the whole fall in extra IMD, from candidates and the reserve.
            // IMD is paid at the higher of the price and the paced price, which falls at most
            // PAYOUT_PRICE_FALL_BPS_PER_HOUR an hour (`_pacedPrice`); eligibility, health and the term stay at
            // the attested price. The rate bounds the speed of a fall, not its size (see the constant): a pool
            // held down is paid about 1% of the volume redeemed per paced hour held, less the fee; a pool pushed
            // up underpays redeemers until each window's push has decayed; after an honest fall redeemers are
            // paid at the higher figure until the paced price has followed it down, about 22 paced hours for 20%.
            payPrice = _payoutPrice(price);
        }
        // The fee base is read once, before the candidate is touched, so the quote and the stored rate agree
        // (final vault panel, info).
        uint256 prior = _feeBase();
        // REVISION (finding b8aa4a98): whole basis points, rounded against the party paying them.
        uint256 feeBps = REDEMPTION_FEE_FLOOR_BPS + Math.ceilDiv(_redemptionRate(amount, prior), 1e14);
        // THE PAYOUT IS CAPPED AT WHAT BACKS A imdUSD, and that is what keeps this channel open.
        //
        // It used to pay (1 - fee) of PAR unconditionally and then refuse the redemption if that
        // removed more than its share of backing (`RedemptionWorsensBacking`, the source revision
        // for finding `b92320ae`: after a permitted borrow/work-mint/repay/withdraw sequence a
        // reserve redemption took backing from 100/250 to 90.15/240). That finding is real and this
        // still answers it -- `test_debtUnwindCannotLeaveReserveRedemptionWorseningBacking` replays
        // exactly its sequence -- by paying 3.94 where par paid 9.85, rather than by refusing.
        // Round 5's review then raised the refusal itself three separate times (`3c1f49fc`,
        // `6a96e6da`, `d9c96fb5`), each time leaving the policy to the requester. The refusal engaged
        // exactly when backing per imdUSD fell below 1 - fee, which is a price fall with work-issued
        // imdUSD outstanding -- so redemption, the mechanism that defends the peg, halted precisely
        // when the peg was under stress, and it refused even burns against positions whose own ratio
        // the redemption would have RAISED. Round 5's review called it "a non-governable [halt] that
        // engages exactly during the stress the peg is meant to survive", quoting this protocol's own
        // objection to a governable cap back at it.
        //
        // Paying pro-rata instead is exactly neutral on backing by construction: remove B per imdUSD
        // from a pool backed at B and the ratio is unchanged, so there is nothing left to guard
        // against. With the fee applied on top it strictly improves ECONOMIC backing (collateral plus
        // reserve over supply). The conservative backingPerUnit() can still fall across a redemption
        // funded from a position when the mat cap binds, because cancelled debt disqualifies collateral
        // it no longer secures (launch audit, vault panel, low: 1.0 -> 0.927 -> 0.756). Accepted: that
        // measure is deliberately not monotone.
        //
        // The honest consequence, which is the point rather than a cost: the peg floor is
        // min(1 - fee, backing). A protocol backed at 0.96 cannot promise 0.995, and the previous
        // design's answer to that was to stop redeeming rather than to stop overpaying.
        payoutScale = Math.mulDiv(payoutScale, 10_000 - feeBps, 10_000);
        gemOut = Math.mulDiv(amount, payoutScale, payPrice);
        if (gemOut == 0) revert ZeroAmount();
        if (gemOut < minGemOut) revert MinimumOutNotMet();
        uint256 reserveOut = Math.min(gemOut, redemptionReserve());
        uint256 debtCancelled;
        uint256 principalCancelled;
        uint256 freshCancelled;
        if (reserveOut < gemOut) {
            // Round reserve-funded debt down, so every wei released by a borrower is covered by
            // cancelled debt. Compute the payout ONCE: its price never depends on the candidate.
            debtCancelled = amount - Math.mulDiv(reserveOut, payPrice, payoutScale);
            (principalCancelled, freshCancelled) = _redeemPosition(candidate, debtCancelled, gemOut - reserveOut, price);
            _clampPacedDebt();
        }
        totalNonPrincipalRedeemed += amount - principalCancelled;
        // The fresh part of the burn is charged in full but does not move the rate everyone else pays.
        redemptionBaseRate = _redemptionRate(amount - freshCancelled, prior);
        lastRedemptionAt = block.timestamp;
        stablecoin.burn(msg.sender, amount);
        if (reserveOut != 0) _payRedemptionReserve(reserveOut);
        if (reserveOut < gemOut) gem.safeTransfer(msg.sender, gemOut - reserveOut);
        emit Cash(msg.sender, candidate, amount, gemOut, reserveOut, debtCancelled, feeBps);
    }

    /// @notice Value backing one imdUSD, 1e18-scaled, never above par, at the primary feed's latest value (no
    /// freshness or agreement check: a quote, where `cash` checks both).
    /// @dev Public because it is the figure a redeemer is actually paid against and the one a reader
    /// needs to judge the protocol: below 1e18 it says plainly that a imdUSD is not fully backed, and
    /// the redemption payout falls with it instead of the channel closing.
    function backingPerUnit() external view returns (uint256) {
        return _backingPerUnit(_price(), mat());
    }

    /// @notice Value backing one imdUSD, 1e18-scaled, never above par.
    /// @dev Reserve plus secured collateral over supply. Capped at 1e18 because a protocol backed
    /// above par does not pay a premium: the surplus is the borrowers' and the work ceiling's
    /// headroom, not a redeemer's windfall. Read pre-payout, so it is the state the burn found.
    ///
    /// PACED (adversarial review 2026-10-05, medium, D1's redemption half; redesigned 2026-10-08): the lower of
    /// the live figure and the paced backing, which may rise by at most BACKING_RISE_PER_HOUR (see the paced
    /// figures' NatSpec). Capital brought in to lift the live figure lifts the payout no faster than that,
    /// whatever its size, whether it is new collateral, a band position's draw, a repayment or a donation,
    /// and whether the payout comes from the reserve or from a candidate.
    /// The live figure's supply is the live one plus what repayments earlier in this transaction burned
    /// (REPAID_THIS_TX_SLOT), so a same-call wipe, cash and draw is paid no premium (sweep panel audit, vault,
    /// medium); collateral and principal added in this transaction are excluded (`_securedCollateralValue`).
    function _backingPerUnit(uint256 price, uint256 m) private view returns (uint256) {
        return _pacedBacking(price, m, block.timestamp - _backingPacedAt);
    }

    /// @dev Backing per imdUSD from the state as it stands, capped at par: reserve plus secured collateral
    /// over supply, excluding this transaction's own capital. SATURATING: the pacing reads it inside lock and
    /// wipe, which must never revert for arithmetic, so anything at or above par reads par without a product
    /// that could overflow at an absurd price.
    function _liveBacking(uint256 price, uint256 m) private view returns (uint256) {
        uint256 supply = stablecoin.totalSupply() + _transient(REPAID_THIS_TX_SLOT);
        if (supply == 0) return 1e18;
        uint256 secured = _securedCollateralValue(price, m);
        if (secured >= supply) return 1e18;
        uint256 reserve = _redemptionReserveBacking(price);
        if (reserve >= supply - secured) return 1e18;
        return Math.mulDiv(reserve + secured, 1e18, supply);
    }

    /// @dev The paced backing `elapsed` seconds after it was written at a usable price: the live figure, but no
    /// more than the paced value plus BACKING_RISE_PER_HOUR an hour, for at most PACE_INTERVAL of `elapsed`. With
    /// no readable price the paced value holds.
    function _pacedBacking(uint256 price, uint256 m, uint256 elapsed) private view returns (uint256) {
        if (price == 0) return Math.min(_backingPaced, 1e18);
        uint256 ceiling = _backingPaced + Math.mulDiv(BACKING_RISE_PER_HOUR, Math.min(elapsed, PACE_INTERVAL), 1 hours);
        return Math.min(_liveBacking(price, m), ceiling);
    }

    /// @dev The paced supply `elapsed` seconds after it was written: moved toward the supply this transaction
    /// began with (the live supply, less what it minted, plus what its repayments burned), up or down, by at most
    /// one `_step`.
    function _pacedSupply(uint256 elapsed) private view returns (uint256) {
        uint256 live = stablecoin.totalSupply() + _transient(REPAID_THIS_TX_SLOT);
        uint256 minted = _transient(MINTED_THIS_TX_SLOT) + _transient(WORK_MINTED_THIS_TX_SLOT);
        live = live > minted ? live - minted : 0;
        if (!_followRateLimited()) return live;
        uint256 value = _supplyPaced;
        // From zero (deployment, or a book that emptied) the paced supply follows the live one at once, but no
        // higher than the fee-base floor: seeded from the live supply, whoever drew first set the launch fee base
        // (a whale's block-long draw diluted fees for a day; a one-wei draw pinned the base at the floor: final
        // sweep panel 2026-10-09, low). So the first day's redemptions are measured against the floor until the
        // paced supply has followed the book up at FOLLOW_BPS_PER_HOUR (paced vault panel #5 restated as
        // accepted: fees err high while the book is new). The paced debt has no seed at all.
        if (value == 0) return Math.min(live, _feeBaseFloor());
        uint256 step = _step(value, elapsed);
        if (live >= value) return Math.min(live, value + step);
        return Math.max(live, value > step ? value - step : 0);
    }

    /// @dev The paced debt `elapsed` seconds after it was written: at most the debt this transaction began with,
    /// less what it cancelled by redemption, liquidation or cover (a position's own wipe and redraw cancel out:
    /// WIPED_THIS_TX_SLOT), and no more than the paced value plus one `_step`. A decrease counts at once.
    function _pacedDebt(uint256 elapsed) private view returns (uint256) {
        uint256 live = _debtForPacing();
        if (!_followRateLimited()) return live;
        return Math.min(live, _debtPaced + _step(_debtPaced, elapsed));
    }

    /// @dev The debt this transaction began with, less what it has cancelled: total debt plus what `wipe` repaid
    /// in it, less what it minted.
    function _debtForPacing() private view returns (uint256) {
        uint256 live = totalDebt + _transient(WIPED_THIS_TX_SLOT);
        uint256 minted = _transient(MINTED_THIS_TX_SLOT);
        return live > minted ? live - minted : 0;
    }

    /// @dev FOLLOW_BPS_PER_HOUR of the larger of a paced value and the fee-base floor, for at most PACE_INTERVAL
    /// of `elapsed`: how far the paced supply or debt may move in one pacing.
    function _step(uint256 paced, uint256 elapsed) private view returns (uint256) {
        return Math.mulDiv(
            Math.max(paced, _feeBaseFloor()), FOLLOW_BPS_PER_HOUR * Math.min(elapsed, PACE_INTERVAL), 10_000 * 1 hours
        );
    }

    /// @dev The paced supply as of now (the fee base).
    function _pacedSupplyNow() internal view returns (uint256) {
        return _pacedSupply(block.timestamp - _pacedAt);
    }

    /// @dev The paced debt as of now (the work ceiling's bound on debt, `ParameterizedVault.backedDebt`).
    function _pacedDebtNow() internal view returns (uint256) {
        return _pacedDebt(block.timestamp - _pacedAt);
    }

    /// @dev keccak256("comp.CDPVault.pacedThisTransaction"): set once the figures are paced in this transaction.
    uint256 private constant PACED_THIS_TX_SLOT = 0xa5af5aeac1078b86a4556924e539e6939ac21e8b1c577f66d2d6e26889efb3e4;
    /// @dev keccak256("comp.CDPVault.principalWipedThisTransaction"): pre-existing principal repaid through `wipe`
    /// in this transaction (by any caller: the tally is per transaction), added back to the debt the paced debt
    /// follows, so a position's own repayment and redraw in one transaction cancel out.
    uint256 private constant WIPED_THIS_TX_SLOT = 0x05396239c2fc4e6167488fce9321b3608d4ab9f7d959141db04a7b14318e0528;
    /// @dev keccak256("comp.CDPVault.preexistingPrincipalCancelledThisTransaction"): pre-existing principal cancelled
    /// by a redemption, a liquidation or cover in this transaction. The paced debt may not exceed what it was at
    /// the transaction's start less this (`_clampPacedDebt`), so cancelling seasoned debt lowers it at once however
    /// the transaction is ordered, while cancelling the transaction's own fresh draw moves nothing (final sweep
    /// panel 2026-10-09, low). Older principal is booked in full, so the paced debt errs low (`_tallyPrincipalRetired`).
    uint256 private constant CANCELLED_PRE_SLOT = 0x017d720555494c1e7627124a9367b025ef616e2c06f28e766961d9a3f3b87be1;
    /// @dev keccak256("comp.CDPVault.pacedDebtAtTransactionStart"): the paced debt as this transaction's pacing wrote
    /// it, plus one so that zero means "not paced".
    uint256 private constant PACED_DEBT_AT_START_SLOT =
        0x1a1ef090c3867d2d0383ad59612de965ceef2f29c76ae7cf079999bfd775cffa;
    /// @dev keccak256("comp.CDPVault.mintedByThisTransaction"), keyed per position: principal this transaction minted
    /// for that position and still outstanding, netted out of what a cancellation or wipe retires.
    uint256 private constant MINTED_BY_SLOT = 0xc9273ad647d44733763448beb4d3b14cd914d3b0863ff071581c73016007af89;

    function _mintedBySlot(address owner) private pure returns (uint256) {
        // The base's top 96 bits are random, so owners never collide with each other or with the fixed slots.
        return MINTED_BY_SLOT ^ uint256(uint160(owner));
    }

    /// @dev Books `principalPaid` retired from `owner`: the part this transaction minted for the position comes
    /// out of the minted tallies (it was never counted); the rest is pre-existing principal, cancelled (cash,
    /// bite, cover) or wiped by its owner.
    /// THE PACED DEBT ERRS LOW, NEVER HIGH. Nothing records how much of a position's debt the paced debt has
    /// followed, so a cancellation of principal older than this transaction is booked as pre-existing in full and
    /// the clamp lowers the paced debt by it. When the cancelled principal was younger than the follow, that is
    /// more than the follow had absorbed, and the paced debt (with `backedDebt` and the work ceiling's ratio term)
    /// reads low until the follow recovers it at FOLLOW_BPS_PER_HOUR: a borrower redeeming their own one-block-old
    /// draw drives it toward zero for gas (payout vault panel 2026-10-09, low, ACCEPTED). The other direction was
    /// tried and is worse: netting out the position's whole twelve-hour record (73191e0) let a fully followed
    /// loan's cancellation book nothing, so another position's zero-second draw counted in full and the ceiling
    /// read HIGH (final sweep panel 3 2026-10-09, low; reverted). A low ceiling refuses work minting it could have
    /// allowed; a high one mints against debt that was not held. The wage is zero at launch, and turning it on is
    /// a governance act behind the timelock.
    function _tallyPrincipalRetired(address owner, uint256 principalPaid, bool cancellation) private {
        uint256 bySlot = _mintedBySlot(owner);
        uint256 own = Math.min(principalPaid, _transient(bySlot));
        if (own != 0) {
            _transientSub(bySlot, own);
            _transientSub(MINTED_THIS_TX_SLOT, own);
        }
        uint256 rest = principalPaid - own;
        if (rest != 0) _transientAdd(cancellation ? CANCELLED_PRE_SLOT : WIPED_THIS_TX_SLOT, rest);
    }

    /// @notice Pace the three figures from the state as it stands. Anyone may call it; every call that moves
    /// capital does so first, so this only matters to let a recovery reach redeemers through a quiet spell.
    function pace() external {
        _pace();
    }

    /// @dev Writes the three figures from the state this TRANSACTION found, at its first call that moves capital:
    /// a fall reaches the paced backing at once, so it is written even when no time has passed (only a rise
    /// waits on the clock), and a transaction's own steps (a wipe and redraw in one call) never pace a dip the
    /// transaction reverses itself. Returns the collateral price it read (zero if unreadable), for the ungated
    /// caller to re-price its term with, so the price is read once per call.
    function _pace() internal returns (uint256 priceOrZero) {
        priceOrZero = _priceOrZero();
        if (_transient(PACED_THIS_TX_SLOT) != 0) return priceOrZero;
        bool usable = priceOrZero != 0 && _priceAgrees();
        _paceWith(usable ? priceOrZero : 0, usable ? mat() : 0);
    }

    /// @dev `_pace` for a gated entry point that has already passed `_requireFreshFeeds` and
    /// `_requirePriceAgreement`: the price is usable, read once, and `m` is `mat()` read once.
    function _paceAt(uint256 price, uint256 m) private {
        if (_transient(PACED_THIS_TX_SLOT) != 0) return;
        _paceWith(price, m);
    }

    function _paceWith(uint256 price, uint256 m) private {
        _transientAdd(PACED_THIS_TX_SLOT, 1);
        uint256 elapsed = block.timestamp - _pacedAt;
        if (price != 0) {
            uint256 sincePrice = block.timestamp - _backingPacedAt;
            _backingPaced = uint128(_pacedBacking(price, m, sincePrice));
            _pricePaced = _pacedPrice(price, sincePrice);
            _backingPacedAt = uint64(block.timestamp);
        }
        _supplyPaced = _pacedSupply(elapsed);
        _debtPaced = _pacedDebt(elapsed);
        _pacedAt = uint64(block.timestamp);
        _transientAdd(PACED_DEBT_AT_START_SLOT, _debtPaced + 1);
    }

    /// @dev After a draw and after every cancellation (cash, bite, cover): the paced debt never exceeds the paced
    /// debt this transaction began with less the pre-existing principal it cancelled, nor the debt it began with
    /// less what it cancelled (`_pacedDebt`'s live figure). So cancelling seasoned debt lowers it at once in any
    /// order and in any transaction, however fresh the debt drawn against it (sweep panel audit 2026-10-07, vault,
    /// high; paced vault panel 2026-10-08, medium; final sweep panel 2026-10-09, low: a draw one block earlier
    /// and a cancellation the next, and a self-redemption of the transaction's own fresh draw). Cancelling principal
    /// older than the transaction but younger than the follow lowers it by more than the follow absorbed: it errs
    /// low, never high (`_tallyPrincipalRetired`).
    function _clampPacedDebt() private {
        if (!_followRateLimited()) return;
        uint256 recorded = _transient(PACED_DEBT_AT_START_SLOT);
        uint256 cap = recorded == 0 ? _debtPaced : recorded - 1;
        uint256 cancelled = _transient(CANCELLED_PRE_SLOT);
        cap = cap > cancelled ? cap - cancelled : 0;
        uint256 next = Math.min(cap, _debtForPacing());
        if (next < _debtPaced) _debtPaced = next;
    }

    /// @dev `_requireFreshFeeds` and `_requirePriceAgreement` as a question: fresh feeds and a spot within
    /// `skew()` of the primary. Pacing holds the backing when the answer is no, rather than reverting the
    /// ungated calls (`lock`, `wipe`) that pace.
    function _priceAgrees() private view returns (bool) {
        if (_pricingStale() || spotFeed.isStale()) return false;
        (uint256 spot,) = spotFeed.latestValue();
        (uint256 primary,) = priceFeed.latestValue();
        return spot != 0 && primary != 0 && _withinSkew(primary, spot);
    }

    /// @dev Whether the paced supply, debt and payout price limit how fast the fee base, the work ceiling and the
    /// price a redemption is paid at follow the live figures. Always on the deployed vault; a test vault that checks
    /// fee, ceiling and payout arithmetic at exact figures turns it off (test/helpers/OpenWorkVault.sol). The paced
    /// backing has no switch.
    function _followRateLimited() internal view virtual returns (bool) {
        return true;
    }

    /// @notice The paced figures and when they were written (see BACKING_RISE_PER_HOUR): the backing and the
    /// payout price at `backingAt`, the last pacing at a usable price; the supply and debt at `at`.
    function paced()
        external
        view
        returns (uint256 backing, uint256 supply, uint256 debt, uint256 at, uint256 backingAt, uint256 price)
    {
        return (_backingPaced, _supplyPaced, _debtPaced, _pacedAt, _backingPacedAt, _pricePaced);
    }

    /// @dev The paced payout price `elapsed` seconds after it was written: the attested price if higher, else
    /// the paced price less at most PAYOUT_PRICE_FALL_BPS_PER_HOUR for at most PACE_INTERVAL of `elapsed`.
    /// Before the first pacing it is the attested price.
    function _pacedPrice(uint256 price, uint256 elapsed) private view returns (uint256) {
        uint256 paced = _pricePaced;
        if (!_followRateLimited() || paced == 0 || price >= paced) return price;
        uint256 floor_ = paced
            - Math.mulDiv(paced, PAYOUT_PRICE_FALL_BPS_PER_HOUR * Math.min(elapsed, PACE_INTERVAL), 10_000 * 1 hours);
        return Math.max(price, floor_);
    }

    /// @dev The price a redemption is paid at now: see `cash`.
    function _payoutPrice(uint256 price) private view returns (uint256) {
        return _pacedPrice(price, block.timestamp - _backingPacedAt);
    }

    /// @notice The price a redemption is paid at right now, 1e18-scaled, against the attested price.
    function payoutPrice() external view returns (uint256) {
        return _payoutPrice(_price());
    }

    /// @notice Re-price `owner`'s secured term at the current price. Anyone may call it, at a fresh, agreed
    /// price; the keeper does so for every open position after each price update.
    /// @dev A term is fixed at the price its position was last touched at (`securedCollateral`), and until this
    /// function existed only the owner, a redemption, a liquidation or cover touched it: after a price fall an idle
    /// position's debt-bound term read low for as long as its owner was idle, and a term an owner had fixed at a
    /// crash low read high after the recovery, lifting the live figure and, at the rise rate, the payout (paced
    /// vault panel 2026-10-08, medium). A fall this causes is paced at once; a rise reaches the payout at the
    /// rise rate, bounded by the aggregate cap.
    function resecure(address owner) external nonReentrant {
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        _paceAt(price, mat());
        _resecure(_positions[owner], price);
    }

    /// @dev The vault's collateral the guard may count as backing: what stood behind debt before this
    /// transaction, and no more than the debt that existed before it holds at mat.
    /// REVISION (finding 8936befa): the whole balance counted, including collateral posted against no
    /// debt and every borrower's surplus, which is withdrawable with no feed or health check and backs
    /// no imdUSD. A redeemer deposited debt-free, redeemed and withdrew in one call, and the deposit
    /// passed the guard for any amount. Secured collateral added in this transaction is excluded, as
    /// backedDebt excludes same-transaction debt; and the remainder counts only up to mat times the
    /// principal that existed before this transaction (less bad debt), the surplus every borrower must
    /// keep in place and the figure section 3 of docs/COMPUTE-BACKING-DESIGN.md backs work minting
    /// against. One-for-one with debt would be wrong the other way: it would refuse the brief's own
    /// flow of redeeming work-issued imdUSD against an eligible position in a fully backed system.
    /// REVISION (finding 7cd5035c): the balance is replaced by `securedCollateral`, which is bounded
    /// position by position, so the slow version of the same deposit no longer fills the gap the cap
    /// leaves open when indebted positions hold less than mat.
    ///
    /// D1 (launch audit 2026-10-05, vault panel, medium). Excluding only the CURRENT
    /// transaction's capital left adjacent transactions open: borrow in one, earn (or cash) in the next,
    /// repay and withdraw in a third, and work-minted imdUSD outlived the debt that authorised it, or a
    /// redemption took the reserve at par while backing was 0.4. Fixed by the paced figures
    /// (`_pace`): the payout is capped by the paced backing and the work ceiling by the paced debt. This figure
    /// is the live part of both. Proofs: docs/AUDIT-VAULT-2026-10-05.md, test/PacedFigures.t.sol,
    /// test/RedemptionLagAtLaunch.t.sol.
    function _securedCollateralValue(uint256 price, uint256 m) private view returns (uint256) {
        uint256 secured = securedCollateral;
        uint256 added = _transient(SECURED_THIS_TX_SLOT);
        uint256 held = secured > added ? secured - added : 0;
        uint256 minted = _transient(MINTED_THIS_TX_SLOT);
        uint256 prior = totalDebt > minted ? totalDebt - minted : 0;
        uint256 bad = totalBadDebt;
        prior = prior > bad ? prior - bad : 0;
        uint256 cap = Math.mulDiv(prior, m, 100);
        // Saturating: the product is taken only when it is below the cap, so no price can make it overflow.
        if (price == 0 || held >= Math.mulDiv(cap, 1e18, price, Math.Rounding.Ceil)) return price == 0 ? 0 : cap;
        return Math.mulDiv(held, price, 1e18);
    }

    /// @dev REVISION (finding b952037a): a position-funded fee stays in the candidate, so a redeemer
    /// who controls the candidate — the same key or a second one — pays nothing to burn against it,
    /// and nothing stopped a mint / self-redeem / withdraw round trip from pinning the rate everyone
    /// else pays at the cap for gas. Principal younger than one half-life of the rate therefore
    /// counts for nothing in the increase when cancelled: the pump now needs that much principal-time
    /// held in the eligible band, exposed to price and liquidation — twelve hours of the whole amount,
    /// or the same product in other tranches, see `draw` — per pinning, and a rotating supply of
    /// it to keep the rate there. It is a cost, not a closure: with the fee retained where the brief
    /// puts it, no rule can tell a seasoned self-redemption from an honest one.
    /// @return principalCancelled Minted principal retired, as opposed to accrued fees.
    /// @return freshCancelled The part of the burn that cancelled principal minted within the window.
    function _redeemPosition(address candidate, uint256 amount, uint256 gemOut, uint256 price)
        private
        returns (uint256 principalCancelled, uint256 freshCancelled)
    {
        _accrue(candidate);
        Position storage position = _positions[candidate];
        uint256 debt = position.debt + _stabilityFees[candidate];
        if (debt == 0 || _collateralRatio(position.collateral, debt, price) >= redemptionCeilingCR()) {
            revert IneligibleRedemptionPosition();
        }
        if (amount > debt) revert ExcessRepayment();
        // Compare the exact collateral/debt fractions, not rounded whole-percent ratios. Deeply
        // underwater positions cannot fund a fixed-price payout that would worsen their ratio.
        if (gemOut > Math.mulDiv(position.collateral, amount, debt)) revert RedemptionWorsensRatio();
        uint256 fresh = _recentlyMinted(position);
        uint256 feesCancelled = _reduceDebt(candidate, amount, price, true);
        principalCancelled = amount - feesCancelled;
        // Only principal can be fresh: cancelled fees move the rate like any other part of the burn.
        freshCancelled = Math.min(principalCancelled, fresh);
        position.collateral -= gemOut;
        _resecure(position, price);
        _recordBadDebt(candidate);
        _clearIfRecoveredAt(candidate, price, mat()); // cash's stack is full; one NHI read on the candidate path
        // Unlike repayment/liquidation, redemption burns everything and remints no stability fees.
        // Its discount remains in this position as backing, with no recipient or distribution.
    }

    /// @notice Current decayed base fee, as a fraction scaled by 1e18.
    function decayedRedemptionBaseRate() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastRedemptionAt;
        uint256 rate = redemptionBaseRate;
        if (rate == 0) return 0;
        return Math.mulDiv(rate, _pow(REDEMPTION_SECOND_DECAY, elapsed, 1e18), 1e18);
    }

    /// @dev `factor` to the power `n`, both scaled by `one`, by squaring.
    /// Both stay at or below `one` (callers pass a factor below it), so no product can overflow.
    function _pow(uint256 factor, uint256 n, uint256 one) private pure returns (uint256 result) {
        result = one;
        unchecked {
            while (n != 0) {
                if (n & 1 != 0) result = result * factor / one;
                n >>= 1;
                factor = factor * factor / one;
            }
        }
    }

    /// @notice Fee for a proposed burn, including its increase against supply BEFORE burning.
    /// A zero amount quotes just the current floor plus decayed base.
    function redemptionFeeBps(uint256 amount) external view returns (uint256) {
        return REDEMPTION_FEE_FLOOR_BPS + Math.ceilDiv(_redemptionRate(amount, _feeBase()), 1e14);
    }

    /// @dev The increase is the burned fraction of the fee base (`_feeBase`, the paced supply), which neither
    /// new principal nor a fresh repayment moves faster than FOLLOW_BPS_PER_HOUR. `prior`
    /// is never zero on a deployed vault (the floor); the zero case is for a subclass that lowers the floor.
    function _redemptionRate(uint256 amount, uint256 prior) private view returns (uint256) {
        uint256 supply = stablecoin.totalSupply();
        if (amount > supply) revert ExcessRepayment();
        uint256 cap = (REDEMPTION_FEE_CAP_BPS - REDEMPTION_FEE_FLOOR_BPS) * 1e14;
        uint256 increase = amount == 0 ? 0 : prior == 0 ? cap : Math.mulDiv(amount, 1e18, prior) / redemptionDivisor();
        return Math.min(decayedRedemptionBaseRate() + increase, cap);
    }

    /// @dev Principal minted within the window and still outstanding; a record older than the window
    /// has aged out whole.
    function _recentlyMinted(Position storage position) private view returns (uint256) {
        return block.timestamp * WAD - position.mintedAt < FRESH_DEBT_WINDOW * WAD ? position.recentlyMinted : 0;
    }

    /// @dev A position's contribution to `securedCollateral` at `price`: its collateral, bounded by
    /// the IMD that the multiple of its principal buys at that price. Never reverts, because deposit
    /// and repayment promise not to: with no price this returns zero, which `_resecureBounded` never writes
    /// over a position that still owes (it keeps the previous term, bounded); and a bound too
    /// large to represent counts it whole.
    function _secured(Position storage position, uint256 price) private view returns (uint256) {
        uint256 collateral = position.collateral;
        uint256 principal = position.debt;
        if (principal == 0 || price == 0) return 0;
        if (principal > type(uint256).max / (SECURED_COLLATERAL_MULTIPLE * 1e18)) return collateral;
        return Math.min(collateral, principal * (SECURED_COLLATERAL_MULTIPLE * 1e18) / price);
    }

    /// @dev Called after a position's collateral or principal moved: replaces the term the position
    /// last contributed with its term at `price`. Any increase is also tallied for the transaction,
    /// so what the guard measures never includes capital that arrived in the same call.
    function _resecure(Position storage position, uint256 price) private {
        _resecureBounded(position, price, type(uint256).max);
    }

    /// @dev `_resecure` with a ceiling on the term kept while the price is unreadable (`_reduceDebt`).
    /// An unreadable price (a reverting Chainlink or share-vault leg reads zero) cannot re-price the term,
    /// and must not zero it: `lock` and `wipe` are ungated, and a zero written while the leg was down
    /// persisted past its recovery, shutting or underpaying `cash` for a day (final panel audit, oracle,
    /// low). The term is kept, never above the position's collateral nor above `unpricedCap`, and dropped
    /// only when the position owes nothing; the next priced checkpoint of the position corrects it.
    function _resecureBounded(Position storage position, uint256 price, uint256 unpricedCap) private {
        uint256 before = position.secured;
        uint256 current = price == 0
            ? (position.debt == 0 ? 0 : Math.min(Math.min(before, position.collateral), unpricedCap))
            : _secured(position, price);
        position.secured = current;
        securedCollateral = securedCollateral - before + current;
        if (current > before) _transientAdd(SECURED_THIS_TX_SLOT, current - before);
    }

    /// @dev THE FEE BASE: the supply a redemption's increase is measured against. The paced supply (`_pace`):
    /// it follows the supply by at most FOLLOW_BPS_PER_HOUR per hour of elapsed time (compounding per pacing), so principal drawn for a block before
    /// a redemption cannot dilute the fee, and a large repayment just before one cannot shrink the base and
    /// pin the fee at the cap (retry panel 2026-10-07 and retry2 panel 2026-10-08, mediums, which the per-position
    /// fee base this replaces answered with state of its own). The same figure charges the redeemer and sets the
    /// base rate everyone after pays.
    /// FLOORED at `_feeBaseFloor()`: while the supply is small, as right after launch, a small redemption would
    /// otherwise store the 4.5% cap as everyone's base rate (final vault panel and final sweep panel
    /// 2026-10-08, lows). At 100,000, storing the cap from the floor takes 4.5% of it times the divisor in burns
    /// (9,000 at 2), paying about 250 imdUSD of fee if split into small burns (450 in one). Under the floor a
    /// redemption's increase is measured as if the supply were the floor, which only lowers fees while the
    /// protocol is that small.
    function _feeBase() internal view returns (uint256) {
        uint256 base = _pacedSupplyNow();
        uint256 floor = _feeBaseFloor();
        return base > floor ? base : floor;
    }

    /// @dev 100,000 imdUSD. A subclass that models only fee arithmetic may lower it.
    function _feeBaseFloor() internal view virtual returns (uint256) {
        return 100_000e18;
    }

    /// @dev Whether `earn` may mint at all. Always for the base vault, whose work channel has no wage;
    /// ParameterizedVault opens it exactly while the wage is nonzero.
    function _earnOpen() internal view virtual returns (bool) {
        return true;
    }

    function _transientAdd(uint256 slot, uint256 amount) private {
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), amount))
        }
    }

    function _transientSub(uint256 slot, uint256 amount) private {
        assembly ("memory-safe") {
            tstore(slot, sub(tload(slot), amount))
        }
    }

    function _transient(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @notice Start an underwater position's grace window; repeated marks preserve an active snapshot.
    /// @dev A mark is actionable from markedAt + grace for one tail(), then expires and must be
    /// retaken, which restarts grace. latestValue cannot reveal a recover-then-fall sequence nobody
    /// transacted through, so bounding a mark's lifetime is what keeps an old mark from turning a later
    /// dip into a same-block liquidation with no effective grace.
    function bark(address owner) external {
        barkFor(owner, msg.sender);
    }

    /// @notice Mark a position underwater and credit the marker's bonus share to `beneficiary`.
    /// @dev The marker is paid at liquidation, so it has to be recorded now, and recording
    /// `msg.sender` is wrong as soon as the call arrives through anything. A keeper bundling the
    /// feed update with the mark calls through a relay, and the relay would be recorded as the
    /// marker: its share would then be paid to a contract with no owner and no way to move it, or
    /// handed to whichever keeper happened to bite. The reward belongs to whoever caused the
    /// mark, not to whatever contract carried the call.
    ///
    /// Naming someone else is allowed and uninteresting: a caller can only give away its own share.
    /// A zero beneficiary is refused, because the bonus is paid by transfer and burning it silently
    /// is worse than failing here.
    function barkFor(address owner, address beneficiary) public nonReentrant {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        (uint256 nhi,) = nhiFeed.latestValue();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner), price, _mat(nhi))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (mark.marked && !_expired(mark)) return;
        uint256 grace = _lull(nhi);
        liquidationMarks[owner] = LiquidationMark(block.timestamp, grace, true, beneficiary);
        emit Bark(owner, block.timestamp, grace);
    }

    /// @notice Anyone may clear a mark after observing recovery, including a recovery caused only by a feed.
    /// @dev latestValue cannot reveal an unobserved recover-then-fall sequence. Keepers should clear marks
    /// when recovery is observed; deposit, repayment and successful borrowing/withdrawal also clear them.
    /// Borrowers should call this while healthy: an unobserved recovery does not restart grace within
    /// the bounded mark lifetime, even if a subsequent dip happens before that lifetime ends.
    function heel(address owner) external nonReentrant {
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (!_healthy(position.collateral, debtOf(owner), price, mat())) revert UnderwaterPosition();
        _clearMark(owner);
    }

    /// @notice Burn caller imdUSD against a marked, still-underwater position after its snapshotted grace.
    /// @dev Payout is floor(debtToRepay * (100 + CHOP_PERCENT) * 1e16 / price) raw collateral, i.e. collateral
    /// worth 120% of the imdUSD burned at the same accepted price the health check reads. Collateral must
    /// cover the full payout, except dust below the seizure for one wei of debt, which is taken whole.
    /// A borrower may mark its own position and so recover the marker's share (CHIP_BPS) of the bonus:
    /// its effective penalty is then 18% of the debt repaid, not 20%. Accepted (launch audit, info).
    /// The mark must still be within its liquidation window (see bark).
    /// A HELD-DOWN POOL IS PAID HERE IN FULL, ACCEPTED (final sweep panel 3 2026-10-09, high). Health and the
    /// seizure both read the attested price, and both feeds read one IMD pool, so that pool pushed down and held
    /// through the feed window and the grace (about seven hours at NHI >= 0.85) makes every position under
    /// mat / (1 - push) of real CR liquidatable and pays the liquidator, per imdUSD repaid, 1.2 / (1 - push) of
    /// collateral at the real price: 1.5x for one 20% step (positions under 212%), 1.875x for two (36%, under
    /// 266%), against 1.2x at an honest price. The loss is the borrower's; the burn retires the debt it repays,
    /// so backing per imdUSD is untouched, and the protocol's cut adds to the reserve. The one exception: a
    /// position under 1.2x of its debt at the held price is liquidated to nothing and leaves the rest as bad
    /// debt (about 9% of a 170% position's debt after two steps), which `cover` charges to the Treasury. Not
    /// paced, unlike `cash`: pacing the seizure underpays liquidators after a real fall faster than the pace, and
    /// a liquidation that does not pay is not made, which leaves real crashes to bad debt that every holder
    /// bears. The defences are the grace (a marked borrower who tops up or repays above mat clears the mark; the
    /// site warns a connected borrower whose position is marked), the cost of the hold (IMD also trades in other
    /// pools and on other chains, so for seven hours every arbitrageur who buys the held pool cheap and sells
    /// elsewhere must be absorbed), and the debt ceiling, which bounds the book at stake.
    function bite(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        uint256 price = _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        {
            uint256 m = mat(); // scoped: bite's stack is full
            _paceAt(price, m);
            if (_healthy(position.collateral, debtOf(owner), price, m)) revert HealthyPosition();
        }
        // Every position is marked and given grace, a drained one too. A drained borrower's re-lock no longer
        // needs a bite to clear: `cover` takes one worth less than the recorded bad debt at its value. The
        // shortcut that bit such a re-lock at once also caught a borrower rebuilding in tranches, or after a
        // price dip, at the 20% penalty with no grace (retry panel audit 2026-10-07 and retry2 2026-10-08,
        // vault, low).
        LiquidationMark storage mark = liquidationMarks[owner];
        if (!mark.marked) revert PositionNotMarked();
        if (block.timestamp - mark.markedAt < mark.grace) revert GracePeriodNotElapsed();
        if (_expired(mark)) revert MarkExpired();
        _accrue(owner);
        if (debtToRepay > position.debt + _stabilityFees[owner]) revert ExcessRepayment();
        uint256 collateralSeized = Math.mulDiv(debtToRepay, (100 + CHOP_PERCENT) * 1e16, price);
        if (collateralSeized > position.collateral) {
            // DUST BELOW ONE WEI OF DEBT IS TAKEN WHOLE (launch audit, vault panel, medium). Without
            // this, collateral smaller than the seizure for a single wei of debt could never be bitten:
            // left after a further price fall, or re-locked by a drained borrower (`lock(1)`) to stop
            // the position draining, it froze the bad debt — unliquidatable, and `cover` refused it.
            // Any larger shortfall is still refused: a bite never seizes more than the formula.
            if (position.collateral == 0 || position.collateral >= _oneWeiSeizure(price)) {
                revert InsufficientCollateral();
            }
            collateralSeized = position.collateral;
        }
        // Both shares come out of the same bonus, never principal or extra borrower collateral.
        uint256 protocolShare = cut();
        if (protocolShare > 10_000 - chip()) revert InvalidBonusShares();
        uint256 principalPart = Math.mulDiv(debtToRepay, 1e18, price);
        uint256 bonus = collateralSeized > principalPart ? collateralSeized - principalPart : 0;
        uint256 protocolCut = Math.mulDiv(bonus, protocolShare, 10_000);
        uint256 markerCut = Math.mulDiv(bonus, chip(), 10_000);
        address marker = mark.marker;
        // Sweep a remainder nobody could ever claim. Taking the largest coverable debt leaves dust,
        // and once that dust is smaller than the seizure for a single wei of debt every later
        // bite reverts InsufficientCollateral: the position freezes with debt outstanding and
        // collateral no one can reach, so it never drains and its loss is never realized. Observed
        // on Sepolia at 887 wei against 157364181818182858 of debt.
        // It is folded in AFTER the split, so it enlarges neither the bonus nor the marker's and
        // protocol's shares of it — the dust is extra incentive for whoever closes the position, and
        // the borrower's loss with both shares at zero is unchanged. Only when debt survives the
        // liquidation: a borrower whose debt is cleared is solvent and the remainder is theirs.
        uint256 remainder = position.collateral - collateralSeized;
        if (remainder != 0 && debtToRepay < position.debt + _stabilityFees[owner] && remainder < _oneWeiSeizure(price))
        {
            collateralSeized += remainder;
        }
        uint256 feePaid = _reduceDebt(owner, debtToRepay, price, true);
        _clampPacedDebt();
        position.collateral -= collateralSeized;
        _resecure(position, price);
        _recordBadDebt(owner);
        _clearIfRecoveredAt(owner, price, mat());
        _payDebt(debtToRepay, feePaid);
        if (marker == msg.sender) {
            gem.safeTransfer(msg.sender, collateralSeized - protocolCut);
        } else {
            gem.safeTransfer(msg.sender, collateralSeized - protocolCut - markerCut);
            if (markerCut != 0) gem.safeTransfer(marker, markerCut);
        }
        if (protocolCut != 0) gem.safeTransfer(feeRecipient(), protocolCut);
        emit Bite(owner, msg.sender, debtToRepay, collateralSeized);
    }

    /// @notice floor(collateral * price * 100 / (debt * 1e18)), using the latest accepted price.
    /// @dev Returns uint256.max for debt-free positions; unrepresentably large ratios also saturate at that value.
    function collateralRatio(address owner) external view returns (uint256) {
        Position storage position = _positions[owner];
        uint256 debt = debtOf(owner);
        if (debt == 0) return type(uint256).max;
        return _collateralRatio(position.collateral, debt, _price());
    }

    /// @notice Collateral and full accrued debt, preserving the original two-word position view.
    function positions(address owner) external view returns (uint256 collateral, uint256 debt) {
        return (_positions[owner].collateral, debtOf(owner));
    }

    /// @notice Linear index accumulated from the last checkpoint; no per-second compounding.
    /// @dev Accrual is measured from `indexCheckpointAt`, not from deployment, so a change to
    /// `duty()` applies only to the time after it. Computing from deployment at the
    /// current rate would reprice every elapsed second, and a rate cut would make the subtraction
    /// in `stabilityFeeOf` underflow, reverting `_accrue` and freezing every position.
    function chi() public view returns (uint256) {
        return
            indexCheckpoint + Math.mulDiv(block.timestamp - indexCheckpointAt, duty() * INDEX_SCALE, 365 days * 10_000);
    }

    /// @notice Freezes accrual to date at the rate in force, so a later rate change is forward-only.
    /// @dev Permissionless by design: it can only move the index forward by time already elapsed,
    /// and it MUST be called in the same transaction that changes the rate, before the change.
    function drip() public {
        uint256 index = chi();
        indexCheckpoint = index;
        indexCheckpointAt = block.timestamp;
        emit IndexCheckpointed(index, block.timestamp);
    }

    /// @notice Unpaid fees on principal since its last debt change, plus previously accrued unpaid fees.
    /// @dev Fees never themselves earn interest. Reads and collateral/mark changes cannot capitalize fees.
    function stabilityFeeOf(address owner) public view returns (uint256) {
        uint256 principal = _positions[owner].debt;
        if (principal == 0) return _stabilityFees[owner];
        return _stabilityFees[owner] + Math.mulDiv(principal, chi() - chiOf[owner], INDEX_SCALE);
    }

    function debtOf(address owner) public view returns (uint256) {
        return _positions[owner].debt + stabilityFeeOf(owner);
    }

    /// @notice Debt not covered by collateral at the current price, including the liquidation bonus.
    /// @dev Measurement only, not insurance or forgiveness. This view does not assert feed freshness.
    /// The existing full-payout liquidation guard is unchanged; all uncovered debt remains repayable.
    function badDebtOf(address owner) external view returns (uint256) {
        return _badDebtOf(owner);
    }

    /// @dev The shortfall at the current price: debt that the position's collateral cannot cover at
    /// the full liquidation payout. A current-price estimate; totalBadDebt records only REALIZED loss
    /// (a drained position), so the two differ by design.
    function _badDebtOf(address owner) private view returns (uint256) {
        uint256 debt = debtOf(owner);
        if (debt == 0) return 0;
        uint256 collateral = _positions[owner].collateral;
        if (collateral == 0) return debt;
        uint256 price = _price();
        // A ratio of at least 100 + CHOP_PERCENT guarantees full coverage and avoids overflow on very large collateral.
        if (_collateralRatio(collateral, debt, price) >= 100 + CHOP_PERCENT) return 0;
        uint256 payoutScale = (100 + CHOP_PERCENT) * 1e16;
        uint256 covered = Math.mulDiv(collateral, price, payoutScale);
        // Match the existing floor-rounded payout exactly: capacity = ceil((collateral + 1)
        // * price / payoutScale) - 1, split into quotients/remainders to avoid overflowing either product.
        uint256 extra = (price - 1) / payoutScale;
        extra += (mulmod(collateral, price, payoutScale) + (price - 1) % payoutScale) / payoutScale;
        return extra >= debt - covered ? 0 : debt - covered - extra;
    }

    /// @notice Minimum CR, derived only from NHI: 200 at/below .60; 170 at/above .85.
    /// @dev The floor is 170 because grace is LONGEST (six hours) when the network is healthy, which is
    /// where the floor applies: 170 covers a 20% bonus after a stressed six-hour-plus fall and the sale
    /// of the largest liquidation that is still profitable in one trade (docs/PARAMETERS-2026-10-05.md).
    /// @dev Linear interpolation rounds up to a whole percent, so rounding cannot weaken the threshold.
    function mat() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _mat(nhi);
    }

    /// @notice Grace derived only from NHI: zero at/below .60; six hours at/above .85.
    function lull() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _lull(nhi);
    }

    /// @notice How long after its grace ends a mark stays actionable: the shorter of the price and NHI
    /// feeds' lifetimes. The spot feed and Chainlink are not read: at the shipped constants the spot feed's
    /// lifetime equals the price feed's (an hour) and Chainlink's (two hours) is longer.
    /// @dev Past that, at least one full feed cycle has elapsed in which nobody liquidated, and either
    /// feed may have moved the position through recovery unobserved; the mark is void and must be retaken.
    function tail() public view returns (uint256) {
        return Math.min(priceFeed.maxAge(), nhiFeed.maxAge());
    }

    /// @dev Accepts only a deployed contract that answers `mintingRights(address)` as IWorkOracle requires.
    /// If the target additionally exposes `vault()` (as MockWorkOracle does), that consumer must be this vault;
    /// an oracle without that view is accepted so a drop-in IWorkOracle implementation remains compatible.
    /// @notice The work oracle `earn` reads: the one this vault created, unless governance replaced it
    /// (ParameterizedVault, `Parameters.workOracle`, only while minting from work is off).
    function oracle() public view virtual returns (IWorkOracle) {
        return _createdOracle;
    }

    function _validateOracle(address oracle_) private view {
        if (oracle_.code.length == 0) revert InvalidOracle();
        (bool ok, bytes memory data) = oracle_.staticcall(abi.encodeCall(IWorkOracle.mintingRights, (address(this))));
        if (!ok || data.length != 32) revert InvalidOracle();
        (ok, data) = oracle_.staticcall(abi.encodeWithSignature("vault()"));
        if (ok && data.length == 32 && abi.decode(data, (uint256)) != uint256(uint160(address(this)))) {
            revert InvalidOracle();
        }
    }

    /// @dev Reverts on a stale feed or an unreadable price; returns the price so the caller reads it once.
    function _requireFreshFeeds() private view returns (uint256 price) {
        if (_pricingStale()) revert StaleFeed();
        price = _price();
    }

    /// @dev A pinned closing block and an attestation valid for its TTL let an attacker know which
    /// block to push and act on the signature afterwards. Price from an average; use spot only to
    /// detect disagreement. Compare against the primary's share without a rounded-down BPS ratio.
    function _requirePriceAgreement() private view {
        if (spotFeed.isStale()) revert StaleFeed();
        (uint256 spot,) = spotFeed.latestValue();
        if (spot == 0) revert InvalidPrice();
        // The RAW primary feed, deliberately, not `_price()`. Both legs quote IMD in the same unit the
        // swarm asks for, so the comparison is a ratio and holds whatever debt is denominated in. A
        // subclass that denominates `_price()` differently — ParameterizedVault prices in USD — would
        // otherwise be comparing a USD figure against an ETH one and diverge by the ETH price itself.
        (uint256 primary,) = priceFeed.latestValue();
        if (primary == 0) revert InvalidPrice();
        if (!_withinSkew(primary, spot)) revert PriceDivergence();
    }

    function _withinSkew(uint256 primary, uint256 spot) private view returns (bool) {
        uint256 difference = primary > spot ? primary - spot : spot - primary;
        return difference <= Math.mulDiv(primary, skew(), 10_000);
    }

    function _accrue(address owner) private {
        _stabilityFees[owner] = stabilityFeeOf(owner);
        chiOf[owner] = chi();
    }

    /// @dev Pay fees first, then principal. Only burning imdUSD can reduce either obligation.
    /// @param cancellation A redemption, a liquidation or cover, as opposed to the owner's own `wipe`.
    function _reduceDebt(address owner, uint256 amount, uint256 priceOrZero, bool cancellation)
        private
        returns (uint256 feePaid)
    {
        Position storage position = _positions[owner];
        {
            uint256 fees = _stabilityFees[owner];
            if (amount > position.debt + fees) revert ExcessRepayment();
            feePaid = Math.min(amount, fees);
            _stabilityFees[owner] = fees - feePaid;
        }
        uint256 principalPaid = amount - feePaid;
        _tallyPrincipalRetired(owner, principalPaid, cancellation);
        {
            uint256 principalBefore = position.debt;
            position.debt -= principalPaid;
            // With no readable price the term cannot be re-priced, but the principal it is bounded by has
            // fallen: scale it down in proportion, as a priced checkpoint would (sweep panel audits, vault and
            // oracle, low: kept whole, a repayment during an outage left a term sized for debt that no longer
            // existed, and the reserve-funded part of cash paid at par over honest backing).
            uint256 unpricedCap =
                principalBefore == 0 ? 0 : Math.mulDiv(position.secured, position.debt, principalBefore);
            _resecureBounded(position, priceOrZero, unpricedCap);
        }
        // Retired debt is no longer fresh, whichever path retired it.
        // REVISION (finding 5ee3f2bc): the record's amount-weighted date did not move when principal
        // was retired, so a mint-then-repay pair retired the new tranche at the record's MEAN age and
        // left the old principal younger each time: twenty pairs kept any amount fresh for gas. The
        // youngest debt is retired first, which with one date per record means what remains keeps the
        // whole record's principal-time: (now - mintedAt') x remaining equals (now - mintedAt) x fresh.
        // Two details make a round trip return the record to where it was. The whole burn retires
        // fresh debt, fees included: fees are paid first, so retiring only the principal part left a
        // fee-sized remainder of the new tranche in the record every time, and once a tranche dwarfs
        // the record the integer-second mean age of the merged record rounds to zero, so that
        // remainder stayed fresh forever. Converting a fee obligation into principal adds no exposure
        // and no new borrowing, which is what the record measures, so it is not fresh either. And the
        // conserved age rounds up (older), undoing the second `draw` rounds toward the present.
        // A record whose remaining debt would be dated outside the window simply ages out.
        uint256 fresh = _recentlyMinted(position);
        uint256 remaining = fresh > amount ? fresh - amount : 0;
        if (fresh == 0 || remaining == 0) {
            position.recentlyMinted = remaining;
        } else {
            uint256 nowWad = block.timestamp * WAD;
            uint256 age = Math.mulDiv(nowWad - position.mintedAt, fresh, remaining, Math.Rounding.Ceil);
            // A chain younger than the age is a test fixture, not a possibility; treated as aged out.
            bool stillFresh = age < FRESH_DEBT_WINDOW * WAD && age <= nowWad;
            position.recentlyMinted = stillFresh ? remaining : 0;
            position.mintedAt = stillFresh ? nowWad - age : position.mintedAt;
        }
        totalDebt -= principalPaid;
        _debtChanged(totalDebt + principalPaid);
        uint256 previous = _recordedBadDebt[owner];
        if (previous != 0) {
            // Include new fees while collateral is exhausted. After recapitalization, only reduce
            // the historical residual once remaining debt is actually below it (fees are paid first).
            uint256 current = debtOf(owner);
            if (position.collateral != 0) current = Math.min(previous, current);
            totalBadDebt = totalBadDebt - previous + current;
            _recordedBadDebt[owner] = current;
        }
    }

    /// @dev Called with the previous total every time `totalDebt` moves. Nothing here: this vault's
    /// ceiling is unlimited and reads no debt. ParameterizedVault overrides it to remember the debt
    /// level a transaction began at, so debt created and repaid inside one transaction never counts
    /// toward the work ceiling's ratio term.
    function _debtChanged(uint256 previousTotal) internal virtual {}

    function _payDebt(uint256 amount, uint256 feePaid) private {
        stablecoin.burn(msg.sender, amount);
        _transientAdd(REPAID_THIS_TX_SLOT, amount);
        if (feePaid != 0) {
            totalFeesMinted += feePaid;
            stablecoin.mint(feeRecipient(), feePaid);
        }
    }

    /// @dev Counts a shortfall only once it is REALIZED, meaning the position has been drained and
    /// the loss is no longer a mark-to-market estimate that a price recovery could erase. The sweep
    /// in bite() is what makes this reachable: before it, a liquidation of the largest coverable
    /// debt left a remainder too small to ever seize, so the position never drained and this never
    /// fired. Recording the live shortfall instead was tried and rejected — it makes totalBadDebt a
    /// moving estimate rather than realized losses, which is a different number than the one the
    /// invariant suite checks.
    function _recordBadDebt(address owner) private {
        // Reachable because bite() sweeps an unreachable remainder: without that, a position
        // drained to dust never hit zero and this never fired, leaving totalBadDebt at zero while
        // badDebtOf reported the shortfall. Still "realized" only — a loss is counted once the
        // position is actually drained, not while it is a mark-to-market estimate a price recovery
        // could erase.
        if (_positions[owner].collateral != 0) return;
        uint256 current = debtOf(owner);
        totalBadDebt = totalBadDebt - _recordedBadDebt[owner] + current;
        _recordedBadDebt[owner] = current;
    }

    /// @notice What one 1e18 of collateral is worth, in the unit debt is denominated in.
    /// @dev Virtual because the denomination is the subclass's choice, and every formula that reads it
    /// is a ratio: `collateralRatio` is collateral x price / debt and `bite` seizes debt / price,
    /// so neither cares what the unit is as long as it is the one debt is in. Here it is the unit the
    /// primary feed quotes — wei of ETH per IMD — so one imdUSD of debt is one ETH-worth of collateral.
    /// ParameterizedVault overrides it to price in USD, which is what makes a imdUSD a dollar.
    /// Not governable, and deliberately: `priceFeed` is immutable and this is chosen at compile time,
    /// so no key can change what a position is measured against.
    /// @dev AUDIT FIX (job da7d5b1c, medium): the VIRTUAL is now the non-reverting read, and `_price`
    /// is the reverting wrapper built on it. Every acting path wants the revert; `_clearIfRecovered`
    /// must not have it, because it runs inside deposit and repay and promises not to block them. One
    /// seam serves both, so a subclass still denominates in exactly one place.
    function _priceOrZero() internal view virtual returns (uint256 price) {
        (price,) = priceFeed.latestValue();
    }

    function _price() internal view returns (uint256 price) {
        price = _priceOrZero();
        if (price == 0) revert InvalidPrice();
    }

    /// @notice True when the inputs a position is measured against cannot be trusted.
    /// @dev Virtual alongside `_price()`: a subclass that prices through another feed has another way
    /// to go stale, and refusing to act is the only safe answer to not knowing a price.
    function _pricingStale() internal view virtual returns (bool) {
        return priceFeed.isStale() || nhiFeed.isStale();
    }

    function _mat(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 170;
        if (nhi <= 0.6e18) return 200;
        return 170 + Math.mulDiv(0.85e18 - nhi, 30, 0.25e18, Math.Rounding.Ceil);
    }

    function _lull(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 6 hours;
        if (nhi <= 0.6e18) return 0;
        return (nhi - 0.6e18) * 6 hours / 0.25e18;
    }

    /// @dev At `price` and a minimum ratio `m` (`mat()`), both read once by the caller.
    function _healthy(uint256 collateral, uint256 debt, uint256 price, uint256 m) private pure returns (bool) {
        return debt == 0 || _collateralRatio(collateral, debt, price) >= m;
    }

    /// @dev For a gated caller, at a price and minimum ratio it has already checked and read once.
    function _clearIfRecoveredAt(address owner, uint256 price, uint256 m) private {
        if (!liquidationMarks[owner].marked) return;
        uint256 debt = debtOf(owner);
        if (debt == 0 || _collateralRatio(_positions[owner].collateral, debt, price) >= m) _clearMark(owner);
    }

    /// @param priced The collateral price the caller already read (`_pace`), zero if unreadable.
    /// @dev Clears a mark only on a recovery observed at a fresh, agreed price: the DENOMINATED price for the
    /// health check (compared against mat like every health check), the raw primary against the spot for the
    /// agreement (`_priceAgrees`). Invalid observations preserve the mark without blocking the ungated calls.
    function _clearIfRecovered(address owner, uint256 priced) private {
        if (!liquidationMarks[owner].marked) return;
        uint256 debt = debtOf(owner);
        if (
            debt == 0
                || (priced != 0
                    && _priceAgrees()
                    && _collateralRatio(_positions[owner].collateral, debt, priced) >= mat())
        ) {
            _clearMark(owner);
        }
    }

    function _expired(LiquidationMark storage mark) private view returns (bool) {
        return block.timestamp > mark.markedAt + mark.grace + tail();
    }

    function _clearMark(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        delete liquidationMarks[owner];
        emit Heel(owner);
    }

    /// @dev Divide collateral into whole/remainder debt units before pricing. This preserves fractions
    /// even for one-wei debt, avoids overflowing debt * 1e16, and saturates only an unrepresentable ratio.
    function _collateralRatio(uint256 collateral, uint256 debt, uint256 price) private pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 scale = 1e16;
        uint256 whole = collateral / debt;
        uint256 priceWhole = price / scale;
        if (priceWhole != 0 && whole > type(uint256).max / priceWhole) return type(uint256).max;
        uint256 ratio = whole * priceWhole;
        uint256 fraction = Math.mulDiv(collateral % debt, price, debt);
        ratio = _saturatingAdd(ratio, Math.mulDiv(whole, price % scale, scale));
        ratio = _saturatingAdd(ratio, fraction / scale);
        return _saturatingAdd(ratio, (mulmod(whole, price, scale) + fraction % scale) / scale);
    }

    /// @dev Unchecked, because both operations are proven in range (gas review 2026-10-05, ~411 gas per
    /// health check): max - a never underflows for any uint256 a, and a + b is reached only when
    /// b <= max - a, so it cannot overflow.
    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return b > type(uint256).max - a ? type(uint256).max : a + b;
        }
    }
}
