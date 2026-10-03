// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {APPROVED_OPERATOR} from "./DeploymentConfig.sol";

/// @notice Where the protocol's own revenue lands: its share of liquidation bonuses, in collateral,
/// and the stability fees minted to it, in stablecoin.
/// @dev CDPVault is immutable, so whatever FEE_RECIPIENT names at deployment collects every protocol
/// cut for that vault's whole life. Naming an account there would put protocol revenue in someone's
/// wallet and make redirecting it mean a new vault; naming this makes the money institutionally
/// separate from the person operating the protocol, from the first liquidation onward.
///
/// It is deliberately almost nothing. Revenue arrives by plain ERC-20 transfer, which notifies no
/// one, so `sync` is how a balance becomes a recorded receipt. Anyone may call it: recording what
/// already arrived takes nothing from anybody, and a figure only the operator could refresh would be
/// worth less than one a observer can.
///
/// What it is NOT: a treasury policy. There is no swap, no liquidity deployment and no accounting of
/// what revenue was for. Those decisions are not made yet, and a contract that cannot be upgraded is
/// the wrong place to guess at them. Withdrawal takes its destination as an argument precisely so the
/// eventual answer — most likely paired liquidity — needs no change here.
contract Treasury {
    using SafeERC20 for IERC20;

    /// @notice Everything this contract has ever been credited with, per token, as recorded by sync.
    /// @dev A running total, not a balance: it does not fall when funds are withdrawn, so it answers
    /// "what has the protocol earned" rather than "what is left".
    mapping(IERC20 token => uint256 amount) public totalReceived;

    /// @notice The balance already counted, per token, so a second sync credits nothing twice.
    mapping(IERC20 token => uint256 amount) public lastSynced;

    event Received(IERC20 indexed token, uint256 amount, uint256 total);
    event Withdrawn(IERC20 indexed token, address indexed to, uint256 amount);

    error Unauthorized();
    error InvalidRecipient();
    error ZeroAmount();

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
