// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {BaselineVault} from "./helpers/BaselineVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IWorkOracle} from "../src/interfaces/IWorkOracle.sol";

/// @dev A drop-in IWorkOracle without MockWorkOracle's `vault()` view; must stay acceptable to the vault.
contract PlainOracle is IWorkOracle {
    mapping(address => uint256) public override mintingRights;

    function consumeRights(address account, uint256 amount) external override {
        mintingRights[account] -= amount;
    }
}

contract CDPVaultTest is ProtocolFixture {
    function test_configuration() public view {
        assertEq(address(vault.imdToken()), address(imd));
        assertEq(address(vault.compToken()), address(comp));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.minCR(), 150);
        assertEq(vault.LIQUIDATION_BONUS_PERCENT(), 10);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
    }

    function test_invalidConstructorTokensAndFeeds() public {
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new BaselineVault(
            address(0), address(comp), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new BaselineVault(alice, address(0), address(0), address(priceFeed), address(nhiFeed), address(spotFeed));
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new BaselineVault(address(imd), alice, address(0), address(priceFeed), address(nhiFeed), address(spotFeed));
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new BaselineVault(
            address(imd), address(imd), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new BaselineVault(address(imd), address(comp), address(0), address(0), address(nhiFeed), address(spotFeed));
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new BaselineVault(address(imd), address(comp), address(0), address(priceFeed), alice, address(spotFeed));
    }

    function test_constructorRejectsInvalidOrWrongVaultOracle() public {
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new BaselineVault(address(imd), address(comp), alice, address(priceFeed), address(nhiFeed), address(spotFeed));
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new BaselineVault(
            address(imd), address(comp), address(imd), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        vm.expectRevert(CDPVault.InvalidOracle.selector);
        new BaselineVault(
            address(imd), address(comp), address(oracle), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
    }

    function test_constructorRejectsMissingOrAliasedSpotFeed() public {
        address[4] memory invalidSpots = [address(0), alice, address(priceFeed), address(nhiFeed)];
        for (uint256 i; i < invalidSpots.length; ++i) {
            vm.expectRevert(CDPVault.InvalidFeed.selector);
            new BaselineVault(
                address(imd), address(comp), address(0), address(priceFeed), address(nhiFeed), invalidSpots[i]
            );
        }
    }

    function test_constructorRejectsSharedPriceAndNhiFeed() public {
        // A valid price of 0.5 must never implicitly become the NHI through an aliased feed.
        priceFeed.setValue(0.5 ether);
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new BaselineVault(
            address(imd), address(comp), address(0), address(priceFeed), address(priceFeed), address(spotFeed)
        );
        vm.expectRevert(CDPVault.InvalidFeed.selector);
        new BaselineVault(
            address(imd), address(comp), address(0), address(nhiFeed), address(nhiFeed), address(spotFeed)
        );
        assertEq(vault.minCR(), 150, "distinct NHI remains independent of the price change");
        assertEq(vault.gracePeriod(), 6 hours);
    }

    function test_constructorAcceptsPlainOracleAndCreatesBoundOracleWhenZero() public {
        PlainOracle plain = new PlainOracle();
        CDPVault supplied = new BaselineVault(
            address(imd), address(comp), address(plain), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        assertEq(address(supplied.oracle()), address(plain));
        CDPVault generated = new BaselineVault(
            address(imd), address(comp), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        MockWorkOracle generatedOracle = MockWorkOracle(address(generated.oracle()));
        assertEq(generatedOracle.vault(), address(generated));
        assertEq(generatedOracle.deployer(), OPERATOR);
        assertEq(address(generated.compToken()), address(comp));
        assertEq(address(generated.imdToken()), address(imd));
        assertEq(address(generated.priceFeed()), address(priceFeed));
        assertEq(address(generated.nhiFeed()), address(nhiFeed));
    }

    function test_bothMintChannelsRequireTokenAuthorization() public {
        CompToken freshComp = new CompToken(address(0));
        CDPVault fresh = new BaselineVault(
            address(imd), address(freshComp), address(0), address(priceFeed), address(nhiFeed), address(spotFeed)
        );
        MockWorkOracle freshOracle = MockWorkOracle(address(fresh.oracle()));
        vm.prank(alice);
        imd.approve(address(fresh), 150 ether);
        vm.prank(alice);
        fresh.depositCollateral(150 ether);
        vm.prank(alice);
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintCOMP(1);
        vm.prank(alice);
        vm.expectRevert(CDPVault.NotInitialized.selector);
        fresh.mintFromWork(1);
        vm.startPrank(OPERATOR);
        freshComp.setVault(address(fresh));
        freshOracle.grantRights(alice, 1);
        vm.stopPrank();
        vm.startPrank(alice);
        fresh.mintCOMP(1);
        fresh.mintFromWork(1);
        vm.stopPrank();
        assertEq(freshComp.balanceOf(alice), 2);
        assertEq(fresh.totalWorkMinted(), 1);
    }

    function test_depositAndWithdrawWithoutDebt() public {
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.CollateralDeposited(alice, 25 ether);
        vault.depositCollateral(25 ether);
        _assertPosition(alice, 25 ether, 0);
        assertEq(imd.balanceOf(address(vault)), 25 ether);
        assertEq(vault.collateralRatio(alice), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.CollateralWithdrawn(alice, 25 ether);
        vault.withdrawCollateral(25 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_depositFailureRollsBackPosition() public {
        vm.startPrank(alice);
        imd.approve(address(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.depositCollateral(1);
        imd.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 ether, 1001 ether)
        );
        vault.depositCollateral(1001 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_allActionsRejectZero() public {
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.depositCollateral(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.withdrawCollateral(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.mintCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.mintFromWork(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.repayCOMP(0);
        vm.expectRevert(CDPVault.ZeroAmount.selector);
        vault.liquidate(alice, 0);
    }

    function test_borrowAt150PercentPreservesRightsAndEmitsEvent() public {
        _open(alice, 150 ether, 0);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.COMPMinted(alice, 100 ether);
        vault.mintCOMP(100 ether);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
        assertEq(comp.balanceOf(alice), 100 ether);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(vault.collateralRatio(alice), 150);
    }

    function test_workMintConsumesRightsWithoutCollateralOrDebt() public {
        _establishWorkBacking(vault, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.WorkMinted(alice, 100 ether);
        vault.mintFromWork(100 ether);
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)] + 100 ether);
        assertEq(comp.balanceOf(alice), 100 ether);
        assertEq(vault.totalWorkMinted(), 100 ether);
        assertEq(oracle.mintingRights(alice), 900 ether);
        vm.prank(alice);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(1);
    }

    function test_workMintRejectsInsufficientRightsWithNoStateChange() public {
        _establishWorkBacking(vault, 1000 ether + 1);
        vm.prank(alice);
        vm.expectRevert(CDPVault.InsufficientRights.selector);
        vault.mintFromWork(1000 ether + 1);
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)]);
        assertEq(vault.totalWorkMinted(), 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }

    function test_borrowWithoutAnyWorkRights() public {
        address borrower = address(0xCAFE);
        vm.prank(OPERATOR);
        imd.mint(borrower, 150 ether);
        vm.prank(borrower);
        imd.approve(address(vault), 150 ether);
        _open(borrower, 150 ether, 100 ether);
        _assertPosition(borrower, 150 ether, 100 ether);
        assertEq(oracle.mintingRights(borrower), 0);
        assertEq(vault.totalWorkMinted(), 0);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_workAndBorrowChannelsKeepSupplyAccountingSeparate() public {
        _open(alice, 150 ether, 100 ether);
        _establishWorkBacking(vault, 50 ether);
        vm.prank(alice);
        vault.mintFromWork(50 ether);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)] + 150 ether);
        assertEq(vault.totalWorkMinted(), 50 ether);
        assertEq(oracle.mintingRights(alice), 950 ether);
        vm.prank(alice);
        vault.repayCOMP(100 ether);
        _assertPosition(alice, 150 ether, 0);
        assertEq(comp.totalSupply(), backingPrincipal[address(vault)] + 50 ether);
        assertEq(vault.totalWorkMinted(), 50 ether);
        assertEq(oracle.mintingRights(alice), 950 ether);
    }

    function test_staleEitherFeedBlocksBothMintChannelsButAllowsRepayment(bool stalePrice) public {
        _open(alice, 200 ether, 100 ether);
        if (stalePrice) priceFeed.setStale(true);
        else nhiFeed.setStale(true);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.mintFromWork(1);
        vm.expectRevert(CDPVault.StaleFeed.selector);
        vault.withdrawCollateral(1);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(200 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(vault.totalWorkMinted(), 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_zeroPriceBlocksBothMintChannelsButAllowsRepayment() public {
        _open(alice, 150 ether, 100 ether);
        priceFeed.setValue(0);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.InvalidPrice.selector);
        vault.mintFromWork(1);
        vault.repayCOMP(100 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        assertEq(comp.totalSupply(), 0);
    }

    function test_mintRejectsInsufficientCollateralIncludingExistingDebt() public {
        vm.prank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        _open(alice, 150 ether, 100 ether);
        vm.prank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_roundingCannotUndercollateralizeOneWeiDebt() public {
        _open(alice, 1, 0);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.mintCOMP(1);
        vault.depositCollateral(1);
        vault.mintCOMP(1);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(1);
        vm.stopPrank();
        assertEq(vault.collateralRatio(alice), 200);
    }

    function test_withdrawChecksPositionAndResultingRatio() public {
        _open(alice, 200 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(201 ether);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(50 ether + 1);
        vault.withdrawCollateral(50 ether);
        vm.stopPrank();
        _assertPosition(alice, 150 ether, 100 ether);
        vm.prank(bob);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
    }

    function test_unsafeWithdrawalCannotEnableLiquidation() public {
        _open(alice, 200 ether, 100 ether);
        vm.startPrank(alice);
        comp.transfer(bob, 100 ether);
        vm.expectRevert(CDPVault.UnsafeCollateralRatio.selector);
        vault.withdrawCollateral(70 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 50 ether);
        _assertPosition(alice, 200 ether, 100 ether);
        assertEq(comp.balanceOf(bob), 100 ether);
        assertEq(imd.balanceOf(address(vault)), 200 ether);
    }

    function test_partialAndFullRepaymentWithoutApprovalPreservesWorkRights() public {
        _open(alice, 150 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CDPVault.COMPRepaid(alice, 40 ether);
        vault.repayCOMP(40 ether);
        _assertPosition(alice, 150 ether, 60 ether);
        assertEq(comp.totalSupply(), 60 ether);
        assertEq(comp.allowance(alice, address(vault)), 0);
        vault.repayCOMP(60 ether);
        vault.withdrawCollateral(150 ether);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(oracle.mintingRights(alice), 1000 ether);
        assertEq(imd.balanceOf(alice), 1000 ether);
    }

    function test_repaymentRejectsExcessDebtAndInsufficientBalanceAtomically() public {
        _open(alice, 150 ether, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(100 ether + 1);
        comp.transfer(bob, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vault.repayCOMP(1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(CDPVault.ExcessRepayment.selector);
        vault.repayCOMP(1);
        _assertPosition(alice, 150 ether, 100 ether);
        assertEq(comp.totalSupply(), 100 ether);
    }

    function test_liquidationRejectsDebtFreeExactly150AndAbove150() public {
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        _open(alice, 150 ether, 100 ether);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        vm.prank(alice);
        vault.depositCollateral(1 ether);
        vm.expectRevert(CDPVault.HealthyPosition.selector);
        vault.liquidate(alice, 1);
        _assertPosition(alice, 151 ether, 100 ether);
    }

    function test_directDonationDoesNotCreateWithdrawableCollateral() public {
        vm.prank(alice);
        imd.transfer(address(vault), 50 ether);
        _assertPosition(alice, 0, 0);
        vm.prank(alice);
        vm.expectRevert(CDPVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
    }

    function testFuzz_depositMintRepayWithdrawSequence(uint256 c, uint256 d, uint256 r, uint256 w) public {
        c = bound(c, 2, 1e36);
        d = bound(d, 1, c * 2 / 3);
        r = bound(r, 0, d);
        vm.startPrank(OPERATOR);
        imd.mint(alice, c);
        vm.stopPrank();
        _open(alice, c, d);
        vm.startPrank(alice);
        if (r != 0) vault.repayCOMP(r);
        uint256 remainingDebt = d - r;
        uint256 requiredCollateral = remainingDebt + remainingDebt / 2 + remainingDebt % 2;
        w = bound(w, 0, c - requiredCollateral);
        if (w != 0) vault.withdrawCollateral(w);
        _assertPosition(alice, c - w, remainingDebt);
        assertEq(comp.totalSupply(), remainingDebt);
        assertGe(vault.collateralRatio(alice), 150);
        if (remainingDebt != 0) vault.repayCOMP(remainingDebt);
        if (c != w) vault.withdrawCollateral(c - w);
        vm.stopPrank();
        _assertPosition(alice, 0, 0);
        assertEq(comp.totalSupply(), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(alice), 1000 ether + c);
        assertEq(oracle.mintingRights(alice), 1000 ether);
    }
}
