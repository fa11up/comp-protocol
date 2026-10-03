// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Where the protocol's own revenue lands: its share of liquidation bonuses, in collateral,
/// and the stability fees minted to it, in stablecoin. It is also the protocol's reserve, and it can
/// say what that reserve is worth.
/// @dev ParameterizedVault creates one in its constructor and routes both revenue streams to it, so
/// the money is institutionally separate from the person operating the protocol from the first
/// liquidation onward, and no deployment step can point the revenue at a wallet instead. (The plain
/// CDPVault still pays FEE_RECIPIENT; a Treasury deployed standalone and named there collects the
/// same way, with no register.)
///
/// It is deliberately almost nothing. Revenue arrives by plain ERC-20 transfer, which notifies no
/// one, so `sync` is how a balance becomes a recorded receipt. Anyone may call it: recording what
/// already arrived takes nothing from anybody, and a figure only the operator could refresh would be
/// worth less than one a observer can.
///
/// The reserve register is the one thing added for compute backing. Each accepted asset has a USD
/// price source and a haircut, and `reserveValueUsd` is the discounted sum — the reserve term of the
/// vault's work-minting ceiling. Its entries change only through the vault's Parameters contract
/// (`registrar`), so every listing, delisting and repricing waits the same 48 hours a fee change
/// does, is readable while it waits, and can be applied by anyone. There is no owner path to it.
///
/// What it is NOT: a treasury policy. There is no swap, no liquidity deployment and no accounting of
/// what revenue was for. Those decisions are not made yet, and a contract that cannot be upgraded is
/// the wrong place to guess at them. Withdrawal takes its destination as an argument precisely so the
/// eventual answer — most likely paired liquidity — needs no change here.
contract Treasury {
    using SafeERC20 for IERC20;

    /// @notice A reserve asset's price source and retained-value factor.
    /// @param priceFeed USD per whole token, 1e18-scaled, read like any other ISwarmFeed.
    /// @param haircutBps The retained-value factor, in basis points: the asset counts for haircutBps /
    /// 10000 of its market value. Zero counts for nothing; 10000 counts in full. A lower factor
    /// limits the supply a volatile asset can authorise through a downturn.
    /// @param decimals The token's decimals, read once at listing, so a 6-decimal stablecoin is not
    /// priced as if it had 18.
    struct ReserveAsset {
        ISwarmFeed priceFeed;
        uint256 haircutBps;
        uint8 decimals;
    }

    uint256 private constant BPS = 10_000;

    /// @notice The contract that created this treasury: for a deployment, the vault whose revenue
    /// lands here, whose Parameters governs the register, and whose COMP may never be reserve.
    address public immutable vault = msg.sender;

    /// @notice Everything this contract has ever been credited with, per token, as recorded by sync.
    /// @dev A running total, not a balance: it does not fall when funds are withdrawn, so it answers
    /// "what has the protocol earned" rather than "what is left".
    mapping(IERC20 token => uint256 amount) public totalReceived;

    /// @notice The balance already counted, per token, so a second sync credits nothing twice.
    mapping(IERC20 token => uint256 amount) public lastSynced;

    mapping(IERC20 asset => ReserveAsset entry) private _reserve;
    IERC20[] private _reserveAssets;

    event Received(IERC20 indexed token, uint256 amount, uint256 total);
    event Withdrawn(IERC20 indexed token, address indexed to, uint256 amount);
    event ReserveAssetSet(IERC20 indexed asset, ISwarmFeed indexed priceFeed, uint256 haircutBps);
    event ReserveAssetRemoved(IERC20 indexed asset);

    error Unauthorized();
    error InvalidRecipient();
    error ZeroAmount();
    /// @notice COMP can never be a reserve asset: the Treasury receives stability fees in COMP, and
    /// backing a liability with the same liability is not backing.
    error CompIsNotReserve();
    error InvalidReserveAsset();
    error InvalidPriceSource();
    error HaircutOutOfRange(uint256 bps);
    error NotAReserveAsset();

    // --- the register ---------------------------------------------------------------------------

    /// @notice The only account that may change the register: the creating vault's Parameters
    /// contract, resolved from the vault. Zero — and the register frozen empty — for a Treasury
    /// whose creator has none, such as one deployed standalone.
    /// @dev Read through the vault rather than stored, because the vault's `parameters` is an
    /// immutable it sets in the same construction that creates this contract: there is nothing to
    /// bind afterwards and no second transaction in which to bind the wrong thing.
    function registrar() public view returns (address) {
        return _linked(abi.encodeWithSignature("parameters()"));
    }

    function reserveAssets() external view returns (IERC20[] memory) {
        return _reserveAssets;
    }

    function reserveAssetCount() external view returns (uint256) {
        return _reserveAssets.length;
    }

    function reserveAsset(IERC20 asset) external view returns (ReserveAsset memory) {
        return _reserve[asset];
    }

    function isReserveAsset(IERC20 asset) public view returns (bool) {
        return address(_reserve[asset].priceFeed) != address(0);
    }

    /// @notice Refuse a listing the register would refuse, with the same error. Parameters calls
    /// this when a change is PROPOSED, so an invalid one never occupies the slot or the two days.
    /// @dev A zero price source means removal, which needs the asset to be listed and no haircut.
    function validateReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) public view {
        if (address(asset) == _linked(abi.encodeWithSignature("compToken()"))) revert CompIsNotReserve();
        if (address(asset) == address(0) || address(asset).code.length == 0) revert InvalidReserveAsset();
        if (address(priceFeed) == address(0)) {
            if (!isReserveAsset(asset)) revert NotAReserveAsset();
            if (haircutBps != 0) revert HaircutOutOfRange(haircutBps);
            return;
        }
        if (address(priceFeed).code.length == 0) revert InvalidPriceSource();
        // Both endpoints are valid: zero backing through full market value.
        if (haircutBps > BPS) revert HaircutOutOfRange(haircutBps);
        // Reverts here if the token has no decimals(), which is also what prices it correctly later.
        IERC20Metadata(address(asset)).decimals();
    }

    /// @notice List, reprice or (with a zero price source) delist a reserve asset. Registrar only,
    /// which is the vault's Parameters contract applying a matured proposal.
    function setReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) external {
        address governor = registrar();
        if (governor == address(0) || msg.sender != governor) revert Unauthorized();
        validateReserveAsset(asset, priceFeed, haircutBps);
        if (address(priceFeed) == address(0)) {
            _remove(asset);
            emit ReserveAssetRemoved(asset);
            return;
        }
        if (!isReserveAsset(asset)) _reserveAssets.push(asset);
        _reserve[asset] = ReserveAsset(priceFeed, haircutBps, IERC20Metadata(address(asset)).decimals());
        emit ReserveAssetSet(asset, priceFeed, haircutBps);
    }

    /// @notice What the reserve is worth, in USD scaled by 1e18: the sum over registered assets of
    /// balance x price x haircutBps / 10000, normalized by the token's decimals.
    /// @dev An asset whose price source is stale or reads zero counts for nothing. A dead feed can
    /// therefore only tighten the ceiling that reads this; it can never inflate it, and it never
    /// makes this view revert.
    function reserveValueUsd() public view returns (uint256 total) {
        uint256 count = _reserveAssets.length;
        for (uint256 i; i < count; ++i) {
            total += reserveValueOf(_reserveAssets[i]);
        }
    }

    /// @notice One asset's discounted USD value; zero for anything unlisted or unpriced.
    function reserveValueOf(IERC20 asset) public view returns (uint256) {
        ReserveAsset storage entry = _reserve[asset];
        if (address(entry.priceFeed) == address(0) || entry.priceFeed.isStale()) return 0;
        (uint256 price,) = entry.priceFeed.latestValue();
        if (price == 0) return 0;
        uint256 marked = Math.mulDiv(asset.balanceOf(address(this)), price, 10 ** entry.decimals);
        return Math.mulDiv(marked, entry.haircutBps, BPS);
    }

    function _remove(IERC20 asset) private {
        uint256 count = _reserveAssets.length;
        for (uint256 i; i < count; ++i) {
            if (_reserveAssets[i] != asset) continue;
            _reserveAssets[i] = _reserveAssets[count - 1];
            _reserveAssets.pop();
            break;
        }
        delete _reserve[asset];
    }

    /// @dev An address the creating vault exposes, or zero if it exposes nothing of the kind. A
    /// staticcall so a Treasury created by something that is not a vault still answers its views.
    function _linked(bytes memory probe) private view returns (address) {
        (bool ok, bytes memory data) = vault.staticcall(probe);
        if (!ok || data.length != 32) return address(0);
        uint256 word = abi.decode(data, (uint256));
        return word > type(uint160).max ? address(0) : address(uint160(word));
    }

    // --- revenue --------------------------------------------------------------------------------

    /// @notice Record anything that has arrived since the last call. Callable by anyone.
    /// @return credited The amount added to this token's running total.
    function sync(IERC20 token) external returns (uint256 credited) {
        uint256 balance = token.balanceOf(address(this));
        uint256 counted = lastSynced[token];
        // A withdrawal lowers the balance below what was counted. That is not a loss of revenue, so
        // the running total holds and only the baseline moves.
        if (balance <= counted) {
            lastSynced[token] = balance;
            return 0;
        }
        credited = balance - counted;
        lastSynced[token] = balance;
        totalReceived[token] += credited;
        emit Received(token, credited, totalReceived[token]);
    }

    /// @notice Move funds out, to a destination the caller names.
    /// @dev Pinned to APPROVED_OPERATOR in source, like every other authority in this protocol, so a
    /// deployment template cannot substitute it. The destination is an argument rather than a second
    /// constant because the point of holding revenue is to deploy it later, and where is not decided.
    /// @notice The only account that may withdraw. A source constant, like every authority here.
    function withdrawer() external pure returns (address) {
        return APPROVED_OPERATOR;
    }

    function withdraw(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != APPROVED_OPERATOR) revert Unauthorized();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        // AUDIT FIX (job c71449d1, low): credit anything that arrived since the last sync BEFORE
        // moving the baseline. Clamping first silently dropped that revenue from totalReceived
        // forever — no funds lost, but the one number this contract exists to answer was wrong.
        uint256 before = token.balanceOf(address(this));
        uint256 counted = lastSynced[token];
        if (before > counted) {
            uint256 credited = before - counted;
            totalReceived[token] += credited;
            emit Received(token, credited, totalReceived[token]);
        }
        token.safeTransfer(to, amount);
        // Keep the baseline honest, so the next sync does not read the withdrawal as fresh revenue.
        lastSynced[token] = token.balanceOf(address(this));
        emit Withdrawn(token, to, amount);
    }
}
