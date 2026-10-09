# Paced vault panel audit — 2026-10-08

Job `dc27aade-6adb-40da-b6d8-0bddfe280ebf` (explorer: https://explorer.imd.fun/jobs/dc27aade-6adb-40da-b6d8-0bddfe280ebf), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `d3861ac5cd4fc50dfdac18dd59efed61b6d5bd8b`.

Scope: the vault in full after the paced figures replaced the per-position lag (record 23), the pacing first and longest, its accepted items given as claims to break. Payload: `whitepaper/requests/audit/audit-paced-vault-panel-quote.json` (`build_audits.py`, Phase 12).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 184 (agent 52205) | audit_judge | completed | 11 | 20 | 32,097 |
| 435 (agent 52255) | audit_math | completed | 4 | 33 | 64,516 |
| 671 (agent 51143) | audit_economics | completed | 3 | 45 | 113,646 |
| 498 (agent 51874) | audit_permissions | completed | 6 | 43 | 107,587 |
| 595 (agent 51142) | audit_flow | completed | 7 | 44 | 96,571 |

The judge's merged list is the result: 3 medium, 2 low, 6 info, nothing critical or high. Judge submission hash `59c3ee342c50c9797d1c2121e7429eecaaef443a4a43c102977e128df1f8b6cd`; raw record of every seat beside this file (`audit-paced-vault-panel-2026-10-08-submission.json`).

**Judge's summary, verbatim:**

> The review is complete. The source tree is unchanged, the findings file parses, and every reproduction fails on the pinned commit for the stated reason.
>
> **Outcome.** Eleven findings are in `.imd-findings.json`: three medium, two low, six info. No critical or high. Every kept finding was reproduced against d3861ac with a Foundry test; the specialists' twenty findings were merged into these eleven, and nothing was dropped for failing to reproduce.
>
> **The three mediums, in rank order:**
>
> - **Draw-then-cancel is never clamped.** The paced-debt clamp runs only after `draw`, so a transaction that draws X and then cancels X of someone else's debt by cash, bite or cover leaves zero-second debt counting in full for the work ceiling next block. Both attached proofs fail for exactly this reason. Nothing is takeable at wage 0; once a wage is set it is the D1 round trip at zero holding time. Fix is three `_clampPacedDebt()` calls after the cancellations. I verified the fix makes all five proof tests pass and costs 22 bytes of initcode. This finding carries the proof.
> - **The accepted dip is not "below par only".** A par book whose par reading is carried by one dominant healthy position dips to the rest-of-book figure when that position wipes and redraws across two blocks. Reproduced at 0.80 on a par book with an underwater tail, no bad debt, wage 0. The three specialist shapes (underwater tail, realized bad debt, work supply) are merged into one finding, since the mechanism and the NatSpec correction are the same.
> - **Nobody but the owner re-prices a debt-bound term.** Marked at a crash low, a high-CR position's term over-reads after recovery and lifts the payout to par when honest backing is 0.86, draining the Treasury's reserve first. The same gap makes the accepted stale-term read after a fall last until the owner acts, not "a few hours". One permissionless re-price function closes both directions.
>
> **The lows** are the pacing clock advancing on an unusable price (anyone forfeits a recovering payout's rise with one call per stale window) and the launch-day fee base starting from zero (a 1% redemption is quoted at 300 bps instead of 100 for about 27 paced hours, contradicting the "only lowers fees" sentence).
>
> **The infos** are the NatSpec defects Q8 asks for: the dead `_mark` reference, the `earnLine` formula, the follow rate compounding under frequent pacing, the "every redeemable one" claim against a 220 ceiling, the per-transaction WIPED tally described as per-position, and `backingPerUnit()` reading an ungated price.
>
> **Coverage.** Read in full: CDPVault, ParameterizedVault, ImdUSD, plus the Treasury valuation path, SharePriceFeed, UsdPriceFeed and SwarmFeed entry points on the ungated pacing path, which I confirmed cannot revert `lock` or `wipe`. Not reached: liquidation and cover were checked only by reading, not by new tests, since the specialists raised nothing there and earlier rounds cover them.

| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | medium | no | `src/CDPVault.sol:742` | Paced debt is clamped only after draw: a draw followed by cash, bite or cover in one transaction leaves zero-second debt counting in full for the work ceiling |
| 2 | medium | no | `src/CDPVault.sol:323` | Paced backing: the accepted dip's stated bound 'exists only while the book is backed below par' does not hold; a par book dips to the rest-of-book figure on a dominant position's wipe and redraw acros |
| 3 | medium | no | `src/CDPVault.sol:333` | A debt-bound term is re-priced by nobody but its owner: marked at a crash low it overpays redeemers past the honest backing after a recovery (reserve first), and after a fall it underpays for as long  |
| 4 | low | no | `src/CDPVault.sol:868` | _pace advances _pacedAt when the backing is held for an unusable price, so any ungated call or pace() during a stale or diverged window forfeits the interval's rise; a stated 'quiet gap recovers one i |
| 5 | low | no | `src/CDPVault.sol:1073` | Launch-day fee: the paced supply starts at zero and follows at 10% an hour, so for about 27 paced hours a redemption's increase is measured against the 100,000 floor while the live supply is 500,000,  |
| 6 | info | no | `src/CDPVault.sol:316` | NatSpec: the follow bound 'at most FOLLOW_BPS_PER_HOUR an hour' compounds under frequent pacing (10.52% an hour paced every block, 11x not 9.85x over a day) |
| 7 | info | no | `src/ParameterizedVault.sol:172` | Stale cross-reference: ParameterizedVault._redemptionReserveBacking cites CDPVault._mark, which this commit removed; the caller is CDPVault._pace through _liveBacking |
| 8 | info | no | `src/CDPVault.sol:202` | NatSpec: CDPVault.earnLine says ParameterizedVault overrides it with reserveValueUsd + totalDebt x earnMat / 10000; the override uses backedDebt (min of totalDebt, the transaction-start debt and the p |
| 9 | info | no | `src/CDPVault.sol:266` | NatSpec: securedCollateral says the exactly-counted set (at most 200% at the touch price) 'includes every redeemable one', but redemption eligibility is mat + gap = 220 at the launch constants |
| 10 | info | no | `src/CDPVault.sol:847` | Comment: WIPED_THIS_TX_SLOT is said to tally principal the caller repaid 'on its own position'; the tally is per transaction, so one contract's wipe and another's draw in the same transaction also net |
| 11 | info | no | `src/CDPVault.sol:754` | NatSpec: backingPerUnit() is said to read 'the latest accepted price', but it reads _price() with no freshness or agreement check, so it quotes against a stale or diverged nonzero price |

## 1. [MEDIUM] Paced debt is clamped only after draw: a draw followed by cash, bite or cover in one transaction leaves zero-second debt counting in full for the work ceiling

`src/CDPVault.sol:742` — blocking: no; citation: resolved

```solidity
            (principalCancelled, freshCancelled) = _redeemPosition(candidate, debtCancelled, gemOut - reserveOut, price);
```

CDPVault._clampPacedDebt (lines 876-882) lowers _debtPaced to totalDebt + WIPED - MINTED and is called from draw only (line 504). In the order lock, draw(X), cash(X, 0, victim) (or draw then bite(victim, X), or draw then cover(drained, X)) the clamp runs while the cancellation has not happened yet (live = T + X - X = T, no change), and _redeemPosition / bite / cover then lower totalDebt with no clamp. The transaction ends with totalDebt = T and _debtPaced = T, though X of that T was drawn seconds ago; the next transaction's _pace finds live T >= paced T and keeps T, so ParameterizedVault.backedDebt counts the fresh X in full. The NatSpec at CDPVault 308-311 and 871-875 and ParameterizedVault 237-239 and 261-263 ('debt cancelled by a redemption, a liquidation or cover and drawn again backs nothing until it has been held'; 'the paced debt never exceeds the debt this transaction began with less what it has cancelled') holds only for cancel-then-draw, the order the sweep panel's proof used. Reachability with the constants as committed: the ordering is reachable now; its only consumer is the work ceiling and WAGE_WAD is 0, so earn is refused and nothing can be taken at launch. Once governance sets a wage (48-hour timelock) it is the D1 round trip at zero holding time: 25% (EARN_MAT 2500) of whatever debt an attacker can cancel in one transaction (bounded by candidates in the 170-220 band, or underwater positions for bite) becomes work-minted imdUSD the next block, after which the attacker wipes and frees. Merged from audit_economics (medium) and audit_permissions (low); both proofs fail on d3861ac for this reason. Smallest fix: call _clampPacedDebt() after every cancellation as well: after _redeemPosition in cash (inside the reserveOut < gemOut branch), after _reduceDebt in bite and after _reduceDebt in cover. Verified: with those three calls both attached proofs pass (5 of 5 tests) and ParameterizedVault initcode goes from 46,987 to 47,009 bytes (2,143 under the limit). wipe needs no change: WIPED_THIS_TX_SLOT offsets its fall.

**Reproduction.** test/scratch/Proof_1306515111da.t.sol (attached as proof). ParameterizedVault over MockIMD at $1 (IMD/ETH 1/2000 x Chainlink 2000e8 etched at CHAINLINK_ETH_USD), NHI 0.85 (mat 170, gap 50), TreasuryFactory etched, no reserve. BOOK locks 199,000 and draws 99,500 (200%, a candidate); 24 hourly pacings so backedDebt() == 99,500e18. A contract holding 40,000 IMD runs in ONE transaction: lock(40_000e18); draw(20_000e18); cash(20_000e18, 0, BOOK). Next block: totalDebt == 99,512e18, BOOK's debt == 79,512e18. EXPECTED backedDebt() <= 79,600e18 (the book less the cancelled 20,000; the churner's 20,000 is 12 seconds old). ACTUAL backedDebt() == 99512103561643835581000. Control in the same file: cash BEFORE draw gives 79545436894977168914333. Second proof (.imd/reads/proofs/Proof_8bb039f8b84d.t.sol, wage 0.01 applied through Parameters): after draw-then-cancel of the whole 99,500, paced debt == 99,500e18, earnLine == 24,878e18 and earn(24_000e18) succeeds where WorkCeilingReached was expected. Run: forge test --match-path test/scratch/Proof_1306515111da.t.sol -vv; test_drawThenCashCountsZeroSecondDebt fails on d3861ac and passes with _clampPacedDebt() added after the cancellation in cash, bite and cover.

Proof attached; kept under `test/paced-vault-panel/` with the specialists' proofs.

## 2. [MEDIUM] Paced backing: the accepted dip's stated bound 'exists only while the book is backed below par' does not hold; a par book dips to the rest-of-book figure on a dominant position's wipe and redraw acros

`src/CDPVault.sol:323` — blocking: no; citation: resolved

```solidity
    /// next leaves the figure where the book stood without it, until it climbs back. That dip exists only while
```

The paced figures' NatSpec (lines 321-328) accepts the dip with the reason that on a par book 'the surplus above the aggregate cap absorbs any one position's exit'. That reasoning assumes the exiting position is not the one carrying the cap. _liveBacking reports par whenever secured >= supply, and _securedCollateralValue caps secured at mat x (totalDebt - MINTED - totalBadDebt) / 100 and compares it with the WHOLE supply. When a dominant healthy position wipes its principal, its term in securedCollateral goes to zero (_secured returns 0 at principal 0), the cap shrinks by mat x P and the supply by P; whenever the rest of the book is below par on its own the next transaction's _pace writes min(live, paced + rise) = the rest-of-book figure, and cash pays min(live, paced) while it climbs back at 2 points of par an hour. Three shapes of par book satisfy this, all reproduced by the specialists and one by me: (a) a par book with an underwater tail (no bad debt, no wage: BOOK 80% underwater, WHALE 500% healthy; audit_math); (b) a par book carrying realized bad debt B after a past liquidation (cap = mat x (D - B - P) can be zero after the exit: audit_permissions reproduced 0.1217 and 0.0000667); (c) a par book with work-minted supply once a wage is on (audit_flow reproduced 0.5429). The stated magnitude bound (the gap to the backing of the book without the position) holds; the stated condition ('only below par', 'only in a book already in crisis') does not, and in shape (b) the figure can reach zero with every open position healthy. What it lets someone do with the constants as committed: a dominant borrower who holds the imdUSD it drew removes the redemption floor (the peg's defence, cash lines 702-729) for about (1 - dip) / 0.02 paced hours, for gas, repeatable every time the figure climbs back; an honest refinance across two blocks triggers it too. It never overpays. Smallest fix: correct the NatSpec (and web/content/docs/economics/risks-and-open-questions.md) to the real condition: the dip exists whenever reserve + mat/100 x (D - B - P) < S - P for the exiting position P, which includes a par book with any underwater position, realized bad debt or work-minted supply, and state its size as (secured_rest + reserve) / supply_rest. If that cost is not acceptable it is a design decision for the requester: either pace a fall caused only by a repayment at the follow rate (which reopens the lift D1 closed unless netted per position) or let cover burn the caller's own imdUSD so anyone can retire the bad debt that arms shape (b).

**Reproduction.** test/scratch/Judge.t.sol::test_parBookDipsOnDominantWipeAndRedraw (fails on d3861ac). ParameterizedVault over MockIMD at $1 (IMD/ETH 1/2000 x Chainlink 2000e8), NHI 0.85 (mat 170, gap 50), no reserve, wage 0. BOOK: lock 199,000 IMD, draw 99,500 (200%). WHALE: lock 2,500,000 IMD, draw 500,000 (500%). 24 hourly pacings. Price to $0.40 (BOOK 80%, underwater; WHALE 200%, healthy); each owner lock(1) to re-price its term; 12 hourly pacings. backingPerUnit() == 1e18 and paced().backing == 1e18 (held 2,699,000 IMD = $1,079,600 >= cap 1.7 x 599,500 = $1,019,150 >= supply 599,500). WHALE wipe(500_000e18) in one block, draw(500_000e18) in the next, one more block. EXPECTED per the NatSpec: backingPerUnit() == 1e18. ACTUAL: backingPerUnit() == 801166056408026274 (the rest of the book: 79,600 / 99,500), paced().backing == 801099389741359608. Three paced hours later cash(1_000e18, 0, WHALE) is paid 2140047258354713965000 IMD where par less the fee pays 2485250000000000000000 (13.9% less). audit_permissions' variant (BOOK 200% plus LOSER bitten to a drained position with 2,917 of bad debt, price back to $1, 60 paced hours at par): BOOK wipe then draw gives backingPerUnit() == 121709869698224744.

## 3. [MEDIUM] A debt-bound term is re-priced by nobody but its owner: marked at a crash low it overpays redeemers past the honest backing after a recovery (reserve first), and after a fall it underpays for as long 

`src/CDPVault.sol:333` — blocking: no; citation: resolved

```solidity
    /// panel 2026-10-08, low), can now lift the payout no faster than the same rate.
```

securedCollateral sums per-position terms min(collateral, 2 x principal / price) in IMD, each fixed at the price of the position's last touch (_secured, _resecure). A term is re-priced only from lock, lockIMD, free, draw and wipe (owner only), cash (candidates below mat + gap = 220 only), bite (unhealthy only) and cover (drained or dust only); a healthy position above 220% is touched by no third party, ever, and lock is ungated, so the owner picks the touch price for free, during a halt included. OVERPAY (Q1): a debt-bound term written at p0 is worth 2P x p / p0 at a later price p. The launch vault panel reported this mirror (low); this commit answers only with the rise rate (line 333) and states no magnitude bound. The paced backing climbs 2 points an hour toward min(live, par) with the inflated live as its target, so after (over-read / 0.02) hours every redemption is paid the stale figure, from the Treasury's sIMD first and then from any candidate in band. The only bound is the aggregate cap (mat x prior debt), which is above par exactly when the book is below par, which is the only time it matters. Reachable with the constants as committed, wage 0, no governance: X (any position above 200%) lock(1) at the low; wait for the recovery and the paced hours; any holder (X included) cash(amount, 0, candidate). Preconditions are a crash leaving the book below par at the recovered price and a lower print before it; honest borrowers topping up during the crash mark their terms at the low exactly as X does. UNDERPAY (the accepted stale-term read, retry2 #6): the NatSpec says 'cold for a few hours, climbs back once positions are touched'. Nothing permissionless touches an idle owner's position, so after a fall by fraction f every untouched debt-bound term reads (1 - f) of its true value and the live figure, and so the payout, reads at most (1 - f x s) of honest backing (s = share of secured value in such positions) for as long as those owners are idle; cost in points: f x s of par, duration unbounded in hours. Merged from audit_economics (medium, the mirror) and audit_math (low, the stale read); both reproduced. Smallest fix, one for both directions: a permissionless re-price, e.g. `function resecure(address owner) external { _requireFreshFeeds(); _requirePriceAgreement(); _resecure(_positions[owner], _price()); }` (about 120 bytes of initcode against a 2,165-byte margin), and have the hourly keeper re-price open positions after each price update; a rise it causes is still bounded by the aggregate cap and the paced rise, a fall is honest. Until then, correct the NatSpec at 331-333: the duration is until the owner acts, and the mirror's magnitude is bounded only by the aggregate cap.

**Reproduction.** test/scratch/Judge.t.sol::test_mirrorLiftOverpaysRedeemer and ::test_staleTermAfterFallIsNotRepricedByAnyone (both fail on d3861ac). Fixture: ParameterizedVault over MockIMD at $1, NHI 0.85, Treasury holding 2,000 IMD. OVERPAY: X locks 30,000 and draws 2,500 (1200%); Y locks 42,500 and draws 25,000 (170%); Z locks 13,000 and draws 5,000 (260%); HOLDER is handed 10,000 imdUSD; 24 paced hours (backingPerUnit() == 1e18). Price to $0.20; X, Y, Z lock(1) (X's term becomes 25,000 IMD = 2 x 2,500 / 0.20); two paced hours. Price to $0.40. Control (snapshot): X, Y, Z lock(1), 40 paced hours: backingPerUnit() == 861538461538461538, the honest (800 + 17,000 + 5,200 + 5,000) / 32,500. Attack branch: only Y and Z lock(1), 40 paced hours: backingPerUnit() == 1000000000000000000 (X's stale 25,000 IMD reads $10,000 against an honest $5,000). HOLDER cash(1_000e18, 0, Z): EXPECTED at most 1,000 x 0.8615 x (1 - fee) / 0.40 = 2132307692307692306550 IMD. ACTUAL 2475000000000000000000 IMD (par less the fee, +16%), the Treasury's whole 2,000 IMD reserve first and 475 out of Z's collateral. UNDERPAY: X locks 600,000 and draws 100,000 (600%); 24 paced hours, par. Price to $0.40; X never transacts; Y lock(1e18) paces; 48 more paced hours. Honest secured value min(600,000, 2 x 100,000 / 0.40) x 0.40 = $200,000 >= supply 100,000, so honest backing is par. ACTUAL backingPerUnit() == 800000000000000000 after 48 paced hours; cash(1, 0, X) reverts IneligibleRedemptionPosition, bark(X) reverts HealthyPosition, cover(X, 1) reverts NoRealizedBadDebt: no external call re-prices X's term.

## 4. [LOW] _pace advances _pacedAt when the backing is held for an unusable price, so any ungated call or pace() during a stale or diverged window forfeits the interval's rise; a stated 'quiet gap recovers one i

`src/CDPVault.sol:868` — blocking: no; citation: resolved

```solidity
        _pacedAt = uint64(block.timestamp);
```

When _priceAgrees() is false _pace passes price 0 and _pacedBacking returns the held value (line 797), but _pacedAt is still written to now (line 868), so the elapsed time is consumed with no rise. The NatSpec says the figure 'holds' through a halt and that 'hourly pacing recovers in full; a quiet gap recovers one interval' (lines 317-321). It holds and also forgets the time. On mainnet a stale window is the ordinary state between purchased attestations (PRICE_MAX_AGE and SPOT_MAX_AGE 1 hour, updates bought on demand), lock, lockIMD, wipe and debt-free free are ungated and pace, and pace() is permissionless, so anyone can keep a recovering payout from climbing with one cheap call per stale window. Cost, never a gain: on a book below par honest redeemers stay underpaid up to 2 points of par per halt, indefinitely if repeated. Merged from audit_math (info), audit_flow (low) and audit_permissions (info); reproduced. Smallest fix: keep a separate timestamp for the backing (written only when _pace writes it at an agreed price) and measure the backing's elapsed from it, still capped at PACE_INTERVAL; _pacedAt keeps serving the supply and debt. Or state at 319-321 that a pacing at an unusable price consumes the interval.

**Reproduction.** test/scratch/Judge.t.sol::test_stalePacingForfeitsTheRise (fails on d3861ac). BOOK at 200% with 99,500 of debt, 24 paced hours; price to $0.40 and BOOK lock(1): paced backing 0.80e18. Price back to $1 (live reads par) and pace(). Case A: a quiet hour, then pace(): the paced backing rises 20000000000000000 (one interval). Case B from the same state: at minute 50 the spot feed is stale and WHALE lock(1) lands (ungated): paced().backing unchanged, paced().at == block.timestamp; at minute 60 the feed is fresh and pace() is called. EXPECTED per the NatSpec: +20000000000000000. ACTUAL: +3333333333333333 (ten minutes' worth).

## 5. [LOW] Launch-day fee: the paced supply starts at zero and follows at 10% an hour, so for about 27 paced hours a redemption's increase is measured against the 100,000 floor while the live supply is 500,000, 

`src/CDPVault.sol:1073` — blocking: no; citation: resolved

```solidity
    /// redemption's increase is measured as if the supply were the floor, which only lowers fees while the
```

_feeBase is max(_pacedSupplyNow(), 100,000e18). _supplyPaced is 0 at deployment and each pacing moves it by at most 10% of max(paced, 100,000) per hour (_step), so it takes 10 paced hours to reach the floor and about 17 more to reach 500,000 (1.1^17 = 5.05). Throughout, _redemptionRate measures a redemption's increase against 100,000: a 1%-of-supply redemption (5,000 against a live 500,000) is quoted 300 bps where the live base gives 100, and 9,000 of burns (about 250-450 imdUSD of fee) store the 4.5% cap as everyone's base rate for the next half-life, where 45,000 would be needed against the live supply. So the sentence at 1072-1074 ('only lowers fees while the protocol is that small') is wrong while the paced supply is below the live one: it raises them, and it is stated nowhere in these files or in docs/MAINNET-RUNBOOK.md. The cheapest pin of the cap for everyone (Q2) is therefore 9,000 imdUSD of burns for the first day or so after launch, against 9% of the live supply once the paced supply has caught up. Not the constants, which are deliberate, but the initialization of the paced supply. Merged from audit_flow and audit_permissions (info); reproduced. Smallest fix: document it at _feeBase and in the runbook, or seed _supplyPaced from the live supply the first time _pace runs with _supplyPaced == 0 (one branch), which keeps the follow limit for everything after.

**Reproduction.** test/scratch/Judge.t.sol::test_launchDayFeeAgainstTheFloor (fails on d3861ac). Fresh ParameterizedVault at $1, NHI 0.85. WHALE locks 1,500,000 and draws 500,000 at deployment; one hour later pace(): paced().supply == 10000000000000000000000. redemptionFeeBps(5_000e18) == 300 (EXPECTED against the live supply at divisor 2: 50 + 50 = 100); redemptionFeeBps(9_000e18) == 500 (the cap). Hourly pacing reaches a 500,000 base after 27 paced hours.

## 6. [INFO] NatSpec: the follow bound 'at most FOLLOW_BPS_PER_HOUR an hour' compounds under frequent pacing (10.52% an hour paced every block, 11x not 9.85x over a day)

`src/CDPVault.sol:316` — blocking: no; citation: resolved

```solidity
    /// BACKING_RISE_PER_HOUR, nor moves the fee base or the work ceiling's debt faster than FOLLOW_BPS_PER_HOUR.
```

_step (lines 829-833) is FOLLOW_BPS_PER_HOUR x min(elapsed, PACE_INTERVAL) / 1 hour of the CURRENT paced value, applied at every pacing, and pace() is permissionless. Paced every 12-second block toward a distant live figure the supply and debt figures grow by (1 + 0.1 x 12/3600) per block, e^0.1 - 1 = 10.52% an hour rather than 10%, and 11.0x rather than 1.1^24 over a day. The backing's rise is absolute and does not compound. No economic consequence at the committed constants beyond the fee base and the work ceiling catching up about 5% faster than stated. Documentation: say 'per pacing, compounding', or compute the step from the value at the start of the interval.

**Reproduction.** Read _step: Math.mulDiv(Math.max(paced, _feeBaseFloor()), FOLLOW_BPS_PER_HOUR * Math.min(elapsed, PACE_INTERVAL), 10_000 * 1 hours) with `paced` the stored value at each pacing. Paced debt 1,000,000e18 with a far larger live debt: one pace after an hour gives 1,100,000e18; 300 paces 12 seconds apart over the same hour give 1,000,000 x (1 + 1/3000)^300 = 1,105,1xx e18. EXPECTED per line 316: at most 1,100,000e18 after an hour.

## 7. [INFO] Stale cross-reference: ParameterizedVault._redemptionReserveBacking cites CDPVault._mark, which this commit removed; the caller is CDPVault._pace through _liveBacking

`src/ParameterizedVault.sol:172` — blocking: no; citation: resolved

```solidity
        // Saturating, like the vault's backing it feeds: an absurd price must not revert lock or wipe (CDPVault._mark).
```

The per-position lag's _mark was replaced by _pace in d3861ac. The property claimed (an absurd price must not revert lock or wipe) still holds: Math.tryMul / Math.tryAdd saturate, and the pacing path's feed reads return zero rather than reverting. Only the name is dead. Reported by all four specialists. Fix: `CDPVault._pace`.

**Reproduction.** grep -n '_mark\b' src/*.sol finds only this comment; grep -n 'function _pace' src/CDPVault.sol finds the function it means (line 861).

## 8. [INFO] NatSpec: CDPVault.earnLine says ParameterizedVault overrides it with reserveValueUsd + totalDebt x earnMat / 10000; the override uses backedDebt (min of totalDebt, the transaction-start debt and the p

`src/CDPVault.sol:202` — blocking: no; citation: resolved

```solidity
    /// it with reserveValueUsd + totalDebt * earnMat / 10000, the bound docs/COMPUTE-BACKING-
```

ParameterizedVault.earnLine (276-278) is reserveValue() + backedDebt() x earnMat / 10000 and backedDebt (260-267) caps totalDebt at the transaction-start and paced figures and subtracts totalBadDebt. The base-vault sentence predates both and overstates the ceiling by the bad debt and the paced lag. Reported by audit_flow and audit_permissions. Fix: say backedDebt.

**Reproduction.** test/PacedFigures.t.sol::test_theWorkCeilingCountsDebtOnlyUpToThePacedDebt: totalDebt 1,000,000e18 drawn an hour ago, paced debt 110,000e18, earnLine() 27,500e18, not 250,000e18 as the sentence implies.

## 9. [INFO] NatSpec: securedCollateral says the exactly-counted set (at most 200% at the touch price) 'includes every redeemable one', but redemption eligibility is mat + gap = 220 at the launch constants

`src/CDPVault.sol:266` — blocking: no; citation: resolved

```solidity
    /// inside their bound (at most 200% at that price, which includes every redeemable one) are
```

SECURED_COLLATERAL_MULTIPLE is 2, so a term equals the collateral only up to 200% CR at its last price. redemptionCeilingCR() is mat() + gap(); at NHI >= 0.85 mat is 170 and Parameters.gap defaults to 50 (MIN_GAP 25), so positions between 200% and 220% are candidates whose term is 2 x principal / price, not their collateral. Documentation only; the consequence is the accepted non-monotone backing across a candidate-funded redemption (lines 722-725). Fix: 'which includes every redeemable one while mat + gap <= 200'.

**Reproduction.** NHI 0.85, gap 50: vault.redemptionCeilingCR() == 220. A position with 210 IMD against 100 imdUSD at $1 is eligible (210 < 220) while its term is min(210, 200) = 200.

## 10. [INFO] Comment: WIPED_THIS_TX_SLOT is said to tally principal the caller repaid 'on its own position'; the tally is per transaction, so one contract's wipe and another's draw in the same transaction also net

`src/CDPVault.sol:847` — blocking: no; citation: resolved

```solidity
    /// @dev keccak256("comp.CDPVault.principalWipedThisTransaction"): principal the caller repaid on its own
```

wipe adds amount - feePaid to the slot with no position key, and _pacedDebt / _clampPacedDebt read it as a single number (live = totalDebt + WIPED - MINTED). A seasoned borrower A wiping X and a fresh borrower B drawing X inside one transaction (through a relay) leave the paced debt where it was, exactly as a position's own wipe and redraw does; the aggregate is unchanged and the new debt is collateralised at mat, so this is the accepted cost of a ceiling that tracks totals, not whose debt (Q3), but it is not the per-position property the comment at 847-848 and line 310-311 state. Reported by audit_economics. Fix: say 'in this transaction, whoever repaid it'.

**Reproduction.** Read wipe (line 562): _transientAdd(WIPED_THIS_TX_SLOT, amount - feePaid) with msg.sender nowhere in the key; _pacedDebt (820) and _clampPacedDebt (878) sum it into one live figure.

## 11. [INFO] NatSpec: backingPerUnit() is said to read 'the latest accepted price', but it reads _price() with no freshness or agreement check, so it quotes against a stale or diverged nonzero price

`src/CDPVault.sol:754` — blocking: no; citation: resolved

```solidity
    /// @notice Value backing one imdUSD, 1e18-scaled, never above par, at the latest accepted price.
```

backingPerUnit() returns _backingPerUnit(_price()); _price() only rejects zero. cash itself is gated by _requireFreshFeeds and _requirePriceAgreement, and _pace holds the stored figure at an unusable price, so no payout is affected; only the public view's description is wrong. Reported by audit_economics. Fix: 'at the latest readable price (cash itself requires a fresh, agreed one)'.

**Reproduction.** Read lines 758-760 against _price (1476-1479): no call to _pricingStale, spotFeed.isStale or _requirePriceAgreement on the view's path.


## Resolution

All eleven findings are answered in `b6286fc`: the three mediums and two lows in code, the six infos in the comments, and the one accepted cost restated with the condition the panel showed to be the real one.

| # | Severity | Outcome |
|---|---|---|
| 1 | medium | **Fixed, as the judge proposed.** `_clampPacedDebt` runs after every cancellation as well as after a draw: after `_redeemPosition` in `cash`, after `_reduceDebt` in `bite` and in `cover`. The three proofs (two specialists' and the judge's, five tests) pass (`test/paced-vault-panel/`). |
| 2 | medium | **Accepted with the real condition stated.** The dip exists whenever the book without the leaving position is below par: a book of healthy positions with slack in the aggregate cap has none; one carrying an underwater position, realized bad debt or work-minted supply dips to the backing of what remains, near zero when the leaver was nearly the whole book. Its size, duration and cost are stated at the paced figures' NatSpec and on the public risks page, and the judge's par-book scenario is kept as a test (`test/PacedFigures.t.sol`, `test_aParBookDipsWhenThePositionCarryingTheCapLeavesAndReturns`). The two code alternatives were weighed and refused: pacing a repayment's fall at the follow rate reopens the lift for the leaver itself (it holds the imdUSD it repaid, redraws and redeems at the stale figure before leaving), and letting anyone cover bad debt with their own imdUSD only disarms one of the three shapes. The runbook keeps the dip rare: liquidate promptly, cover bad debt promptly (donating imdUSD to the Treasury if fees have not accrued), refinance in one transaction. |
| 3 | medium | **Fixed, as the judge proposed.** `resecure(owner)` re-prices any position's term at a fresh, agreed price; anyone may call it, and the keeper does for every open position after each price update. An idle position's under-read after a fall and a term fixed at a crash low after a recovery are both corrected by a third party; the over-read's lift is paced at the rise rate until then, bounded by the aggregate cap. Both directions kept as tests. |
| 4 | low | **Fixed, as the judge proposed.** The backing keeps its own clock (`_backingPacedAt`, written only when the backing is paced at a usable price), so a pacing through a stale or diverged window holds it without consuming its interval. The judge's case A/B is kept as a test. |
| 5 | low | **Fixed, as the judge proposed.** A paced supply of zero follows the live supply, so the first day's redemptions are measured against the supply that exists; the paced debt has no such seed, since debt that counts at once backs work minting. Kept as a test. |
| 6 | info | **Fixed.** The follow bound is stated as per hour of elapsed time, compounding per pacing. |
| 7 | info | **Fixed.** The cross-reference names `CDPVault._pace` through `_liveBacking`. |
| 8 | info | **Fixed.** `earnLine`'s NatSpec gives the override's real formula (`backedDebt`). |
| 9 | info | **Fixed.** `securedCollateral`'s NatSpec gives the redeemable band's edge as mat + gap. |
| 10 | info | **Fixed.** `WIPED_THIS_TX_SLOT` is described as per transaction. |
| 11 | info | **Fixed.** `backingPerUnit()`'s NatSpec says it is a quote at the primary's latest value, with the checks in `cash`. |

Also in this commit: the `_withinSkew` helper shared by the agreement check and `_priceAgrees`, and `_debtForPacing` shared by the paced debt and the clamp, to keep the initcode under the 2 KB margin with `resecure` added.
Verification: `forge test` 630 passed, 0 failed (4 skipped); with `AUDIT_PROOFS=true` 631 passed, 0 failed; the invariants clean under six further seeds; `script/checks` failure set unchanged by name (23); `docs/abi` regenerated (`resecure` added; `paced` returns the backing's own clock); ParameterizedVault initcode 47,089 bytes (2,063 under EIP-3860); `deploy/mainnet/rehearse-fork.sh` green through both stages, the keeper's bark and bite and the Treasury-paid ask.
