// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TreasuryFactoryEtch} from "./TreasuryFactoryEtch.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIMD} from "src/MockIMD.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {Parameters} from "src/Parameters.sol";
import {Treasury} from "src/Treasury.sol";
import {UsdPriceFeed} from "src/UsdPriceFeed.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD} from "src/DeploymentConfig.sol";
import {TestSwarmFeed} from "./TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./MirroredSwarmFeed.sol";

contract ReserveTestToken is ERC20 {
    uint8 private immutable places;

    constructor(uint8 places_) ERC20("Reserve", "RSV") {
        places = places_;
    }

    function decimals() public view override returns (uint8) {
        return places;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReserveUsdAggregator {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setDecimals(uint8 next) external {
        decimals = next;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice An ETH/USD leg that is never stale, for suites that are not about staleness.
/// @dev `ParameterizedVault` denominates in USD, so it halts once the Chainlink leg passes
/// `ETH_USD_MAX_AGE` — correct behaviour, but it means any test that warps a day forward must either
/// refresh the answer or use this. Reports `block.timestamp`, so time can pass freely.
contract FreshUsdAggregator {
    uint8 public decimals = 8;
    int256 public answer = 1e8;

    function set(int256 answer_) external {
        answer = answer_;
    }

    function setDecimals(uint8 next) external {
        decimals = next;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

abstract contract WorkBackingFixture is Test {
    address internal constant BORROWER = address(0xBA);
    address internal constant WORKER = address(0xCA);
    address internal constant OTHER_WORKER = address(0xDA);
    /// @dev The fixture's Chainlink ETH/USD answer (8 decimals) and the same price 1e18-scaled, which
    /// is what `UsdPriceFeed.ethUsdPrice` reports and what `ParameterizedVault.reserveValue` divides by.
    int256 internal constant ETH_USD_ANSWER = 2000e8;
    uint256 internal constant ETH_USD = 2000 ether;
    /// @dev USD per reserve-asset token. One dollar, which is one unit of the vault's account now that
    /// `_price()` denominates in USD — so the register needs no conversion and the ceiling arithmetic
    /// reads in whole units. It was pinned to the ETH/USD price while the vault measured in ETH.
    uint256 internal constant ASSET_USD = 1 ether;
    MockIMD internal collateral;
    ParameterizedVault internal backedVault;
    ImdUSD internal stable;
    MockWorkOracle internal workOracle;
    Parameters internal parameters;
    Treasury internal reserve;
    TestSwarmFeed internal primary;
    TestSwarmFeed internal health;
    TestSwarmFeed internal reservePrice;
    ReserveTestToken internal asset;
    ReserveUsdAggregator internal usd;

    function setUp() public virtual {
        TreasuryFactoryEtch.etch(vm);
        vm.warp(1_000_000);
        collateral = new MockIMD();
        // One dollar per IMD, which is 1e18/ETH_USD of an ETH. Pinned in the unit the swarm feed
        // quotes so that one IMD is worth one unit of the vault's USD account, as before this vault
        // denominated in dollars one IMD was worth one ETH.
        primary = new TestSwarmFeed(uint256(1 ether) * 1e18 / ETH_USD);
        health = new TestSwarmFeed(0.85 ether);
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(primary));
        backedVault = new ParameterizedVault(
            address(collateral), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = backedVault.stablecoin();
        workOracle = MockWorkOracle(address(backedVault.oracle()));
        parameters = backedVault.parameters();
        reserve = backedVault.treasury();
        asset = new ReserveTestToken(18);
        reservePrice = new TestSwarmFeed(ASSET_USD);
        ReserveUsdAggregator implementation = new ReserveUsdAggregator();
        vm.etch(CHAINLINK_ETH_USD, address(implementation).code);
        usd = ReserveUsdAggregator(CHAINLINK_ETH_USD);
        usd.setDecimals(8);
        usd.set(ETH_USD_ANSWER, vm.getBlockTimestamp());
        vm.startPrank(APPROVED_OPERATOR);
        workOracle.grantRights(WORKER, type(uint128).max);
        workOracle.grantRights(OTHER_WORKER, type(uint128).max);
        vm.stopPrank();
    }

    function _apply() internal {
        vm.warp(parameters.pendingEta());
        vm.prank(address(0xA990));
        parameters.applyPending();
        _refreshEthUsd();
    }

    /// @dev Re-date the Chainlink leg at the fixture's price after a warp, so a test that moves time
    /// to mature a proposal does not also expire the USD leg unless it means to.
    function _refreshEthUsd() internal {
        usd.set(ETH_USD_ANSWER, vm.getBlockTimestamp());
    }

    /// @dev What `reserveValue` must report for a USD figure at the fixture's ETH/USD price.
    /// @dev Sets the primary feed so the VAULT reads `valueInVaultUnit` dollars per collateral unit.
    /// The feed quotes IMD in wei of ETH and the vault multiplies by ETH/USD, so a test that cares
    /// what the vault sees has to divide by the leg rather than set the figure directly.
    function _setVaultPrice(uint256 valueInVaultUnit) internal {
        primary.setValue(Math.mulDiv(valueInVaultUnit, 1e18, ETH_USD));
    }

    /// @dev The identity, now that the vault denominates in USD and the register is kept in USD. It
    /// used to divide by ETH/USD, because the vault measured collateral in ETH. Kept as a named helper
    /// rather than inlined so the places that care about the unit still read as caring about it.
    function _inVaultUnit(uint256 usdValue) internal pure returns (uint256) {
        return usdValue;
    }

    /// @dev Raise the debt ceiling through governance, for a test about arithmetic at sizes above the
    /// launch ceiling (LINE, $1M) rather than about the ceiling itself. Takes the 48-hour timelock.
    function _raiseLine(uint256 next) internal {
        Parameters.ParamSet memory p = parameters.current();
        p.line = next;
        vm.prank(APPROVED_OPERATOR);
        parameters.propose(p);
        _apply();
    }

    function _register(IERC20 token, ISwarmFeed feed, uint256 haircut) internal {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeReserveAsset(token, feed, haircut);
        _apply();
    }

    function _setRatio(uint256 ratio) internal {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeEarnMat(ratio);
        _apply();
    }

    function _openDebt(uint256 debt) internal {
        uint256 amount = debt * 2;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, amount);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), amount);
        backedVault.lock(amount);
        backedVault.draw(debt);
        vm.stopPrank();
    }

    // Retain half the market value of a token worth one ETH, so twice the requested balance supplies
    // exactly `value` of backing in the vault's unit (and 2000 x value in the USD register).
    function _fundReserve(uint256 value) internal {
        _register(asset, reservePrice, 5000);
        asset.mint(address(reserve), value * 2);
    }

    function _mintWork(address worker, uint256 amount) internal {
        vm.prank(worker);
        backedVault.earn(amount);
    }
}
