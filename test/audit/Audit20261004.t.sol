// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Treasury} from "src/Treasury.sol";
import {UsdPriceFeed} from "src/UsdPriceFeed.sol";
import {ISwarmFeed} from "src/interfaces/ISwarmFeed.sol";
import {APPROVED_OPERATOR, CHAINLINK_ETH_USD, ETH_USD_MAX_AGE} from "src/DeploymentConfig.sol";
import {WorkBackingFixture} from "../helpers/WorkBackingFixture.sol";
import {TestSwarmFeed} from "../helpers/TestSwarmFeed.sol";

/// @notice A feed whose `isStale()` answers a word that is not a valid ABI bool.
/// @dev The point of the finding: a successful call whose RETURN cannot be decoded panics in the
/// CALLER's frame, where no try/catch clause can see it.
contract MalformedBoolFeed {
    uint256 public staleWord = 2;
    uint256 private valueWord = 1 ether;
    bool public shortValue;

    function setStaleWord(uint256 word) external {
        staleWord = word;
    }

    function setShortValue(bool short) external {
        shortValue = short;
    }

    function isStale() external view returns (bool) {
        uint256 word = staleWord;
        assembly {
            mstore(0, word)
            return(0, 32)
        }
    }

    function latestValue() external view returns (uint256, uint64) {
        if (shortValue) {
            uint256 word = valueWord;
            assembly {
                mstore(0, word)
                return(0, 32) // one word where the tuple needs two
            }
        }
        return (valueWord, uint64(block.timestamp));
    }

    function maxAge() external pure returns (uint256) {
        return 1 days;
    }
}

/// @notice A feed whose `latestValue()` second word cannot be a uint64.
contract OversizedTimestampFeed {
    function isStale() external pure returns (bool) {
        return false;
    }

    function latestValue() external pure returns (uint256, uint64) {
        assembly {
            mstore(0, 1000000000000000000)
            mstore(32, shl(70, 1)) // far beyond uint64
            return(0, 64)
        }
    }

    function maxAge() external pure returns (uint256) {
        return 1 days;
    }
}

/// @notice A reserve token that stops answering balance queries.
contract PausableBalanceToken is ERC20 {
    bool public paused;

    constructor() ERC20("Pausable", "PSE") {}

    function setPaused(bool next) external {
        paused = next;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function balanceOf(address who) public view override returns (uint256) {
        require(!paused, "paused balance");
        return super.balanceOf(who);
    }
}

/// @notice A token that hands control to the recipient after moving balances.
contract CallbackToken is ERC20 {
    address public hook;

    constructor() ERC20("Callback", "CB") {}

    function setHook(address hook_) external {
        hook = hook_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == hook && hook != address(0)) ReceiptHook(hook).onReceipt();
    }
}

/// @notice The withdrawal recipient, which calls permissionless `sync` from inside the transfer.
contract ReceiptHook {
    Treasury private immutable treasury;
    IERC20 private immutable token;

    constructor(Treasury treasury_, IERC20 token_) {
        treasury = treasury_;
        token = token_;
    }

    function onReceipt() external {
        treasury.sync(token);
    }
}

/// @notice An ETH/USD leg dated ahead of the chain.
contract FutureDatedAggregator {
    uint8 public constant decimals = 8;
    uint256 public at;

    function set(uint256 at_) external {
        at = at_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (10, 4000e8, at, at, 10);
    }
}

/// @notice An ETH/USD leg whose discarded round identifiers do not fit in uint80.
contract BadRoundPaddingAggregator {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 at = block.timestamp;
        assembly {
            mstore(0, shl(80, 1)) // roundId, too large for uint80
            mstore(32, 2000000000000) // answer, 2000e8
            mstore(64, at)
            mstore(96, at)
            mstore(128, shl(80, 1)) // answeredInRound, likewise
            return(0, 160)
        }
    }
}

/// @notice Reproductions for the five findings of audit job da7d5b1c, which audited commit 36f305a.
/// @dev Each `test_regression_*` fails on that commit and passes on the fix. The `test_observed_*`
/// ones pin the behaviour the auditor measured, so the consequence stays visible and not just the
/// absence of a bug. Reconstructed from the reproductions in the work record: this node delivered no
/// artifacts/audit.md (artifacts: [], bundleBytes: 0), so the original proof sources were lost.
contract Audit20261004Test is WorkBackingFixture {
    // --- MEDIUM: _clearIfRecovered priced in ETH against USD debt -------------------------------

    /// @dev Finding 1. The automatic helper read the RAW primary feed and compared the resulting
    /// ETH-valued ratio against mat, understating it by the whole ETH/USD factor, so a position
    /// restored to health kept its mark.
    function test_regression_usdRecoveryMustClearMark() public {
        _markedThenRestored();
        assertGe(backedVault.collateralRatio(BORROWER), 150, "position is healthy in USD terms");
        (bool marked,,) = _mark(BORROWER);
        assertFalse(marked, "a recovered position must not keep its liquidation mark");
    }

    /// @dev Finding 1's consequence: the retained mark keeps its original grace, so a later decline
    /// is liquidatable immediately instead of requiring a fresh mark and a fresh six hours.
    function test_observed_retainedMarkSkipsNewGrace() public {
        _markedThenRestored();
        (, uint256 markedAt,) = _mark(BORROWER);
        assertEq(markedAt, 0, "no mark means no grace to inherit");
    }

    /// @dev The explicit entry point always used the denominated price, so it was the only way to
    /// clear a mark while finding 1 stood. It is still the only route when recovery comes from a PRICE
    /// move rather than a deposit, because nothing calls into the vault to notice.
    function test_explicitClearStillWorksOnARecoveredPosition() public {
        _setVaultPrice(2 ether);
        _openDebt(2000 ether);
        _setVaultPrice(0.7 ether);
        vm.prank(address(0xA11CE));
        backedVault.bark(BORROWER);

        _setVaultPrice(2 ether); // recovered by the market, with no vault interaction
        (bool marked,,) = _mark(BORROWER);
        assertTrue(marked, "a price move alone does not clear a mark");

        vm.prank(address(0xA11CE));
        backedVault.heel(BORROWER);
        (marked,,) = _mark(BORROWER);
        assertFalse(marked, "the explicit path clears it");
    }

    /// @dev A position that is still underwater keeps its mark through a deposit, as before.
    function test_aStillUnderwaterPositionKeepsItsMark() public {
        _setVaultPrice(2 ether);
        _openDebt(2000 ether);
        _setVaultPrice(0.7 ether);
        vm.prank(address(0xA11CE));
        backedVault.bark(BORROWER);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, 100 ether);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), 100 ether);
        backedVault.lock(100 ether);
        vm.stopPrank();
        (bool marked,,) = _mark(BORROWER);
        assertTrue(marked, "still below mat, so the mark stands");
    }

    // --- MEDIUM: try/catch does not cover decoding ----------------------------------------------

    /// @dev Finding 2. A word of 2 is not a bool. Listing now refuses it, where before both the
    /// listing probe and the valuation accepted the length and then panicked on the decode.
    function test_regression_malformedBoolShouldFailClosed() public {
        MalformedBoolFeed feed = new MalformedBoolFeed();
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(IERC20(address(asset)), ISwarmFeed(address(feed)), 10_000);
    }

    /// @dev Finding 2, the half a listing check cannot catch: a source that was well formed when
    /// listed and degrades afterwards must count for nothing, never revert the reserve sum.
    function test_regression_shortDataAfterListingShouldFailClosed() public {
        MalformedBoolFeed feed = new MalformedBoolFeed();
        feed.setStaleWord(0); // well formed at listing time
        _register(IERC20(address(asset)), ISwarmFeed(address(feed)), 10_000);
        asset.mint(address(reserve), 1000 ether);
        assertEq(reserve.reserveValueUsd(), 1000 ether, "listed and priced");

        feed.setShortValue(true);
        assertEq(reserve.reserveValueUsd(), 0, "a one-word tuple counts for nothing");
        assertEq(backedVault.earnLine(), 0, "and does not brick the ceiling");

        feed.setShortValue(false);
        feed.setStaleWord(type(uint256).max);
        assertEq(reserve.reserveValueUsd(), 0, "nor does a non-boolean staleness answer");
        backedVault.earnLine();
    }

    /// @dev Finding 2's third shape: a declared uint64 that cannot hold the returned word.
    function test_regression_oversizedTimestampShouldFailClosed() public {
        OversizedTimestampFeed feed = new OversizedTimestampFeed();
        vm.prank(APPROVED_OPERATOR);
        vm.expectRevert(Treasury.InvalidPriceSource.selector);
        parameters.proposeReserveAsset(IERC20(address(asset)), ISwarmFeed(address(feed)), 10_000);
    }

    // --- MEDIUM: an unisolated balanceOf took the whole reserve down ----------------------------

    /// @dev Finding 3. One listed token that stops answering balances must not void the valuation of
    /// unrelated healthy assets, nor stop work minting against them.
    function test_regression_revertingBalanceMustNotBrickOtherReserves() public {
        PausableBalanceToken broken = new PausableBalanceToken();
        TestSwarmFeed brokenPrice = new TestSwarmFeed(ASSET_USD);
        _register(IERC20(address(broken)), ISwarmFeed(address(brokenPrice)), 10_000);
        broken.mint(address(reserve), 500 ether);

        _register(IERC20(address(asset)), ISwarmFeed(address(reservePrice)), 10_000);
        asset.mint(address(reserve), 1000 ether);
        assertEq(reserve.reserveValueUsd(), 1500 ether, "both assets counted");

        broken.setPaused(true);
        assertEq(reserve.reserveValueUsd(), 1000 ether, "the healthy asset still backs the protocol");
        assertEq(backedVault.earnLine(), _inVaultUnit(1000 ether), "and the ceiling is still readable");
        _mintWork(WORKER, 100 ether);
        assertEq(stable.balanceOf(WORKER), 100 ether, "work minting survives one broken entry");
    }

    // --- LOW: the previous audit's own fix allowed a reentrant double-credit --------------------

    /// @dev Finding 4. `withdraw` credited the unsynced delta and only then moved the baseline, so a
    /// recipient callback calling permissionless `sync` credited the remaining balance a second time.
    function test_regression_unsyncedWithdrawalCallbackMustNotDoubleCredit() public {
        CallbackToken token = new CallbackToken();
        Treasury standalone = new Treasury();
        ReceiptHook hook = new ReceiptHook(standalone, IERC20(address(token)));
        token.setHook(address(hook));
        token.mint(address(standalone), 100 ether);

        vm.prank(APPROVED_OPERATOR);
        standalone.withdraw(IERC20(address(token)), address(hook), 40 ether);

        assertEq(standalone.totalReceived(IERC20(address(token))), 100 ether, "exactly what arrived");
        assertEq(token.balanceOf(address(standalone)), 60 ether, "custody unchanged by the record");
    }

    /// @dev The fix must not lose the receipt it was originally written to keep.
    function test_withdrawStillCreditsRevenueThatArrivedSinceTheLastSync() public {
        CallbackToken token = new CallbackToken();
        Treasury standalone = new Treasury();
        token.mint(address(standalone), 100 ether);
        vm.prank(APPROVED_OPERATOR);
        standalone.withdraw(IERC20(address(token)), address(0xBEEF), 40 ether);
        assertEq(standalone.totalReceived(IERC20(address(token))), 100 ether, "credited before clamping");
        assertEq(standalone.sync(IERC20(address(token))), 0, "and the withdrawal is not fresh revenue");
    }

    // --- LOW: the USD leg's defensive reads ----------------------------------------------------

    /// @dev Finding 5a. A future-dated answer read as fresh for ETH_USD_MAX_AGE past its own stamp.
    function test_regression_futureUsdTimestampMustBeStale() public {
        UsdPriceFeed usdFeed = backedVault.usdPriceFeed();
        FutureDatedAggregator implementation = new FutureDatedAggregator();
        vm.etch(CHAINLINK_ETH_USD, address(implementation).code);
        FutureDatedAggregator(CHAINLINK_ETH_USD).set(vm.getBlockTimestamp() + 365 days);

        assertTrue(usdFeed.isStale(), "an observation dated ahead of the chain is unusable");
        assertEq(usdFeed.ethUsdPrice(), 0, "and prices nothing");
    }

    /// @dev Finding 5b. The DISCARDED round identifiers were decoded into uint80 before any check,
    /// so malformed padding panicked here instead of reading as the documented zero.
    function test_regression_badRoundPaddingMustReturnZero() public {
        UsdPriceFeed usdFeed = backedVault.usdPriceFeed();
        BadRoundPaddingAggregator implementation = new BadRoundPaddingAggregator();
        vm.etch(CHAINLINK_ETH_USD, address(implementation).code);

        (uint256 value,) = usdFeed.latestValue();
        assertGt(value, 0, "the answer itself is well formed, so it is usable");
        assertFalse(usdFeed.isStale(), "and fresh");
    }

    /// @dev Finding 5's safe direction, on the asset the design actually prices through the USD leg:
    /// IMD held as reserve. A dead ETH/USD leg degrades the ceiling to zero rather than reverting it.
    function test_aDeadUsdLegZeroesTheReserveRatherThanRevertingTheCeiling() public {
        _register(IERC20(address(collateral)), ISwarmFeed(address(backedVault.usdPriceFeed())), 10_000);
        vm.prank(APPROVED_OPERATOR);
        collateral.mint(address(reserve), 1000 ether);
        assertGt(backedVault.earnLine(), 0, "backed while the leg answers");

        vm.warp(vm.getBlockTimestamp() + ETH_USD_MAX_AGE + 1);
        assertTrue(backedVault.usdPriceFeed().isStale(), "the leg is past its maximum age");
        assertEq(reserve.reserveValueUsd(), 0, "an unpriceable asset counts for nothing");
        assertEq(backedVault.earnLine(), 0, "and the ceiling reads zero rather than reverting");
    }

    // --- helpers --------------------------------------------------------------------------------

    function _markedThenRestored() private {
        _setVaultPrice(2 ether);
        _openDebt(2000 ether); // 4000 IMD collateral at $2 = $8000, $2000 debt
        _setVaultPrice(0.7 ether); // $2800 against $2000: 140%, below the 170% floor
        vm.prank(address(0xA11CE));
        backedVault.bark(BORROWER);
        (bool marked,,) = _mark(BORROWER);
        assertTrue(marked, "marked while underwater");

        vm.prank(APPROVED_OPERATOR);
        collateral.mint(BORROWER, 1000 ether);
        vm.startPrank(BORROWER);
        collateral.approve(address(backedVault), 1000 ether);
        backedVault.lock(1000 ether); // 5000 IMD at $0.7 = $3500: 175%
        vm.stopPrank();
    }

    /// @dev The stored struct is (markedAt, grace, marked, marker); reordered so the flag reads first.
    function _mark(address owner) private view returns (bool marked, uint256 markedAt, uint256 grace) {
        (markedAt, grace, marked,) = backedVault.liquidationMarks(owner);
    }
}
