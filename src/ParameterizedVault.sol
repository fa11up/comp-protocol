// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CDPVault} from "./CDPVault.sol";
import {Parameters, ICheckpointedVault} from "./Parameters.sol";
import {Treasury} from "./Treasury.sol";
import {UsdPriceFeed} from "./UsdPriceFeed.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";

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
/// are, never where the price comes from, where the revenue goes, or which contract governs.
/// Governance over this vault is therefore bounded by what Parameters can express and by the hard
/// limits Parameters enforces on itself.
contract ParameterizedVault is CDPVault {
    /// @notice The governed source of this vault's economics. Immutable: a governor who could
    /// replace it would have unbounded authority through the replacement.
    Parameters public immutable parameters;

    /// @notice Where this vault's protocol bonus share (IMD) and paid stability fees (COMP) land,
    /// and the reserve whose value is the first term of `workCeiling`.
    Treasury public immutable treasury;

    /// @notice IMD in USD: this vault's primary IMD/ETH feed times Chainlink ETH/USD. The price
    /// source the Treasury's register is expected to hold for IMD.
    UsdPriceFeed public immutable usdPriceFeed;

    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_
    ) CDPVault(imdToken_, compToken_, oracle_, priceFeed_, nhiFeed_, spotFeed_) {
        // AUDIT FIX (job c71449d1): there is deliberately no way to pass a Parameters in. Accepting
        // one allowed an attacker to bind an impostor ahead of the deployer, and allowed a second
        // vault to borrow a Parameters already bound elsewhere and read a rate it is never
        // checkpointed for. The vault creates its own, which also means the pair comes up linked with
        // no post-deploy transaction — what a launch manifest requires, since it makes none and can
        // name at most four contracts.
        parameters = new Parameters(ICheckpointedVault(address(this)));
        // The same idiom for the other two, and for the same reasons: a Treasury passed in could be
        // anyone's wallet (which is what FEE_RECIPIENT is today), and a manifest has no fifth slot
        // to deploy one in. Created here, the Treasury's creator is this vault, so its register is
        // governed by this vault's Parameters and refuses this vault's COMP, with nothing bound later.
        treasury = new Treasury();
        usdPriceFeed = new UsdPriceFeed(ISwarmFeed(priceFeed_));
    }

    function debtCeiling() public view override returns (uint256) {
        return parameters.debtCeiling();
    }

    function protocolBonusShareBps() public view override returns (uint256) {
        return parameters.protocolBonusShareBps();
    }

    function stabilityFeeBps() public view override returns (uint256) {
        return parameters.stabilityFeeBps();
    }

    function maxDivergenceBps() public view override returns (uint256) {
        return parameters.maxDivergenceBps();
    }

    function markerShareBps() public view override returns (uint256) {
        return parameters.markerShareBps();
    }

    /// @notice Both revenue streams land in the Treasury this vault created, never in an account.
    function feeRecipient() public view override returns (address) {
        return address(treasury);
    }

    /// @notice The ratio term of the work ceiling, in basis points of collateral-backed debt.
    function workRatioBps() public view returns (uint256) {
        return parameters.workRatioBps();
    }

    /// @notice The Treasury's reserve in this vault's own unit of account: `reserveValueUsd()` divided
    /// by Chainlink ETH/USD. Zero while that leg is stale, so a dead USD price only tightens the ceiling.
    /// @dev The vault's unit is whatever the primary feed prices collateral in — the pinned question
    /// asks for wei of ETH per IMD, so one COMP of debt is one ETH-worth of collateral to `minCR`,
    /// `liquidate` and `debtCeiling`. The register is kept in USD, as the design specifies, and the
    /// conversion happens here where the unit is known, so the two terms of `workCeiling` are added in
    /// the same unit. For IMD priced through `usdPriceFeed` the ETH/USD leg cancels exactly and the
    /// reserve is worth balance x primary price x haircut, which is what the vault itself would lend
    /// against. REVISION (finding 9366455): before this the USD figure was added to debt unconverted,
    /// authorising ETH/USD times more work minting than the reserve was worth in the vault's unit.
    function reserveValue() public view returns (uint256) {
        uint256 usd = treasury.reserveValueUsd();
        if (usd == 0) return 0;
        uint256 ethUsd = usdPriceFeed.ethUsdPrice();
        if (ethUsd == 0) return 0;
        return Math.mulDiv(usd, 1e18, ethUsd);
    }

    /// @notice The principal the ratio term may count: `totalDebt`, capped at what it was when this
    /// transaction began, less the principal recorded as bad debt.
    /// @dev Two exclusions, one for each way principal can stand for collateral that is not there.
    /// REVISION (finding 4d30331c): debt created in the current transaction does not count. Without
    /// that, a rights holder with transient capital raised totalDebt with their own position, minted
    /// work against a quarter of it, repaid (a zero-second fee is zero) and withdrew everything in one
    /// call, leaving work-minted COMP with nothing behind it. The cap is the debt level at the start of
    /// the transaction, remembered in transient storage, so the ratio term is only ever backed by
    /// positions that existed before the caller arrived. A position held across transactions counts
    /// in full, so the ceiling stays point-in-time for the slow version of the same round trip: that is
    /// the accepted design (the ceiling gates new minting only; repayment lowers it and leaves what was
    /// minted), and the cost of it is real capital at risk in an open position, not gas.
    /// REVISION (finding e3888b1e): `totalBadDebt` is subtracted, saturating. After a liquidation
    /// drains a position its residual principal stays in totalDebt with no collateral behind it, and
    /// it was credited as if surplus collateral stood behind it. totalBadDebt is accrued debt (fees
    /// included) while totalDebt is principal, so the subtraction over-counts slightly, in the
    /// tightening direction. A position left with collateral below the liquidation payout but not yet
    /// drained is not recorded until someone finishes it; the remainder is seizable at the usual 10%
    /// bonus, and the sweep in `liquidate` then records it.
    function backedDebt() public view returns (uint256) {
        uint256 debt = Math.min(totalDebt, _debtAtTransactionStart());
        uint256 bad = totalBadDebt;
        return debt > bad ? debt - bad : 0;
    }

    /// @notice reserveValue + backedDebt * workRatioBps / 10000, in this vault's unit of account.
    /// @dev A sum, not a maximum, because the two terms are backed by different things: the reserve
    /// one-for-one by assets the protocol owns, the ratio term by the surplus collateral every
    /// borrower posts above their own debt. Section 3 of docs/COMPUTE-BACKING-DESIGN.md shows
    /// backing exceeds one for every reserve size exactly when the ratio is below minCR - 1, and
    /// Parameters caps the ratio at half that cliff.
    function workCeiling() public view override returns (uint256) {
        return reserveValue() + Math.mulDiv(backedDebt(), parameters.workRatioBps(), 10_000);
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
