// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {MockIMD} from "src/MockIMD.sol";
import {TestSwarmFeed} from "./helpers/TestSwarmFeed.sol";
import {MirroredSwarmFeed} from "./helpers/MirroredSwarmFeed.sol";
import {TreasuryFactoryEtch} from "./helpers/TreasuryFactoryEtch.sol";
import {TREASURY_FACTORY} from "src/DeploymentConfig.sol";

/// @dev A factory that returns a Treasury serving someone else.
contract ForeignTreasuryFactory {
    function create() external returns (Treasury) {
        return new Treasury(address(0xF0E));
    }
}

/// @notice The vault creates its Treasury through TREASURY_FACTORY, for the EIP-3860 initcode limit.
contract TreasuryFactoryTest is Test {
    function _vault() private returns (ParameterizedVault) {
        TestSwarmFeed primary = new TestSwarmFeed(0.001 ether);
        return new ParameterizedVault(
            address(new MockIMD()), address(0), address(0), address(primary), address(new TestSwarmFeed(0.9 ether)),
            address(new MirroredSwarmFeed(address(primary)))
        );
    }

    function test_aTreasuryServesWhoeverAskedForIt() public {
        TreasuryFactory factory = new TreasuryFactory();
        address stranger = address(0x5157);
        vm.prank(stranger);
        Treasury t = factory.create();
        assertEq(t.vault(), stranger, "the caller, never the factory");
        assertEq(t.registrar(), address(0), "a caller with no parameters() governs nothing");
    }

    function test_theVaultsTreasuryIsLinkedBothWays() public {
        TreasuryFactoryEtch.etch(vm);
        ParameterizedVault vault = _vault();
        Treasury t = vault.treasury();
        assertEq(t.vault(), address(vault));
        assertEq(t.registrar(), address(vault.parameters()), "the vault's Parameters governs the register");
        assertEq(vault.feeRecipient(), address(t), "both revenue streams land in it");
    }

    function test_aVaultCannotBeBuiltWithoutTheFactory() public {
        assertEq(TREASURY_FACTORY.code.length, 0);
        TestSwarmFeed primary = new TestSwarmFeed(0.001 ether);
        address imd = address(new MockIMD());
        address health = address(new TestSwarmFeed(0.9 ether));
        address spot = address(new MirroredSwarmFeed(address(primary)));
        vm.expectRevert(ParameterizedVault.TreasuryFactoryMissing.selector);
        new ParameterizedVault(imd, address(0), address(0), address(primary), health, spot);
    }

    /// @dev The point of the factory: the vault's initcode no longer carries the Treasury's.
    function test_theVaultsInitcodeFitsEip3860WithRoom() public pure {
        uint256 size = type(ParameterizedVault).creationCode.length;
        // 3 KB since the sweep panel fixes (banked warmth, the burn tally, the drained-position bite):
        // 45,741 bytes of initcode against the 49,152 cap.
        // 1 KB since the final sweep panel (2026-10-09): the margin was reserved for audit fixes, and the paced
        // payout price, the cancellation-aware clamp and the permissionless re-price (records 24 and 25) took it;
        // what is left is for the last corrections before the deploy commit is frozen, not for features.
        assertLt(size, 49_152 - 1_024, "keep at least 1 KB of headroom under EIP-3860");
    }

    /// @dev F10 (launch audit, governance panel). The vault trusted whatever TREASURY_FACTORY returned.
    /// It now refuses a Treasury that does not serve it.
    function test_aTreasuryServingAnotherVaultIsRefused() public {
        vm.etch(TREASURY_FACTORY, address(new ForeignTreasuryFactory()).code);
        TestSwarmFeed primary = new TestSwarmFeed(0.001 ether);
        address imd = address(new MockIMD());
        address health = address(new TestSwarmFeed(0.9 ether));
        address spot = address(new MirroredSwarmFeed(address(primary)));
        vm.expectRevert(ParameterizedVault.TreasuryNotOurs.selector);
        new ParameterizedVault(imd, address(0), address(0), address(primary), health, spot);
    }
}
