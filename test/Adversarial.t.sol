// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {IWorkOracle} from "../src/interfaces/IWorkOracle.sol";

abstract contract ReentryProbe {
    uint256 public blockedCallbacks;

    function _probe(CDPVault vault, address account) internal {
        bytes[8] memory calls = [
            abi.encodeCall(vault.depositCollateral, (1)),
            abi.encodeCall(vault.withdrawCollateral, (1)),
            abi.encodeCall(vault.mintCOMP, (1)),
            abi.encodeCall(vault.repayCOMP, (1)),
            abi.encodeCall(vault.liquidate, (account, 1)),
            abi.encodeCall(vault.mintFromWork, (1)),
            abi.encodeCall(vault.markUnderwater, (account)),
            abi.encodeCall(vault.clearRecoveredMark, (account))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(vault).call(calls[i]);
            require(
                !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "reentry not blocked"
            );
            ++blockedCallbacks;
        }
    }
}

contract AdversarialOracle is IWorkOracle, ReentryProbe {
    error OracleOffline();
    CDPVault public immutable vault;
    mapping(address => uint256) public override mintingRights;
    bool public fail;

    constructor(CDPVault vault_, address account) {
        vault = vault_;
        mintingRights[account] = 100 ether;
    }

    function setFail(bool fail_) external {
        fail = fail_;
    }

    function consumeRights(address account, uint256 amount) external {
        require(msg.sender == address(vault));
        mintingRights[account] -= amount;
        _probe(vault, account);
        if (fail) revert OracleOffline();
    }
}

contract AdversarialCollateral is ERC20, ReentryProbe {
    enum Mode {
        Normal,
        FalseIn,
        ShortIn,
        FalseOut,
        Callback
    }
    Mode public mode;
    CDPVault public vault;

    constructor(address account) ERC20("Adversarial", "BAD") {
        _mint(account, 1000 ether);
    }

    function configure(CDPVault vault_, Mode mode_) external {
        vault = vault_;
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.FalseIn) return false;
        bool result = super.transferFrom(from, to, amount);
        if (mode == Mode.ShortIn) _burn(to, 1);
        if (mode == Mode.Callback) _probe(vault, from);
        return result;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.FalseOut) return false;
        if (mode == Mode.Callback) _probe(vault, to);
        return super.transfer(to, amount);
    }
}

contract AdversarialTest is Test {
    address internal alice = address(0xA11CE);
    CompToken internal comp;
    CDPVault internal vault;
    AdversarialCollateral internal collateral;
    AdversarialOracle internal oracle;
    TestSwarmFeed internal priceFeed;
    TestSwarmFeed internal nhiFeed;

    function setUp() public {
        collateral = new AdversarialCollateral(alice);
        comp = new CompToken(address(0));
        priceFeed = new TestSwarmFeed(1 ether);
        nhiFeed = new TestSwarmFeed(0.85 ether);
        // The immutable oracle validates the address of the vault that will be created next.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        oracle = new AdversarialOracle(CDPVault(predictedVault), alice);
        vault = new CDPVault(address(collateral), address(comp), address(oracle), address(priceFeed), address(nhiFeed));
        assertEq(address(vault), predictedVault);
        vm.startPrank(0x5167D014a056E43883e1BBEa5530c3c0dC993281);
        comp.setVault(address(vault));
        vm.stopPrank();
        vm.prank(alice);
        collateral.approve(address(vault), type(uint256).max);
    }

    function test_oracleCallbackCannotReenterAnyVaultAction() public {
        vm.startPrank(alice);
        vault.depositCollateral(150 ether);
        vault.mintFromWork(100 ether);
        vm.stopPrank();
        assertEq(oracle.blockedCallbacks(), 8);
        assertEq(oracle.mintingRights(alice), 0);
        assertEq(comp.balanceOf(alice), 100 ether);
        (, uint256 debt) = vault.positions(alice);
        assertEq(debt, 0);
        assertEq(vault.totalWorkMinted(), 100 ether);
    }

    function test_revertingOracleRollsBackWorkRightsAndSupply() public {
        oracle.setFail(true);
        vm.startPrank(alice);
        vault.depositCollateral(150 ether);
        vm.expectRevert(AdversarialOracle.OracleOffline.selector);
        vault.mintFromWork(100 ether);
        vm.stopPrank();
        (, uint256 debt) = vault.positions(alice);
        assertEq(debt, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(vault.totalWorkMinted(), 0);
        assertEq(oracle.mintingRights(alice), 100 ether);
        assertEq(oracle.blockedCallbacks(), 0);
    }

    function test_failedAndShortTransfersCannotCreditCollateral() public {
        collateral.configure(vault, AdversarialCollateral.Mode.FalseIn);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(collateral)));
        vault.depositCollateral(10 ether);
        collateral.configure(vault, AdversarialCollateral.Mode.ShortIn);
        vm.prank(alice);
        vm.expectRevert(CDPVault.UnexpectedCollateralReceived.selector);
        vault.depositCollateral(10 ether);
        (uint256 c, uint256 d) = vault.positions(alice);
        assertEq(c, 0);
        assertEq(d, 0);
        assertEq(collateral.balanceOf(alice), 1000 ether);
        assertEq(collateral.balanceOf(address(vault)), 0);
        assertEq(collateral.totalSupply(), 1000 ether);
    }

    function test_transferCallbacksCannotReenterDepositOrWithdrawal() public {
        collateral.configure(vault, AdversarialCollateral.Mode.Callback);
        vm.startPrank(alice);
        vault.depositCollateral(150 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        assertEq(collateral.blockedCallbacks(), 16);
        (uint256 c,) = vault.positions(alice);
        assertEq(c, 0);
        assertEq(collateral.balanceOf(alice), 1000 ether);
    }

    function test_failedOutgoingTransferRollsBackWithdrawal() public {
        vm.prank(alice);
        vault.depositCollateral(150 ether);
        collateral.configure(vault, AdversarialCollateral.Mode.FalseOut);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(collateral)));
        vault.withdrawCollateral(150 ether);
        (uint256 c,) = vault.positions(alice);
        assertEq(c, 150 ether);
        assertEq(collateral.balanceOf(address(vault)), 150 ether);
    }

    function test_failedLiquidationTransferRollsBackBurnAndPosition() public {
        vm.startPrank(alice);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        nhiFeed.setValue(0.6 ether);
        vault.markUnderwater(alice);
        collateral.configure(vault, AdversarialCollateral.Mode.FalseOut);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(collateral)));
        vault.liquidate(alice, 100 ether);
        (uint256 c, uint256 d) = vault.positions(alice);
        assertEq(c, 150 ether);
        assertEq(d, 100 ether);
        assertEq(comp.balanceOf(alice), 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_liquidationTransferCallbackCannotReenter() public {
        vm.startPrank(alice);
        vault.depositCollateral(150 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        nhiFeed.setValue(0.6 ether);
        vault.markUnderwater(alice);
        collateral.configure(vault, AdversarialCollateral.Mode.Callback);
        vm.prank(alice);
        vault.liquidate(alice, 100 ether);
        assertEq(collateral.blockedCallbacks(), 8);
        assertEq(comp.totalSupply(), 0);
    }
}
