// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "./CDPVault.sol";
import {Parameters, ICheckpointedVault} from "./Parameters.sol";
import {Treasury} from "./Treasury.sol";
import {TreasuryFactory} from "./TreasuryFactory.sol";
import {UsdPriceFeed} from "./UsdPriceFeed.sol";
import {SharePriceFeed} from "./SharePriceFeed.sol";
import {IShareVault} from "./interfaces/IShareVault.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {TREASURY_FACTORY} from "./DeploymentConfig.sol";

/// @notice CDPVault with its economic knobs read from a governed Parameters contract, its revenue
/// routed to a Treasury it owns, and its work minting bounded by what that Treasury and the
/// collateral pool back.
/// @dev The difference from CDPVault is a handful of overrides. That is the whole point of having
/// made those functions virtual: adding governance and a ceiling required no change to the vault's
/// logic, so the accounting, liquidation and attestation paths audited for CDPVault are the same
/// code here.
///
/// What this does NOT do is make the vault upgradeable. The price feeds, the attester and the
/// collateral token are still immutable constructor arguments, and `parameters`, `treasury` and
/// `usdPriceFeed` are immutables this constructor creates: the governor can change what the numbers
/// are, never where the COLLATERAL price comes from, where the revenue goes, or which contract governs.
/// Two other price-bearing inputs are governed, behind the same 48-hour delay: the price source of each
/// reserve asset other than the collateral (Parameters.proposeReserveAsset), and the work oracle `earn`
/// mints against (Parameters.proposeWorkOracle). See Parameters for what that lets the governor do.
/// Governance over this vault is therefore bounded by what Parameters can express and by the hard
/// limits Parameters enforces on itself.
contract ParameterizedVault is CDPVault {
    error TreasuryFactoryMissing();
    error TreasuryNotOurs();

    /// @notice The governed source of this vault's economics. Immutable: a governor who could
    /// replace it would have unbounded authority through the replacement.
    Parameters public immutable parameters;

    /// @notice Where this vault's protocol bonus share (IMD) and paid stability fees (imdUSD) land,
    /// and the reserve whose value is the first term of `earnLine`.
    Treasury public immutable treasury;

    /// @notice IMD in USD: this vault's primary IMD/ETH feed times Chainlink ETH/USD. The price
    /// source the Treasury's register is expected to hold for IMD.
    UsdPriceFeed public immutable usdPriceFeed;
    /// @notice What one unit of collateral is worth in USD, per 1e18 raw units: `usdPriceFeed` itself
    /// when the collateral is IMD, or a `SharePriceFeed` over it when the collateral is a share of an
    /// ERC-4626 vault holding IMD (sIMD on mainnet). Every collateral valuation reads this one price.
    ISwarmFeed public immutable collateralPriceFeed;

    constructor(
        address gem_,
        address stablecoin_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) CDPVault(gem_, stablecoin_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {
        // AUDIT FIX (job c71449d1): there is deliberately no way to pass a Parameters in. Accepting
        // one allowed an attacker to bind an impostor ahead of the deployer, and allowed a second
        // vault to borrow a Parameters already bound elsewhere and read a rate it is never
        // checkpointed for. The vault creates its own, which also means the pair comes up linked with
        // no post-deploy transaction — what a launch manifest requires, since it makes none and can
        // name only a bounded number of contracts.
        parameters = new Parameters(ICheckpointedVault(address(this)));
        // The same idiom for the other two, and for the same reasons: a Treasury passed in could be
        // anyone's wallet (which is what FEE_RECIPIENT is today), and a manifest has no fifth slot
        // to deploy one in. Created for this vault, its register is governed by this vault's
        // Parameters and refuses this vault's imdUSD, with nothing bound later. It is created through
        // TREASURY_FACTORY rather than with `new`, for the EIP-3860 limit: the Treasury's ~10 KB of
        // creation code would otherwise sit inside this contract's initcode and push it over.
        if (TREASURY_FACTORY.code.length == 0) revert TreasuryFactoryMissing();
        treasury = TreasuryFactory(TREASURY_FACTORY).create();
        // Trust the factory's answer only after it proves it: the Treasury must serve this vault
        // (launch audit, governance panel). A factory that returned anything else is refused here.
        if (treasury.vault() != address(this)) revert TreasuryNotOurs();
        usdPriceFeed = new UsdPriceFeed(ISwarmFeed(priceFeed_));
        // A share collateral is priced as its exchange rate times the underlying's USD price. The
        // adapter works per 1e18 RAW units, so sIMD's 24 decimals against IMD's 18 cannot misvalue it.
        collateralPriceFeed = _isShareVault(gem_)
            ? ISwarmFeed(address(new SharePriceFeed(gem_, ISwarmFeed(address(usdPriceFeed)))))
            : ISwarmFeed(address(usdPriceFeed));
    }

    /// @dev True when the token answers `asset()` with another nonzero address. A raw staticcall, so a
    /// plain ERC-20 without the member reads as "not a share vault" instead of reverting.
    function _isShareVault(address token) private view returns (bool) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IShareVault.asset, ()));
        if (!ok || data.length < 32) return false;
        address asset = abi.decode(data, (address));
        return asset != address(0) && asset != token;
    }

    function line() public view override returns (uint256) {
        return parameters.line();
    }

    function cut() public view override returns (uint256) {
        return parameters.cut();
    }

    function duty() public view override returns (uint256) {
        return parameters.duty();
    }

    function redemptionDivisor() public view override returns (uint256) {
        return parameters.redemptionDivisor();
    }

    /// @dev And minting from work IS on exactly while the wage is nonzero: `earn` is refused at wage 0.
    /// Rights are priced at claim and outlive the wage that priced them, so with the wage back at 0 they
    /// stayed spendable through `earn` while the lag then guarding the ceiling was off, reopening D1's borrow / earn / unwind
    /// round trip; and one `earn(1)` during a pending `proposeWorkOracle` made the replacement
    /// unapplyable for good (final panel audits, vault and governance, medium). Rights claimed under a
    /// wage are kept, and spendable again the moment a wage is set.
    function _earnOpen() internal view virtual override returns (bool) {
        return parameters.wage() != 0;
    }

    /// @notice The work oracle `earn` reads: a governed replacement if one was applied, else the oracle
    /// this vault created. See Parameters.proposeWorkOracle.
    function oracle() public view override returns (IWorkOracle) {
        address replacement = parameters.workOracle();
        return replacement == address(0) ? super.oracle() : IWorkOracle(replacement);
    }

    function _surplus() internal view override returns (address) {
        return address(treasury);
    }

    function _syncSurplus(address) internal override {
        treasury.sync(stablecoin);
    }

    function skew() public view override returns (uint256) {
        return parameters.skew();
    }

    function chip() public view override returns (uint256) {
        return parameters.chip();
    }

    function gap() public view override returns (uint256) {
        return parameters.gap();
    }

    /// @notice All of the Treasury's collateral (sIMD on mainnet) is usable, whether or not governance has
    /// listed it for reserve valuation. Plain IMD the Treasury holds is never paid to a redeemer; it funds
    /// the oracle (`Treasury.fundOracle`).
    function redemptionReserve() public view override returns (uint256) {
        return gem.balanceOf(address(treasury));
    }

    function _payRedemptionReserve(uint256 amount) internal override {
        treasury.redeemIMD(msg.sender, amount);
    }

    /// @dev The Treasury's IMD is valued at this vault's own price whether or not governance has
    /// listed it, because `redemptionReserve` pays it out whether or not governance has listed it.
    /// REVISION (finding 998ff6b2): the register valued unlisted IMD at zero on BOTH sides, so in the
    /// launch configuration (an empty register) every reserve-funded payout checked as zero against
    /// zero and the guard was vacuous for the asset the route actually pays; listed IMD whose source
    /// read stale, or carried a zero factor, did the same. The IMD held is valued at the price the IMD
    /// leaving is paid at, which is what makes the backing figure mean something for this route. Other
    /// listed assets still count at their registered, discounted value: they back imdUSD but never leave
    /// through this route. (The value leaving used to be returned too, for a guard the pro-rata payout
    /// replaced; dropped, sweep panel audit, vault, info.)
    function _redemptionReserveBacking(uint256 price) internal view override returns (uint256) {
        uint256 others = reserveValue() - treasury.reserveValueOf(gem);
        // Saturating, like the vault's backing it feeds: an absurd price must not revert lock or wipe (CDPVault._mark).
        (bool ok, uint256 product) = Math.tryMul(gem.balanceOf(address(treasury)), price);
        (bool fits, uint256 total) = Math.tryAdd(others, product / 1e18);
        return ok && fits ? total : type(uint256).max;
    }

    /// @notice Both revenue streams land in the Treasury this vault created, never in an account.
    function feeRecipient() public view override returns (address) {
        return address(treasury);
    }

    /// @notice The ratio term of the work ceiling, in basis points of collateral-backed debt.
    function earnMat() public view returns (uint256) {
        return parameters.earnMat();
    }

    /// @notice The Treasury's reserve in this vault's unit of account, which is USD.
    /// @dev No conversion, because `_price()` denominates this vault in dollars and the register is
    /// already kept in dollars. Both terms of `earnLine` are therefore added in the same unit by
    /// construction rather than by arithmetic.
    ///
    /// It used to divide by Chainlink ETH/USD, because the vault priced collateral in ETH while the
    /// register was in USD. REVISION (finding 9366455) added that conversion after the USD figure was
    /// found being added to an ETH-denominated debt term unconverted, authorising ETH/USD times more
    /// work minting than the reserve was worth. Denominating the vault in USD removes the mismatch at
    /// its source, so the conversion goes rather than being maintained.
    ///
    /// Still zero while the USD price is unusable: `reserveValueUsd` prices IMD through `usdPriceFeed`,
    /// so a dead leg values the reserve at nothing and only tightens the ceiling.
    function reserveValue() public view returns (uint256) {
        return treasury.reserveValueUsd();
    }

    /// @notice One imdUSD of debt is one USD-worth of collateral.
    /// @dev What makes imdUSD a dollar stablecoin rather than an ETH-denominated CDP token. The swarm
    /// feed quotes IMD in wei of ETH, so the base vault measures a position in ETH and a borrower's
    /// required collateral moved whenever ETH moved even with IMD/ETH flat. Pricing through
    /// `usdPriceFeed` — the same feed times Chainlink ETH/USD — denominates the ratio and the
    /// liquidation seizure in dollars and changes neither formula, because both are ratios in `_price()`.
    ///
    /// The divergence guard is unaffected and must stay that way: it compares the RAW primary feed
    /// against spot, both quoting IMD in ETH, so the ETH/USD factor never enters it. Comparing a
    /// denominated price against spot would sit them an ETH price apart and refuse every action.
    function _priceOrZero() internal view override returns (uint256 price) {
        (price,) = collateralPriceFeed.latestValue();
    }

    /// @notice Stale if either leg of the USD price is, on top of the base vault's own feeds.
    /// @dev Adding a way to halt is the cost of denominating in a unit this protocol does not publish
    /// itself. It is the right direction — a position cannot be safely liquidated at a price nobody
    /// knows — but it is a real dependency: a dead Chainlink ETH/USD leg stops minting, marking and
    /// liquidation here, where in `earnLine` it only zeroes the reserve term. `ETH_USD_MAX_AGE`
    /// bounds how long a dead leg takes to read as stale.
    function _pricingStale() internal view override returns (bool) {
        return super._pricingStale() || collateralPriceFeed.isStale();
    }

    /// @notice The principal the ratio term may count: `totalDebt`, capped at what it was when this
    /// transaction began, less the principal recorded as bad debt.
    /// @dev Two exclusions, one for each way principal can stand for collateral that is not there.
    /// REVISION (finding 4d30331c): debt created in the current transaction does not count. Without
    /// that, a rights holder with transient capital raised totalDebt with their own position, minted
    /// work against a quarter of it, repaid (a zero-second fee is zero) and withdrew everything in one
    /// call, leaving work-minted imdUSD with nothing behind it. The cap is the debt level at the start of
    /// the transaction, remembered in transient storage, so the ratio term is only ever backed by debt
    /// that existed before the caller arrived; and it counts only up to the paced debt, which rises by at most
    /// FOLLOW_BPS_PER_HOUR an hour and falls at once (CDPVault._pace), so cancelling another position's debt and
    /// drawing as much backs nothing until the new debt has been held. A position held for hours counts in full, so the ceiling stays point-in-time for the slow version of the
    /// same round trip: that is
    /// the accepted design (the ceiling gates new minting only; repayment lowers it and leaves what was
    /// minted), and the cost of it is real capital at risk in an open position, not gas. (The redemption
    /// half differs: a repayment one transaction before a redemption can lift what it is paid, for gas,
    /// within a bound; see CDPVault._backingPerUnit.)
    /// REVISION (finding e3888b1e): `totalBadDebt` is subtracted, saturating. After a liquidation
    /// drains a position its residual principal stays in totalDebt with no collateral behind it, and
    /// it was credited as if surplus collateral stood behind it. totalBadDebt is accrued debt (fees
    /// included) while totalDebt is principal, so the subtraction over-counts slightly, in the
    /// tightening direction. A position left with collateral below the liquidation payout but not yet
    /// drained is not recorded until someone finishes it; the remainder is seizable at the usual bonus,
    /// and dust below one wei of debt is taken whole by `bite` (or swept by `cover`), which records it.
    ///
    /// D1, FOR THE WORK CEILING (launch audit 2026-10-05, vault panel, medium). Excluding only the CURRENT
    /// transaction's capital left adjacent transactions open: borrow in one, earn (or cash) in the next,
    /// repay and withdraw in a third, and work-minted imdUSD outlived the debt that authorised it, or a
    /// redemption took the reserve at par while backing was 0.4. Fixed by the paced figures in CDPVault
    /// (the paced debt, CDPVault._pace): debt counts only up to a figure that rises by at most FOLLOW_BPS_PER_HOUR
    /// an hour and falls at once, at every wage, tracked from deployment. The redemption half is the paced
    /// backing. Proofs: docs/AUDIT-VAULT-2026-10-05.md, test/LaggedBacking.t.sol.
    function backedDebt() public view returns (uint256) {
        // D1: debt counts only up to the paced debt, which rises by at most FOLLOW_BPS_PER_HOUR an hour and falls
        // at once, so debt drawn to lift the ceiling must be held for hours and debt cancelled this transaction
        // (by a redemption, a liquidation or cover) backs nothing even if the same amount is drawn again.
        uint256 debt = Math.min(Math.min(totalDebt, _debtAtTransactionStart()), _pacedDebtNow());
        uint256 bad = totalBadDebt;
        return debt > bad ? debt - bad : 0;
    }

    /// @notice reserveValue + backedDebt * earnMat / 10000, in this vault's unit of account.
    /// @dev A sum, not a maximum, because the two terms are backed by different things: the reserve
    /// one-for-one by assets the protocol owns, the ratio term by the surplus collateral every
    /// borrower posts above their own debt. Section 3 of docs/COMPUTE-BACKING-DESIGN.md shows
    /// backing exceeds one for every reserve size exactly when the ratio is below mat - 1: 7000 bps at
    /// the loosest mat (170), and Parameters caps the ratio at 2500, about a third of that cliff (136%
    /// worst-case backing with an empty reserve).
    function earnLine() public view override returns (uint256) {
        return reserveValue() + Math.mulDiv(backedDebt(), parameters.earnMat(), 10_000);
    }

    /// @dev keccak256("comp.ParameterizedVault.debtAtTransactionStart"). Transient: it holds the
    /// totalDebt this transaction began at, plus one so that zero means "not recorded", and is
    /// cleared by the EVM when the transaction ends. Only the first change in a transaction writes it.
    uint256 private constant DEBT_AT_TX_START_SLOT = 0x7725e61503ba1ad2a9201f7e632975d8b51272123bd39a80dc1e04ce8746d1f6;

    function _debtChanged(uint256 previousTotal) internal override {
        uint256 recorded;
        assembly ("memory-safe") {
            recorded := tload(DEBT_AT_TX_START_SLOT)
        }
        if (recorded != 0) return;
        assembly ("memory-safe") {
            tstore(DEBT_AT_TX_START_SLOT, add(previousTotal, 1))
        }
    }

    /// @dev totalDebt as it stood before this transaction touched it; totalDebt itself if it has not.
    function _debtAtTransactionStart() private view returns (uint256) {
        uint256 recorded;
        assembly ("memory-safe") {
            recorded := tload(DEBT_AT_TX_START_SLOT)
        }
        return recorded == 0 ? totalDebt : recorded - 1;
    }
}
