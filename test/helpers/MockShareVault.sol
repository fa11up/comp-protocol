// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice An ERC-4626-shaped share over an 18-decimal asset, with sIMD's 24 decimals and a settable
/// exchange rate. Switches let a test make it misreport a deposit or stop answering altogether.
contract MockShareVault is ERC20 {
    IERC20 public immutable underlying;
    /// @dev Asset raw units per 1e18 share raw units: what `convertToAssets(1e18)` returns.
    uint256 public rate;
    bool public reportDouble;
    bool public silent;

    constructor(IERC20 asset_, uint256 rate_) ERC20("Staked IMD (mock)", "sIMD") {
        underlying = asset_;
        rate = rate_;
    }

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setReportDouble(bool on) external {
        reportDouble = on;
    }

    function setSilent(bool on) external {
        silent = on;
    }

    function asset() external view returns (address) {
        require(!silent, "silent");
        return address(underlying);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!silent, "silent");
        return shares * rate / 1e18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets * 1e18 / rate;
        _mint(receiver, shares);
        // A share vault that reports more than it minted: the borrower must be credited what arrived.
        if (reportDouble) return shares * 2;
    }
}
