# Launch audit — vault panel (2026-10-05)

Job `414e25cc-f7f9-47d1-bc5e-c0dfb8705119` (order 8f30a6c7), `template: audit` at `e52a025`: four specialists
(math, permissions, economics, control flow) and a judge, all `claude-fable-5-1`, all accepted. The judge
reproduced every kept claim. Raw submissions: `audit-vault-2026-10-05-submissions.json`.

**Kept: 3 medium, 4 low, 9 info. No high or critical.**

## Judge's summary

The review is written to `.imd-findings.json`: 16 entries — 3 medium, 4 low, 9 info (the last is a coverage note, not a defect). Three carry proofs that fail on this tree. No high or critical finding survived.

## Kept, after reproducing each

**Medium**
- **Dust re-lock freezes bad debt** (`src/CDPVault.sol:488`, two specialists merged). After a liquidation drains a position, the owner calls `lock(1)`. `bite` then reverts `InsufficientCollateral` and `cover` reverts `NoRealizedBadDebt`, so the residual stays in `totalBadDebt` and the matching Treasury imdUSD stays behind `BadDebtFirst`. Neither specialist's proof was supplied, so I wrote one. The fix I suggest in `bite` makes it pass on a patched copy, where the rest of the suite still passes (491 tests).
- **Redemption backing cap bypass** (`src/CDPVault.sol:608`). Borrow, redeem and unwind in three adjacent transactions pays 95.5 IMD where the pro-rata share is 38.
- **Work ceiling bypass** (`src/ParameterizedVault.sol:221`). Borrow, earn and unwind leaves 250 work-minted imdUSD with no debt, no collateral and backing 0.

**Low**
- Splitting a redemption into chunks pays about a third less than the documented fee (5 chunks: 101.3 against 150).
- `backingPerUnit` falls across a position-funded redemption when the mat cap binds (1.0 → 0.927 → 0.756), contradicting the "strictly improves backing" comment.
- `earn` then `cash` in one transaction dilutes the fee base (450 bps instead of 500).
- Listing sIMD as reserve against `usdPriceFeed` values it 125,786× too high; this is a governor error with a cheap guard, and it sits in `Treasury.sol`, outside the three contracts in scope.

**Info**
- One note on self-marking: a borrower who marks its own position recovers the marker's share of the bonus.
- Seven NatSpec mismatches, merged from the specialists' duplicates.

## Where I disagreed with the specialists

- **A dust variant needs no owner action, and the specialist's cause for it did not reproduce.** The first bite left 27,646 raw units against a 27,645 one-wei seizure, not an exact tie. A further 10% price fall then made it unseizable: 1,850 imdUSD of debt neither liquidatable nor coverable, with `totalBadDebt` reading 0.
- **Backing-cap proof replaced.** The original borrowed and earned in one block in its own setup, so it reverted under the fix it proposed. My version separates the honest steps by block and passes with the fix applied.
- **Block-scoping does not close either round trip.** One block apart, the work-ceiling sequence still succeeds for 0.0000338 imdUSD of stability fee; the redemption sequence has the same structure but I did not run it a block apart. Block-scoping also broke 73 existing tests on the patched copy. I recommend an age-based exclusion instead; that narrows a documented design choice, so it is the requester's call.
- **Dropped: "supply identity omits `totalFeesMinted`".** A paid fee is burned from the payer and re-minted to the Treasury, so the identity in the source holds as written.
- **Dropped as a separate finding: fresh-principal chunking (49d98342).** It is the earlier audits' open advisory 08f0352c, not a regression. Its proof does fail as described; I note it under the fee-split finding.
- **Corrected a figure.** Worst-case backing at mat 170 and earnMat 2500 is 136%, not "roughly 128%".

## Not verified

- sIMD itself and the live Chainlink aggregator were out of reach; everything share-related rests on mocks.
- The feeds, relay, work oracle and factories were read only where the vault calls them.
- One unverified lead, not in the file: if sIMD's one-block hold is inherited on transfer as the docs say, sending dust sIMD to the Treasury each block might keep `Treasury.fundOracle` reverting.

Answers to questions 1–8, including the ones where nothing was found, are in the coverage entry.

## 1. [medium] One raw unit of sIMD re-locked on a drained position makes its realized bad debt uncoverable, unliquidatable and unredeemable, freezing Treasury imdUSD behind BadDebtFirst

`src/CDPVault.sol:488`

Merged from audit_permissions 33d5623f and audit_flow 3ee7c31d (same mechanism). CDPVault.cover refuses any position whose collateral is non-zero (line 488). CDPVault.lock is ungated (no price, minimum or health check) and credits the caller's own position. CDPVault.bite reverts InsufficientCollateral whenever the formula seizure exceeds the position's collateral (line 796), and the seizure for ONE wei of debt is floor(1.2e18 / price) raw collateral units; the dust sweep at lines 813-819 only runs inside a bite that already passed that check. With the mainnet collateral (sIMD, 24 decimals, priced per 1e18 raw units, about 8.68e13) one wei of debt seizes about 13,800 raw units (27,645 after a 50% fall), so a position holding fewer raw units than that can never be bitten; this holds at every price below 0.6e18 per 1e18 raw units, i.e. always for sIMD. Redemption cannot name it either (gemOut - reserveOut must be <= collateral * debtCancelled / debt, which rounds to 0). So after a liquidation drains a position and records its residual in totalBadDebt, the owner calls lock(1) and the position is unreachable by every path except the owner's own wipe. lock deliberately leaves _recordedBadDebt in place, so totalBadDebt keeps the residual permanently. Consequences: (1) Treasury.withdraw(imdUSD) reverts BadDebtFirst and Treasury.payStream treats the amount as not spare, so protocol imdUSD equal to the frozen residual can never be withdrawn, streamed or spent on cover; (2) ParameterizedVault.backedDebt subtracts totalBadDebt for ever, lowering the work ceiling by earnMat x residual; (3) _securedCollateralValue subtracts it from the principal the mat cap applies to, lowering backingPerUnit for redeemers; (4) the 'bad debt first' policy in docs/PARAMETERS-2026-10-05.md cannot be executed for that position. Cost to the drained borrower: one raw unit of sIMD (about 1e-22 USD) and gas. Two related states come from the same two guards: (a) a drained borrower who later re-collateralises to health keeps the record until they choose to repay, with cover refused throughout; (b) with no action by the owner at all: the largest coverable bite leaves a remainder at or just above the one-wei seizure (the sweep at line 816 only takes a remainder strictly below it), and if the price falls further before a second bite that remainder becomes unseizable. Reproduced: 27,646 raw units left against a 27,645 seizure; after a further 10% fall the seizure is 30,717, bite(owner, 1) reverts InsufficientCollateral, cover reverts NoRealizedBadDebt, and 1,850 imdUSD of uncollateralised debt is neither recorded in totalBadDebt (it reads 0) nor liquidatable, so backedDebt and the secured-collateral cap keep counting it until the price recovers. Reachable with the constants as committed (CHOP_PERCENT 20, sIMD collateral, any NHI). Smallest fix: in bite, when collateralSeized > position.collateral and 0 < position.collateral < Math.mulDiv(1, (100 + CHOP_PERCENT) * 1e16, price), seize the whole remaining collateral instead of reverting and compute the bonus saturating (bonus = collateralSeized > principalPart ? collateralSeized - principalPart : 0); a one-wei bite then always drains sub-threshold dust, _recordBadDebt fires and cover works, so re-locking dust cannot interpose (I applied exactly this to a copy of the tree: the proof passes and the existing suites still pass, see reproduction). To also close variant (a) and dust that no keeper will pay gas for, let cover accept a position that is underwater at the current price (collateral worth less than its debt), sweeping that collateral to the Treasury first; that makes cover price-gated for such positions and is the requester's choice.

**Reproduction**

ParameterizedVault over an sIMD-shaped share (24 decimals, 7.95e12 raw IMD per 1e18 raw share), IMD/ETH 0.00546e18, ETH/USD 2000e8 (collateral price 86,814,000,000,000), NHI 0.85 (mat 170, grace 6h). BORROWER lockIMD(1000e18) [$10,920], draw(6400e18). KEEPER lockIMD(5000e18), draw(20000e18). Primary halves to 0.00273e18 (price 43,407,000,000,000). KEEPER bark(BORROWER); warp 6h; KEEPER bite(BORROWER, collateral * price / 1.2e18), then bite(BORROWER, 1) for the 27,646-unit remainder the first bite left (27,645 seized, 1 swept): collateral == 0, totalBadDebt == debtOf(BORROWER) == 1850.19e18. KEEPER transfers 1851.19 imdUSD to the Treasury. BORROWER deposits 1 IMD into the share vault and calls vault.lock(1). Expected: the realized loss can still be retired (a liquidator takes the dust, or cover applies). Actual (run on this tree): bite(BORROWER, 1) reverts InsufficientCollateral() (seizure 27,645 > 1); cover(BORROWER, 1850194630136986297600) reverts NoRealizedBadDebt(); totalBadDebt stays at the residual and only BORROWER's own wipe can change it. Run: forge test --match-path test/scratch/DustRelockFreeze.t.sol -> FAIL: NoRealizedBadDebt(). With the bite fix applied to a copy of the tree the same test passes and the rest of the suite is unchanged (491 passed; the only failures were the two round-trip proofs below, which that fix does not address). Variant (b) was run separately (test/scratch/DustVariant.t.sol): same setup, stop after the first bite, set the primary to 0.002457e18; bite(BORROWER, 1) reverts InsufficientCollateral and cover(BORROWER, 1) reverts NoRealizedBadDebt while totalBadDebt == 0 and debtOf(BORROWER) == 1850194630136986297601.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract DustFeed is ISwarmFeed {
    uint256 public constant maxAge = 1 days;
    uint256 private value;

    constructor(uint256 v) {
        value = v;
    }

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }
}

contract DustMirror is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(ISwarmFeed p) {
        primary = p;
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}

contract DustAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev sIMD's shape: an ERC-4626 share with 24 decimals, 7.95 IMD per share.
contract DustShare is ERC20 {
    IERC20 public immutable underlying;
    uint256 public constant RATE = 7.95e12; // raw IMD per 1e18 raw share

    constructor(IERC20 asset_) ERC20("Staked IMD", "sIMD") {
        underlying = asset_;
    }

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares * RATE / 1e18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets * 1e18 / RATE;
        _mint(receiver, shares);
    }
}

/// @notice After a liquidation drains a position and realizes its residual, the owner locks ONE raw
/// unit of sIMD back in. `cover` refuses the position (collateral != 0), `bite` cannot seize the unit
/// (one wei of debt seizes floor(1.2e18 / price) raw units, far more than one), and redemption cannot
/// name it. totalBadDebt keeps the residual for ever and the Treasury's imdUSD stays behind
/// `BadDebtFirst`.
contract DustRelockFreezeProof is Test {
    address private constant BORROWER = address(0xBA);
    address private constant KEEPER = address(0xBEEF);

    MockIMD private imd;
    DustShare private share;
    DustFeed private primary;
    ParameterizedVault private vault;
    ImdUSD private stable;
    Treasury private treasury;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new DustAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        share = new DustShare(imd);
        // IMD at 0.00546 ETH with ETH at $2000: $10.92 per IMD, 8.6814e13 per 1e18 raw sIMD.
        primary = new DustFeed(0.00546 ether);
        DustFeed health = new DustFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(share), address(0), address(0), address(primary), address(health), address(new DustMirror(primary))
        );
        stable = vault.stablecoin();
        treasury = vault.treasury();
        vm.startPrank(APPROVED_OPERATOR);
        imd.mint(BORROWER, 1_001 ether);
        imd.mint(KEEPER, 5_000 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        imd.approve(address(share), type(uint256).max);
        share.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(KEEPER);
        imd.approve(address(vault), type(uint256).max);
    }

    function test_oneRawUnitRelockedOnADrainedPositionCannotFreezeItsBadDebt() public {
        (uint256 price,) = vault.collateralPriceFeed().latestValue();
        assertEq(price, 86_814_000_000_000, "USD per 1e18 raw sIMD at the brief's figures");

        vm.startPrank(BORROWER);
        vault.lockIMD(1_000 ether); // $10,920
        vault.draw(6_400 ether); // 170.6%
        vm.stopPrank();
        vm.startPrank(KEEPER);
        vault.lockIMD(5_000 ether);
        vault.draw(20_000 ether);
        vm.stopPrank();

        // The price halves; the position is marked, grace runs, and it is liquidated to nothing.
        primary.set(0.00273 ether);
        (price,) = vault.collateralPriceFeed().latestValue();
        vm.prank(KEEPER);
        vault.bark(BORROWER);
        vm.warp(block.timestamp + 6 hours);
        (uint256 held,) = vault.positions(BORROWER);
        vm.startPrank(KEEPER);
        vault.bite(BORROWER, held * price / 1.2e18);
        (held,) = vault.positions(BORROWER);
        if (held != 0) vault.bite(BORROWER, 1);
        vm.stopPrank();
        (held,) = vault.positions(BORROWER);
        assertEq(held, 0, "drained");
        uint256 bad = vault.totalBadDebt();
        assertGt(bad, 1_800 ether, "the residual is realized");
        assertEq(vault.debtOf(BORROWER), bad);

        // The Treasury holds imdUSD (standing in for collected stability fees) to cover it with.
        vm.prank(KEEPER);
        stable.transfer(address(treasury), bad + 1 ether);

        // The drained borrower locks ONE raw unit of sIMD (1e-24 sIMD).
        vm.startPrank(BORROWER);
        share.deposit(1 ether, BORROWER);
        vault.lock(1);
        vm.stopPrank();
        assertEq(uint256(1.2e18) / price, 27_645, "one wei of debt seizes 27,645 raw units; the position holds 1");

        // Whatever path the protocol offers, the realized loss must still be retirable: a liquidator
        // may take the dust, and the Treasury's imdUSD may then cover what is owed.
        vm.startPrank(KEEPER);
        try vault.barkFor(BORROWER, KEEPER) {} catch {}
        try vault.bite(BORROWER, 1) {} catch {}
        vm.stopPrank();
        uint256 owed = vault.debtOf(BORROWER);
        vault.cover(BORROWER, owed); // reverts NoRealizedBadDebt on the code as it is
        assertEq(vault.totalBadDebt(), 0, "the realized loss is retired");
        assertEq(vault.debtOf(BORROWER), 0);
    }
}
```

## 2. [medium] Redemption backing cap excludes only same-transaction capital: a borrow / redeem / unwind sequence over adjacent transactions takes the reserve at par while backing is 0.4

`src/CDPVault.sol:608`

Kept from audit_economics e657e37d, with the proof rewritten and the proposed fix corrected. _securedCollateralValue (lines 606-615) and _redemptionRate (lines 681-689) exclude only what the CURRENT TRANSACTION added, through the transient slots SECURED_THIS_TX_SLOT and MINTED_THIS_TX_SLOT, which the EVM clears when the transaction ends. A position opened in one transaction therefore counts in full as secured collateral (up to mat x its principal) and as prior supply in the next transaction, and is closed in a third. The comment at lines 223-228 calls this slow round trip 'the accepted design' on the ground that it 'costs real capital in an open position, not gas'. It does not: the three transactions fit in one block (zero seconds of fee, no liquidation exposure at 200%), and one block apart the cost I measured is 24 seconds of stability fee, 0.0000338 imdUSD on 1000 of principal. Who loses: every remaining imdUSD holder. When backing per unit is below 1 (work-minted imdUSD outliving the debt it was minted against, the stressed state the cash() comment block is written for), the caller turns the pro-rata payout into a par payout and empties the reserve; the fee is also diluted by the caller's own minted supply (450 bps instead of the 500 cap). This is the same harm as findings 8936befa (high) and 7cd5035c (medium) that the secured-collateral accounting was built to close; those used a debt-free deposit, this uses a healthy indebted one. Reachable with the constants as committed (mat 170, earnMat 2500, divisor 2, LINE $1M). Call sequence from an external account, three transactions: lock(2000e18); draw(1000e18) | cash(100e18, 0, address(0)) | wipe(1000e18); free(2000e18). Fix: the exclusion has to be by AGE, not by transaction. The specialist's block-scoped tally (storage keyed by block.number instead of transient storage) makes the attached proof pass (I applied it to a copy of the tree and ran it) but leaves the identical sequence open one block later at the cost quoted above, and it breaks 73 existing tests that open a position and act on it in one block. The fix that closes it counts a position's secured term and its principal toward 'prior' only once that principal is older than FRESH_DEBT_WINDOW, using the per-position recentlyMinted / mintedAt record draw already maintains (subtract a global tally of fresh principal and fresh secured collateral, aged out lazily when a position is next touched, erring toward excluding). That changes when honest new debt starts to count as backing, so it is the requester's decision; whichever is chosen, the comment at lines 223-228 claims a cost the code does not impose and should be corrected.

**Reproduction**

State: ParameterizedVault, 18-decimal IMD at $1 (primary 5e14 wei per IMD, Chainlink 2000e8), NHI 0.85 (mat 170), Treasury holding 100 IMD, empty register. BORROWER lock(1700e18), draw(1000e18); 13 hours and one block later WORKER earn(250e18); next block BORROWER wipe(debtOf), free(1700e18). Now totalDebt == 0, totalSupply == 250e18, backingPerUnit() == 0.4e18. ATTACKER holds 100 imdUSD and 2000 IMD and sends, in ONE block as three separate transactions: lock(2000e18) and draw(1000e18); cash(100e18, 0, address(0)); wipe(1000e18) and free(2000e18). Expected: gemOut <= 100 x 0.4 x (1 - 5%) = 38e18 IMD, the pro-rata share of the backing the burn found. Actual: cash returns 95.5e18 IMD (feeBps 450 because the attacker's 1000 counted as prior supply; backingPerUnit read as 1e18 because 1700 of the attacker's mat-capped collateral counted), the Treasury keeps 4.5 IMD against 150 imdUSD still outstanding (backing 0.03), and the attacker's position is empty again. Run: forge test --match-path test/scratch/BackingRoundTrip.t.sol -> FAIL 'a redemption may not take more than its pro-rata share of backing: 95500000000000000000 > 38000000000000000000'. The specialist's original proof was replaced because its own setup borrowed and earned in one block, so it reverted WorkCeilingReached under the fix it proposed; this version puts every honest setup step in its own block with the debt aged 13 hours, and passes with either a block-scoped or an age-based exclusion.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {Treasury} from "src/Treasury.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract ProofFeed is ISwarmFeed {
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

contract ProofMirror is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(ISwarmFeed p) {
        primary = p;
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}

contract ProofAggregator {
    /// @dev A pure constant: `vm.etch` copies code only, so a storage initializer would read as zero.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice The backing cap on redemption, and the work ceiling's debt term, are both defeated by a
/// three-transaction round trip inside ONE block: open a 200% position, redeem (or earn), close.
/// The transient-storage exclusions only see a single transaction; the source comments say the
/// cross-transaction version "costs real capital in an open position, not gas", but here the
/// capital is exposed for zero seconds and the attacker takes the whole reserve at par while the
/// burn found backing at 0.4.
contract BackingRoundTripProof is Test {
    address private constant BORROWER = address(0xBA);
    address private constant WORKER = address(0xCA);
    address private constant ATTACKER = address(0xA7);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    Treasury private treasury;
    MockWorkOracle private oracle;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new ProofAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        // 1 IMD = 1/2000 ETH and 1 ETH = $2000, so the vault prices IMD at exactly $1.
        ProofFeed primary = new ProofFeed(uint256(1 ether) * 1e18 / 2000 ether);
        ProofFeed health = new ProofFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new ProofMirror(primary))
        );
        stable = vault.stablecoin();
        treasury = vault.treasury();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        oracle.grantRights(WORKER, 1_000 ether);
        imd.mint(BORROWER, 1_700 ether);
        imd.mint(ATTACKER, 2_000 ether);
        imd.mint(address(treasury), 100 ether); // the reserve
        vm.stopPrank();
        vm.prank(BORROWER);
        imd.approve(address(vault), type(uint256).max);
        vm.prank(ATTACKER);
        imd.approve(address(vault), type(uint256).max);
    }

    /// @dev A borrower opens 1000 of debt, a worker mints 250 against it thirteen hours later, the
    /// borrower unwinds. 100 of reserve now stands behind 250 of work-issued imdUSD: backing 0.4, the
    /// state `test_debtUnwindCannotLeaveReserveRedemptionWorseningBacking` pins. Every honest step is
    /// in its own block and the debt is aged, so this setup is unaffected by a fix that scopes the
    /// exclusion to the block or to principal older than the fresh-debt window.
    function _underback() private {
        vm.startPrank(BORROWER);
        vault.lock(1_700 ether);
        vault.draw(1_000 ether);
        vm.stopPrank();
        _nextBlock(13 hours);
        vm.prank(WORKER);
        vault.earn(250 ether);
        _nextBlock(12);
        // The worker lends the borrower the thirteen hours of stability fee, and funds the attacker.
        vm.startPrank(WORKER);
        stable.transfer(BORROWER, 1 ether);
        stable.transfer(ATTACKER, 100 ether);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        vault.wipe(vault.debtOf(BORROWER));
        vault.free(1_700 ether);
        stable.transfer(address(0xdead), stable.balanceOf(BORROWER));
        vm.stopPrank();
        _nextBlock(12);
        assertEq(vault.totalDebt(), 0);
        assertEq(stable.totalSupply(), 250 ether);
        assertEq(vault.backingPerUnit(), 0.4 ether, "100 of reserve behind 250 of supply");
    }

    function _nextBlock(uint256 secondsLater) private {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + secondsLater);
    }

    function test_sameBlockRoundTripTakesTheReserveAtParWhileBackingIsPointFour() public {
        _underback();
        uint256 backingBefore = vault.backingPerUnit();
        uint256 reserveBefore = imd.balanceOf(address(treasury));
        uint256 blockBefore = vm.getBlockNumber();

        // Transaction 1: open a 200% position. Transaction 2: redeem. Transaction 3: close it.
        // `isolate = true` makes each call its own transaction; block.number never moves.
        vm.startPrank(ATTACKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        uint256 out = vault.cash(100 ether, 0, address(0));
        vault.wipe(1_000 ether);
        vault.free(2_000 ether);
        vm.stopPrank();
        assertEq(vm.getBlockNumber(), blockBefore, "the whole sequence fits in one block");

        // What the burn should have been paid at the backing it found: 100 x 0.4 less the capped fee.
        uint256 proRata = Math.mulDiv(100 ether, Math.mulDiv(backingBefore, 10_000 - 500, 10_000), 1e18);
        assertEq(proRata, 38 ether, "pro-rata payout for 100 of a 250 supply backed at 0.4");

        // Actual: paid at par less a diluted fee, and the attacker's position is empty again.
        (uint256 collateral, uint256 debt) = vault.positions(ATTACKER);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertLe(out, proRata, "a redemption may not take more than its pro-rata share of backing");
        assertGe(imd.balanceOf(address(treasury)), reserveBefore - proRata, "reserve drained beyond pro-rata");
    }
}
```

## 3. [medium] backedDebt excludes only same-transaction debt: borrow, earn and unwind in adjacent transactions mints work imdUSD against debt that is gone a block later

`src/ParameterizedVault.sol:221`

Kept from audit_economics 40d9da19; its proof was run and fails for the reason given. backedDebt() caps totalDebt at _debtAtTransactionStart(), a transient slot written by _debtChanged and cleared when the transaction ends. The REVISION note for finding 4d30331c (lines 204-212) and docs/COMPUTE-BACKING-DESIGN.md (section on 'D counts only debt that existed before the transaction began') close the single-transaction round trip and accept the cross-transaction one because 'the cost of it is real capital at risk in an open position, not gas'. That premise does not hold: a rights holder borrows in transaction 1, earns a quarter of that debt in transaction 2 (the slot is empty, so backedDebt reads the whole debt), and repays and withdraws in transaction 3. In one block the position is open for zero seconds; across three blocks I measured the whole cost at 0.0000338 imdUSD of stability fee per 1000 borrowed. The block ends with work-minted imdUSD, no debt and no collateral, and with the launch configuration (an empty register) backingPerUnit() is 0 for that supply. The honest sequence 'someone borrows, a worker earns against it, the borrower later repays' reaches the same end state and is the documented design; what this adds is that the minter needs no one else's debt and no exposure: only rights and collateral worth 8x the mint for one block, up to 25% of whatever LINE has left ($250k at the committed $1M). Who loses: every imdUSD holder, by dilution of backing. Reachable with the constants as committed (earnMat 2500, mat 170). Call sequence, one key, three transactions: lock(2000e18); draw(1000e18) | earn(250e18) | wipe(1000e18); free(2000e18). Fix: as for the redemption cap, the exclusion must be by age. Making DEBT_AT_TX_START_SLOT block-scoped makes the attached proof pass (verified on a patched copy) but leaves the same mint open one block later for 24 seconds of fee; the ratio term should count only principal older than FRESH_DEBT_WINDOW (a global tally of fresh principal maintained beside each position's recentlyMinted record and subtracted in backedDebt). This narrows the accepted design, so it needs the requester's decision; in either case the sentence at lines 211-212 states a cost the code does not impose.

**Reproduction**

State: fresh ParameterizedVault, IMD at $1, NHI 0.85, empty register; WORKER holds 1000e18 of work rights and 2000 IMD. earnLine() == 0 and earn(1) reverts WorkCeilingReached. In one block, as separate transactions (foundry.toml sets isolate = true, so each top-level call is its own transaction): lock(2000e18), draw(1000e18); earn(250e18); wipe(1000e18), free(2000e18). Expected: earn reverts WorkCeilingReached, because no debt that outlives the caller's own round trip backs it. Actual: earn succeeds (backedDebt() == 1000e18, earnLine() == 250e18); afterwards totalDebt == 0, the vault holds no collateral, totalSupply == 250e18 and backingPerUnit() == 0. Run: forge test --match-path test/scratch/Proof_40d9da19ad31.t.sol -> FAIL 'next call did not revert as expected'. The same sequence with one block (12 s) between each step also succeeds on this tree: totalSupply 250e18, totalDebt 0, backingPerUnit 0, total fee paid 33789954337000 wei of imdUSD.

**Proof**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ParameterizedVault} from "src/ParameterizedVault.sol";
import {CDPVault} from "src/CDPVault.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {MockIMD} from "src/MockIMD.sol";
import {MockWorkOracle} from "src/MockWorkOracle.sol";
import {TreasuryFactory} from "src/TreasuryFactory.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, TREASURY_FACTORY} from "src/DeploymentConfig.sol";

contract CeilingFeed is ISwarmFeed {
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

contract CeilingMirror is ISwarmFeed {
    ISwarmFeed private immutable primary;

    constructor(ISwarmFeed p) {
        primary = p;
    }

    function latestValue() external view returns (uint256, uint64) {
        return primary.latestValue();
    }

    function isStale() external view returns (bool) {
        return primary.isStale();
    }

    function maxAge() external view returns (uint256) {
        return primary.maxAge();
    }
}

contract CeilingAggregator {
    /// @dev A pure constant: `vm.etch` copies code only, so a storage initializer would read as zero.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice `backedDebt` excludes debt created in the current TRANSACTION. A worker who borrows in one
/// transaction, earns in the next and unwinds in a third, all in one block, mints work-backed imdUSD
/// against debt that never outlives the block. The comment on `backedDebt` says the cross-transaction
/// version costs "real capital at risk in an open position, not gas"; inside one block it risks nothing.
contract WorkCeilingRoundTripProof is Test {
    address private constant WORKER = address(0xCA);

    MockIMD private imd;
    ParameterizedVault private vault;
    ImdUSD private stable;
    MockWorkOracle private oracle;

    function setUp() public {
        if (TREASURY_FACTORY.code.length == 0) vm.etch(TREASURY_FACTORY, address(new TreasuryFactory()).code);
        vm.etch(CHAINLINK_ETH_USD, address(new CeilingAggregator()).code);
        vm.warp(1_000_000);
        imd = new MockIMD();
        // 1 IMD = 1/2000 ETH and 1 ETH = $2000, so the vault prices IMD at exactly $1.
        CeilingFeed primary = new CeilingFeed(uint256(1 ether) * 1e18 / 2000 ether);
        CeilingFeed health = new CeilingFeed(0.85 ether);
        vault = new ParameterizedVault(
            address(imd), address(0), address(0), address(primary), address(health), address(new CeilingMirror(primary))
        );
        stable = vault.stablecoin();
        oracle = MockWorkOracle(address(vault.oracle()));
        vm.startPrank(APPROVED_OPERATOR);
        oracle.grantRights(WORKER, 1_000 ether);
        imd.mint(WORKER, 2_000 ether);
        vm.stopPrank();
        vm.prank(WORKER);
        imd.approve(address(vault), type(uint256).max);
    }

    function test_sameBlockRoundTripMintsWorkAgainstDebtThatIsGoneBeforeTheBlockEnds() public {
        // A fresh vault: no debt, no reserve, so the ceiling is zero and nothing may be earned.
        assertEq(vault.earnLine(), 0);
        vm.prank(WORKER);
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(1);

        uint256 blockBefore = block.number;
        // Transaction 1: borrow. Transaction 2: earn a quarter of that debt. Transaction 3: unwind.
        // `isolate = true` makes each call its own transaction; block.number never moves.
        vm.startPrank(WORKER);
        vault.lock(2_000 ether);
        vault.draw(1_000 ether);
        // Expected: the ceiling's debt term is backed only by positions that outlive the block, so
        // debt opened in this block does not authorise this mint.
        vm.expectRevert(CDPVault.WorkCeilingReached.selector);
        vault.earn(250 ether);
        vault.wipe(1_000 ether);
        vault.free(2_000 ether);
        vm.stopPrank();
        assertEq(block.number, blockBefore, "the whole sequence fits in one block");

        // Actual on the current code: the earn succeeds, and the block ends with 250 work-minted imdUSD,
        // no debt, no collateral and an empty reserve.
        assertEq(vault.totalDebt(), 0);
        assertEq(imd.balanceOf(address(vault)), 0, "no collateral is left in the vault");
        assertEq(stable.totalSupply(), 0, "no work-minted imdUSD should have been issued");
    }
}
```

## 4. [low] Redemption fee is charged at the post-increase rate per call, so splitting one redemption into chunks pays about a third less than the documented fee for its size

`src/CDPVault.sol:687`

Merged from audit_permissions 8f16cfdd and audit_flow 327a7c68. _redemptionRate(amount) returns decayed base + amount / priorSupply / divisor, capped, and cash() charges that single post-increase rate on the whole burn and stores it as the new base. A sequence of n burns therefore pays each chunk at the rate at the end of that chunk, roughly the integral of a linear rate (about half the increase) instead of the end-point rate a single call pays, and the 4.5% cap binds the single call sooner. docs/PARAMETERS-2026-10-05.md tabulates the fee by 'Redeemed at once', and DeploymentConfig.sol:129-130 and Parameters.sol:85-87 present the schedule as a property of the fraction redeemed ('redeeming 10% of supply at once costs 5.5% (the 5% cap)'); the REVISION note above _redemptionRate says a redeemer should pay 'the fee-adjusted price for that size'. With the committed divisor 2 a redeemer who splits pays materially less for the same size while leaving the base rate the same or slightly higher for everyone after, so the brake on a run is weaker than the parameter record assumes. No same-transaction mint is involved (the fcd5b261 netting does not apply); the chunks can be separate transactions in one block or one multicall. A related, already recorded effect is advisory 08f0352c (docs/INTERNAL-AUDIT-2026-10-04.md, docs/REDEMPTION-CHECKS.md): chunks against principal younger than FRESH_DEBT_WINDOW do not move the stored base at all. It is not reopened here; the specialist's proof for it (49d98342) runs and fails as described (39,776.1 received fresh against 39,382.2 aged for forty 1,000 chunks), and it shows the effect holds across blocks within the 12-hour window, not only 'same-block' as the earlier record words it. Reachable with the constants as committed. Fix, if size-invariance is wanted: charge each burn the mean of its pre- and post-increase rates (decayed + increase / 2, capped), which makes the total the exact integral and chunking neutral, and leave the stored base update as it is. That lowers the single-call fee relative to today, so it is an economic choice; the alternative is to correct the three documents to say the schedule is per call.

**Reproduction**

ParameterizedVault, 18-decimal IMD at $1, one borrower: lock(400_000e18), draw(100_000e18); Treasury holds 50,000 IMD so every burn is reserve-funded; redemptionBaseRate 0; divisor 2; next block. Single call cash(5_000e18, 0, address(0)): redemptionFeeBps(5_000e18) == 300, gemOut 4,850e18 (fee 150), redemptionBaseRate after 25000000000000000 (2.50%). Same starting state, five calls cash(1_000e18, 0, address(0)) in the same block: total gemOut 4,898.7e18 (fee 101.3, 32% less), base after 25515518375422644 (2.55%). Fifty calls of cash(100e18): total gemOut 4,909.89e18 (fee 90.11, 40% less), base after 25633493800422496. Expected per the parameter record: 5% of supply costs 3.00% however it is burned. Actual: 2.03% in five chunks, 1.80% in fifty. Reproduced with test/scratch/Explore.t.sol test_feeSplit (state snapshot between the three runs).

## 5. [low] backingPerUnit falls across a position-funded redemption whenever the aggregate mat cap binds; the 'neutral / strictly improves backing in every state' claim in cash() is false

`src/CDPVault.sol:614`

Kept from audit_math 347a44d3. cash() pays amount x backingPerUnit x (1 - fee) / price, and the comment at lines 540-542 argues this is 'exactly neutral on backing by construction' and 'strictly IMPROVES backing, in every state'. That holds for a pool of assets removed pro rata. The backing figure is not such a pool: _securedCollateralValue returns min(securedCollateral x price, (totalDebt - minted - totalBadDebt) x mat / 100) (line 614). When the second term binds, each imdUSD of principal a redemption cancels removes mat/100 (1.70 to 2.00) imdUSD of counted backing while supply falls by one, so the ratio falls with every position-funded burn. Consequences: (1) redeemers in a run are paid in order, the first at 1 - fee and later ones at a lower, falling multiple, the opposite of the pro-rata neutrality the code documents; (2) the public backingPerUnit() view drops below par purely because a redemption happened, with no price move; (3) the comment at line 652 ('Its discount remains in this position as backing') stops being true once the candidate's principal reaches zero, because _secured returns 0 for a debt-free position and the retained fee becomes freely withdrawable collateral. Reachable with the shipped constants (mat 170, earnMat 2500): it needs the cap to bind with supply above principal, which any repayment after work minting produces, since totalEarned never falls. Not a theft: no redeemer receives more than par less the fee. Smallest fix: decide which statement is the design. If pro-rata neutrality is wanted, the ratio term must shrink by no more than the principal cancelled when measured for redemption (value the secured term at min(collateral value, prior principal) for the payout calculation); otherwise delete the neutrality / 'every state' claim at lines 540-542 and the 'remains as backing' sentence at 652, and document that the payout declines through a run.

**Reproduction**

ParameterizedVault, 18-decimal IMD at $1, NHI 0.85 (mat 170, gap 50), empty Treasury, each step in its own block. A: lock(684e18), draw(400e18) (ratio 171). B: lock(1800e18), draw(600e18). W: earn(250e18). B: wipe(600e18). Now totalDebt 400e18, supply about 650e18, secured value 684, cap 400 x 1.7 = 680, backingPerUnit() == 1e18 (capped). R: cash(100e18, 0, A). Expected per lines 540-542: backingPerUnit() afterwards >= before. Actual: R receives 95e18 IMD (fee at the 500 bps cap), A's debt is 300, backing = min(589, 510) = 510 over 550, backingPerUnit() == 927272839310158516. A second cash(100e18, 0, A) pays 88.09e18 and leaves backingPerUnit() == 755555719374254448. Reproduced with test/scratch/Explore.t.sol test_backingFalls.

## 6. [low] _redemptionRate nets out principal drawn this transaction but not imdUSD earned this transaction, so earn-then-cash in one call dilutes the fee base and the stored base rate

`src/CDPVault.sol:686`

Kept from audit_economics 126977f1. The fix for finding fcd5b261 measures the fee increase against 'the supply that existed before this transaction' (comment at line 676) by subtracting MINTED_THIS_TX_SLOT from totalSupply. Only draw() adds to that slot (line 424). earn() (lines 447-465) mints imdUSD to the caller without touching it, so supply earned earlier in the same transaction counts as prior supply. A rights holder who earns and redeems in one call pays a smaller increase and, because redemptionBaseRate is stored from the same figure, leaves a lower base for every later redeemer. Bounded by the work ceiling: with earnMat 2500 and an empty register earn can add at most 25% of debt, cutting the increase by at most 20%. Unlike the draw path the earned supply is permanent, so this is a weakening of the brake during a run and of the fee a candidate retains, not an extraction. Reachable with the constants as committed. Smallest fix: add _transientAdd(MINTED_THIS_TX_SLOT, amount) to earn(), but only into a tally _redemptionRate reads; _securedCollateralValue subtracts the same slot from totalDebt (line 611), and earned imdUSD is not debt, so either use a second slot for earn or subtract the earn tally in _redemptionRate alone.

**Reproduction**

ParameterizedVault, 18-decimal IMD at $1. A: lock(2000e18), draw(1000e18) (totalSupply 1000e18); Treasury holds 1000 IMD; divisor 2; next block. redemptionFeeBps(100e18) == 500 and earnLine() == 250e18. A contract holding 250e18 of work rights calls, in ONE transaction: vault.earn(250e18); fee = vault.redemptionFeeBps(100e18); out = vault.cash(100e18, 0, address(0)). Expected: fee 500 bps and redemptionBaseRate 45000000000000000, the increase measured against the 1000 that existed before the transaction. Actual: fee == 450 (100 / 1250 / 2 = 4%), out == 95.5e18, redemptionBaseRate == 40000000000000000. Reproduced with test/scratch/Explore.t.sol test_earnDilutes.

## 7. [low] A reserve listing accepts any price source: the collateral token listed against the per-IMD usdPriceFeed is valued 125,786x and raises earnLine by the same factor (governor trust assumption with a che

`src/Treasury.sol:188`

Merged from audit_economics 5886ca9c and audit_flow dc6b6dcf. Outside the three contracts in scope, but question 7 asks whether a reserve listing can authorise unbacked minting, and ParameterizedVault.earnLine() adds Treasury.reserveValueUsd() unbounded. setReserveAsset special-cases the vault's gem by fixing its decimals at 18 (the vault prices collateral per 1e18 raw units) but accepts whatever priceFeed the proposal names; Parameters._validate and Treasury.validateReserveAsset only check that the asset has code and decimals and that the feed answers isStale() / latestValue() well-formed. ParameterizedVault creates two feeds: usdPriceFeed (USD per 1e18 raw IMD, documented at ParameterizedVault.sol:40-41 as 'the price source the Treasury's register is expected to hold for IMD') and collateralPriceFeed (USD per 1e18 raw sIMD, 7.95e-6 of the former). docs/MAINNET-RUNBOOK.md section 8 names the correct call, proposeReserveAsset(sIMD, vault.collateralPriceFeed(), haircut), but nothing on chain ties a listing of gem to that feed, and the two feed getters sit side by side. If the governor proposes sIMD with usdPriceFeed, every raw sIMD unit is valued at the price of a raw IMD unit and any rights holder can earn up to their rights with nothing behind it. More generally the governor can list any token against any feed after 48 hours, so the reserve term of the work ceiling and the reserve term of backingPerUnit (capped at par for payouts, but an under-backed system then reads as fully backed) are bounded only by trust in that key; ParameterizedVault's header (lines 25-26: the governor can change 'never where the price comes from') is true of collateral pricing and false of reserve pricing. This is the intended power of the role, visible for two days, not a bypass. Smallest guard: in validateReserveAsset, when asset == vault.gem(), require address(priceFeed) == vault.collateralPriceFeed() (read through the same _linked probe used for gem()); and reword lines 25-26 to say reserve price sources are governed.

**Reproduction**

ParameterizedVault over a 24-decimal share at 7.95e12 raw IMD per 1e18 raw share, IMD/ETH 0.00546e18, ETH/USD 2000e8 (IMD $10.92, collateralPriceFeed 86,814,000,000,000). The Treasury holds 100e24 raw sIMD (795 IMD, true value 8,681.4e18 USD). APPROVED_OPERATOR calls parameters.proposeReserveAsset(share, vault.usdPriceFeed(), 10000); 48 hours later anyone calls applyPending(). Expected: a listing of the collateral token is valued at its collateral price, about 8,681.4e18, or refused. Actual: vault.reserveValue() == 1092000000000000000000000000 (1.092e27, i.e. $1.092 billion) and vault.earnLine() == the same figure, 125,786 times the true value. Reproduced with test/scratch/Mislist.t.sol.

## 8. [info] A borrower can name itself marker and recover the marker's share of the bonus: the effective liquidation penalty is 18% of debt repaid, not the 20% the parameter record states

`src/CDPVault.sol:826`

Kept from audit_math 6239493d as the answer to question 2's 'can a marker or borrower extract more than the formula'. barkFor records the caller's chosen beneficiary as marker and bite pays that address chip() of the bonus; nothing excludes owner == beneficiary, and the owner is the party best placed to know the moment their position goes under. docs/PARAMETERS-2026-10-05.md states the borrower's cost of liquidation as 20% of the debt repaid; with a self-mark it is 18% (the 10% marker share of the 20% bonus returns to the borrower). A borrower who also supplies the imdUSD and bites itself pays only the protocol cut (2%), which is economically a repayment and extracts nothing from anyone. A second-key variant cannot be prevented on chain, and no one receives more than the formula's total seizure, so this is recorded only so that the 20% in the parameter record is read as the maximum a keeper-marked liquidation costs, not the borrower's floor.

**Reproduction**

NHI 0.60 (mat 200, lull 0), 18-decimal IMD at $1. Borrower lock(200e18), draw(100e18). Price falls to $0.90 (ratio 180 < 200). Borrower calls barkFor(self, self) then bite(self, 100e18) in the same block: collateralSeized 133.33e18, bonus 22.22e18, protocolCut 2222222222222222222 to the Treasury, borrower receives 131111111111111111111 and keeps 66666666666666666667 in the position. Expected penalty per the parameter record: 20% of debt repaid (22.22 IMD at $0.90). Actual: 2.22 IMD. With a third-party liquidator and a self-mark the borrower recovers markerCut = 2.22 IMD of the 22.22 bonus. Reproduced with test/scratch/Explore.t.sol test_selfMark.

## 9. [info] NatSpec still describes a 10% bonus and a 1.1e18 / 110% payout; CHOP_PERCENT is 20 and bite seizes 120%

`src/CDPVault.sol:779`

Merged from four specialist entries (a20e5af1 item 1-4, 20a43855, d9cd8978, 21521360). bite computes collateralSeized = Math.mulDiv(debtToRepay, (100 + CHOP_PERCENT) * 1e16, price) (line 795) with CHOP_PERCENT = 20 (line 112): 1.2e18, collateral worth 120% of the imdUSD burned. The stale figure appears in four places: src/CDPVault.sol:779 ('floor(debtToRepay * 1.1e18 / price) IMD, i.e. collateral worth 110%'), src/CDPVault.sol:177 on cut() ('it splits the existing 10% bonus'), src/CDPVault.sol:882 on badDebtOf ('including the 10% payout', while the code uses 100 + CHOP_PERCENT), and src/ParameterizedVault.sol:218 on backedDebt ('seizable at the usual 10% bonus'). Two more comments in the same area claim what the code does not do: the sweep comment at lines 804-806 says the dust it folds in is 'smaller than the seizure for a single wei of debt' and that this prevents the freeze, but a remainder equal to or just above that seizure is left and freezes the same way once the price falls further (see the medium finding), and the unit 'IMD' in 779 is sIMD raw units on mainnet. Behaviour is unaffected; a reader sizing liquidation risk or bad debt from these comments understates the bonus by half. Fix: write 1.2e18 / 120% / 20%, or refer to CHOP_PERCENT.

**Reproduction**

bite(owner, 100e18) at price 1e18 seizes 120e18 of collateral (line 795), not the 110e18 line 779 states. Observed at mainnet scale in test/scratch/DustRelockFreeze.t.sol: the one-wei seizure is floor(1.2e18 / 43407000000000) = 27,645 raw units, i.e. 1.2 wei of value per wei of debt, and a remainder of 27,646 was left by the first bite.

## 10. [info] Contract NatSpec says both tokens use 18 decimals, the price is USD per IMD and the collateral is MockIMD; the deployed collateral is 24-decimal sIMD priced per 1e18 raw units

`src/CDPVault.sol:28`

Merged from a20e5af1 item 5, 4c51e063, 8b471557 and 83a29035. docs/MAINNET-RUNBOOK.md deploys ParameterizedVault with StakedIMD (24 decimals) as gem, priced through SharePriceFeed per 1e18 RAW share units. The arithmetic is decimal-agnostic and correct (ratio, seizure and the dust threshold were exercised at mainnet scale in the dust re-lock reproduction, and test/ShareCollateral.t.sol covers the rest), so this is documentation only, but line 28 is the first statement a reader meets and it contradicts the unit convention every formula depends on, the same assumption SharePriceFeed's header warns against. The constructor @param at line 279 ('Deployed, nonrebasing, fee-free MockIMD collateral (18 decimals)') has the same problem, and in the base vault the price is wei of ETH per IMD rather than USD. Fix: state that collateral is any token priced per 1e18 raw units by _priceOrZero(), USD-denominated in ParameterizedVault, and that only imdUSD is fixed at 18 decimals.

**Reproduction**

ParameterizedVault constructed over a 24-decimal ERC-4626 share at 7.95e12 raw IMD per 1e18 raw share, IMD at $10.92: gem.decimals() == 24 and collateralPriceFeed().latestValue() == 86,814,000,000,000, a USD price per 1e18 raw share units, not 'USD per IMD scaled by 1e18' (1.092e19). Asserted in test/scratch/DustRelockFreeze.t.sol.

## 11. [info] Bad-debt NatSpec claims 'no insurance or debt forgiveness' and that _badDebtOf is shared with _recordBadDebt; cover() retires bad debt with Treasury imdUSD and the accumulator never calls _badDebtOf

`src/CDPVault.sol:270`

Merged from audit_flow 37b397a0 and 7f6c33f4. (1) Since commit e52a025 cover(owner, amount) burns the Treasury's imdUSD against a drained position through _reduceDebt, lowering the position's debt, _recordedBadDebt and totalBadDebt. The comment on totalBadDebt (lines 270-271: 'Measurement only: no insurance or debt forgiveness. Only debt repayment reduces a recorded residual') and on badDebtOf (line 883: 'Measurement only, not insurance or forgiveness') describe the vault before cover existed. (2) Lines 889-891 say _badDebtOf is 'Shared with _recordBadDebt so the accumulator and this view can never disagree about what bad debt means'. _recordBadDebt (lines 1041-1051) never calls _badDebtOf: it records debtOf(owner) only once collateral is zero, while _badDebtOf is a mark-to-market shortfall for any position; the two legitimately disagree whenever a position is underwater but not drained, which the comment at 1034-1040 itself explains. (3) 'adding collateral cannot hide it' (line 271) is true and is the root of the medium finding: adding one raw unit of collateral makes the record permanent. Fix: say that repayment and cover() reduce a recorded residual, and replace the 'shared' sentence with a pointer to the realized-only rule.

**Reproduction**

(1) test/Cover.t.sol test_coverRetiresRealizedBadDebtWithTheTreasurysImdUSD: after cover(owner, bad) from an unrelated account, debtOf(owner) == 0 and totalBadDebt == 0 with no repayment by the borrower. (2) Read _recordBadDebt at lines 1041-1051: no call to _badDebtOf. Position with collateral 170e18 and debt 100e18 at price 0.5e18, unliquidated: badDebtOf(owner) = 100e18 - 170e18 x 0.5 / 1.2 = 29.17e18 while totalBadDebt == 0.

## 12. [info] Misattached NatSpec: the stability-fee documentation (including the drip-before-change rule) sits on redemptionDivisor(), duty() has none, and earnLine's description names totalDebt where the code use

`src/CDPVault.sol:159`

Merged from a20e5af1 item 7, a796a42b, 8b92f10f and e93659a9. Lines 159-165 describe the annual stability fee and the rule that a governed subclass MUST call drip in the same transaction as a rate change; they are followed by a second @notice for the redemption divisor (166-167) and the whole block documents redemptionDivisor() at line 168. duty() at line 172 is undocumented. A NatSpec consumer shows redemptionDivisor() with two @notice tags and the fee rule under the wrong function. In the same family: src/CDPVault.sol:192-194 says ParameterizedVault's ceiling is 'reserveValueUsd + totalDebt * earnMat / 10000' (and DeploymentConfig.sol:144 repeats it) where the implementation uses backedDebt(), totalDebt capped at the transaction start less totalBadDebt; src/Parameters.sol:217-220 puts proposeReserveAsset's documentation on proposeRedemptionDivisor (separate finding); src/Treasury.sol:437-438 ('Release reserve IMD for a redemption priced and burned by this Treasury's vault...') sits above the oracle-budget section, detached from redeemIMD at line 511. The code itself is right: Parameters._apply calls vault.drip() before writing the new set (Parameters.sol:455-456), so a governed rate change does not reprice elapsed time. Fix: move lines 159-165 above duty(), and name backedDebt in the earnLine description.

**Reproduction**

Read src/CDPVault.sol lines 159-174: the block beginning '@notice Annual stability fee on open debt' is immediately followed by 'function redemptionDivisor()' and 'function duty()' has no NatSpec. Read ParameterizedVault.earnLine (line 233): reserveValue() + Math.mulDiv(backedDebt(), parameters.earnMat(), 10_000), not totalDebt.

## 13. [info] ImdUSD.burn NatSpec says the vault only burns the caller's tokens; cover() burns the Treasury's on behalf of any caller

`src/ImdUSD.sol:61`

Merged from d332273e, 992f23e0, aa0f0274 and 2deb3e94. ImdUSD.burn is documented as 'CDPVault only burns the caller's tokens during repayment, liquidation or redemption'. CDPVault.cover (src/CDPVault.sol:486-500) calls stablecoin.burn(payer, amount) where payer is the Treasury returned by _surplus(), not msg.sender, and anyone may call cover. The behaviour is intended ('Bad debt first', docs/PARAMETERS-2026-10-05.md) and bounded: only against a position with zero collateral and a recorded residual, only up to what is owed (ExcessRepayment), never twice (the debt is reduced by the same call). But the token's own statement of what its single burner may do to a holder's balance is no longer true, and a holder reading ImdUSD alone cannot tell that the vault can burn an account other than the caller. No other path burns a third party: wipe, bite and cash all burn msg.sender. Fix: name cover and the Treasury in the comment.

**Reproduction**

test/Cover.t.sol test_coverRetiresRealizedBadDebtWithTheTreasurysImdUSD: STRANGER calls vault.cover(BORROWER, bad); stable.balanceOf(treasury) falls by bad and stable.balanceOf(STRANGER) stays 0. Also exercised in test/scratch/DustRelockFreeze.t.sol with the fix applied on a copy of the tree (cover called by the test contract, Treasury debited).

## 14. [info] Parameters.proposeRedemptionDivisor carries proposeReserveAsset's NatSpec; proposeReserveAsset has none

`src/Parameters.sol:217`

Merged from a5b013b1 and e93659a9. The @notice at lines 217-220 ('Queue a listing, repricing or (with a zero price source) delisting of one of the Treasury's reserve assets ...') documents proposeReserveAsset (line 230, which has no NatSpec) but is attached to proposeRedemptionDivisor (line 221), which queues a divisor validated to MIN_/MAX_REDEMPTION_DIVISOR (1 to 8) and never touches the register. Generated ABI documentation and any reader of the governed divisor are told the wrong thing about the one governed input to the redemption fee. Fix: move the block above proposeReserveAsset and give proposeRedemptionDivisor a one-line notice ('Queue a change to the redemption fee divisor, refused outside 1..8').

**Reproduction**

Read src/Parameters.sol lines 217-223 against _validate (lines 349-353) and _apply (lines 422-425): proposeRedemptionDivisor encodes Change.RedemptionDivisor with a uint256, _validate calls _checkDivisor and _apply writes redemptionDivisor. Expected: NatSpec describes the divisor. Actual: it describes a reserve-asset listing.

## 15. [info] MAX_EARN_MAT_BPS rationale cites 'mat 150', a 5000-bps cliff and 120% worst-case backing; the shipped mat floor is 170, the cliff 7000 and the figure 136%

`src/Parameters.sol:72`

Kept from audit_math d2eb4647, with its figure corrected. _mat (src/CDPVault.sol:1081-1085) floors at 170 since the 2026-10-05 parameter change, so the cliff 'mat - 1' of docs/COMPUTE-BACKING-DESIGN.md section 3 is 0.70, i.e. 7000 bps, and at earnMat 2500 the worst-case backing with an empty reserve is 1.70 / 1.25 = 136% (the specialist wrote 'roughly 128%'; 136% is the arithmetic). The same stale derivation is at src/DeploymentConfig.sol:146 ('which is 5000 at the loosest NHI. 2500 is half that cliff, 120% worst-case backing'). The constant 2500 is a deliberate value and not a finding; the derivation written beside it is wrong in the safe direction. Note that the derivation in either form assumes the surplus collateral behind debt stays in place, which the two round-trip findings show a borrower can withdraw a block after work is minted against it.

**Reproduction**

mat() with NHI >= 0.85e18 returns 170 (src/CDPVault.sol:1082), the loosest value. Worst-case backing of debt D plus work 0.25 D with collateral at exactly mat: 1.70 D / 1.25 D = 1.36. The comment at src/Parameters.sol:72 says mat 150 and 120%.

## 16. [info] Coverage, answers to questions 1-8 where nothing was found, and specialist claims that were dropped

`src/CDPVault.sol:34`

Not a defect: the record of what this review covered. READ IN FULL: src/CDPVault.sol, src/ParameterizedVault.sol, src/ImdUSD.sol, src/Parameters.sol, src/Treasury.sol, src/Governed.sol, src/UsdPriceFeed.sol, src/SharePriceFeed.sol, src/interfaces/IShareVault.sol, src/interfaces/ISwarmFeed.sol, src/MockIMD.sol, src/MockWorkOracle.sol, and the economic constants of src/DeploymentConfig.sol. NOT REVIEWED: SwarmFeed, PriceFeed, NhiFeed, SpotFeed, SwarmRelay, SwarmWorkOracle, OracleAsker, Registry and the two factories (read only where the vault calls them). COULD NOT REACH: StakedIMD (sIMD) itself and the live Chainlink aggregator; no fork was run, so lockIMD's behaviour against the real staking vault, sIMD's exchange-rate behaviour under donation (SharePriceFeed reads convertToAssets(1e18) live) and its one-block hold rest on the mocks and the documents. No static analyser was run. Twelve independent specialist passes were not run; this is one reviewer re-deriving thirty specialist entries.
Q1 positions: nothing found. lock/free/draw/wipe act only on msg.sender's position; draw and indebted free check _healthy at the gated price after _accrue; lock credits exactly the balance delta or reverts; lockIMD credits the shares that arrived by balance, so a share vault that over-reports cannot inflate the credit (test/ShareCollateral.t.sol), and every state-changing entry except drip is nonReentrant, so reentry through deposit cannot reach another entry point. Third-party effects are the designed ones: cash against a named candidate and cover against the Treasury.
Q2 liquidation: the dust freeze (medium) and the self-mark note (info). The split itself is exact: protocolCut and markerCut are floors of the same bonus, the liquidator receives the rest, the swept dust is added after the split and is below one wei of debt in value.
Q3 redemption: the round trip (medium), the per-call fee (low), earn dilution (low) and the falling backing ratio (low). A redemption cannot worsen a candidate's ratio: line 641 compares exact fractions. The divisor is bounded 1..8 at proposal and at application.
Q4 bad debt: coverage cannot exceed what is owed (_reduceDebt reverts ExcessRepayment), cannot apply while collateral is non-zero, cannot be spent twice, and totalBadDebt moves with the per-position record in every writer (_reduceDebt lines 1009-1017, _recordBadDebt). The defect is the opposite direction: the record can be made permanent (medium).
Q5 stability fee: nothing found. Parameters._apply calls vault.drip() before writing the new set; chi() is non-decreasing and chiOf is only ever assigned chi(), so chiOf cannot exceed chi.
Q6 price gating: nothing found. draw, indebted free, earn (finite ceiling), cash, barkFor, heel and bite all require fresh feeds and price agreement; ParameterizedVault adds collateralPriceFeed staleness. lock, wipe, cover, debt-free free and drip are ungated and move value only toward safety; _clearIfRecovered refuses to clear a mark on stale or divergent feeds without blocking the deposit or repayment.
Q7 work issuance: the adjacent-transaction round trip (medium) and the reserve mis-listing (low). Within one transaction the transient cap holds.
Q8 arithmetic: nothing found. _collateralRatio saturates, _secured guards its product, every payout uses mulDiv and floors against the receiver, the fee rounds up to a whole basis point, _mat rounds up. Units agree at 24 decimals because every formula is per 1e18 raw units.
DROPPED: (1) a20e5af1 item 6, 'the supply identity omits totalFeesMinted': it does not reproduce. A paid fee is burned from the payer and re-minted to the fee recipient, so supply moves only by principal and the identity at lines 124 and 442 (supply = totalDebt + totalEarned - totalNonPrincipalRedeemed) holds as written; the invariant the specialist cited runs at a zero rate where totalFeesMinted is 0. (2) 49d98342 as a separate finding: it is advisory 08f0352c of the earlier audits, an open requester decision, not

**Reproduction**

Commands run on this tree: forge test --match-path 'test/scratch/*' for the three attached proofs (all FAIL as stated) and for test/scratch/Explore.t.sol, Mislist.t.sol and DustVariant.t.sol (the figures quoted in each finding). The full suite was run on a patched copy only (491 passed with the bite fix). Supply identity check for the dropped claim: wipe(amount) with fee f and principal p burns p + f from the payer and mints f to the Treasury (lines 1027-1030), so totalSupply falls by p, exactly as totalDebt does.
