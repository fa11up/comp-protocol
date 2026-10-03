// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CompToken} from "./CompToken.sol";
import {MockWorkOracle} from "./MockWorkOracle.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {FEE_RECIPIENT, MAX_DIVERGENCE_BPS, MARKER_SHARE_BPS, STABILITY_FEE_BPS} from "./DeploymentConfig.sol";

/// @notice Price-aware COMP borrowing and independent work-credit minting on Sepolia.
/// @dev Both tokens use 18 decimals; price is COMP per IMD scaled by 1e18.
/// NHI alone determines collateral requirements and liquidation grace. There is no parameter admin.
/// Zero COMP and oracle arguments create permanently bound contracts with no post-deployment setup.
/// The requester has no initialization authority in this mode; the operator retains only the mock faucets.
contract CDPVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    struct LiquidationMark {
        uint256 markedAt;
        uint256 grace;
        bool marked;
        address marker;
    }

    error InvalidToken();
    error InvalidOracle();
    error InvalidFeed();
    error InvalidPrice();
    error NotInitialized();
    error StaleFeed();
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientRights();
    error UnsafeCollateralRatio();
    error HealthyPosition();
    error ExcessRepayment();
    error UnexpectedCollateralReceived();
    error PositionNotMarked();
    error GracePeriodNotElapsed();
    error MarkExpired();
    error UnderwaterPosition();
    error DebtCeilingReached();
    error PriceDivergence();
    error InvalidBonusShares();

    event OracleSet(address indexed oracle);
    event CollateralDeposited(address indexed account, uint256 amount);
    event CollateralWithdrawn(address indexed account, uint256 amount);
    event COMPMinted(address indexed account, uint256 amount);
    event WorkMinted(address indexed account, uint256 amount);
    event COMPRepaid(address indexed account, uint256 amount);
    event Liquidated(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);
    event UnderwaterMarked(address indexed owner, uint256 markedAt, uint256 grace);
    event UnderwaterMarkCleared(address indexed owner);

    uint256 public constant LIQUIDATION_BONUS_PERCENT = 10;
    uint256 public constant maxDivergenceBps = MAX_DIVERGENCE_BPS;
    uint256 public constant markerShareBps = MARKER_SHARE_BPS;
    uint256 private constant INDEX_SCALE = 1e18;
    uint256 public immutable deployedAt = block.timestamp;

    /// @notice Maximum collateral-backed minted principal, in stablecoin units (fees are additional).
    /// @dev Unlimited by default so behaviour is unchanged; a deployment that wants a cap overrides
    /// this. There is no admin, so the value a deployment chooses is permanent for that vault —
    /// raising a ceiling means a new vault and a migration, which is the price of having no keys.
    function debtCeiling() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Share of the liquidation bonus paid to FEE_RECIPIENT, in basis points of the bonus.
    /// @dev Zero by default. The borrower's loss is identical either way: this splits the existing
    /// 10% bonus rather than seizing more, so turning it on never makes liquidation harsher.
    /// @notice Annual stability fee on open debt, in basis points, accrued linearly from deployment.
    /// @dev Virtual for the same reason debtCeiling and protocolBonusShareBps are: a deployment pins
    /// it in source, and a test can hold it at another value without rewriting the source to do it.
    /// There is no setter, so a deployment's rate is permanent for that vault.
    function stabilityFeeBps() public view virtual returns (uint256) {
        return STABILITY_FEE_BPS;
    }

    function protocolBonusShareBps() public view virtual returns (uint256) {
        return 0;
    }

    /// @notice Outstanding minted principal, as used by the unchanged debt ceiling.
    /// @dev Accrued, unpaid stability fees are additional obligations returned by debtOf/positions.
    uint256 public totalDebt;

    IERC20 public immutable imdToken;
    CompToken public immutable compToken;
    IWorkOracle public immutable oracle;
    ISwarmFeed public immutable priceFeed;
    ISwarmFeed public immutable nhiFeed;
    ISwarmFeed public immutable spotFeed;
    uint256 public totalWorkMinted;
    uint256 public totalFeesMinted;
    /// @notice Recorded residual debt from liquidations that exhausted collateral, at its last update.
    /// @dev Measurement only: no insurance or debt forgiveness. Only debt repayment reduces a recorded
    /// residual; adding collateral cannot hide it. Use badDebtOf for a current-price, accrued view.
    uint256 public totalBadDebt;
    mapping(address account => Position position) private _positions;
    mapping(address account => uint256 index) public debtIndexOf;
    mapping(address account => uint256 fees) private _stabilityFees;
    mapping(address account => uint256 debt) private _recordedBadDebt;
    mapping(address account => LiquidationMark mark) public liquidationMarks;

    /// @param imdToken_ Deployed, nonrebasing, fee-free MockIMD collateral (18 decimals).
    /// @param compToken_ Zero creates a fresh CompToken bound to this vault; otherwise an existing token
    /// to be authorized separately through its reciprocal setVault check.
    /// @param oracle_ Zero creates a fresh MockWorkOracle bound to this vault during construction.
    /// A supplied oracle must already be deployed and, if it exposes vault(), bound to this vault.
    /// @param priceFeed_ Immutable collateral price feed, scaled by 1e18.
    /// @param nhiFeed_ Immutable network health feed, scaled by 1e18.
    /// @param spotFeed_ Immutable spot price feed, used only to bound divergence from the primary average.
    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) {
        if (
            imdToken_.code.length == 0 || (compToken_ != address(0) && compToken_.code.length == 0)
                || imdToken_ == compToken_
        ) {
            revert InvalidToken();
        }
        if (
            priceFeed_.code.length == 0 || nhiFeed_.code.length == 0 || spotFeed_.code.length == 0
                || priceFeed_ == nhiFeed_ || spotFeed_ == nhiFeed_ || spotFeed_ == priceFeed_
        ) revert InvalidFeed();
        imdToken = IERC20(imdToken_);
        compToken = compToken_ == address(0) ? new CompToken(address(this)) : CompToken(compToken_);
        priceFeed = ISwarmFeed(priceFeed_);
        nhiFeed = ISwarmFeed(nhiFeed_);
        spotFeed = ISwarmFeed(spotFeed_);
        if (oracle_ == address(0)) {
            oracle_ = address(new MockWorkOracle(address(this)));
        }
        _validateOracle(oracle_);
        oracle = IWorkOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = imdToken.balanceOf(address(this));
        _positions[msg.sender].collateral += amount;
        imdToken.safeTransferFrom(msg.sender, address(this), amount);
        if (imdToken.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        _clearIfRecovered(msg.sender);
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
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
        _clearMark(msg.sender);
        imdToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function mintCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        if (compToken.vault() != address(this)) revert NotInitialized();
        _accrue(msg.sender);
        Position storage position = _positions[msg.sender];
        uint256 resultingDebt = position.debt + _stabilityFees[msg.sender] + amount;
        if (!_healthy(position.collateral, resultingDebt)) revert UnsafeCollateralRatio();
        uint256 resultingTotal = totalDebt + amount;
        if (resultingTotal > debtCeiling()) revert DebtCeilingReached();
        totalDebt = resultingTotal;
        position.debt += amount;
        _clearMark(msg.sender);
        compToken.mint(msg.sender, amount);
        emit COMPMinted(msg.sender, amount);
    }

    /// @notice Mint earned COMP by consuming work rights, without collateral or a debt entry.
    /// @dev With this vault as sole minter/burner, supply = summed accrued debt + totalWorkMinted
    /// + totalFeesMinted - all fees accrued (paid and unpaid). Equivalently it is outstanding minted
    /// principal + totalWorkMinted. Unpaid fees are claims, not supply. Neither repayment path restores rights.
    function mintFromWork(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        if (compToken.vault() != address(this)) revert NotInitialized();
        if (oracle.mintingRights(msg.sender) < amount) revert InsufficientRights();
        totalWorkMinted += amount;
        oracle.consumeRights(msg.sender, amount);
        compToken.mint(msg.sender, amount);
        emit WorkMinted(msg.sender, amount);
    }

    /// @notice Repay the caller's debt by burning their COMP; no COMP approval is required.
    /// @dev Repayment does not restore consumed work credits.
    function repayCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        uint256 feePaid = _reduceDebt(msg.sender, amount);
        _payDebt(amount, feePaid);
        _clearIfRecovered(msg.sender);
        emit COMPRepaid(msg.sender, amount);
    }

    /// @notice Start an underwater position's grace window; repeated marks preserve an active snapshot.
    /// @dev A mark is actionable from markedAt + grace for one liquidationWindow(), then expires and must be
    /// retaken, which restarts grace. latestValue cannot reveal a recover-then-fall sequence nobody
    /// transacted through, so bounding a mark's lifetime is what keeps an old mark from turning a later
    /// dip into a same-block liquidation with no effective grace.
    function markUnderwater(address owner) external nonReentrant {
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (mark.marked && !_expired(mark)) return;
        uint256 grace = gracePeriod();
        liquidationMarks[owner] = LiquidationMark(block.timestamp, grace, true, msg.sender);
        emit UnderwaterMarked(owner, block.timestamp, grace);
    }

    /// @notice Anyone may clear a mark after observing recovery, including a recovery caused only by a feed.
    /// @dev latestValue cannot reveal an unobserved recover-then-fall sequence. Keepers should clear marks
    /// when recovery is observed; deposit, repayment and successful borrowing/withdrawal also clear them.
    /// Borrowers should call this while healthy: an unobserved recovery does not restart grace within
    /// the bounded mark lifetime, even if a subsequent dip happens before that lifetime ends.
    function clearRecoveredMark(address owner) external nonReentrant {
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (!_healthy(position.collateral, debtOf(owner))) revert UnderwaterPosition();
        _clearMark(owner);
    }

    /// @notice Burn caller COMP against a marked, still-underwater position after its snapshotted grace.
    /// @dev Payout is floor(debtToRepay * 1.1e18 / price) IMD, i.e. collateral worth 110% of the COMP burned
    /// at the same accepted price the health check reads; collateral must cover the full payout.
    /// The mark must still be within its liquidation window (see markUnderwater).
    function liquidate(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (!mark.marked) revert PositionNotMarked();
        if (block.timestamp - mark.markedAt < mark.grace) revert GracePeriodNotElapsed();
        if (_expired(mark)) revert MarkExpired();
        _accrue(owner);
        if (debtToRepay > position.debt + _stabilityFees[owner]) revert ExcessRepayment();
        uint256 price = _price();
        uint256 collateralSeized = Math.mulDiv(debtToRepay, (100 + LIQUIDATION_BONUS_PERCENT) * 1e16, price);
        if (collateralSeized > position.collateral) revert InsufficientCollateral();
        // Both shares come out of the same bonus, never principal or extra borrower collateral.
        uint256 protocolShare = protocolBonusShareBps();
        if (protocolShare > 10_000 - markerShareBps) revert InvalidBonusShares();
        uint256 bonus = collateralSeized - Math.mulDiv(debtToRepay, 1e18, price);
        uint256 protocolCut = Math.mulDiv(bonus, protocolShare, 10_000);
        uint256 markerCut = Math.mulDiv(bonus, markerShareBps, 10_000);
        address marker = mark.marker;
        // Sweep a remainder nobody could ever claim. Taking the largest coverable debt leaves dust,
        // and once that dust is smaller than the seizure for a single wei of debt every later
        // liquidate reverts InsufficientCollateral: the position freezes with debt outstanding and
        // collateral no one can reach, so it never drains and its loss is never realized. Observed
        // on Sepolia at 887 wei against 157364181818182858 of debt.
        // It is folded in AFTER the split, so it enlarges neither the bonus nor the marker's and
        // protocol's shares of it — the dust is extra incentive for whoever closes the position, and
        // the borrower's loss with both shares at zero is unchanged. Only when debt survives the
        // liquidation: a borrower whose debt is cleared is solvent and the remainder is theirs.
        uint256 remainder = position.collateral - collateralSeized;
        if (
            remainder != 0 && debtToRepay < position.debt + _stabilityFees[owner]
                && remainder < Math.mulDiv(1, (100 + LIQUIDATION_BONUS_PERCENT) * 1e16, price)
        ) {
            collateralSeized += remainder;
        }
        uint256 feePaid = _reduceDebt(owner, debtToRepay);
        position.collateral -= collateralSeized;
        _recordBadDebt(owner);
        _clearIfRecovered(owner);
        _payDebt(debtToRepay, feePaid);
        if (marker == msg.sender) {
            imdToken.safeTransfer(msg.sender, collateralSeized - protocolCut);
        } else {
            imdToken.safeTransfer(msg.sender, collateralSeized - protocolCut - markerCut);
            if (markerCut != 0) imdToken.safeTransfer(marker, markerCut);
        }
        if (protocolCut != 0) imdToken.safeTransfer(FEE_RECIPIENT, protocolCut);
        emit Liquidated(owner, msg.sender, debtToRepay, collateralSeized);
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

    /// @notice Deployment-based linear index; no per-second compounding or mutable rate.
    function debtIndex() public view returns (uint256) {
        return INDEX_SCALE + Math.mulDiv(block.timestamp - deployedAt, stabilityFeeBps() * INDEX_SCALE, 365 days * 10_000);
    }

    /// @notice Unpaid fees on principal since its last debt change, plus previously accrued unpaid fees.
    /// @dev Fees never themselves earn interest. Reads and collateral/mark changes cannot capitalize fees.
    function stabilityFeeOf(address owner) public view returns (uint256) {
        uint256 principal = _positions[owner].debt;
        if (principal == 0 || stabilityFeeBps() == 0) return _stabilityFees[owner];
        return _stabilityFees[owner] + Math.mulDiv(principal, debtIndex() - debtIndexOf[owner], INDEX_SCALE);
    }

    function debtOf(address owner) public view returns (uint256) {
        return _positions[owner].debt + stabilityFeeOf(owner);
    }

    /// @notice Debt not covered by collateral at the current primary price, including the 10% payout.
    /// @dev Measurement only, not insurance or forgiveness. This view does not assert feed freshness.
    /// The existing full-payout liquidation guard is unchanged; all uncovered debt remains repayable.
    function badDebtOf(address owner) external view returns (uint256) {
        return _badDebtOf(owner);
    }

    /// @dev The shortfall at the current price: debt that the position's collateral cannot cover at
    /// the full liquidation payout. Shared with _recordBadDebt so the accumulator and this view can
    /// never disagree about what bad debt means.
    function _badDebtOf(address owner) private view returns (uint256) {
        uint256 debt = debtOf(owner);
        if (debt == 0) return 0;
        uint256 collateral = _positions[owner].collateral;
        if (collateral == 0) return debt;
        uint256 price = _price();
        // A ratio of at least 110 guarantees full coverage and avoids overflow on very large collateral.
        if (_collateralRatio(collateral, debt, price) >= 100 + LIQUIDATION_BONUS_PERCENT) return 0;
        uint256 payoutScale = (100 + LIQUIDATION_BONUS_PERCENT) * 1e16;
        uint256 covered = Math.mulDiv(collateral, price, payoutScale);
        // Match the existing floor-rounded payout exactly: capacity = ceil((collateral + 1)
        // * price / payoutScale) - 1, split into quotients/remainders to avoid overflowing either product.
        uint256 extra = (price - 1) / payoutScale;
        extra += (mulmod(collateral, price, payoutScale) + (price - 1) % payoutScale) / payoutScale;
        return extra >= debt - covered ? 0 : debt - covered - extra;
    }

    /// @notice Minimum CR, derived only from NHI: 200 at/below .60; 150 at/above .85.
    /// @dev Linear interpolation rounds up to a whole percent, so rounding cannot weaken the threshold.
    function minCR() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _minCR(nhi);
    }

    /// @notice Grace derived only from NHI: zero at/below .60; six hours at/above .85.
    function gracePeriod() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _gracePeriod(nhi);
    }

    /// @notice How long after its grace ends a mark stays actionable: the shorter feed lifetime.
    /// @dev Past that, at least one full feed cycle has elapsed in which nobody liquidated, and either
    /// feed may have moved the position through recovery unobserved; the mark is void and must be retaken.
    function liquidationWindow() public view returns (uint256) {
        return Math.min(priceFeed.maxAge(), nhiFeed.maxAge());
    }

    /// @dev Accepts only a deployed contract that answers `mintingRights(address)` as IWorkOracle requires.
    /// If the target additionally exposes `vault()` (as MockWorkOracle does), that consumer must be this vault;
    /// an oracle without that view is accepted so a drop-in IWorkOracle implementation remains compatible.
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
        if (priceFeed.isStale() || nhiFeed.isStale()) revert StaleFeed();
        _price();
    }

    /// @dev A pinned closing block and an attestation valid for its TTL let an attacker know which
    /// block to push and act on the signature afterwards. Price from an average; use spot only to
    /// detect disagreement. Compare against the primary's share without a rounded-down BPS ratio.
    function _requirePriceAgreement() private view {
        if (spotFeed.isStale()) revert StaleFeed();
        (uint256 spot,) = spotFeed.latestValue();
        if (spot == 0) revert InvalidPrice();
        uint256 primary = _price();
        uint256 difference = primary > spot ? primary - spot : spot - primary;
        if (difference > Math.mulDiv(primary, maxDivergenceBps, 10_000)) revert PriceDivergence();
    }

    function _accrue(address owner) private {
        _stabilityFees[owner] = stabilityFeeOf(owner);
        debtIndexOf[owner] = debtIndex();
    }

    /// @dev Pay fees first, then principal. Only burning COMP can reduce either obligation.
    function _reduceDebt(address owner, uint256 amount) private returns (uint256 feePaid) {
        Position storage position = _positions[owner];
        uint256 fees = _stabilityFees[owner];
        if (amount > position.debt + fees) revert ExcessRepayment();
        feePaid = Math.min(amount, fees);
        _stabilityFees[owner] = fees - feePaid;
        uint256 principalPaid = amount - feePaid;
        position.debt -= principalPaid;
        totalDebt -= principalPaid;
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

    function _payDebt(uint256 amount, uint256 feePaid) private {
        compToken.burn(msg.sender, amount);
        if (feePaid != 0) {
            totalFeesMinted += feePaid;
            compToken.mint(FEE_RECIPIENT, feePaid);
        }
    }

    /// @dev Counts a shortfall only once it is REALIZED, meaning the position has been drained and
    /// the loss is no longer a mark-to-market estimate that a price recovery could erase. The sweep
    /// in liquidate() is what makes this reachable: before it, a liquidation of the largest coverable
    /// debt left a remainder too small to ever seize, so the position never drained and this never
    /// fired. Recording the live shortfall instead was tried and rejected — it makes totalBadDebt a
    /// moving estimate rather than realized losses, which is a different number than the one the
    /// invariant suite checks.
    function _recordBadDebt(address owner) private {
        // Reachable because liquidate() sweeps an unreachable remainder: without that, a position
        // drained to dust never hit zero and this never fired, leaving totalBadDebt at zero while
        // badDebtOf reported the shortfall. Still "realized" only — a loss is counted once the
        // position is actually drained, not while it is a mark-to-market estimate a price recovery
        // could erase.
        if (_positions[owner].collateral != 0) return;
        uint256 current = debtOf(owner);
        totalBadDebt = totalBadDebt - _recordedBadDebt[owner] + current;
        _recordedBadDebt[owner] = current;
    }

    function _price() private view returns (uint256 price) {
        (price,) = priceFeed.latestValue();
        if (price == 0) revert InvalidPrice();
    }

    function _minCR(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 150;
        if (nhi <= 0.6e18) return 200;
        return 150 + Math.mulDiv(0.85e18 - nhi, 50, 0.25e18, Math.Rounding.Ceil);
    }

    function _gracePeriod(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 6 hours;
        if (nhi <= 0.6e18) return 0;
        return (nhi - 0.6e18) * 6 hours / 0.25e18;
    }

    function _healthy(uint256 collateral, uint256 debt) private view returns (bool) {
        return debt == 0 || _collateralRatio(collateral, debt, _price()) >= minCR();
    }

    function _clearIfRecovered(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        Position storage position = _positions[owner];
        uint256 debt = debtOf(owner);
        if (debt == 0) {
            _clearMark(owner);
        } else if (!priceFeed.isStale() && !nhiFeed.isStale() && !spotFeed.isStale()) {
            (uint256 price,) = priceFeed.latestValue();
            (uint256 spot,) = spotFeed.latestValue();
            uint256 difference = price > spot ? price - spot : spot - price;
            // Invalid recovery observations preserve the mark without blocking deposits or repayments.
            if (
                price != 0 && spot != 0 && difference <= Math.mulDiv(price, maxDivergenceBps, 10_000)
                    && _collateralRatio(position.collateral, debt, price) >= minCR()
            ) {
                _clearMark(owner);
            }
        }
    }

    function _expired(LiquidationMark storage mark) private view returns (bool) {
        return block.timestamp > mark.markedAt + mark.grace + liquidationWindow();
    }

    function _clearMark(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        delete liquidationMarks[owner];
        emit UnderwaterMarkCleared(owner);
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

    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256) {
        return b > type(uint256).max - a ? type(uint256).max : a + b;
    }
}
