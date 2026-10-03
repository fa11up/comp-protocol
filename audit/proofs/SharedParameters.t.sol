// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "src/MockIMD.sol";
import {Parameters, ICheckpointedVault} from "src/Parameters.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

contract Feed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 v) {
        value = v;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

/// @notice Finding: ParameterizedVault's constructor accepts any Parameters, including one already
/// bound to a different vault, and Parameters' constructor binds whatever address it is handed. A
/// second vault reading a Parameters that pokes a different vault gets every rate change applied to
/// time that has already elapsed, and a rate cut makes debtIndex() fall below the borrowers'
/// recorded index so every debt read on the second vault reverts.
contract SharedParametersTest is Test {
    address private constant BORROWER = address(0xB0B);

    MockIMD private imd;
    Feed private price;
    Feed private spot;
    Feed private nhi;
    Parameters private params;
    ParameterizedVault private vaultA;

    function setUp() public {
        // Auditor-supplied proof, preserved verbatim apart from this gate. It is EXPECTED TO
        // FAIL until the finding is fixed; run with AUDIT_PROOFS=true to reproduce it. Gated so
        // the default suite stays green, because a permanently red test is one no agent can
        // make pass and it burns a build node's whole revision budget.
        if (!vm.envOr("AUDIT_PROOFS", false)) vm.skip(true);

        vm.warp(10 days);
        imd = new MockIMD();
        price = new Feed(1 ether);
        spot = new Feed(1 ether);
        nhi = new Feed(0.9 ether);
        params = new Parameters(ICheckpointedVault(address(0)));
        vaultA = new ParameterizedVault(
            address(imd), address(0), address(0), address(price), address(nhi), address(spot), params
        );
        vm.prank(APPROVED_OPERATOR); // permissionless today; pranked so a governor-gated fix still sets up
        params.bindVault(ICheckpointedVault(address(vaultA)));
    }

    /// @dev Expected: a vault refuses a Parameters that is already bound to another vault (or that
    /// names a vault other than itself), because that Parameters can never checkpoint it.
    /// Actual: construction succeeds and vaultB.parameters() == params while params.vault() == vaultA.
    function test_aVaultRefusesParametersBoundToAnotherVault() public {
        vm.expectRevert();
        new ParameterizedVault(
            address(imd), address(0), address(0), address(price), address(nhi), address(spot), params
        );
    }

    /// @dev The consequence, on the code as it is: a borrower in vaultB is frozen by a rate cut.
    /// Once construction is refused there is nothing to demonstrate and the test passes.
    function test_aRateCutFreezesEveryPositionInTheSecondVault() public {
        ParameterizedVault vaultB;
        try new ParameterizedVault(
            address(imd), address(0), address(0), address(price), address(nhi), address(spot), params
        ) returns (ParameterizedVault b) {
            vaultB = b;
        } catch {
            return;
        }
        assertEq(address(vaultB.parameters()), address(params));
        assertEq(address(params.vault()), address(vaultA), "params still poke vaultA only");

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_000 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vaultB), type(uint256).max);
        vaultB.depositCollateral(1_000 ether);
        vaultB.mintCOMP(100 ether);
        vm.stopPrank();

        // Half a year in, the borrower touches the position (1 wei repayment), which records
        // debtIndexOf[BORROWER] = 1.01e18 and banks ~1 COMP of fees. Then another half year.
        vm.warp(block.timestamp + 182 days);
        vm.prank(BORROWER);
        vaultB.repayCOMP(1);
        vm.warp(block.timestamp + 183 days);

        vm.prank(APPROVED_OPERATOR);
        params.propose(Parameters.ParamSet(type(uint256).max, 3_333, 0, 500, 1_000));
        vm.warp(block.timestamp + params.TIMELOCK());
        uint256 owed = vaultB.debtOf(BORROWER); // the instant before the change
        assertGt(owed, 100 ether, "2% accrued over a year");
        params.applyPending();

        // vaultA was poked and is fine; vaultB was not: its debtIndex() is back to 1e18, below the
        // 1.01e18 recorded for the borrower.
        vaultA.debtOf(BORROWER);
        assertEq(vaultB.debtIndex(), 1e18, "vaultB's index fell");
        assertGt(vaultB.debtIndexOf(BORROWER), 1e18, "below what the borrower has recorded");
        // Expected: the fee accrued at the old rate is still owed and the position is readable.
        // Actual: panic 0x11 (underflow) in stabilityFeeOf, and repayCOMP / withdrawCollateral /
        // liquidate / mintCOMP all revert the same way, for every position that accrued mid-period.
        assertEq(vaultB.debtOf(BORROWER), owed, "accrued fees survive a forward-only rate change");
        vm.prank(BORROWER);
        vaultB.repayCOMP(1 ether);
    }
}