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
import {FEE_RECIPIENT} from "./DeploymentConfig.sol";

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

    /// @notice Maximum collateral-backed debt this vault will ever carry, in stablecoin units.
    /// @dev Unlimited by default so behaviour is unchanged; a deployment that wants a cap overrides
    /// this. There is no admin, so the value a deployment chooses is permanent for that vault —
    /// raising a ceiling means a new vault and a migration, which is the price of having no keys.
    function debtCeiling() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Share of the liquidation bonus paid to FEE_RECIPIENT, in basis points of the bonus.
    /// @dev Zero by default. The borrower's loss is identical either way: this splits the existing
    /// 10% bonus rather than seizing more, so turning it on never makes liquidation harsher.
    function protocolBonusShareBps() public view virtual returns (uint256) {
        return 0;
    }

    /// @notice Total collateral-backed debt outstanding. Work-minted supply is tracked separately.
    uint256 public totalDebt;

    IERC20 public immutable imdToken;
    CompToken public immutable compToken;
    IWorkOracle public immutable oracle;
    ISwarmFeed public immutable priceFeed;
    ISwarmFeed public immutable nhiFeed;
    uint256 public totalWorkMinted;
    mapping(address account => Position position) public positions;
    mapping(address account => LiquidationMark mark) public liquidationMarks;

    /// @param imdToken_ Deployed, nonrebasing, fee-free MockIMD collateral (18 decimals).
    /// @param compToken_ Zero creates a fresh CompToken bound to this vault; otherwise an existing token
    /// to be authorized separately through its reciprocal setVault check.
    /// @param oracle_ Zero creates a fresh MockWorkOracle bound to this vault during construction.
    /// A supplied oracle must already be deployed and, if it exposes vault(), bound to this vault.
    /// @param priceFeed_ Immutable collateral price feed, scaled by 1e18.
    /// @param nhiFeed_ Immutable network health feed, scaled by 1e18.
    constructor(address imdToken_, address compToken_, address oracle_, address priceFeed_, address nhiFeed_) {
        if (
            imdToken_.code.length == 0 || (compToken_ != address(0) && compToken_.code.length == 0)
                || imdToken_ == compToken_
        ) {
            revert InvalidToken();
        }
        if (priceFeed_.code.length == 0 || nhiFeed_.code.length == 0 || priceFeed_ == nhiFeed_) revert InvalidFeed();
        imdToken = IERC20(imdToken_);
        compToken = compToken_ == address(0) ? new CompToken(address(this)) : CompToken(compToken_);
        priceFeed = ISwarmFeed(priceFeed_);
        nhiFeed = ISwarmFeed(nhiFeed_);
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
        positions[msg.sender].collateral += amount;
        imdToken.safeTransferFrom(msg.sender, address(this), amount);
        if (imdToken.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        _clearIfRecovered(msg.sender);
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[msg.sender];
        if (amount > position.collateral) revert InsufficientCollateral();
        uint256 remaining = position.collateral - amount;
        // A withdrawal with debt always lowers CR, so it cannot be allowed with stale feeds.
        // Debt-free collateral remains withdrawable: its ratio is infinite and no solvency depends on a feed.
        if (position.debt != 0) {
            _requireFreshFeeds();
            if (!_healthy(remaining, position.debt)) revert UnsafeCollateralRatio();
        }
        position.collateral = remaining;
        _clearMark(msg.sender);
        imdToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function mintCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        if (compToken.vault() != address(this)) revert NotInitialized();
        Position storage position = positions[msg.sender];
        uint256 resultingDebt = position.debt + amount;
        if (!_healthy(position.collateral, resultingDebt)) revert UnsafeCollateralRatio();
        uint256 resultingTotal = totalDebt + amount;
        if (resultingTotal > debtCeiling()) revert DebtCeilingReached();
        totalDebt = resultingTotal;
        position.debt = resultingDebt;
        _clearMark(msg.sender);
        compToken.mint(msg.sender, amount);
        emit COMPMinted(msg.sender, amount);
    }

    /// @notice Mint earned COMP by consuming work rights, without collateral or a debt entry.
    /// @dev With zero initial supply and this vault as sole minter/burner, supply equals summed debt
    /// plus totalWorkMinted. Repayments and liquidations burn debt; neither restores work rights.
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
        Position storage position = positions[msg.sender];
        if (amount > position.debt) revert ExcessRepayment();
        position.debt -= amount;
        totalDebt -= amount;
        compToken.burn(msg.sender, amount);
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
        Position storage position = positions[owner];
        if (_healthy(position.collateral, position.debt)) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (mark.marked && !_expired(mark)) return;
        uint256 grace = gracePeriod();
        liquidationMarks[owner] = LiquidationMark(block.timestamp, grace, true);
        emit UnderwaterMarked(owner, block.timestamp, grace);
    }

    /// @notice Anyone may clear a mark after observing recovery, including a recovery caused only by a feed.
    /// @dev latestValue cannot reveal an unobserved recover-then-fall sequence. Keepers should clear marks
    /// when recovery is observed; deposit, repayment and successful borrowing/withdrawal also clear them.
    /// Borrowers should call this while healthy: an unobserved recovery does not restart grace within
    /// the bounded mark lifetime, even if a subsequent dip happens before that lifetime ends.
    function clearRecoveredMark(address owner) external nonReentrant {
        _requireFreshFeeds();
        Position storage position = positions[owner];
        if (!_healthy(position.collateral, position.debt)) revert UnderwaterPosition();
        _clearMark(owner);
    }

    /// @notice Burn caller COMP against a marked, still-underwater position after its snapshotted grace.
    /// @dev Payout is floor(debtToRepay * 1.1e18 / price) IMD, i.e. collateral worth 110% of the COMP burned
    /// at the same accepted price the health check reads; collateral must cover the full payout.
    /// The mark must still be within its liquidation window (see markUnderwater).
    function liquidate(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        _requireFreshFeeds();
        Position storage position = positions[owner];
        if (_healthy(position.collateral, position.debt)) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (!mark.marked) revert PositionNotMarked();
        if (block.timestamp - mark.markedAt < mark.grace) revert GracePeriodNotElapsed();
        if (_expired(mark)) revert MarkExpired();
        if (debtToRepay > position.debt) revert ExcessRepayment();
        uint256 price = _price();
        uint256 collateralSeized = Math.mulDiv(debtToRepay, (100 + LIQUIDATION_BONUS_PERCENT) * 1e16, price);
        if (collateralSeized > position.collateral) revert InsufficientCollateral();
        // The protocol's cut comes out of the bonus, never out of the principal, so a liquidator is
        // always made whole on the debt it burned.
        uint256 protocolCut =
            Math.mulDiv(collateralSeized - Math.mulDiv(debtToRepay, 1e18, price), protocolBonusShareBps(), 10_000);
        position.debt -= debtToRepay;
        totalDebt -= debtToRepay;
        position.collateral -= collateralSeized;
        _clearIfRecovered(owner);
        compToken.burn(msg.sender, debtToRepay);
        imdToken.safeTransfer(msg.sender, collateralSeized - protocolCut);
        if (protocolCut != 0) imdToken.safeTransfer(FEE_RECIPIENT, protocolCut);
        emit Liquidated(owner, msg.sender, debtToRepay, collateralSeized);
    }

    /// @notice floor(collateral * price * 100 / (debt * 1e18)), using the latest accepted price.
    /// @dev Returns uint256.max for debt-free positions; unrepresentably large ratios also saturate at that value.
    function collateralRatio(address owner) external view returns (uint256) {
        Position storage position = positions[owner];
        if (position.debt == 0) return type(uint256).max;
        return _collateralRatio(position.collateral, position.debt, _price());
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
        Position storage position = positions[owner];
        if (position.debt == 0) {
            _clearMark(owner);
        } else if (!priceFeed.isStale() && !nhiFeed.isStale()) {
            (uint256 price,) = priceFeed.latestValue();
            if (price != 0 && _collateralRatio(position.collateral, position.debt, price) >= minCR()) {
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
