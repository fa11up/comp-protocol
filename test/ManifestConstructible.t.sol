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
    /// @dev The explicit opt-in the manifest now passes instead of a literal address.
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

        assertGt(address(vault.imdToken()).code.length, 0, "the vault deployed its own collateral");
        // The faucet's authority is a source constant, so a fresh one is as usable as the reused one.
        assertEq(MockIMD(address(vault.imdToken())).deployer(), APPROVED_OPERATOR);
        // Everything else the vault creates is wired to it, with nothing sent after construction.
        assertEq(vault.compToken().vault(), address(vault));
        assertEq(address(vault.parameters().vault()), address(vault));
        assertEq(address(vault.usdPriceFeed().imdEthFeed()), p);
        assertGt(address(vault.treasury()).code.length, 0);
    }
}
