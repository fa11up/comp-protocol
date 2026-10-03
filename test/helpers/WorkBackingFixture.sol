// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIMD} from "src/MockIMD.sol";
import {CompToken} from "src/CompToken.sol";
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

abstract contract WorkBackingFixture is Test {
    address internal constant BORROWER = address(0xBA);
    address internal constant WORKER = address(0xCA);
    address internal constant OTHER_WORKER = address(0xDA);
    MockIMD internal collateral;
    ParameterizedVault internal backedVault;
    CompToken internal stable;
    MockWorkOracle internal workOracle;
    Parameters internal parameters;
    Treasury internal reserve;
    TestSwarmFeed internal primary;
    TestSwarmFeed internal health;
    TestSwarmFeed internal reservePrice;
    ReserveTestToken internal asset;
    ReserveUsdAggregator internal usd;

    function setUp() public virtual {
        vm.warp(1_000_000);
        collateral = new MockIMD();
        primary = new TestSwarmFeed(1 ether);
        health = new TestSwarmFeed(0.85 ether);
        MirroredSwarmFeed spot = new MirroredSwarmFeed(address(primary));
        backedVault = new ParameterizedVault(
            address(collateral), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = backedVault.compToken();
        workOracle = MockWorkOracle(address(backedVault.oracle()));
        parameters = backedVault.parameters();
        reserve = backedVault.treasury();
        asset = new ReserveTestToken(18);
        reservePrice = new TestSwarmFeed(1 ether);
        ReserveUsdAggregator implementation = new ReserveUsdAggregator();
        vm.etch(CHAINLINK_ETH_USD, address(implementation).code);
        usd = ReserveUsdAggregator(CHAINLINK_ETH_USD);
        usd.setDecimals(8);
        usd.set(2000e8, vm.getBlockTimestamp());
        vm.startPrank(APPROVED_OPERATOR);
        workOracle.grantRights(WORKER, type(uint128).max);
        workOracle.grantRights(OTHER_WORKER, type(uint128).max);
        vm.stopPrank();
    }

    function _apply() internal {
        vm.warp(parameters.pendingEta());
        vm.prank(address(0xA990));
        parameters.applyPending();
        usd.set(2000e8, vm.getBlockTimestamp());
    }

    function _register(IERC20 token, ISwarmFeed feed, uint256 haircut) internal {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeReserveAsset(token, feed, haircut);
        _apply();
    }

    function _setRatio(uint256 ratio) internal {
        vm.prank(APPROVED_OPERATOR);
        parameters.proposeWorkRatio(ratio);
        _apply();
    }

    function _openDebt(uint256 debt) internal {
        uint256 amount = debt * 2;
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, amount);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), amount);
        backedVault.depositCollateral(amount);
        backedVault.mintCOMP(debt);
        vm.stopPrank();
    }

    // Fifty percent has the same value under both haircut conventions. The disputed endpoints
    // are reproduced in the findings proof, not blessed by a passing expectation here.
    function _fundReserve(uint256 value) internal {
        _register(asset, reservePrice, 5000);
        asset.mint(address(reserve), value * 2);
    }

    function _mintWork(address worker, uint256 amount) internal {
        vm.prank(worker);
        backedVault.mintFromWork(amount);
    }
}
