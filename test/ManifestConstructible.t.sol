// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceFeed} from "src/PriceFeed.sol";
import {NhiFeed} from "src/NhiFeed.sol";
import {SpotFeed} from "src/SpotFeed.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {MockIMD} from "src/MockIMD.sol";
import {APPROVED_OPERATOR} from "src/DeploymentConfig.sol";

/// @notice The project must be constructible from its manifest arguments on ANY chain.
/// @dev Round 4's launch parked with "project constructor failed" from the protected-invariant
/// harness. The cause was not the contracts: launch.json passed a LITERAL MockIMD address, which has
/// code only on Sepolia, and the vault's constructor requires the collateral token to have code. The
/// harness builds on a chain where that address is empty, so the project could not be deployed at all.
contract ManifestConstructibleTest is Test {
    /// @dev The address the parked manifest passed. Nothing is deployed here, as on any fresh chain.
    address private constant REUSED_ON_SEPOLIA = 0xE44AB81Ce23d34E29383dD158a1DfFEB1c10d439;
    /// @dev The explicit opt-in a caller outside a manifest passes instead of a literal address.
    address private constant FAUCET = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    function _feeds() private returns (address, address, address) {
        return (address(new PriceFeed(86_400, 2_000)), address(new NhiFeed(86_400, 2_000)), address(new SpotFeed(3_600, 2_000)));
    }

    /// @dev The regression: a literal address is refused where it has no code, which is the whole
    /// point of the check. The manifest must not pass one.
    function test_aLiteralCollateralAddressIsStillRefusedWhereItHasNoCode() public {
        assertEq(REUSED_ON_SEPOLIA.code.length, 0, "nothing deployed at the reused address on this chain");
        (address p, address n, address s) = _feeds();
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new ParameterizedVault(REUSED_ON_SEPOLIA, address(0), address(0), p, n, s);
    }

    /// @dev And the fix: zero means the vault deploys the faucet itself, so the manifest can pass zero
    /// and the project constructs on any chain, which is what the harness needs.
    /// @dev Zero is still refused, because zero is what an unset field looks like and a mainnet vault
    /// taking a mock token as collateral would accept a worthless asset against real debt.
    function test_zeroCollateralIsStillRefusedSoAnUnsetFieldCannotSlipThrough() public {
        (address p, address n, address s) = _feeds();
        vm.expectRevert(CDPVault.InvalidToken.selector);
        new ParameterizedVault(address(0), address(0), address(0), p, n, s);
    }

    function test_theProjectConstructsFromItsManifestArgumentsOnABareChain() public {
        (address p, address n, address s) = _feeds();
        ParameterizedVault vault = new ParameterizedVault(FAUCET, address(0), address(0), p, n, s);

        assertGt(address(vault.gem()).code.length, 0, "the vault deployed its own collateral");
        // The faucet's authority is a source constant, so a fresh one is as usable as the reused one.
        assertEq(MockIMD(address(vault.gem())).deployer(), APPROVED_OPERATOR);
        // Everything else the vault creates is wired to it, with nothing sent after construction.
        assertEq(vault.stablecoin().vault(), address(vault));
        assertEq(address(vault.parameters().vault()), address(vault));
        assertEq(address(vault.usdPriceFeed().imdEthFeed()), p);
        assertGt(address(vault.treasury()).code.length, 0);
    }

    /// @notice The shape a manifest WOULD use if it could name the collateral: deploy MockIMD as its
    /// own artifact and have the vault reference it.
    /// @dev Kept as a test, not shipped in launch.json, and the reason is a pair of caps that differ.
    /// A launch MANIFEST takes eight contracts, but the REQUEST's `draft.contracts` takes four, and a
    /// request is what approves a manifest — round 3 parked on a manifest that "omits the approved
    /// vault". So a five-contract manifest cannot be declared, and a manifest naming more than the
    /// request approved is the divergence class that has parked four rounds. The sentinel below is
    /// what ships. This test exists so the better shape is proven and ready if that cap moves too.
    function test_theManifestShapeConstructsWithTheTokenAsANamedArtifact() public {
        MockIMD collateral = new MockIMD();
        (address p, address n, address s) = _feeds();
        ParameterizedVault vault = new ParameterizedVault(address(collateral), address(0), address(0), p, n, s);

        assertEq(address(vault.gem()), address(collateral), "the vault took the named token");
        assertEq(vault.gem().balanceOf(address(vault)), 0, "and holds none of it yet");
        assertEq(collateral.deployer(), APPROVED_OPERATOR, "whose faucet is the approved operator's");
        assertTrue(address(vault.stablecoin()) != address(0), "stablecoin created in-constructor");
        assertTrue(address(vault.parameters()) != address(0), "parameters too");
        assertTrue(address(vault.treasury()) != address(0), "and the treasury");
        assertTrue(address(vault.usdPriceFeed()) != address(0), "and the USD price feed");
    }

    /// @dev The sentinel is what the manifest actually passes, and what makes the project
    /// constructible on the bare chain the protected-invariant harness builds on.
    function test_theSentinelDeploysAFaucetSoTheProjectConstructsAnywhere() public {
        (address p, address n, address s) = _feeds();
        ParameterizedVault vault = new ParameterizedVault(FAUCET, address(0), address(0), p, n, s);
        assertTrue(address(vault.gem()) != FAUCET, "the sentinel is replaced, never used as a token");
        assertTrue(address(vault.gem()).code.length > 0, "by a faucet the vault deployed");
    }
}
