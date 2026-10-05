// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {ImdUSD} from "../src/ImdUSD.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {APPROVED_OPERATOR} from "../src/DeploymentConfig.sol";

/// @dev Stands in for anything that marks on a keeper's behalf — a relay bundling the feed update
/// with the mark, a router, a batcher. It holds nothing and has no way to move a token, which is
/// exactly why being recorded as the marker would strand the reward.
contract Forwarder {
    function markVia(CDPVault vault, address owner) external {
        vault.bark(owner);
    }

    function markForVia(CDPVault vault, address owner, address beneficiary) external {
        vault.barkFor(owner, beneficiary);
    }
}

contract MarkerBeneficiaryTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);
    address private constant LIQUIDATOR = address(0x1A1D);

    BaselineVault private vault;
    MockIMD private imd;
    ImdUSD private comp;
    TestSwarmFeed private price;
    TestSwarmFeed private nhi;
    TestSwarmFeed private spot;
    Forwarder private forwarder;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        imd = new MockIMD();
        price = new TestSwarmFeed(1 ether);
        spot = new TestSwarmFeed(1 ether);
        nhi = new TestSwarmFeed(0.6 ether); // mat 200, grace 0
        vault = new BaselineVault(address(imd), address(0), address(0), address(price), address(nhi), address(spot));
        comp = vault.stablecoin();
        forwarder = new Forwarder();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 300 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.lock(300 ether);
        vault.draw(150 ether); // CR 200
        comp.transfer(LIQUIDATOR, 150 ether);
        vm.stopPrank();
        price.setValue(0.9 ether);
        spot.setValue(0.9 ether);
    }

    function _marker() private view returns (address marker) {
        (,,, marker) = vault.liquidationMarks(BORROWER);
    }

    function test_theOneArgumentFormStillCreditsTheCaller() public {
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        assertEq(_marker(), KEEPER, "unchanged for anyone calling directly");
    }

    function test_aCallerMayCreditSomeoneElse() public {
        vm.prank(KEEPER);
        vault.barkFor(BORROWER, LIQUIDATOR);
        assertEq(_marker(), LIQUIDATOR, "a caller can only give away its own share");
    }

    function test_aZeroBeneficiaryIsRefused() public {
        vm.prank(KEEPER);
        vm.expectRevert(CDPVault.InvalidBeneficiary.selector);
        vault.barkFor(BORROWER, address(0));
    }

    /// @dev The defect this exists to prevent. Marking through a contract records THAT CONTRACT, and
    /// the marker's share is paid at liquidation — to a forwarder that cannot move a token.
    function test_markingThroughAContractWouldStrandTheReward() public {
        forwarder.markVia(vault, BORROWER);
        assertEq(_marker(), address(forwarder), "the contract is recorded, not the keeper");

        uint256 before = imd.balanceOf(address(forwarder));
        vm.prank(LIQUIDATOR);
        vault.bite(BORROWER, 50 ether);
        uint256 stranded = imd.balanceOf(address(forwarder)) - before;

        assertGt(stranded, 0, "the marker share is paid to the forwarder");
        assertEq(imd.balanceOf(KEEPER), 0, "and the keeper that caused the mark gets nothing");
    }

    /// @dev And the fix: the same call, naming the keeper, pays the keeper.
    function test_markingThroughAContractForTheKeeperPaysTheKeeper() public {
        forwarder.markForVia(vault, BORROWER, KEEPER);
        assertEq(_marker(), KEEPER);

        vm.prank(LIQUIDATOR);
        vault.bite(BORROWER, 50 ether);

        uint256 px = 0.9 ether;
        uint256 repaid = 50 ether;
        uint256 bonus = repaid * (100 + vault.CHOP_PERCENT()) * 1e16 / px - repaid * 1e18 / px;
        assertEq(imd.balanceOf(KEEPER), bonus * vault.chip() / 10_000, "exactly the marker share");
        assertEq(imd.balanceOf(address(forwarder)), 0, "and nothing is stranded in the forwarder");
    }
}
