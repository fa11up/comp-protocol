# Launch audit — governance panel (2026-10-05)

Job `ae08d373-e004-4a5f-99a2-34bb602b4599` (order 1bf116ff), `template: audit` at `e52a025`: four specialists and a judge, accepted; models claude-fable-5-1. Raw submissions: `audit-governance-2026-10-05` json beside this file.

**Kept: 1 medium, 3 low, 11 info.**

## Judge's summary

The review is complete and `.imd-findings.json` holds 15 verified findings, 3 of them with Foundry proofs that fail on the committed code.

**What I did.** I read Treasury, Parameters, Governed, TreasuryFactory, ParameterizedVault, CDPVault, ImdUSD, DeploymentConfig, SharePriceFeed and UsdPriceFeed in full, plus the three interfaces they use. I ran all four specialist proofs (all fail as claimed), then wrote my own scratch tests for the items no proof covered. The project's own suite stays green at 490 passed, 2 skipped, with the scratch files excluded. I could not reach StakedIMD itself, since no fork is available; the fundOracle finding relies on the hold behaviour the repo's own fork tests record.

**Kept, after merging duplicates across the four specialists:**

- **Medium.** A drained borrower who locks 1 wei (unseizable at mainnet sIMD prices) or enough to be healthy makes `cover` revert forever, and the Treasury's imdUSD up to `totalBadDebt` is frozen against withdraw and the stream. Three specialists reported it; I confirmed both variants. Proof attached (sIMD-shaped fixture).
- **Low.** `cover` burns Treasury imdUSD outside the sync accounting, so later fee receipts are dropped from `totalReceived`. Four specialists; proof attached.
- **Low.** The register accepts the collateral against any feed. Listing sIMD through `usdPriceFeed` values one share at about $10.9M instead of $86.81, inflating `earnLine` about 125,000x. Two specialists; I wrote and ran the proof.
- **Low.** `fundOracle` unwraps shares, so a one-wei sIMD transfer in the same block can block the oracle budget via the inherited hold. Reproduced against a mock modelling the documented hold, with that caveat stated. Unreachable until the asker is deployed.
- **Info (11).** The `reserveValueUsd` never-reverts claim versus mulDiv overflow, the unchecked factory return, seven stale or misattached NatSpec blocks, the 5.5% comment, stale runbook constants, and a dead return value.

**Dropped or merged.** Nothing a specialist reported failed to reproduce. The four cover-sync reports, the three dust-lock reports, and the repeated NatSpec items were each collapsed into one finding. For the dust-lock fix I rejected one specialist's suggestion to simply drop the collateral check, since that would let Treasury imdUSD repay a collateralised borrower.

**Answers to the seven questions where nothing was wrong.** The timelock cannot be shortened or widened and only the operator proposes; a reserve-asset proposal can be stalled only by the listed token or feed refusing to answer, and the late-application window is a previously recorded note. Every Treasury exit is bounded as documented, and the stream cannot exceed its daily cap through rounding, day boundaries or a rate change. Native and ERC-20 sync accounting is sound except for the cover path. Decimals handling in the register is correct for every asset other than the mis-fed collateral case. The factory cannot hand anyone a Treasury a vault trusts. The launch fee hand-off is operator-only and moves only future fees. Bad-debt-first ordering holds across withdraw, payStream and cover within a transaction and across days.

## 1. [medium] A drained borrower who re-collateralises makes cover unreachable and freezes Treasury imdUSD up to totalBadDebt against withdraw and payStream

`src/CDPVault.sol:488`

CDPVault.cover (reached on ParameterizedVault, whose _surplus() is its Treasury) is the only path that spends the imdUSD Treasury.withdraw (line 327, BadDebtFirst) and Treasury.payStream (line 358, spare = balance - owed) hold back for the vault's totalBadDebt. It refuses any position whose collateral is nonzero. lock() and lockIMD() accept any amount into any position with no health check and no minimum, including a position bite() has just drained to zero with its residual recorded in totalBadDebt. The borrower of that position therefore decides whether the record can ever be retired:
(a) Dust. With the committed constants (CHOP_PERCENT 20, sIMD with 24 decimals priced per 1e18 raw units, about 8.68e13 at IMD = $10.92) the seizure for ONE wei of debt is mulDiv(1, 1.2e18, price) = roughly 13,800 to 30,000 raw share units, so after the borrower locks 1 wei (or anything below that figure) bite() reverts InsufficientCollateral for every debtToRepay >= 1, the sweep in bite() sits after that check and never runs, _redeemPosition refuses it (RedemptionWorsensRatio), and cover() reverts NoRealizedBadDebt. _reduceDebt keeps the recorded figure (min(previous, current) once collateral != 0), so totalBadDebt still counts the loss. Cost to the griefer: one wei plus gas, after a default that already realised the loss. It also front-runs any specific cover() transaction.
(b) Health. Locking enough collateral to be healthy (ratio >= mat) makes the position unmarkable (bark reverts HealthyPosition), so nothing but the borrower's own wipe can ever lower totalBadDebt, while cover still reverts because collateral != 0.
In both cases the Treasury's imdUSD up to the recorded amount is permanently unavailable to the operator (withdraw reverts BadDebtFirst), to the stream (payStream pays only what is above the record) and to cover. No funds are lost and the frozen imdUSD stays in the Treasury, so this is a liveness and griefing defect on protocol revenue and on the protocol's ability to heal unbacked supply, not a theft. Reachable with the constants as committed; three specialists reported it independently (two as medium, one as low) and the reproductions agree.
Smallest fix for (a): in cover(), treat collateral below the single-wei seizure, Math.mulDiv(1, (100 + CHOP_PERCENT) * 1e16, _price()), as drained: sweep it to the payer (or leave it) and proceed; keep NoRealizedBadDebt for anything larger. Do NOT simply drop the collateral != 0 check, since that would let Treasury imdUSD repay a borrower whose debt is backed by collateral. For (b) the Treasury's reservation should read only the bad debt cover can actually reach (a vault accumulator of recorded bad debt on zero-collateral positions, maintained where collateral crosses zero and in _reduceDebt's recapitalised branch), or lock()/lockIMD() should refuse deposits while _recordedBadDebt[owner] != 0 so a drained borrower must repay before re-collateralising. The second changes vault behaviour and is the requester's call; the attached proof passes with the sweep fix alone.

**Reproduction**

Fixture (test/scratch, attached proof): gem = sIMD-shaped share (24 decimals, convertToAssets(1e18) = 7.95e12), IMD/ETH 5.46e15 (IMD = $10.92 at ETH $2000), NHI 0.85 (mat 170, grace 6h). BORROWER lockIMD(7950e18) -> 1e27 raw shares (~$86,814), draw(50,000e18). KEEPER lockIMD(79,500e18), draw(300,000e18). IMD falls to $5 (primary 2.5e15): bark(BORROWER); +6h; KEEPER bite(BORROWER, 33,125e18) seizes exactly 1e27: collateral 0, totalBadDebt about 16,877e18 (recorded). KEEPER transfers 20,000e18 imdUSD to the Treasury. BORROWER deposits 1e18 IMD into the share vault, obtains shares and calls vault.lock(1): accepted. Then bark + 6h + bite(BORROWER, 1) reverts InsufficientCollateral (seizure 30,188 raw units > 1). EXPECTED: cover(BORROWER, debtOf(BORROWER)) retires the loss (totalBadDebt == 0) and the operator may then withdraw the Treasury's imdUSD. ACTUAL: cover reverts NoRealizedBadDebt(); Treasury.withdraw(imdUSD, operator, balance - bad + 1) reverts BadDebtFirst(16,877e18); payStream pays nothing above the record. Variant (b), reproduced in test/scratch/JudgeChecks.t.sol test_healthyRecollateralisationFreezesTreasuryImdUSD: after the same drain the price recovers and BORROWER lockIMD(7950e18) again (ratio > 170). totalBadDebt still 16,877e18; cover(BORROWER, 1e18) reverts NoRealizedBadDebt; bark(BORROWER) reverts HealthyPosition; withdraw of (balance - bad + 1) reverts BadDebtFirst(bad); withdraw of (balance - bad) succeeds, leaving exactly `bad` imdUSD frozen, still frozen 365 days later. The attached proof (Proof_8dddc7a7b3a0.t.sol) fails on the committed code with NoRealizedBadDebt().

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract Imd is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev sIMD-shaped: 24 decimals, `rate` = IMD raw per 1e18 share raw (7.95 IMD per whole share).
contract Share is ERC20 {
    IERC20 public immutable underlying;
    uint256 public immutable rate;

    constructor(IERC20 underlying_, uint256 rate_) ERC20("Staked IMD", "sIMD") {
        underlying = underlying_;
        rate = rate_;
    }

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf(owner) * rate / 1e18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets * 1e18 / rate;
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "owner only");
        shares = (assets * 1e18 + rate - 1) / rate;
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }
}

contract Feed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 initial) {
        set(initial);
    }

    function set(uint256 next) public {
        value = next;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract Aggregator {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice A liquidated borrower locks ONE WEI of sIMD into their drained position. At real sIMD
/// prices (about $86.8 per whole share, i.e. 8.68e13 per 1e18 raw units) the seizure for a single
/// wei of debt is ~30,000 raw share units, so no `bite` can ever touch that wei; `cover` refuses the
/// position because its collateral is nonzero; and totalBadDebt keeps the full residual forever,
/// which is the floor `Treasury.withdraw` and `payStream` hold imdUSD under. Expected: the realized
/// loss stays coverable and the floor can be cleared. Actual: NoRealizedBadDebt, forever.
contract DustLockBlocksCoverTest is Test {
    address private constant BORROWER = address(0xB0B);
    address private constant KEEPER = address(0xCAFE);

    Imd private imd;
    Share private share;
    Feed private primary;
    Feed private nhi;
    Feed private spot;
    Aggregator private usd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    Treasury private treasury;

    function setUp() public {
        vm.warp(1_000_000);
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new Aggregator()).code);
        usd = Aggregator(CHAINLINK_ETH_USD);
        usd.set(2000e8);

        imd = new Imd();
        share = new Share(imd, 7.95e12); // 1e24 raw sIMD = 7.95e18 raw IMD
        primary = new Feed(5.46e15); // IMD in wei of ETH: $10.92 at $2000/ETH
        spot = new Feed(5.46e15);
        nhi = new Feed(0.85e18); // mat 170, grace 6 hours
        vault = new ParameterizedVault(
            address(share), address(0), address(0), address(primary), address(nhi), address(spot)
        );
        stable = vault.stablecoin();
        treasury = vault.treasury();
    }

    function _stake(address who, uint256 assets) private {
        imd.mint(who, assets);
        vm.startPrank(who);
        imd.approve(address(vault), assets);
        vault.lockIMD(assets);
        vm.stopPrank();
    }

    function test_oneWeiOfCollateralMustNotStrandRealizedBadDebt() public {
        // Borrower: 1,000 sIMD ($86,814) against $50,000 of imdUSD, 173%.
        _stake(BORROWER, 7_950e18);
        vm.prank(BORROWER);
        vault.draw(50_000e18);
        // Keeper: holds imdUSD to liquidate with and to fund the Treasury.
        _stake(KEEPER, 79_500e18);
        vm.prank(KEEPER);
        vault.draw(300_000e18);

        // IMD falls to $5: the borrower's collateral is worth $39,750 against $50,000 of debt.
        primary.set(2.5e15);
        spot.set(2.5e15);
        vault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        usd.set(2000e8);
        // Largest coverable debt at this price drains the position exactly.
        vm.prank(KEEPER);
        vault.bite(BORROWER, 33_125e18);
        (uint256 collateral,) = vault.positions(BORROWER);
        assertEq(collateral, 0, "drained");
        uint256 bad = vault.totalBadDebt();
        assertGt(bad, 16_000e18, "about $16.9k of realized bad debt");

        // The Treasury holds more imdUSD than the loss.
        vm.prank(KEEPER);
        stable.transfer(address(treasury), 20_000e18);

        // The borrower acquires one wei of sIMD and deposits it into the drained position.
        imd.mint(BORROWER, 1e18);
        vm.startPrank(BORROWER);
        imd.approve(address(share), 1e18);
        share.deposit(1e18, BORROWER);
        share.approve(address(vault), 1);
        (bool accepted,) = address(vault).call(abi.encodeCall(CDPVault.lock, (1)));
        vm.stopPrank();
        accepted; // whether or not the vault accepts the dust, the loss must remain coverable

        // No liquidation can reach one wei: the seizure for one wei of debt is 1.2e18 / 3.975e13
        // = 30,188 raw share units, so bite(1) reverts InsufficientCollateral.
        vault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        usd.set(2000e8);
        (uint256 dust,) = vault.positions(BORROWER);
        if (dust != 0) {
            vm.prank(KEEPER);
            vm.expectRevert(CDPVault.InsufficientCollateral.selector);
            vault.bite(BORROWER, 1);
        }

        // Expected: the realized loss is still coverable from the protocol's surplus. Actual today:
        // NoRealizedBadDebt, and totalBadDebt (the imdUSD floor) can never be cleared. (`debtOf`
        // rather than `totalBadDebt`: the record does not include fees accrued since the bite.)
        vault.cover(BORROWER, vault.debtOf(BORROWER));
        assertEq(vault.totalBadDebt(), 0, "the loss is retired");
        uint256 held = stable.balanceOf(address(treasury));
        vm.prank(APPROVED_OPERATOR);
        treasury.withdraw(IERC20(address(stable)), APPROVED_OPERATOR, held);
        assertEq(stable.balanceOf(address(treasury)), 0, "nothing is held for a loss that was retired");
    }
}
```

## 2. [low] cover burns Treasury imdUSD outside the Treasury's receipt accounting, so revenue arriving afterwards is dropped from totalReceived

`src/CDPVault.sol:493`

Treasury.sync credits balance - lastSynced and, when the balance is at or below the baseline, only lowers the baseline (Treasury.sol:294-297). Every outflow the Treasury itself performs (_withdraw, _withdrawUnderlying, withdrawNative) credits unsynced arrivals first and then moves the baseline to the post-transfer balance, which is the fix for the lost-receipt low in docs/AUDIT-2026-10-03.md (job c71449d1). cover, added in the pinned commit, is an outflow the Treasury does not perform: the vault burns the Treasury's imdUSD directly through ImdUSD.burn (and re-mints only the fee part), leaving lastSynced[imdUSD] above the real balance. The next imdUSD to arrive, up to the principal burned, is absorbed by the stale baseline and never reaches totalReceived, which the Treasury's own NatSpec (line 523) calls 'the one number this contract exists to answer'. Stability fees reach the Treasury by plain mint with no notification, so unsynced imdUSD is the Treasury's normal state and the loss is permanent. No funds move. Reachable with the constants as committed whenever cover is used (it is permissionless). Four specialists reported it; merged here. Smallest fix: in CDPVault.cover, call the permissionless Treasury(payer).sync(IERC20(address(stablecoin))) immediately before the burn (credits anything unsynced) and again after it (re-bases to the post-burn balance), e.g. through a virtual hook ParameterizedVault overrides; or give Treasury a vault-only spend hook that runs _withdraw's credit-first logic. The specialists report the attached proof passes with the two-line sync change.

**Reproduction**

Fixture (attached proof): ParameterizedVault over MockIMD at $1 (primary 5e14, ETH/USD 2000e8), NHI 0.85. BORROWER locks 170e18 and draws 100e18; KEEPER locks 450e18 and draws 250e18. Price to $0.50; bark(BORROWER); +6h; KEEPER bites 70.83e18, draining the position: totalBadDebt = 29.1697e18. KEEPER transfers 29.1697e18 imdUSD to the Treasury; Treasury.sync(imdUSD): totalReceived R = 29.1727e18 (the transfer plus the bite's fee re-mint), lastSynced == balance. Anyone calls vault.cover(BORROWER, 29.1697e18): Treasury balance falls to 0.0030e18, lastSynced stays 29.1727e18. One year later KEEPER wipes its accrued fee of 11.1076e18, which ImdUSD.mint delivers to the Treasury (balance 11.1106e18). Treasury.sync(imdUSD). EXPECTED: totalReceived = R + 11.1076e18 = 40.2803e18. ACTUAL: 29.1727e18 (credited 0). Proof output on the committed code: 'revenue that arrived after cover is lost: 29172748858447488467 != 40280351598173515717'. A second specialist proof (Proof_37bd56fc6540.t.sol) shows the same with a 50e18 transfer after cover: 120.83e18 recorded against 150.00e18 arrived, and its companion test shows syncing before and after the burn gives the right total.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

/// @dev A controllable feed: value is set by the test, dated at the time it was set, never stale.
contract Feed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private at;

    constructor(uint256 v) {
        set(v);
    }

    function set(uint256 v) public {
        value = v;
        at = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, at);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

/// @dev Chainlink ETH/USD stand-in: $2000 with 8 decimals, always dated now.
contract Aggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Finding: `cover` burns the Treasury's imdUSD through `ImdUSD.burn`, which the Treasury's
/// `sync` accounting never sees. `lastSynced[imdUSD]` stays at the pre-burn balance, so stability
/// fees that arrive afterwards are masked up to the burned amount and never reach `totalReceived`.
/// FAILS on the code as committed; PASSES once `cover` reconciles the Treasury's baseline
/// (sync before and after the burn).
contract CoverMasksReceiptsTest is Test {
    address private constant BORROWER = address(0xBA);
    address private constant KEEPER = address(0xBEEF);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    Treasury private treasury;
    Feed private primary;
    Feed private spot;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new Aggregator()).code);
        imd = new MockIMD();
        // 1 IMD = $1: 0.0005 ETH at $2000/ETH.
        primary = new Feed(0.0005 ether);
        spot = new Feed(0.0005 ether);
        Feed health = new Feed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(spot)
        );
        stable = vault.stablecoin();
        treasury = vault.treasury();
    }

    function _open(address who, uint256 amount, uint256 debt) private {
        vm.prank(APPROVED_OPERATOR);
        imd.mint(who, amount);
        vm.startPrank(who);
        imd.approve(address(vault), amount);
        vault.lock(amount);
        vault.draw(debt);
        vm.stopPrank();
    }

    function _setPrice(uint256 usd) private {
        primary.set(usd * 1e18 / 2000 ether);
        spot.set(usd * 1e18 / 2000 ether);
    }

    function test_feesArrivingAfterCoverAreRecorded() public {
        // A realized bad debt, made the vault's way: BORROWER at mat is crashed, marked and drained.
        _open(BORROWER, 170 ether, 100 ether);
        _open(KEEPER, 450 ether, 250 ether);
        _setPrice(0.5 ether);
        vault.bark(BORROWER);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _setPrice(0.5 ether);
        uint256 repayable = uint256(170 ether) * 0.5 ether / ((100 + vault.CHOP_PERCENT()) * 1e16);
        vm.prank(KEEPER);
        vault.bite(BORROWER, repayable);
        uint256 bad = vault.totalBadDebt();
        assertGt(bad, 0, "realized bad debt");
        _setPrice(1 ether);

        // The Treasury holds `bad` imdUSD (standing in for collected fees), fully synced.
        IERC20 t = IERC20(address(stable));
        vm.prank(KEEPER);
        stable.transfer(address(treasury), bad);
        treasury.sync(t);
        uint256 recorded = treasury.totalReceived(t);
        assertEq(treasury.lastSynced(t), stable.balanceOf(address(treasury)));

        // Anyone covers the loss: the vault burns `bad` from the Treasury, which records nothing.
        vault.cover(BORROWER, bad);
        uint256 afterBurn = stable.balanceOf(address(treasury));

        // A year later KEEPER pays its stability fees, which are minted to the Treasury as revenue.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _setPrice(1 ether);
        uint256 fees = vault.stabilityFeeOf(KEEPER);
        assertGt(fees, 0);
        assertLt(fees, bad, "the receipt is smaller than the burn, so it is entirely masked");
        vm.prank(KEEPER);
        vault.wipe(fees);
        assertEq(stable.balanceOf(address(treasury)), afterBurn + fees, "the fees landed");

        // Expected: the record grows by what arrived. Actual on the committed code: it does not move.
        treasury.sync(t);
        assertEq(treasury.totalReceived(t), recorded + fees, "revenue that arrived after cover is lost");
    }
}
```

## 3. [low] The register accepts the vault's own collateral with any well-formed price source; listing sIMD through usdPriceFeed inflates reserveValueUsd and earnLine about 125,000x

`src/Treasury.sol:188`

setReserveAsset special-cases the creating vault's collateral: its decimals are pinned at 18 because its price must be quoted per 1e18 RAW units (struct NatSpec lines 46-55), which only the vault's collateralPriceFeed (a SharePriceFeed for sIMD) does. validateReserveAsset (line 144-174) checks that the source has code and answers isStale() and latestValue() in shape, but not WHICH source it is. The vault also exposes usdPriceFeed (USD per 1e18 raw IMD), a valid ISwarmFeed the runbook names next to collateralPriceFeed and the one every existing test lists the (non-share) collateral against. A proposal listing sIMD against usdPriceFeed passes both validations, is applied after 48 hours, and then reserveValueOf = balance(24-dec raw) x (USD per 1e18 raw IMD) / 1e18, which values every 1e24 raw sIMD (one share, 7.95 IMD, about $86.81) as 1e6 IMD, about $10.92M: an inflation of 1e18 / convertToAssets(1e18) = 125,786x. reserveValueUsd feeds earnLine directly, so the work ceiling is inflated by that factor and any rights holder can earn() against backing that does not exist. Redemption is unaffected: _redemptionReserveBacking subtracts reserveValueOf(gem) and re-adds the gem at the vault's price, so the error cancels there. This is a governance input error, visible for 48 hours, and the runbook says the work channel ships closed, so the launch impact is nil; it is reported because the register already knows the one correct source for the one asset whose convention differs and can refuse the wrong one for free, where every other invalid listing is refused. Two specialists reported it; merged. Smallest fix: in validateReserveAsset, when asset == _linked('gem()') require address(priceFeed) == _linked('collateralPriceFeed()') (skip the check when the vault exposes none, so a standalone Treasury is unaffected). Existing tests list the plain-IMD collateral against usdPriceFeed, which IS collateralPriceFeed in that configuration, so they keep passing.

**Reproduction**

Fixture (attached proof): ParameterizedVault over an sIMD-shaped share (24 decimals, convertToAssets(1e18) = 7.95e12), IMD = $10.92 (primary 5.46e15, ETH/USD 2000e8). Deposit 7.95e18 IMD into the share vault for the Treasury: balance 1e24 raw sIMD. collateralPriceFeed.latestValue() = 8.6814e13, so the right valuation is mulDiv(1e24, 8.6814e13, 1e18) = 86.814e18 ($86.81). APPROVED_OPERATOR calls parameters.proposeReserveAsset(sIMD, vault.usdPriceFeed(), 10_000). EXPECTED: revert InvalidPriceSource (the collateral is priced per 1e18 raw units by collateralPriceFeed only). ACTUAL: accepted; warp 48h; applyPending() lists it; treasury.reserveValueUsd() = 10920000000000000000000000 ($10,920,000) and vault.earnLine() returns the same figure (test/scratch/JudgeChecks.t.sol test_gemListedWithUsdPriceFeedIsAccepted_andInflates logs expected 86814000000000000000 against actual 10920000000000000000000000). The attached proof fails on the committed code with 'next call did not revert as expected'.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {Parameters} from "src/Parameters.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract Imd is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev sIMD-shaped: 24 decimals, `rate` = IMD raw per 1e18 share raw (7.95 IMD per whole share).
contract Share is ERC20 {
    IERC20 public immutable underlying;
    uint256 public immutable rate;

    constructor(IERC20 underlying_, uint256 rate_) ERC20("Staked IMD", "sIMD") {
        underlying = underlying_;
        rate = rate_;
    }

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf(owner) * rate / 1e18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets * 1e18 / rate;
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "owner only");
        shares = (assets * 1e18 + rate - 1) / rate;
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }
}

contract Feed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;
    uint64 private updatedAt;

    constructor(uint256 initial) {
        set(initial);
    }

    function set(uint256 next) public {
        value = next;
        updatedAt = uint64(block.timestamp);
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

/// @dev Chainlink ETH/USD stand-in with no storage, so it survives vm.etch: $2,000, always fresh.
contract Aggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Finding: the register special-cases the vault's own collateral (decimals pinned at 18,
/// priced per 1e18 RAW units) but does not pin the one price source that quotes that way, the
/// vault's `collateralPriceFeed`. Listing sIMD against the vault's other feed, `usdPriceFeed`
/// (USD per 1e18 raw IMD), passes validation, matures after 48 hours and values one sIMD
/// (7.95 IMD, about $86.81) at $10,920,000.
///
/// Expected: `proposeReserveAsset(sIMD, usdPriceFeed, ...)` is refused with InvalidPriceSource.
/// Actual: it is accepted, and reserveValueUsd / earnLine are inflated about 125,786x.
contract GemWrongFeedProofTest is Test {
    Imd private imd;
    Share private share;
    ParameterizedVault private vault;
    Treasury private treasury;
    Parameters private parameters;

    function setUp() public {
        vm.warp(1_000_000);
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new Aggregator()).code);
        imd = new Imd();
        share = new Share(imd, 7.95e12); // 1e24 raw sIMD = 7.95e18 raw IMD
        Feed primary = new Feed(5.46e15); // $10.92 at $2000/ETH
        Feed spot = new Feed(5.46e15);
        Feed nhi = new Feed(0.85e18);
        vault = new ParameterizedVault(
            address(share), address(0), address(0), address(primary), address(nhi), address(spot)
        );
        treasury = vault.treasury();
        parameters = vault.parameters();
        // The Treasury holds one whole sIMD: 1e24 raw units, 7.95 IMD, about $86.81.
        imd.mint(address(this), 7.95e18);
        imd.approve(address(share), 7.95e18);
        share.deposit(7.95e18, address(treasury));
        assertEq(share.balanceOf(address(treasury)), 1e24);
    }

    function test_collateralMayOnlyBeListedThroughCollateralPriceFeed() public {
        ISwarmFeed wrong = ISwarmFeed(address(vault.usdPriceFeed()));
        assertTrue(address(wrong) != address(vault.collateralPriceFeed()), "fixture: the share has its own feed");

        // The listing must be refused where every other invalid listing is: at proposal.
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(IERC20(address(share)), wrong, 10_000);

        // And whatever the register does accept must value the collateral as the vault does.
        (bool proposed,) = address(parameters).call(
            abi.encodeCall(Parameters.proposeReserveAsset, (IERC20(address(share)), wrong, 10_000))
        );
        if (proposed) {
            vm.warp(block.timestamp + 48 hours);
            parameters.applyPending();
        }
        (uint256 right,) = vault.collateralPriceFeed().latestValue();
        uint256 atMost = Math.mulDiv(1e24, right, 1e18); // about 86.81e18
        assertLe(treasury.reserveValueUsd(), atMost, "one sIMD is worth about $86.81, not $10.92M");
    }
}
```

## 4. [low] fundOracle unwraps sIMD held by the Treasury, so sIMD's inherited same-block hold lets a one-wei share transfer block the daily oracle budget

`src/Treasury.sol:505`

The repository records as a live fact that StakedIMD's SameBlockRedeem hold is per account and that a transfer passes the sender's hold on to the recipient (test/SharePriceFeedFork.t.sol:170-172; docs/COMPUTE-BACKING-DESIGN.md:548: 'any incoming transfer bumps the recipient's, so a design that redeems could be griefed with dust'). The protocol's answer was never to redeem on a hot path; IShareVault's NatSpec says the Treasury withdraws 'only from shares it has held since an earlier block'. fundOracle is the one path that does redeem: _withdrawUnderlying calls the share vault's withdraw with the Treasury as owner. Any address can deposit 1 wei of IMD into StakedIMD and transfer the resulting share dust to the Treasury in the same block as (front-running) a fundOracle call, bumping the Treasury's hold and making the withdraw revert. The NatSpec at lines 449-452 acknowledges only the self-inflicted case (shares arriving from a liquidation). A griefer who keeps this up for the day's blocks denies the asker its budget, and a day not claimed is not carried over (the asker then cannot buy the price updates every price-dependent action depends on). Not reachable today only because ORACLE_ASKER is a placeholder with no code (fundOracle reverts OracleAskerMissing first); it becomes reachable the moment the asker is deployed, with no contract change. CAVEAT: the hold itself is modelled here from the repository's own fork test notes, not re-verified against StakedIMD (no fork available), so the premise is the requester's recorded observation. Smallest fix: transfer sIMD shares to ORACLE_ASKER (a plain transfer is not held) and let the asker unwrap when it spends, or have fundOracle fall back to a share transfer when the withdraw reverts.

**Reproduction**

test/scratch/JudgeChecks.t.sol test_fundOracleBlockedByDustTransferInSameBlock: a mock share vault records lastDepositBlock[receiver] on deposit, propagates max(sender, recipient) on transfer and reverts SameBlockRedeem in withdraw when lastDepositBlock[owner] >= block.number, which is the behaviour the repo's fork notes describe. ORACLE_ASKER is etched with code. The Treasury receives 100 sIMD in block N; roll to N+1. Quiet block: treasury.fundOracle() returns 10e18 (the default oracleBudget). State reverted. Same block, GRIEFER deposits 1e18 IMD into the share vault and transfers 1 raw share unit to the Treasury, then anyone calls treasury.fundOracle(). EXPECTED per the NatSpec: 10 IMD reaches the asker. ACTUAL: reverts SameBlockRedeem; repeated every block, the asker is never funded that day.

## 5. [info] NatSpec says reserveValueUsd 'never makes this view revert', but a listed feed or token answering an enormous value reverts it, and with it earnLine, backingPerUnit and cash

`src/Treasury.sol:217`

validateReserveAsset and the three isolated reads (_readBool, _readValue, _readBalance) check the SHAPE of a source's answers but not their magnitude. Math.mulDiv(balance, price, 10 ** decimals) reverts MathOverflowedMulDiv when the quotient does not fit 256 bits, and the checked `total +=` in reserveValueUsd can overflow too. The NatSpec at lines 197-199 ('it never makes this view revert') and ParameterizedVault's reliance on it ('a dead leg values the reserve at nothing and only tightens the ceiling', line 171-172) are therefore not true for a listed source that answers an absurd value. Because ParameterizedVault._redemptionReserveBacking reads reserveValue(), such an answer also reverts backingPerUnit and cash (when supply > 0), not just earn, until a delisting matures 48 hours later. Only a governance-listed feed or token can do it, and a SwarmFeed is bounded by its deviation band while fresh, so this is a trust-gated liveness note and a documentation gap, not a bypass; the register is empty at launch. Three specialists reported it; merged. Fix: in reserveValueOf, treat a price or balance above a sane bound (e.g. > type(uint128).max) as unpriced and return 0, which keeps the 'counts for nothing' promise, and saturate the sum in reserveValueUsd (or use Math.tryMul).

**Reproduction**

test/scratch/JudgeChecks.t.sol test_reserveValueUsdRevertsOnHugeFeedValue: list an 18-decimal token with haircut 10000 against a feed answering 1e18; give the Treasury 2e18 tokens; reserveValueUsd() == 2e18. Set the feed to type(uint256).max. EXPECTED per the NatSpec: a finite value or zero. ACTUAL: treasury.reserveValueUsd() reverts MathOverflowedMulDiv() (2e18 * (2^256 - 1) / 1e18 > 2^256) and vault.earnLine() reverts the same way.

## 6. [info] ParameterizedVault trusts whatever TREASURY_FACTORY returns without checking that the Treasury serves this vault

`src/ParameterizedVault.sol:70`

With the genuine TreasuryFactory this is sound: Treasury.vault is msg.sender, which is the constructing vault, so no third party can obtain a Treasury this vault trusts or a vault whose Treasury another caller controls (Treasury has no owner; its registrar is the vault's own Parameters). The vault, however, verifies nothing about the returned address. A wrong contract at the pinned TREASURY_FACTORY address (a deployment-ordering mistake of the kind the runbook already warns about for the relayer and the work oracle factory) could hand back a Treasury bound to another vault and every fee and protocol cut would be routed to it with no revert: its withdraw guards, registrar and redeemIMD would answer to the other vault, and this vault's cash would revert Unauthorized on redeemIMD. One `if (treasury.vault() != address(this)) revert` after create() makes the deployment fail loudly. Not a defect in the committed code; a hardening the Q5 scope asks about. Note the same fixture that runs the test suite (vm.etch of the factory) is what makes this reproducible.

**Reproduction**

test/scratch/JudgeChecks.t.sol test_vaultAcceptsTreasuryBoundToAnotherVault: etch at TREASURY_FACTORY a factory whose create() returns new Treasury(address(0xBAD)); deploy ParameterizedVault. EXPECTED: construction reverts. ACTUAL: it succeeds; vault.treasury().vault() == 0xBAD and vault.feeRecipient() is that Treasury.

## 7. [info] NatSpec: fundOracle is no longer 'the Treasury's third and last way out' nor 'the only one with no key behind it'

`src/Treasury.sol:446`

Value now leaves the Treasury through seven routes: withdraw and withdrawNative (operator key), handOffLaunchFees (operator, future fees only), fundOracle (keyless, gem to ORACLE_ASKER, capped by oracleBudget), payStream (keyless, imdUSD to the governed payee, capped by streamPerDay), redeemIMD (vault only, driven by anyone's cash) and the vault's cover (keyless burn of the Treasury's imdUSD). At least three have no key behind them. A reader auditing exits from this sentence would stop at three. Four specialists reported it; merged. Documentation only: reword to list the exits or drop the count and uniqueness claims.

**Reproduction**

Read src/Treasury.sol:446-447 against payStream (line 343, external, no caller check, moves imdUSD), redeemIMD (line 511, msg.sender == vault, reached through anyone's cash) and src/CDPVault.sol:486 cover (permissionless, burns the Treasury's imdUSD). EXPECTED: the comment enumerates every exit. ACTUAL: it names fundOracle as the third, last and only keyless one.

## 8. [info] NatSpec for redeemIMD is attached to the oracle-budget section and the oracleDay variable; redeemIMD itself is undocumented

`src/Treasury.sol:437`

The two doc lines describing redeemIMD (lines 437-438) sit above the '--- the oracle budget ---' banner and so bind to the next declaration, `uint256 public oracleDay;`. redeemIMD (line 511), the vault-only collateral exit, carries no NatSpec, so its access rule and gem-only asset rule are undocumented where the function is, and generated docs describe oracleDay as 'Release reserve IMD for a redemption'. Three specialists reported it; merged. Fix: move the two lines directly above `function redeemIMD`.

**Reproduction**

Read src/Treasury.sol:437-443 and 511-516, or run forge doc: the @notice at 437 attaches to oracleDay and redeemIMD has none. EXPECTED: the reverse.

## 9. [info] NatSpec for proposeReserveAsset is attached to proposeRedemptionDivisor; proposeReserveAsset is undocumented

`src/Parameters.sol:221`

The four-line notice at lines 217-220 ('Queue a listing, repricing or (with a zero price source) delisting of one of the Treasury's reserve assets... imdUSD is refused with StablecoinIsNotReserve, a haircut must be at most 10000') precedes `function proposeRedemptionDivisor`, which does none of that, and `proposeReserveAsset` at line 230 has no NatSpec. Generated documentation therefore says the divisor proposal queues a listing. Three specialists reported it; merged. Fix: move the block above proposeReserveAsset and give proposeRedemptionDivisor its own line (bounds MIN_/MAX_REDEMPTION_DIVISOR).

**Reproduction**

Read src/Parameters.sol:217-232: the notice above proposeRedemptionDivisor(uint256) describes reserve-asset listing; proposeReserveAsset(address,address,uint256) has no entry. EXPECTED: each function documented by its own notice.

## 10. [info] NatSpec: Governed and Parameters cite a live ceiling-against-outstanding-debt check as the reason _validate runs twice, but Parameters removed that check

`src/Governed.sol:20`

Governed's docstring (lines 19-21) says _validate runs again at application 'because a bound that reads live state (a ceiling against outstanding debt) can hold when proposed and be false two days later', and Parameters.vault's @dev (lines 131-132) says the vault binding is needed for 'checking a proposed ceiling against debt that is actually outstanding'. Parameters._validate deliberately has no such check any more (lines 408-417, removed for the c71449d1 low); grep shows totalDebt is only the ICheckpointedVault interface declaration. The only live-state validation left is the reserve-asset probe through Treasury.validateReserveAsset (the asset's decimals() and the feed's two reads), which is also the only change whose application a third party (the listed token's or feed's owner) can block until the governor cancels, so the second run still matters, but for the register, not the ceiling. Three specialists reported it; merged. Fix: cite the reserve-asset probe in both places.

**Reproduction**

Propose an Economics set with line = 1 wei while totalDebt is large; warp 48h; applyPending() succeeds with no debt-related revert (no _validate branch reads totalDebt). EXPECTED per the docstrings: a second check of the ceiling against outstanding debt. ACTUAL: none exists; the only live-state check is the reserve-asset probe.

## 11. [info] NatSpec: withdrawer() carries withdraw()'s documentation (two @notice tags); withdraw() has no @notice

`src/Treasury.sol:304`

The block starting 'Move funds out, to a destination the caller names' with its @dev about the pinned operator and the destination argument documents withdraw(), but it precedes `function withdrawer()`, which also has its own @notice (line 308). withdraw() (line 319) has only the @dev listing what cannot be taken. Fix: move the first @notice/@dev pair above withdraw().

**Reproduction**

Read src/Treasury.sol:304-319 or run forge doc: withdrawer() carries two notices; withdraw(address,address,uint256) has no notice. EXPECTED: one each.

## 12. [info] NatSpec on bite, cut, badDebtOf and ParameterizedVault.backedDebt still describe a 10% liquidation payout (1.1e18, 110%) after CHOP_PERCENT was raised to 20

`src/CDPVault.sol:779`

bite computes collateralSeized = mulDiv(debtToRepay, (100 + CHOP_PERCENT) * 1e16, price) with CHOP_PERCENT = 20 (line 112, decided 2026-10-05 per docs/PARAMETERS-2026-10-05.md), i.e. 1.2e18 and 120%. The @dev on bite (lines 779-780: '1.1e18', '110%'), the @dev on cut (line 177: 'the existing 10% bonus'), the @notice on badDebtOf (line 882: 'including the 10% payout') and ParameterizedVault.backedDebt's @dev (lines 218-219: 'seizable at the usual 10% bonus') all state the old figure. These are the lines a keeper or integrator reads to size a liquidation. Two specialists reported it; merged. Fix: update the four comments to 1.2e18 / 120% / 20%, or reference CHOP_PERCENT instead of a literal.

**Reproduction**

bite(owner, 100e18) at price 1e18: EXPECTED per line 779: 110e18 collateral seized. ACTUAL: collateralSeized = 100e18 * 1.2e18 / 1e18 = 120e18 (line 795), as the existing Liquidation tests assert.

## 13. [info] DeploymentConfig says redeeming 10% of supply at divisor 2 'costs 5.5% (the 5% cap)'; the fee formula gives 5.0%

`src/DeploymentConfig.sol:130`

CDPVault.cash charges REDEMPTION_FEE_FLOOR_BPS (50) plus min(base + redeemed/supply/divisor, 4.5%) rounded up to whole bps, so the total is capped at REDEMPTION_FEE_CAP_BPS = 500 = 5.0%. At divisor 2, 10% of supply adds 5% to the base, which saturates at 4.5%, for a total of 5.0%, not 5.5%; the sentence contradicts itself by also naming the 5% cap. docs/PARAMETERS-2026-10-05.md's table (5.00%) and Parameters.sol's bound comments agree with the code; this one line does not. Two specialists reported it; merged. Fix: '5.5%' -> '5%'.

**Reproduction**

test/scratch/JudgeChecks.t.sol test_tenPercentRedemptionCostsFivePercent: with 100,000e18 imdUSD supply, divisor 2 and a calm base, vault.redemptionFeeBps(10,000e18) returns 500 (50 + ceilDiv(min(0.1e18/2, 0.045e18), 1e14) = 50 + 450). EXPECTED per the comment: 550.

## 14. [info] Runbook lists the economic constants to 'carry over unchanged' as CUT_BPS 3333, DUTY_BPS 200 and ETH_USD_MAX_AGE 1 day; the source has 1000, 444 and 2 hours

`docs/MAINNET-RUNBOOK.md:121`

docs/MAINNET-RUNBOOK.md is named by the task as the authority on the deployment, and its constants checklist is what the deployer reads back against chain state. Lines 121-122 are stale against src/DeploymentConfig.sol (CUT_BPS 1000 at line 122, DUTY_BPS 444 at line 141, ETH_USD_MAX_AGE 2 hours at line 30) and docs/PARAMETERS-2026-10-05.md. A deployer verifying against the runbook would flag the correct values as wrong, or 'carry over' the old ones. Documentation only.

**Reproduction**

Compare docs/MAINNET-RUNBOOK.md:121-122 with src/DeploymentConfig.sol:30, 122 and 141. EXPECTED: equal. ACTUAL: 3333 vs 1000, 200 vs 444, 1 day vs 2 hours.

## 15. [info] _redemptionReserveBacking's second return value and `amount` argument are dead code left from the removed RedemptionWorsensBacking guard

`src/ParameterizedVault.sol:146`

The only caller is CDPVault._backingPerUnit (line 586), which passes amount = 0 and discards the second value. The rounded-up 'value leaving the reserve' costs a mulDiv per call and suggests to a reader that a reserve-outflow bound still exists; the comment at CDPVault.sol:217-218 still describes it. Code quality only; no behaviour depends on it. Fix: drop the argument and the second return (or document that the bound was removed in favour of pro-rata payout).

**Reproduction**

grep -n _redemptionReserveBacking src: one call site, `(uint256 backing,) = _redemptionReserveBacking(0, price);` at src/CDPVault.sol:586. EXPECTED: a used return value. ACTUAL: always discarded, always computed with amount 0.
