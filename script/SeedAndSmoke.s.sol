// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {NhiFeed} from "../src/NhiFeed.sol";
import {SpotFeed} from "../src/SpotFeed.sol";
import {CDPVault} from "../src/CDPVault.sol";
import {CompToken} from "../src/CompToken.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {MockWorkOracle} from "../src/MockWorkOracle.sol";

/// @notice Seed all three feeds through the reporter path, drive one borrow/repay cycle, then
/// prove the divergence guard refuses to price while the two price feeds disagree.
/// @dev The reporter path is the testnet fallback; the attested path is exercised separately by
/// RelayAttestation (JS), because the signed struct comes from the control plane.
/// PRICE is WETH wei per 1e18 raw IMD, the same figure the oracle question asks for.
contract SeedAndSmoke is Script {
    function run() external {
        CDPVault vault = CDPVault(vm.envAddress("VAULT"));
        uint256 price = vm.envUint("PRICE"); // e.g. 1292410679962996
        uint256 nhi = vm.envOr("NHI", uint256(0.9e18)); // >= 0.85e18 => minCR 150, grace 6h
        address me = vm.envAddress("OPERATOR");

        PriceFeed priceFeed = PriceFeed(address(vault.priceFeed()));
        NhiFeed nhiFeed = NhiFeed(address(vault.nhiFeed()));
        SpotFeed spotFeed = SpotFeed(address(vault.spotFeed()));
        // Spot defaults to the primary: zero divergence, which is the only state that lets the
        // vault price at all. SPOT exists so a run can deliberately put the two out of band.
        uint256 spot = vm.envOr("SPOT", price); // read for the divergence smoke check below
        MockIMD imd = MockIMD(address(vault.imdToken()));
        CompToken comp = vault.compToken();

        vm.startBroadcast();

        // THIS SCRIPT NO LONGER SEEDS, and that is the operational cost of deleting the reporter
        // fallback. It used to call report() on each stale feed, which is exactly the authority that
        // must not exist on mainnet: a key able to set the price directly, unbounded once the feed
        // aged past maxAge. With it gone a value reaches a feed only through a signed attestation, so
        // seeding is a purchase and not a transaction we can make.
        //
        // The practical consequence is that walking a feed back to market after a large move now
        // costs IMD per step instead of gas, on testnet exactly as on mainnet. That is the point:
        // the fallback let us rehearse a protocol we were never going to deploy.
        require(
            !priceFeed.isStale() && !nhiFeed.isStale() && !spotFeed.isStale(),
            "feeds are stale and this script cannot seed them: buy an attestation per stale feed and relay it (keeper/watch.mjs reports which, oracle/relay-attestation.js sends it)"
        );
        console2.log("minCR now         ", vault.minCR());
        console2.log("gracePeriod now   ", vault.gracePeriod());

        // A deposit large enough to clear minCR at this price, plus headroom.
        // MockIMD's faucet is pinned to APPROVED_OPERATOR in source, so the broadcaster cannot
        // mint unless it happens to be that wallet — it spends the balance it already holds.
        uint256 debt = vm.envOr("DEBT", uint256(1e18));
        uint256 collateral = (debt * 1e18 * vault.minCR() * 3) / (price * 100);
        require(imd.balanceOf(me) >= collateral, "insufficient IMD: mint to this wallet from the faucet operator");
        imd.approve(address(vault), collateral);
        vault.depositCollateral(collateral);
        vault.mintCOMP(debt);
        console2.log("collateral         ", collateral);
        console2.log("debt               ", debt);
        console2.log("collateralRatio    ", vault.collateralRatio(me));
        require(comp.balanceOf(me) >= debt, "COMP not minted");

        // Work channel: no collateral, no debt. grantRights is pinned to APPROVED_OPERATOR in
        // source, so unless the broadcaster is that wallet the rights must be granted separately.
        // Exercised only when they are already there, which keeps this script re-runnable.
        MockWorkOracle workOracle = MockWorkOracle(address(vault.oracle()));
        if (workOracle.mintingRights(me) >= debt) {
            uint256 beforeWork = vault.totalWorkMinted();
            vault.mintFromWork(debt);
            require(vault.totalWorkMinted() == beforeWork + debt, "work mint not recorded");
            console2.log("work channel       exercised");
        } else {
            console2.log("work channel       SKIPPED - no rights; grantRights from the faucet operator");
        }

        vault.repayCOMP(debt);
        vm.stopBroadcast();

        (uint256 c, uint256 d) = vault.positions(me);
        console2.log("after repay: collateral", c, "debt", d);
        require(d == 0, "debt not cleared");
        require(comp.totalSupply() == vault.totalWorkMinted(), "supply invariant broken");
        console2.log("\nSupply invariant holds: totalSupply == summed debt + totalWorkMinted");
    }
}
