// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Governed} from "./Governed.sol";
import {Treasury} from "./Treasury.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {
    CHIP_BPS,
    SKEW_BPS,
    CUT_BPS,
    DUTY_BPS,
    LINE,
    EARN_MAT_BPS,
    WAGE_WAD,
    ORACLE_BUDGET_PER_DAY,
    MAX_ORACLE_BUDGET_PER_DAY,
    REDEMPTION_DIVISOR,
    STREAM_PAYEE,
    STREAM_PER_DAY
} from "./DeploymentConfig.sol";

/// @notice The vault's economic knobs, moved out of source constants into a governed contract.
interface ICheckpointedVault {
    function totalDebt() external view returns (uint256);
    function drip() external;
    function treasury() external view returns (address);
    function oracle() external view returns (address);
    function totalEarned() external view returns (uint256);
}

/// @dev What a replacement work oracle must answer. `predecessor` is required only once anything has
/// ever been minted from work (see `proposeWorkOracle`).
interface IWorkOracleSuccessor {
    function vault() external view returns (address);
    function mintingRights(address account) external view returns (uint256);
    function predecessor() external view returns (address);
}

/// @notice The numbers that set the protocol's economics, and the reserve register that backs its
/// work minting, changeable under a delay.
/// @dev Why these and not everything: a parameter is safe to govern when the worst a wrong value can
/// do is price the protocol badly. A fee can be too high, a ceiling too tight, a divergence bound too
/// loose — each is a bad business decision that a borrower can see coming and exit ahead of. The
/// things deliberately NOT here are the ones where a wrong value is not a bad decision but a theft:
/// the attester, the three feeds and the collateral token. Swapping a feed is not adjusting a
/// parameter, it IS control of the price, and whoever sets the price can bite everyone. Those
/// stay immutable in the vault, which is why this contract is given no way to reach them.
///
/// Every bound below is a constant in this file rather than a governance choice, so the governor
/// cannot widen these bounds — raising the fee cap takes a new Parameters contract and a new vault,
/// which is a visible event rather than a transaction.
///
/// TRUST ASSUMPTION, stated rather than denied (final panel audit, governance, info): the governor can
/// mint. It lists any token the Treasury holds as a reserve asset against any price source that answers
/// in shape (`proposeReserveAsset`), which sets the reserve term of `earnLine` up to MAX_RESERVE_VALUE per
/// asset; and while the wage is zero it can install a work oracle it controls (`proposeWorkOracle`).
/// Together that is minting with no collateral and no attested work, diluting every imdUSD holder. One
/// proposal slot and a 48-hour delay on each step put the full path (listing, oracle, wage) at 144 hours
/// of public proposals from the launch state, 192 from a running wage (which must first go to zero); the
/// oracle and wage pair alone (96 hours) mints only against the ratio term, a quarter of the warmed
/// collateral-backed debt. The listing step by itself, with neither oracle nor wage, already moves money:
/// the listed value raises the redemption backing, so `cash` pays redeemers more from the reserve. The
/// per-listing cap (Treasury.MAX_RESERVE_VALUE, $1e18) is an overflow bound and not a limit on damage,
/// and the register's length is unbounded. `earn` is refused while the wage is zero. The governor is a
/// cold key for all of this (docs/MAINNET-RUNBOOK.md section 3).
contract Parameters is Governed {
    struct ParamSet {
        uint256 line;
        uint256 cut;
        uint256 duty;
        uint256 skew;
        uint256 chip;
    }

    /// @notice What a pending payload changes. One Governed slot, several shapes of change: the
    /// payload's first word says which, so the 48-hour delay, the public pending window and the
    /// permissionless application are the same code for all of them.
    /// @dev The work ratio and the register travel separately from the five-value set rather than
    /// inside it, so a listing can be queued without restating every fee and a fee change without
    /// naming an asset — and so the set a borrower prices against keeps its shape.
    enum Change {
        Economics,
        EarnMat,
        ReserveAsset,
        Wage,
        Gap,
        OracleBudget,
        RedemptionDivisor,
        Stream,
        WorkOracle
    }

    uint256 private constant BPS = 10_000;

    /// @notice Hard cap on the work ceiling's ratio term. 7000 is the cliff where worst-case backing
    /// touches one at the loosest NHI (mat 170); at 2500 it is 136% with an empty reserve.
    /// A constant, so governance can lower the ratio and can never raise it past here.
    uint256 public constant MAX_EARN_MAT_BPS = 2_500;

    /// @notice Hard cap on the imdUSD one accepted task earns. One task can never be worth more than
    /// one imdUSD, whatever a governor proposes.
    /// @dev The binding constraint on work minting is the work ceiling, not this: the ceiling asks
    /// whether backing exists, and this only converts a count into an amount. The cap is here anyway
    /// because the two multiply — an unbounded rate would let a governor turn a modest task count
    /// into a claim the ceiling then has to absorb — and because a rate above one imdUSD per task makes
    /// no sense against a token meant to be worth a dollar.
    uint256 public constant MAX_WAGE_WAD = 1 ether;

    /// @notice Bounds on the redemption fee divisor: each redemption raises the fee base by
    /// redeemed / supply / divisor. At 1 a run reaches the 5% cap after 4.5% of supply; at 8 it takes
    /// 36%. Outside these the fee is either a wall or no brake at all.
    uint256 public constant MIN_REDEMPTION_DIVISOR = 1;
    uint256 public constant MAX_REDEMPTION_DIVISOR = 8;

    /// @notice Hard cap on the operator stream, in imdUSD per UTC day ($182,500 a year). A constant,
    /// so no proposal can turn the stream into a drain.
    uint256 public constant MAX_STREAM_PER_DAY = 500 ether;

    uint256 public constant MIN_GAP = 25;
    uint256 public constant MAX_GAP = 100;
    /// @notice Ratio points above the NHI-derived mat, never an absolute ceiling.
    uint256 public gap = 50;

    /// @notice Hard cap on the annual stability fee. 10% is high for a fee this protocol charges on
    /// its own stablecoin; above it the fee stops being a cost of borrowing and becomes a way to
    /// drive positions into liquidation.
    uint256 public constant MAX_DUTY_BPS = 1_000;

    /// @notice Floor on the divergence bound. Below 1% the primary feed and the spot feed disagree
    /// from ordinary market noise alone and the vault halts constantly.
    uint256 public constant MIN_DIVERGENCE_BPS = 100;

    /// @notice Ceiling on the divergence bound. The bound is the only thing standing between a bad
    /// attestation and the collateral; at 20% it is already permissive.
    uint256 public constant MAX_SKEW_BPS = 2_000;

    /// @notice The live values.
    ParamSet private _current;

    /// @notice The live ratio term of the vault's work ceiling, in basis points of totalDebt.
    uint256 private _earnMat;

    /// @notice The live imdUSD-per-accepted-task rate, 1e18-scaled.
    uint256 private _wage;
    /// @notice IMD the Treasury may stream to the oracle asker per UTC day. Governed, and hard-capped
    /// at MAX_ORACLE_BUDGET_PER_DAY so no proposal can turn the stream into a drain.
    uint256 public oracleBudget;
    /// @notice The live redemption fee divisor; see MIN_/MAX_REDEMPTION_DIVISOR.
    uint256 public redemptionDivisor;
    /// @notice Who the Treasury's operator stream pays, and at most how much imdUSD per UTC day.
    address public streamPayee;
    uint256 public streamPerDay;
    /// @notice A replacement for the vault's work oracle; zero means the one the vault created. Exists so
    /// that integrating minting from work upstream never forces a new vault: the created oracle pins the
    /// WorkRegistry, the receipt schema and its leaf encoding in bytecode, and any of those may change.
    address public workOracle;

    /// @notice The vault these parameters govern: its creator, fixed at construction.
    /// @dev Needed for two things that cannot be done without it: checking a proposed ceiling
    /// against debt that is actually outstanding, and checkpointing the fee index before the rate
    /// changes. The binding is one-way and one-time — it is an address this contract reads, never an
    /// authority over the vault beyond the permissionless `drip`.
    ICheckpointedVault public vault;

    error ZeroVault();
    error FeeTooHigh(uint256 bps);
    error DivergenceOutOfRange(uint256 bps);
    error SharesExceedBonus(uint256 markerBps, uint256 protocolBps);
    error ZeroCeiling();
    error EarnMatTooHigh(uint256 bps);
    error WageTooHigh(uint256 wad);
    error GapOutOfRange(uint256 spread);
    error OracleBudgetTooHigh(uint256 imdPerDay);
    error RedemptionDivisorOutOfRange(uint256 divisor);
    error StreamTooHigh(uint256 perDay);
    error WorkMintingOn();
    error InvalidWorkOracle();
    error StreamPayeeMissing();

    /// @dev Seeded from the shipped constants, so a fresh Parameters is exactly the configuration
    /// the vault would have had with them compiled in — including the unlimited default ceiling,
    /// which CDPVault pins as a literal rather than a named constant. Governance starts from the
    /// status quo, so binding it to a live vault changes nothing by itself.
    /// @param vault_ the vault these parameters govern, which is always its creator.
    /// @dev AUDIT FIX (two mediums, job c71449d1). Parameters used to be deployable standalone and
    /// bound afterwards, which was unsafe in two ways that share one root cause — the binding was a
    /// separate transaction. An attacker could front-run the deployer and bind an impostor whose
    /// `drip` does nothing, so rate changes reached the real vault with no checkpoint; and a
    /// second vault could be pointed at an already-bound Parameters and read a rate it is never
    /// checkpointed for. Both end in `stabilityFeeOf` underflowing and freezing positions.
    ///
    /// There is no fix that keeps a separate binding transaction: a mid-construction callback cannot
    /// verify the caller, because the vault has no code yet. So the transaction is gone. A vault
    /// creates its own Parameters and is the only thing it can ever govern, which also means a
    /// deployment comes up linked with nothing sent afterwards — what a launch manifest requires.
    constructor(ICheckpointedVault vault_) {
        if (address(vault_) == address(0)) revert ZeroVault();
        vault = vault_;
        _current = ParamSet({
            line: LINE,
            cut: CUT_BPS,
            duty: DUTY_BPS,
            skew: SKEW_BPS,
            chip: CHIP_BPS
        });
        // The shipped ratio is subject to the same bound as any proposal; a constant above the cap
        // is a misconfiguration this contract refuses to be deployed with.
        if (EARN_MAT_BPS > MAX_EARN_MAT_BPS) revert EarnMatTooHigh(EARN_MAT_BPS);
        _earnMat = EARN_MAT_BPS;
        // Same treatment as the ratio: a shipped constant above its own cap is a misconfiguration
        // this contract refuses to exist with, rather than one discovered at the first proposal.
        if (WAGE_WAD > MAX_WAGE_WAD) revert WageTooHigh(WAGE_WAD);
        _wage = WAGE_WAD;
        if (ORACLE_BUDGET_PER_DAY > MAX_ORACLE_BUDGET_PER_DAY) revert OracleBudgetTooHigh(ORACLE_BUDGET_PER_DAY);
        oracleBudget = ORACLE_BUDGET_PER_DAY;
        _checkDivisor(REDEMPTION_DIVISOR);
        redemptionDivisor = REDEMPTION_DIVISOR;
        _checkStream(STREAM_PAYEE, STREAM_PER_DAY);
        (streamPayee, streamPerDay) = (STREAM_PAYEE, STREAM_PER_DAY);
    }

    /// @notice Queue a complete replacement set. Always all five, so the pending payload is the whole
    /// configuration a borrower will face rather than a diff they have to apply themselves.
    function propose(ParamSet calldata next) external {
        _propose(abi.encode(Change.Economics, next));
    }

    /// @notice Queue a change to the work ceiling's ratio term. Refused above MAX_EARN_MAT_BPS.
    function proposeEarnMat(uint256 bps) external {
        _propose(abi.encode(Change.EarnMat, bps));
    }

    /// @notice Queue a change to the imdUSD an accepted task earns. Refused above one imdUSD per task.
    function proposeWage(uint256 wad) external {
        _propose(abi.encode(Change.Wage, wad));
    }

    function proposeGap(uint256 spread) external {
        _propose(abi.encode(Change.Gap, spread));
    }

    /// @notice Queue a change to the daily oracle budget. Refused above MAX_ORACLE_BUDGET_PER_DAY.
    function proposeOracleBudget(uint256 imdPerDay) external {
        _propose(abi.encode(Change.OracleBudget, imdPerDay));
    }

    /// @notice Propose the redemption fee divisor, within MIN_/MAX_REDEMPTION_DIVISOR.
    function proposeRedemptionDivisor(uint256 divisor) external {
        _propose(abi.encode(Change.RedemptionDivisor, divisor));
    }

    /// @notice Replace the vault's work oracle (zero: back to the one it created). Refused while minting
    /// from work is ON — at proposal and again at application — so no rights are ever CONSUMABLE in two
    /// oracles at once: the vault reads one oracle, `earn` is refused at wage 0, and a superseded
    /// `SwarmWorkOracle` refuses claims once it is no longer the vault's oracle. Once anything has ever
    /// been minted from work, or CREDITED by a claim and not yet minted (`SwarmWorkOracle.totalCredited`),
    /// the replacement must name the current oracle as its `predecessor`, so it can start from the tallies
    /// already credited instead of crediting them a second time; before that, there is nothing to carry
    /// over.
    /// @dev A governed power, not a neutral one: see the trust assumption on this contract. The 48-hour
    /// delay applies like every other change. `SwarmWorkOracle` answers no `predecessor()`, so once
    /// anything has been minted the successor has to be a new contract type that does (and that carries
    /// the old tallies): until one exists the oracle cannot be replaced after the first mint, which is the
    /// documented position (second-half review 2026-10-07, info). Before the first mint, a fresh
    /// `SwarmWorkOracle` built DIRECTLY for this vault, `new SwarmWorkOracle(address(vault), maxAge)` from
    /// any account, qualifies. `WorkOracleFactory.create` does not: it binds the oracle to its caller,
    /// which is the vault only inside the vault's own constructor (final panel audit, governance, info).
    function proposeWorkOracle(address next) external {
        _propose(abi.encode(Change.WorkOracle, next));
    }

    /// @notice Propose who the operator stream pays and its daily cap. A zero amount turns it off.
    function proposeStream(address payee, uint256 perDay) external {
        _propose(abi.encode(Change.Stream, payee, perDay));
    }

    /// @notice Queue a listing, repricing or (with a zero price source) delisting of one of the
    /// Treasury's reserve assets. The Treasury's own rules apply at proposal — imdUSD is refused with
    /// `StablecoinIsNotReserve`, a haircut must be at most 10000, the vault's collateral only against its
    /// own collateral price — so a change the register would refuse never occupies the slot. Applying it,
    /// like every other change, is anyone's to do after the delay.
    function proposeReserveAsset(IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) external {
        _propose(abi.encode(Change.ReserveAsset, asset, priceFeed, haircutBps));
    }

    function current() external view returns (ParamSet memory) {
        return _current;
    }

    function earnMat() external view returns (uint256) {
        return _earnMat;
    }

    /// @notice What SwarmWorkOracle multiplies an attested task count by, 1e18-scaled.
    function wage() external view returns (uint256) {
        return _wage;
    }

    function line() external view returns (uint256) {
        return _current.line;
    }

    function cut() external view returns (uint256) {
        return _current.cut;
    }

    function duty() external view returns (uint256) {
        return _current.duty;
    }

    function skew() external view returns (uint256) {
        return _current.skew;
    }

    function chip() external view returns (uint256) {
        return _current.chip;
    }

    /// @notice What kind of change is waiting, and when it can be applied; eta is zero if nothing is.
    function pendingChange() public view returns (Change kind, uint256 eta) {
        if (pendingEta == 0) return (kind, 0);
        return (_kind(pending), pendingEta);
    }

    /// @notice The pending five-value set, or an empty one with a zero eta if the pending change is
    /// of another kind or there is none. `pendingChange` says which.
    function pendingSet() external view returns (ParamSet memory next, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.Economics) return (next, 0);
        (, next) = abi.decode(pending, (Change, ParamSet));
        return (next, at);
    }

    function pendingEarnMat() external view returns (uint256 bps, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.EarnMat) return (0, 0);
        (, bps) = abi.decode(pending, (Change, uint256));
        return (bps, at);
    }

    function pendingOracleBudget() external view returns (uint256 imdPerDay, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.OracleBudget) return (0, 0);
        (, imdPerDay) = abi.decode(pending, (Change, uint256));
        return (imdPerDay, at);
    }

    function pendingRedemptionDivisor() external view returns (uint256 divisor, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.RedemptionDivisor) return (0, 0);
        (, divisor) = abi.decode(pending, (Change, uint256));
        return (divisor, at);
    }

    function pendingStream() external view returns (address payee, uint256 perDay, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.Stream) return (address(0), 0, 0);
        (, payee, perDay) = abi.decode(pending, (Change, address, uint256));
        return (payee, perDay, at);
    }

    function pendingGap() external view returns (uint256 spread, uint256 eta) {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.Gap) return (0, 0);
        (, spread) = abi.decode(pending, (Change, uint256));
        return (spread, at);
    }

    function pendingReserveAsset()
        external
        view
        returns (IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps, uint256 eta)
    {
        (Change kind, uint256 at) = pendingChange();
        if (at == 0 || kind != Change.ReserveAsset) return (asset, priceFeed, 0, 0);
        (, asset, priceFeed, haircutBps) = abi.decode(pending, (Change, IERC20, ISwarmFeed, uint256));
        return (asset, priceFeed, haircutBps, at);
    }

    function _kind(bytes memory payload) private pure returns (Change) {
        return abi.decode(payload, (Change));
    }

    function _treasury() private view returns (Treasury) {
        return Treasury(payable(vault.treasury()));
    }

    function _predecessor(address oracle) private view returns (address) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("predecessor()"));
        return ok && data.length == 32 ? abi.decode(data, (address)) : address(0);
    }

    function _credited(address oracle) private view returns (uint256) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("totalCredited()"));
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : 0;
    }

    function _checkDivisor(uint256 divisor) private pure {
        if (divisor < MIN_REDEMPTION_DIVISOR || divisor > MAX_REDEMPTION_DIVISOR) {
            revert RedemptionDivisorOutOfRange(divisor);
        }
    }

    function _checkStream(address payee, uint256 perDay) private pure {
        if (perDay > MAX_STREAM_PER_DAY) revert StreamTooHigh(perDay);
        if (perDay != 0 && payee == address(0)) revert StreamPayeeMissing();
    }

    function _validate(bytes memory payload) internal view override {
        Change kind = _kind(payload);
        if (kind == Change.WorkOracle) {
            (, address replacement) = abi.decode(payload, (Change, address));
            if (_wage != 0) revert WorkMintingOn();
            // Anything to carry over: rights minted, or rights CREDITED by claims and not yet minted. Keyed
            // on totalEarned alone, a replacement between a claim and its mint stranded rights priced at
            // the old wage (sweep panel audit, governance, low). Probed, so an oracle without the view (the
            // test faucet) answers nothing to carry.
            bool minted = vault.totalEarned() != 0 || _credited(address(vault.oracle())) != 0;
            if (replacement == address(0)) {
                if (minted) revert InvalidWorkOracle();
                return;
            }
            IWorkOracleSuccessor successor = IWorkOracleSuccessor(replacement);
            if (replacement.code.length == 0 || successor.vault() != address(vault)) revert InvalidWorkOracle();
            successor.mintingRights(address(vault));
            // Probed, so a successor without the view (SwarmWorkOracle) is refused with this contract's own
            // error rather than an empty revert from the typed call.
            if (minted && _predecessor(replacement) != address(vault.oracle())) revert InvalidWorkOracle();
            return;
        }
        if (kind == Change.RedemptionDivisor) {
            (, uint256 divisor) = abi.decode(payload, (Change, uint256));
            _checkDivisor(divisor);
            return;
        }
        if (kind == Change.Stream) {
            (, address payee, uint256 perDay) = abi.decode(payload, (Change, address, uint256));
            _checkStream(payee, perDay);
            return;
        }
        if (kind == Change.Gap) {
            (, uint256 spread) = abi.decode(payload, (Change, uint256));
            if (spread < MIN_GAP || spread > MAX_GAP) {
                revert GapOutOfRange(spread);
            }
            return;
        }
        if (kind == Change.EarnMat) {
            (, uint256 bps) = abi.decode(payload, (Change, uint256));
            if (bps > MAX_EARN_MAT_BPS) revert EarnMatTooHigh(bps);
            return;
        }
        if (kind == Change.OracleBudget) {
            (, uint256 imdPerDay) = abi.decode(payload, (Change, uint256));
            if (imdPerDay > MAX_ORACLE_BUDGET_PER_DAY) revert OracleBudgetTooHigh(imdPerDay);
            return;
        }
        if (kind == Change.Wage) {
            (, uint256 wad) = abi.decode(payload, (Change, uint256));
            if (wad > MAX_WAGE_WAD) revert WageTooHigh(wad);
            return;
        }
        if (kind == Change.ReserveAsset) {
            (, IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) =
                abi.decode(payload, (Change, IERC20, ISwarmFeed, uint256));
            // The register's rules, applied where they fail fast and with the register's own errors.
            _treasury().validateReserveAsset(asset, priceFeed, haircutBps);
            return;
        }
        (, ParamSet memory next) = abi.decode(payload, (Change, ParamSet));

        if (next.duty > MAX_DUTY_BPS) revert FeeTooHigh(next.duty);
        if (next.skew < MIN_DIVERGENCE_BPS || next.skew > MAX_SKEW_BPS) {
            revert DivergenceOutOfRange(next.skew);
        }
        // The vault pays the marker out of the liquidator's bonus and keeps the protocol's cut from
        // the same bonus; together they cannot exceed it, or a liquidation owes more than it earns.
        //
        // AUDIT NOTE (job c71449d1, info): this bound is economically empty at its top. At
        // cut 10000 a liquidator who did not mark receives exactly the principal
        // back — no reward for the stablecoin, the inventory risk or the gas — so liquidations stop
        // and bad debt accumulates. It stays a bound rather than a tighter cap because the borrower's
        // loss is identical at every split and the change is visible for 48 hours, so this is a trust
        // assumption to state plainly, not a bypass to close.
        if (next.chip + next.cut > BPS) {
            revert SharesExceedBonus(next.chip, next.cut);
        }
        if (next.line == 0) revert ZeroCeiling();

        // There is deliberately NO check that the ceiling clears outstanding debt, and an independent
        // audit is why (job c71449d1, low). Checking it at application made the proposal's success
        // depend on a figure third parties control: minting is permissionless up to the CURRENT
        // ceiling, so any borrower with collateral could front-run applyPending with draw to keep
        // totalDebt above the proposed figure, then repay next block and repeat. The whole five-value
        // payload travelled in one struct, so a fee or divergence change could be held hostage too.
        //
        // The check was also protecting nothing. A ceiling below outstanding debt strands no one: it
        // gates new minting only, and repayment, withdrawal and liquidation are not ceiling-gated. So
        // the worst a low ceiling does is stop growth, which is what a ceiling is for.
    }

    function _apply(bytes memory payload) internal override {
        Change kind = _kind(payload);
        if (kind == Change.WorkOracle) {
            (, workOracle) = abi.decode(payload, (Change, address));
            return;
        }
        if (kind == Change.RedemptionDivisor) {
            (, redemptionDivisor) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.Stream) {
            (, streamPayee, streamPerDay) = abi.decode(payload, (Change, address, uint256));
            return;
        }
        if (kind == Change.Gap) {
            (, gap) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.EarnMat) {
            (, _earnMat) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.OracleBudget) {
            (, oracleBudget) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.Wage) {
            (, _wage) = abi.decode(payload, (Change, uint256));
            return;
        }
        if (kind == Change.ReserveAsset) {
            (, IERC20 asset, ISwarmFeed priceFeed, uint256 haircutBps) =
                abi.decode(payload, (Change, IERC20, ISwarmFeed, uint256));
            _treasury().setReserveAsset(asset, priceFeed, haircutBps);
            return;
        }
        // Freeze accrual to date at the old rate, in this transaction, before the new rate is
        // readable. The vault's index is linear from its last checkpoint, so without this the change
        // would reach time that has already passed.
        vault.drip();
        (, _current) = abi.decode(payload, (Change, ParamSet));
    }
}
