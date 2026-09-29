// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CompToken} from "./CompToken.sol";
import {MockWorkOracle} from "./MockWorkOracle.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Collateralized COMP borrowing against consumable work credits on Sepolia.
/// @dev PRICE ASSUMPTION: 1 IMD == 1 COMP, fixed for this testnet demonstration. Both use 18 decimals.
/// No market feed, interest, stability fee, or peg redemption is implemented. A production feed is out of scope.
/// The oracle is selected once; there is no owner, upgrade, emergency withdrawal, or mutable parameter authority.
///
/// Two constructor modes resolve the token/vault/oracle dependency cycle:
/// - Assembled (workflow order): `compToken_` is a deployed CompToken. A zero `oracle_` defers the one-time
///   `setOracle` call to the approved operator; a nonzero `oracle_` is validated and locked immediately.
/// - Self-contained (constructor-only factories): `compToken_` is zero. The vault creates `CompToken(this)`
///   and, when `oracle_` is also zero, `MockWorkOracle(this)`, so every link is complete and locked when the
///   constructor returns and no call is needed from any account afterwards.
contract CDPVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    error Unauthorized();
    error AlreadyInitialized();
    error InvalidToken();
    error InvalidOracle();
    error NotInitialized();
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientRights();
    error UnsafeCollateralRatio();
    error HealthyPosition();
    error ExcessRepayment();
    error UnexpectedCollateralReceived();

    event OracleSet(address indexed oracle);
    event CollateralDeposited(address indexed account, uint256 amount);
    event CollateralWithdrawn(address indexed account, uint256 amount);
    event COMPMinted(address indexed account, uint256 amount);
    event COMPRepaid(address indexed account, uint256 amount);
    event Liquidated(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);

    uint256 public constant MIN_COLLATERAL_RATIO = 150;
    uint256 public constant LIQUIDATION_BONUS_PERCENT = 10;

    IERC20 public immutable imdToken;
    CompToken public immutable compToken;
    IWorkOracle public oracle;
    address private _initializer;
    mapping(address account => Position position) public positions;

    /// @param imdToken_ Deployed, nonrebasing, fee-free MockIMD collateral (18 decimals).
    /// @param compToken_ Deployed CompToken whose vault must be set to this contract before borrowing, or zero
    /// to have this vault create and permanently bind its own CompToken (self-contained mode).
    /// @param oracle_ Zero defers one-time setup in assembled mode and creates a bound MockWorkOracle in
    /// self-contained mode; a deployed IWorkOracle is validated and locked immediately in either mode.
    constructor(address imdToken_, address compToken_, address oracle_) {
        if (imdToken_.code.length == 0 || imdToken_ == compToken_) revert InvalidToken();
        imdToken = IERC20(imdToken_);
        if (compToken_ == address(0)) {
            compToken = new CompToken(address(this));
            if (oracle_ == address(0)) {
                oracle_ = address(new MockWorkOracle(address(this)));
            }
        } else {
            if (compToken_.code.length == 0) revert InvalidToken();
            compToken = CompToken(compToken_);
            if (oracle_ == address(0)) {
                _initializer = APPROVED_OPERATOR;
                return;
            }
        }
        _setOracle(oracle_);
    }

    /// @notice Finish deferred initialization once; all initialization authority is then erased.
    /// @dev Only the workflow's approved operator may call, including after factory deployment. A rejected
    /// target leaves initialization available; only a successful call erases the authority.
    function setOracle(address oracle_) external {
        if (_initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != _initializer) revert Unauthorized();
        _setOracle(oracle_);
        delete _initializer;
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = imdToken.balanceOf(address(this));
        positions[msg.sender].collateral += amount;
        imdToken.safeTransferFrom(msg.sender, address(this), amount);
        if (imdToken.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[msg.sender];
        if (amount > position.collateral) revert InsufficientCollateral();
        uint256 remaining = position.collateral - amount;
        if (!_healthy(remaining, position.debt)) revert UnsafeCollateralRatio();
        position.collateral = remaining;
        imdToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function mintCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(oracle) == address(0) || compToken.vault() != address(this)) revert NotInitialized();
        if (oracle.mintingRights(msg.sender) < amount) revert InsufficientRights();
        Position storage position = positions[msg.sender];
        uint256 resultingDebt = position.debt + amount;
        if (!_healthy(position.collateral, resultingDebt)) revert UnsafeCollateralRatio();
        position.debt = resultingDebt;
        oracle.consumeRights(msg.sender, amount);
        compToken.mint(msg.sender, amount);
        emit COMPMinted(msg.sender, amount);
    }

    /// @notice Repay the caller's debt by burning their COMP; no COMP approval is required.
    /// @dev Repayment does not restore consumed work credits.
    function repayCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[msg.sender];
        if (amount > position.debt) revert ExcessRepayment();
        position.debt -= amount;
        compToken.burn(msg.sender, amount);
        emit COMPRepaid(msg.sender, amount);
    }

    /// @notice Burn the caller's COMP against an unhealthy position and receive IMD with a 10% bonus.
    /// @dev PRICE ASSUMPTION: 1 IMD == 1 COMP. Payout is floor(debtToRepay * 110 / 100).
    /// Reverts if the target is healthy, repayment exceeds debt, or collateral cannot cover the full payout.
    /// At the fixed price, a healthy position cannot become unhealthy through normal operations.
    function liquidate(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        Position storage position = positions[owner];
        if (_healthy(position.collateral, position.debt)) revert HealthyPosition();
        if (debtToRepay > position.debt) revert ExcessRepayment();
        uint256 bonus = debtToRepay / 10;
        if (debtToRepay > position.collateral || bonus > position.collateral - debtToRepay) {
            revert InsufficientCollateral();
        }
        uint256 collateralSeized = debtToRepay + bonus;
        position.debt -= debtToRepay;
        position.collateral -= collateralSeized;
        compToken.burn(msg.sender, debtToRepay);
        imdToken.safeTransfer(msg.sender, collateralSeized);
        emit Liquidated(owner, msg.sender, debtToRepay, collateralSeized);
    }

    /// @notice Integer CR percentage at the fixed 1 IMD == 1 COMP price, rounded down.
    /// @dev Returns uint256.max for debt-free positions; unrepresentably large ratios also saturate at that value.
    function collateralRatio(address owner) external view returns (uint256) {
        Position storage position = positions[owner];
        uint256 debt = position.debt;
        if (debt == 0) return type(uint256).max;
        uint256 whole = position.collateral / debt;
        if (whole > type(uint256).max / 100) return type(uint256).max;
        uint256 scaled = whole * 100;
        uint256 fraction = Math.mulDiv(position.collateral % debt, 100, debt);
        if (fraction > type(uint256).max - scaled) return type(uint256).max;
        return scaled + fraction;
    }

    /// @dev Accepts only a deployed contract that answers `mintingRights(address)` as IWorkOracle requires.
    /// If the target additionally exposes `vault()` (as MockWorkOracle does), that consumer must be this vault;
    /// an oracle without that view is accepted so a drop-in IWorkOracle implementation remains compatible.
    function _setOracle(address oracle_) private {
        if (oracle_.code.length == 0) revert InvalidOracle();
        (bool ok, bytes memory data) = oracle_.staticcall(abi.encodeCall(IWorkOracle.mintingRights, (address(this))));
        if (!ok || data.length != 32) revert InvalidOracle();
        (ok, data) = oracle_.staticcall(abi.encodeWithSignature("vault()"));
        if (ok && data.length == 32 && abi.decode(data, (uint256)) != uint256(uint160(address(this)))) {
            revert InvalidOracle();
        }
        oracle = IWorkOracle(oracle_);
        emit OracleSet(oracle_);
    }

    /// @dev Equivalent to collateral * 100 >= debt * 150, without overflowing either product.
    function _healthy(uint256 collateral, uint256 debt) private pure returns (bool) {
        return collateral >= debt && collateral - debt >= debt / 2 + debt % 2;
    }
}
