// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IShareVault} from "./interfaces/IShareVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
contract CDPVault is ReentrancyGuard {
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
        /// @dev This position's capital that is not warm yet, principal and secured term, as of `coldAt`;
        /// it cools by half every BACKING_HALF_LIFE. See `_lag`.
        uint128 coldDebt;
        uint128 coldSecured;
        /// @dev Warmth this position has BANKED: warm principal and secured collateral that left it (a
        /// repayment, a withdrawal, a redemption or liquidation against it) and may come back warm, less what
        /// it cooled while away at the lag's own rate since the bank's date, and nothing after a day. See `_lag`.
        uint128 bankDebt;
        uint128 bankSecured;
        uint64 coldAt;
        uint64 bankDebtAt;
        uint64 bankSecuredAt;
        /// @dev WARM principal this position repaid (`wipe`, or a liquidation or `cover` of it), as of `coldAt`:
        /// still counted in the fee base while it ages, and released as this position borrows back from its
        /// bank. See `_reduceDebt` and `_feeBase`.
        uint128 feeExcess;
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

    /// @notice Each redemption raises the fee base by redeemed / supply / this. The base vault reads
    /// the source constant; ParameterizedVault reads its governed Parameters.
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
    /// it with reserveValueUsd + totalDebt * earnMat / 10000, the bound docs/COMPUTE-BACKING-
    /// DESIGN.md section 3 derives, and `earn` enforces whatever this returns.
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
    /// is the lag's to discount (`laggedNow`, `_feeBase`).
    /// keccak256("comp.CDPVault.securedCollateralAddedThisTransaction"),
    /// keccak256("comp.CDPVault.principalMintedThisTransaction") and
    /// keccak256("comp.CDPVault.workMintedThisTransaction").
    uint256 private constant SECURED_THIS_TX_SLOT = 0xf45fbc7390d8fe64766790eac1c1a0c998865663167e91e17d360ad63faf32cb;
    uint256 private constant MINTED_THIS_TX_SLOT = 0x7863d18732bd3fc443c44a39552cffecac393d3fbf3094322f7f794631746012;
    uint256 private constant WORK_MINTED_THIS_TX_SLOT = 0xf427427e9c6fc4311907632705fbeaa6595527cec8a17ee1a7090d960da2ff6d;
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
    /// inside their bound (at most 200% at that price, which includes every redeemable one) are
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

    /// @notice LAGGED CAPITAL — the fix for finding D1 (launch audit 2026-10-05, vault panel, medium).
    /// The redemption cap reads it at every wage (`_backingPerUnit`); the work ceiling only once minting
    /// from work is switched on (`_lagApplies`).
    /// @dev Backing reads min(live, lagged), and the lagged figures are the live ones less the capital that
    /// is still COLD. Cold is kept PER POSITION (`_lag`): what a position adds is cold, and its cold
    /// halves every BACKING_HALF_LIFE (capital one block old counts about 0.04%, an hour 11%, six hours
    /// half). Every position cools at the same rate, so the vault's total cold cools at that rate too and
    /// is kept as one figure, read in constant time. A day in which nothing is touched credits it in full;
    /// under activity a day credits about 94%, two days 99.6% (see `_cool`). A decrease takes the
    /// position's own cold first and counts at once. So capital brought in one transaction and withdrawn a
    /// few later cannot authorise work minting or a redemption at par, and what one position removes can
    /// never warm what another adds, in either order (retry panel audit 2026-10-07, vault, high: with ONE
    /// aggregate lag, a draw followed by the cancellation of another borrower's warm debt left the lag
    /// warm for the new debt). A position's own warm capital that leaves and returns is credited again from
    /// its bank, which cools at the same rate while it waits. A price fall that re-prices a debt-bound term
    /// upward is new to the lag too, so collateral long held counts as cold for a few hours: accepted, the
    /// lag's safe direction (retry2 panel audit 2026-10-08, vault, low). Tracked from deployment, so it is
    /// warm whenever it is read.
    uint256 internal constant BACKING_HALF_LIFE = 6 hours;
    /// @dev A day: cold capital, and a bank, left untouched this long count in full (`_cool`).
    uint256 public constant BACKING_WARMUP = 1 days;
    /// @dev 2^(-1 / BACKING_HALF_LIFE), the per-second factor cold capital keeps, 1e27-scaled.
    uint256 private constant COLD_SECOND_DECAY = 999967910367635122012970996;
    uint256 private constant RAY = 1e27;
    uint256 private _coldDebt;
    uint256 private _coldSecured;
    uint256 private _coldAt = block.timestamp;
    /// @dev The positions' `feeExcess`, summed, as of `_coldAt`: warm principal repaid in the last hours,
    /// still counted in the supply the redemption fee is measured against (`_feeBase`).
    uint256 private _feeExcess;
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
        if (
            gem_.code.length == 0 || (stablecoin_ != address(0) && stablecoin_.code.length == 0)
                || gem_ == stablecoin_
        ) {
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
            // bytes and this vault's subclass is already at 36,416 of the 49,152 EIP-3860 permits.
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
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = gem.balanceOf(address(this));
        Position storage position = _positions[msg.sender];
        position.collateral += amount;
        _resecure(position, _priceOrZero());
        gem.safeTransferFrom(msg.sender, address(this), amount);
        if (gem.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        _clearIfRecovered(msg.sender);
        emit Lock(msg.sender, amount);
    }

    /// @notice Lock collateral by handing over the share vault's UNDERLYING: the vault deposits it into
    /// the share vault on the caller's behalf and credits the shares it receives.
    /// @dev For a collateral token that is an ERC-4626 share (sIMD over IMD), so a borrower holding the
    /// plain token does not need a separate wrapping transaction. The credit is the shares actually
    /// received, measured by balance, not the amount `deposit` reports. Reverts `CollateralNotWrappable`
    /// when the collateral is not a share vault. The vault never redeems shares; see IShareVault.
    function lockIMD(uint256 assets) external nonReentrant {
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
        _resecure(position, _priceOrZero());
        _clearIfRecovered(msg.sender);
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
        if (debt != 0) {
            _requireFreshFeeds();
            _requirePriceAgreement();
            if (!_healthy(remaining, debt)) revert UnsafeCollateralRatio();
        }
        position.collateral = remaining;
        _resecure(position, _priceOrZero());
        _clearMark(msg.sender);
        gem.safeTransfer(msg.sender, amount);
        emit Free(msg.sender, amount);
    }

    function draw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        if (stablecoin.vault() != address(this)) revert NotInitialized();
        _accrue(msg.sender);
        Position storage position = _positions[msg.sender];
        uint256 resultingDebt = position.debt + _stabilityFees[msg.sender] + amount;
        if (!_healthy(position.collateral, resultingDebt)) revert UnsafeCollateralRatio();
        uint256 resultingTotal = totalDebt + amount;
        if (resultingTotal > line()) revert DebtCeilingReached();
        totalDebt = resultingTotal;
        _debtChanged(resultingTotal - amount);
        _lag(position, false, position.debt, position.debt + amount);
        position.debt += amount;
        _resecure(position, _priceOrZero());
        _transientAdd(MINTED_THIS_TX_SLOT, amount);
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
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        uint256 feePaid = _reduceDebt(msg.sender, amount, true);
        _payDebt(amount, feePaid);
        _clearIfRecovered(msg.sender);
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
            uint256 last = _priceOrZero();
            if (last == 0 || position.collateral >= _oneWeiSeizure(last)) {
                _requireFreshFeeds();
                _requirePriceAgreement();
                uint256 price = _price();
                if (position.collateral >= _coverDust(owner, price)) {
                    // A re-lock worth less than the bad debt the position already realized is taken AT ITS
                    // VALUE: the surplus burns at least that much of the position's debt for it. So holding
                    // cover off costs the griefer the whole re-lock, with no liquidator needed (retry panel
                    // audit 2026-10-07, vault, low: the bite that cleared a $1.20 re-lock paid $0.18), and
                    // a borrower rebuilding is paid par for it, not bitten at a 20% penalty.
                    if (!_relockBelowBadDebt(owner, price)) revert NoRealizedBadDebt();
                    if (amount < Math.mulDiv(position.collateral, price, 1e18, Math.Rounding.Ceil)) {
                        revert CoverBelowCollateralValue();
                    }
                }
                last = price;
            }
            uint256 price_ = last;
            uint256 dust = position.collateral;
            position.collateral = 0;
            _resecure(position, price_);
            _recordBadDebt(owner);
            gem.safeTransfer(payer, dust);
        }
        if (_recordedBadDebt[owner] == 0) revert NoRealizedBadDebt();
        // The surplus account records what arrived before any of it is burned, so revenue landing
        // since its last sync is not lost from its books (launch audit, governance panel, low).
        _syncSurplus(payer);
        uint256 feePaid = _reduceDebt(owner, amount, true);
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
        _clearIfRecovered(owner);
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

    /// @notice Burn exactly `amount` caller imdUSD for feed-priced IMD, less the capped fee.
    /// @dev Treasury IMD is spent first; only the shortfall cancels the named candidate's debt.
    /// No approval, partial fill or fee transfer. All checks and both payouts are atomic.
    function cash(uint256 amount, uint256 minGemOut, address candidate)
        external
        nonReentrant
        returns (uint256 gemOut)
    {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        // The fee base is read once, before the candidate is touched: retiring its cold principal first made
        // the stored rate's base count the imdUSD about to be burned as warm (final vault panel, info).
        uint256 prior = _feeBase();
        uint256 base = _redemptionRate(amount, prior);
        // REVISION (finding b8aa4a98): whole basis points, rounded against the party paying them.
        uint256 feeBps = REDEMPTION_FEE_FLOOR_BPS + Math.ceilDiv(base, 1e14);
        uint256 price = _price();
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
        uint256 payoutScale = Math.mulDiv(_backingPerUnit(price), 10_000 - feeBps, 10_000);
        gemOut = Math.mulDiv(amount, payoutScale, price);
        if (gemOut == 0) revert ZeroAmount();
        if (gemOut < minGemOut) revert MinimumOutNotMet();
        uint256 reserveOut = Math.min(gemOut, redemptionReserve());
        uint256 debtCancelled;
        uint256 principalCancelled;
        uint256 freshCancelled;
        if (reserveOut < gemOut) {
            // Round reserve-funded debt down, so every wei released by a borrower is covered by
            // cancelled debt. Compute the payout ONCE: its price never depends on the candidate.
            debtCancelled = amount - Math.mulDiv(reserveOut, price, payoutScale);
            (principalCancelled, freshCancelled) = _redeemPosition(candidate, debtCancelled, gemOut - reserveOut, price);
        }
        totalNonPrincipalRedeemed += amount - principalCancelled;
        // The fresh part of the burn is charged in full but does not move the rate everyone else pays.
        redemptionBaseRate = freshCancelled == 0 ? base : _redemptionRate(amount - freshCancelled, prior);
        lastRedemptionAt = block.timestamp;
        stablecoin.burn(msg.sender, amount);
        if (reserveOut != 0) _payRedemptionReserve(reserveOut);
        if (reserveOut < gemOut) gem.safeTransfer(msg.sender, gemOut - reserveOut);
        emit Cash(msg.sender, candidate, amount, gemOut, reserveOut, debtCancelled, feeBps);
    }

    /// @notice Value backing one imdUSD, 1e18-scaled, never above par, at the latest accepted price.
    /// @dev Public because it is the figure a redeemer is actually paid against and the one a reader
    /// needs to judge the protocol: below 1e18 it says plainly that a imdUSD is not fully backed, and
    /// the redemption payout falls with it instead of the channel closing.
    function backingPerUnit() external view returns (uint256) {
        return _backingPerUnit(_price());
    }

    /// @notice Value backing one imdUSD, 1e18-scaled, never above par.
    /// @dev Reserve plus secured collateral over supply. Capped at 1e18 because a protocol backed
    /// above par does not pay a premium: the surplus is the borrowers' and the work ceiling's
    /// headroom, not a redeemer's windfall. Read pre-payout, so it is the state the burn found.
    ///
    /// ALWAYS LAGGED, NOT ONLY WITH WORK MINTING ON (adversarial review 2026-10-05, medium; the D1
    /// redemption half). A price fall alone puts backing below par, and then capital brought in one
    /// transaction lifted it toward par for a redemption in the next. So this is the LOWER of the live
    /// figure and a lagged one in which fresh capital leaves BOTH sides: warmed-up secured collateral
    /// over supply less the principal that is still warming up. An attacker's capital can raise the live
    /// figure but not the lagged one, whichever position it sits in (`_lag`); honest redemptions are not
    /// underpaid, because new debt and the imdUSD minted against it are excluded together. When every unit
    /// of supply is fresh there is no lagged figure and the live one stands. The supply is the live one plus
    /// what repayments earlier in this transaction burned (REPAID_THIS_TX_SLOT), so a same-call wipe, cash and
    /// draw is paid no premium (sweep panel audit, vault, medium).
    /// ACCEPTED, one transaction apart: a borrower in the 170-200% band whose term is its whole collateral can
    /// repay without moving it, and a redemption in the next transaction is paid that briefly higher backing,
    /// diluted again by a redraw in the one after (retry panel audit 2026-10-07, vault, medium). It exists only
    /// below par, costs gas, and the premium is at most (supply - fresh) / (supply - fresh - repaid), the
    /// repayment bounded by the churner's principal above half its collateral's value (15% of it at a 170%
    /// minimum ratio). Both ways of closing it were worse: lagging the whole supply underpaid every redeemer
    /// after an honest unwind (0.4 to 0.08 in test/Redemption.t.sol), and keeping the left-behind part per
    /// position (58f73de) could be stranded and pumped, for gas, to underpay redeemers without bound (final
    /// vault panel 2026-10-08, high, and five further findings). It was removed.
    function _backingPerUnit(uint256 price) private view returns (uint256) {
        uint256 supply = stablecoin.totalSupply() + _transient(REPAID_THIS_TX_SLOT);
        if (supply == 0) return 1e18;
        uint256 reserve = _redemptionReserveBacking(price);
        uint256 perUnit = Math.mulDiv(reserve + _securedCollateralValue(price, false), 1e18, supply);
        (uint256 lagDebt,) = laggedNow();
        uint256 fresh = totalDebt - lagDebt;
        if (supply > fresh) {
            uint256 lagged = Math.mulDiv(reserve + _securedCollateralValue(price, true), 1e18, supply - fresh);
            if (lagged < perUnit) perUnit = lagged;
        }
        return perUnit < 1e18 ? perUnit : 1e18;
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
    /// redemption took the reserve at par while backing was 0.4. Fixed by the lagged capital in CDPVault
    /// (`laggedNow`, BACKING_WARMUP): increases warm up over about a day, decreases count at once. `lagged`
    /// is passed by `_backingPerUnit` always and by `backedDebt`'s callers while the wage is nonzero.
    /// Proofs: docs/AUDIT-VAULT-2026-10-05.md, test/LaggedBacking.t.sol, test/RedemptionLagAtLaunch.t.sol.
    function _securedCollateralValue(uint256 price, bool lagged) private view returns (uint256) {
        uint256 secured = securedCollateral;
        uint256 added = _transient(SECURED_THIS_TX_SLOT);
        uint256 held = secured > added ? secured - added : 0;
        uint256 minted = _transient(MINTED_THIS_TX_SLOT);
        uint256 prior = totalDebt > minted ? totalDebt - minted : 0;
        if (lagged) {
            // D1: capital from earlier transactions counts only as it has warmed up.
            (uint256 lagDebt, uint256 lagSecured) = laggedNow();
            held = Math.min(held, lagSecured);
            prior = Math.min(prior, lagDebt);
        }
        uint256 bad = totalBadDebt;
        prior = prior > bad ? prior - bad : 0;
        return Math.min(Math.mulDiv(held, price, 1e18), Math.mulDiv(prior, mat(), 100));
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
        uint256 feesCancelled = _reduceDebt(candidate, amount, false);
        principalCancelled = amount - feesCancelled;
        // Only principal can be fresh: cancelled fees move the rate like any other part of the burn.
        freshCancelled = Math.min(principalCancelled, fresh);
        position.collateral -= gemOut;
        _resecure(position, price);
        _recordBadDebt(candidate);
        _clearIfRecovered(candidate);
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

    /// @dev The increase is the burned fraction of the fee base (`_feeBase`): warm supply, plus warm
    /// principal repaid in the last hours, so neither new principal nor a fresh repayment moves it.
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
        _lag(position, true, before, current);
        if (current > before) _transientAdd(SECURED_THIS_TX_SLOT, current - before);
    }

    /// @dev COLD CAPITAL IS KEPT PER POSITION; WARMTH IS BANKED PER POSITION. Called whenever a position's
    /// principal or secured term moves from `before` to `after_`, with the vault totals already moved or
    /// about to move by the same amount. An increase is cold, less what the position's bank gives back; a
    /// decrease takes the position's own cold first, counts at once, and banks the warm remainder. History:
    /// one aggregate lag turned a borrower's own wipe-and-redraw into fresh capital for a day (final panel
    /// audit, vault, medium); netting that against the aggregate per transaction let another position
    /// inherit the warmth (sweep panel audit, vault, high); banking only what the aggregate visibly lost
    /// still let it, when the new debt came first, and read a stale aggregate (retry panel audit
    /// 2026-10-07, vault, high and medium). Now no aggregate is consulted: what a position holds warm is
    /// its own, and a bank only ever returns warmth to the position that lost it, cooling while it waits
    /// (retry2 panel audit 2026-10-08, medium). For debt, returns the cold principal a decrease retired.
    function _lag(Position storage position, bool secured, uint256 before, uint256 after_)
        private
        returns (uint256 coldOut)
    {
        if (after_ == before) return 0;
        // Cool the vault's totals and this position's figures to now: all cool at the same rate.
        (_coldDebt, _coldSecured) = _coldNow();
        uint256 elapsed = block.timestamp - _coldAt;
        (_feeExcess, _coldAt) = (_cool(_feeExcess, elapsed, true), block.timestamp);
        elapsed = block.timestamp - position.coldAt;
        (position.coldDebt, position.coldSecured, position.coldAt) = (
            uint128(_cool(position.coldDebt, elapsed, false)),
            uint128(_cool(position.coldSecured, elapsed, false)),
            uint64(block.timestamp)
        );
        position.feeExcess = uint128(_cool(position.feeExcess, elapsed, false));
        uint256 cold = secured ? position.coldSecured : position.coldDebt;
        // A bank cools while it waits, at the lag's own rate, and is gone after a day: capital that
        // comes back after hours is credited only what is left, and a one-block visit cannot re-arm it,
        // because what leaves again is only what was credited (retry2 panel audit 2026-10-08, vault, medium:
        // emptied by a visit and re-dated on the next departure, a once-seasoned position kept its warmth
        // forever while its capital was present one block a day).
        uint256 bank = _cool(
            secured ? position.bankSecured : position.bankDebt,
            block.timestamp - (secured ? position.bankSecuredAt : position.bankDebtAt),
            true
        );
        uint256 total = secured ? _coldSecured : _coldDebt;
        // Every subtraction below is guarded by the comparison or the min before it.
        unchecked {
            if (after_ < before) {
                uint256 out = before - after_;
                coldOut = Math.min(cold, out);
                cold -= coldOut;
                total = total > coldOut ? total - coldOut : 0;
                bank = Math.min(bank + (out - coldOut), type(uint128).max);
            } else {
                uint256 credit = Math.min(after_ - before, bank);
                bank -= credit;
                cold += after_ - before - credit;
                total += after_ - before - credit;
                // Principal coming back warm from the bank is the supply its repayment took away, returning:
                // the fee base stops counting the repayment. The debt bank is also filled by a redemption's
                // cancellation, so a redraw after one releases a repayment's share early, raising the next fee a
                // little: accepted, bounded by the position's own share (final vault panel 2026-10-08, low).
                if (!secured && position.feeExcess != 0) _moveFeeExcess(position, 0, credit);
            }
        }
        // Saturates rather than reverts, because deposit and repayment promise not to: past 128 bits of raw
        // units (3.4e14 sIMD) the position records less cold than the total holds for it, so the surplus stays
        // cold in the total until it cools, the safe direction.
        if (cold > type(uint128).max) cold = type(uint128).max;
        if (secured) {
            (position.coldSecured, position.bankSecured, position.bankSecuredAt) =
                (uint128(cold), uint128(bank), uint64(block.timestamp));
            _coldSecured = total;
        } else {
            (position.coldDebt, position.bankDebt, position.bankDebtAt) =
                (uint128(cold), uint128(bank), uint64(block.timestamp));
            _coldDebt = total;
        }
    }

    /// @dev `amount` after `elapsed` seconds of halving every BACKING_HALF_LIFE, rounded up for the vault's
    /// totals and banks (`up`) and down for a position's own figures; and nothing once a whole BACKING_WARMUP
    /// has passed untouched, for ALL of them alike. That is what keeps them consistent: a total is untouched
    /// for a day only when every position in it is, so when the total reads zero so does every position. A
    /// cutoff on the totals alone let an old position's repayment, retiring cold the total no longer held,
    /// warm a new position's capital (final vault panel 2026-10-08, medium). The reverse remains: a position
    /// untouched for a day reads zero while a busy total still holds its share, which then stays in the total
    /// until it cools. That only understates the lagged figures, the safe direction: accepted (retry2, low).
    /// A touch only restarts the day, so activity can slow warming but never speed it.
    function _cool(uint256 amount, uint256 elapsed, bool up) private pure returns (uint256) {
        if (amount == 0 || elapsed == 0) return amount;
        if (elapsed >= BACKING_WARMUP) return 0;
        return Math.mulDiv(amount, _pow(COLD_SECOND_DECAY, elapsed, RAY), RAY, up ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @dev The vault's total cold principal and secured collateral as of now.
    function _coldNow() private view returns (uint256 debt, uint256 secured) {
        uint256 elapsed = block.timestamp - _coldAt;
        return (_cool(_coldDebt, elapsed, true), _cool(_coldSecured, elapsed, true));
    }

    /// @dev THE FEE BASE: the supply a redemption's increase is measured against. The live supply, less
    /// principal still cold and work minted in this transaction (new supply does not dilute the fee: a draw
    /// held for one block, or minted in the redeeming call, lowered every fee and reset the base rate,
    /// retry2 panel audit 2026-10-08, vault, medium), plus warm principal repaid in the last hours, fading
    /// at the lag's half-life (a dominant borrower's repay, redeem a little, redraw pinned the fee at the cap
    /// for a tenth of the honest cost, retry panel audit 2026-10-07, medium). Both terms are kept per
    /// position, so one position's cold draw and repayment cannot erase another's warm repayment (retry2,
    /// medium: as one absolute figure it could). A repayment of cold principal and a redemption's burn
    /// count at once. The same figure charges the redeemer and sets the base rate everyone after pays, so
    /// neither can be lowered by principal held for a block.
    /// FLOORED at `_feeBaseFloor()`: while most supply is new, as right after launch, the warm base is near
    /// zero, and a dust redemption then stored the 4.5% cap as everyone's base rate for days (final vault
    /// panel 2026-10-08, low). Under the floor a redemption's increase is measured as if the supply were the
    /// floor, which only lowers fees while the protocol is that small.
    function _feeBase() internal view returns (uint256) {
        uint256 base = stablecoin.totalSupply() + _cool(_feeExcess, block.timestamp - _coldAt, true);
        uint256 out = _coldPrincipal() + _transient(WORK_MINTED_THIS_TX_SLOT);
        base = base > out ? base - out : 0;
        uint256 floor = _feeBaseFloor();
        return base > floor ? base : floor;
    }

    /// @dev 1,000 imdUSD. A subclass that models only fee arithmetic may lower it.
    function _feeBaseFloor() internal view virtual returns (uint256) {
        return 1_000e18;
    }

    /// @dev The vault's principal still cold, as of now.
    function _coldPrincipal() internal view virtual returns (uint256 debt) {
        (debt,) = _coldNow();
    }

    /// @dev Principal minted in this transaction (for a subclass that models fully warmed capital).
    function _principalMintedThisTransaction() internal view returns (uint256) {
        return _transient(MINTED_THIS_TX_SLOT);
    }

    /// @dev Moves a position's `feeExcess`, and the vault's total with it, by `add` and then down by up to
    /// `remove`. Called only after `_lag` has cooled both to now in the same call.
    function _moveFeeExcess(Position storage position, uint256 add, uint256 remove) private {
        uint256 own = position.feeExcess + add;
        uint256 total = _feeExcess + add;
        remove = Math.min(remove, own);
        position.feeExcess = uint128(Math.min(own - remove, type(uint128).max));
        _feeExcess = total > remove ? total - remove : 0;
    }

    /// @notice The lagged debt and secured collateral as of now: the live figures less what is still cold.
    function laggedNow() public view returns (uint256 debt, uint256 secured) {
        (uint256 coldDebt, uint256 coldSecured) = _coldNow();
        debt = totalDebt > coldDebt ? totalDebt - coldDebt : 0;
        secured = securedCollateral > coldSecured ? securedCollateral - coldSecured : 0;
    }

    /// @dev Whether backing reads the lagged figures. Never for the base vault; ParameterizedVault turns
    /// it on exactly when minting from work is on (a nonzero wage), which is also exactly when `earn` is
    /// open there (`_earnOpen`).
    function _lagApplies() internal view virtual returns (bool) {
        return false;
    }

    /// @dev Whether `earn` may mint at all. Always for the base vault, whose work channel has no wage;
    /// ParameterizedVault opens it exactly while the wage is nonzero, the same switch as the lag.
    function _earnOpen() internal view virtual returns (bool) {
        return true;
    }

    function _transientAdd(uint256 slot, uint256 amount) private {
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), amount))
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
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (mark.marked && !_expired(mark)) return;
        uint256 grace = lull();
        liquidationMarks[owner] = LiquidationMark(block.timestamp, grace, true, beneficiary);
        emit Bark(owner, block.timestamp, grace);
    }

    /// @notice Anyone may clear a mark after observing recovery, including a recovery caused only by a feed.
    /// @dev latestValue cannot reveal an unobserved recover-then-fall sequence. Keepers should clear marks
    /// when recovery is observed; deposit, repayment and successful borrowing/withdrawal also clear them.
    /// Borrowers should call this while healthy: an unobserved recovery does not restart grace within
    /// the bounded mark lifetime, even if a subsequent dip happens before that lifetime ends.
    function heel(address owner) external nonReentrant {
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (!_healthy(position.collateral, debtOf(owner))) revert UnderwaterPosition();
        _clearMark(owner);
    }

    /// @notice Burn caller imdUSD against a marked, still-underwater position after its snapshotted grace.
    /// @dev Payout is floor(debtToRepay * (100 + CHOP_PERCENT) * 1e16 / price) raw collateral, i.e. collateral
    /// worth 120% of the imdUSD burned at the same accepted price the health check reads. Collateral must
    /// cover the full payout, except dust below the seizure for one wei of debt, which is taken whole.
    /// A borrower may mark its own position and so recover the marker's share (CHIP_BPS) of the bonus:
    /// its effective penalty is then 18% of the debt repaid, not 20%. Accepted (launch audit, info).
    /// The mark must still be within its liquidation window (see bark).
    function bite(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        uint256 price = _price();
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
        if (
            remainder != 0 && debtToRepay < position.debt + _stabilityFees[owner]
                && remainder < _oneWeiSeizure(price)
        ) {
            collateralSeized += remainder;
        }
        uint256 feePaid = _reduceDebt(owner, debtToRepay, true);
        position.collateral -= collateralSeized;
        _resecure(position, price);
        _recordBadDebt(owner);
        _clearIfRecovered(owner);
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
        return indexCheckpoint
            + Math.mulDiv(block.timestamp - indexCheckpointAt, duty() * INDEX_SCALE, 365 days * 10_000);
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

    /// @notice How long after its grace ends a mark stays actionable: the shorter feed lifetime.
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

    function _requireFreshFeeds() private view {
        if (_pricingStale()) revert StaleFeed();
        _price();
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
        uint256 difference = primary > spot ? primary - spot : spot - primary;
        if (difference > Math.mulDiv(primary, skew(), 10_000)) revert PriceDivergence();
    }

    function _accrue(address owner) private {
        _stabilityFees[owner] = stabilityFeeOf(owner);
        chiOf[owner] = chi();
    }

    /// @dev Pay fees first, then principal. Only burning imdUSD can reduce either obligation.
    /// @param repayment A burn by the borrower, a liquidator or the Treasury (`wipe`, `bite`, `cover`), as
    /// opposed to a redemption against the position: its warm principal stays in the fee base while it ages.
    function _reduceDebt(address owner, uint256 amount, bool repayment) private returns (uint256 feePaid) {
        Position storage position = _positions[owner];
        uint256 fees = _stabilityFees[owner];
        if (amount > position.debt + fees) revert ExcessRepayment();
        feePaid = Math.min(amount, fees);
        _stabilityFees[owner] = fees - feePaid;
        uint256 principalPaid = amount - feePaid;
        uint256 principalBefore = position.debt;
        {
            uint256 coldOut = _lag(position, false, principalBefore, principalBefore - principalPaid);
            if (repayment && principalPaid > coldOut) _moveFeeExcess(position, principalPaid - coldOut, 0);
        }
        position.debt -= principalPaid;
        // With no readable price the term cannot be re-priced, but the principal it is bounded by has
        // fallen: scale it down in proportion, as a priced checkpoint would (sweep panel audits, vault and
        // oracle, low: kept whole, a repayment during an outage left a term sized for debt that no longer
        // existed, and the reserve-funded part of cash paid at par over honest backing).
        uint256 unpricedCap = principalBefore == 0 ? 0 : Math.mulDiv(position.secured, position.debt, principalBefore);
        _resecureBounded(position, _priceOrZero(), unpricedCap);
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

    function _healthy(uint256 collateral, uint256 debt) private view returns (bool) {
        return debt == 0 || _collateralRatio(collateral, debt, _price()) >= mat();
    }

    function _clearIfRecovered(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        Position storage position = _positions[owner];
        uint256 debt = debtOf(owner);
        if (debt == 0) {
            _clearMark(owner);
        } else if (!_pricingStale() && !spotFeed.isStale()) {
            // AUDIT FIX (job da7d5b1c, medium): TWO prices, because they answer different questions.
            // The divergence comparison takes the RAW primary, since both legs quote IMD in the same
            // unit and the ETH/USD factor would cancel anyway. The health check takes the DENOMINATED
            // price, because it is compared against mat like every other health check. Reading one
            // price for both put ETH-valued collateral against USD-denominated debt the moment
            // ParameterizedVault denominated in dollars, understating the ratio by the whole ETH/USD
            // factor — so a position restored to health kept its mark, and a liquidator could reuse
            // that stale grace after a later decline.
            (uint256 primary,) = priceFeed.latestValue();
            (uint256 spot,) = spotFeed.latestValue();
            uint256 difference = primary > spot ? primary - spot : spot - primary;
            uint256 priced = _priceOrZero();
            // Invalid recovery observations preserve the mark without blocking deposits or repayments.
            if (
                primary != 0 && spot != 0 && priced != 0
                    && difference <= Math.mulDiv(primary, skew(), 10_000)
                    && _collateralRatio(position.collateral, debt, priced) >= mat()
            ) {
                _clearMark(owner);
            }
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
