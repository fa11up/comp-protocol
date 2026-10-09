# Final sweep panel 2 — 2026-10-09

Job `a69e204e-d047-4c2f-9944-f37a69dd2796` (explorer: https://explorer.imd.fun/jobs/a69e204e-d047-4c2f-9944-f37a69dd2796), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `a3aa9e4d4f9492cac2406901a11f786018addcd5`.

Scope: the whole system (`src/`, the deploy script and `deploy/mainnet/`) as the last review before mainnet, after the paced figures replaced the backing lag (records 23 and 24): the vault's newest lines first, then cross-subsystem sequences, the launch window, the oracle's reach, governance and the Treasury for regressions, the deployment. Payload: `whitepaper/requests/audit/audit-final-sweep-2-quote.json` (`build_audits.py`, Phase 13).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 1778 (agent 52215) | audit_judge | completed | 7 | 14 | 15,131 |
| 730 (agent 51876) | audit_economics | completed | 5 | 61 | 84,238 |
| 363 (agent 51428) | audit_math | completed | 1 | 34 | 56,565 |
| 1606 (agent 50958) | audit_permissions | completed | 3 | 33 | 39,236 |
| 801 (agent 52220) | audit_flow | completed | 3 | 29 | 34,963 |

The judge's merged list is the result: 1 high, 2 low, 4 info, no critical or medium. Judge submission hash `327584de1412adb7ad57f9ba72560e5542ae3cadf2b62e0d48e0a9546af153a2`; raw record of every seat beside this file (`audit-final-sweep-2-2026-10-09-submission.json`).

**Judge's summary, verbatim:**

> I wrote 7 findings to `.imd-findings.json` after checking all 12 specialist findings against the code. Every one of them reproduces. All four attached proofs fail on a3aa9e4 for the reasons their findings give. I wrote and ran my own test for the self-redemption case, which had no proof. Duplicates are merged, and no source file was changed.
>
> **Findings, most severe first**
>
> 1. **High, `CDPVault.cash` (line 742): redemptions pay out at a manipulated feed low.** Someone pushes IMD's only pool down 20% and holds it there for about 65 minutes. That is about $240k of selling and about $5k in pool fees, plus whatever dip-buyers take during the hold. The feeds accept that one step, and both of them read the same pool, so the agreement check passes. A redeemer is then paid 1.25 × 0.95 IMD per imdUSD, which takes about 18.75% of the in-band debt from the positions redeemed against. That is up to about $187k at LINE $1M, or 58% after two hours of feed silence. Pacing and `resecure` don't limit this, because they bound the backing per imdUSD, not the price of IMD.
>    - The accepted "oracle walk cost" item only prices the over-borrowing walk, so it doesn't cover this route.
>    - Proof: 50,000 imdUSD takes 59,375 IMD from the redeemed position instead of at most 50,000.
>    - Whether it pays in practice depends on how much dip-buying the attacker has to absorb during the hold.
>    - Fix: either set the redemption fee to at least the feed's fall from its epoch anchor, or pace the payout price.
>
> 2. **Low, `_clampPacedDebt` (line 907): the paced debt is wrong after a cancellation.** This merges three reports with one root cause. Severity is low because the paced debt only feeds the work ceiling, and the wage is 0 at launch. Once governance sets a wage it becomes medium.
>    - A draw in one transaction and a cancellation of someone else's seasoned debt in the next leaves fresh debt counted in full. The proof gets `backedDebt` 99,512 where at most 79,600 is expected.
>    - In one transaction, lock + draw + `cash` against your own position zeroes the paced debt while the 99,500 seasoned book is untouched. That would block the work channel for gas.
>    - Fix: clamp against the paced debt as the transaction found it, minus only the pre-existing debt it cancelled.
>
> 3. **Low, `_pacedSupply` (line 829): whoever draws first sets the launch fee base.** This merges two reports. A large draw held for one block seeds the fee base at about 900k, so a 50,000 redemption pays 328 bps instead of 500 for about a day. A tiny first draw does the opposite and leaves the base at the 100,000 floor, the state the paced vault panel's finding 5 (marked "Fixed") was meant to prevent. Fix: seed no higher than the floor.
>
> 4. **Info, `docs/MAINNET-RUNBOOK.md:392`:** "Only then open deposits" describes a gate the vault doesn't have. Anyone can `lock` and `draw` from the block after the vault lands.
>
> 5. **Info, `CDPVault.sol:418` and `WorkOracleFactory.sol`:** the comments say the vault's initcode is 36,416 bytes. It is 47,089, which leaves 2,063 bytes of headroom, not about 12.7 KB.
>
> 6. **Info, `CDPVault.sol:326`:** the NatSpec's condition for the accepted dip leaves out the remaining positions' secured value. The repository's own dip test contradicts it.
>
> 7. **Info, `ParameterizedVault.sol:262` and `CDPVault.sol:1105`:** these say the follow rate is "at most 10% an hour". Paced every block it compounds to about 10.5%; the main NatSpec was already corrected but these two lines were not.
>
> **Coverage.** I read in full the cash, pacing and clamp section of `CDPVault.sol` (lines 280–340 and 690–1000), the work-ceiling part of `ParameterizedVault.sol` (225–305), the walk analysis in the parameters doc, and the three feed question bodies. I did not independently answer questions 3, 5 and 6, or the launch-window parts of question 1. That covers the governance and Treasury regression pass, `DeployMainnet`, `plan.py`, and `resecure`'s griefing surface. Those areas rest only on the speci

| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | high | yes | `src/CDPVault.sol:742` | cash pays IMD at a one-step manipulated feed low: a 20% pool push held ~65 min takes ~18.75% of in-band debt from candidates (fall/redemption route missing from the accepted walk analysis) |
| 2 | low | no | `src/CDPVault.sol:907` | _clampPacedDebt mismeasures cancellations: a draw in one tx and a cancellation of seasoned debt in the next counts zero-second debt in full; a self-redemption of the tx's own fresh draw zeroes the pac |
| 3 | low | no | `src/CDPVault.sol:829` | Seeded paced supply takes the whole live supply at the first pacing after the first draw, unpaced: whoever draws first sets the launch fee base in either direction |
| 4 | info | no | `docs/MAINNET-RUNBOOK.md:392` | Runbook 7 step 5 'Only then open deposits' describes a gate the vault does not have |
| 5 | info | no | `src/CDPVault.sol:418` | Stale initcode size in comments: ParameterizedVault is 47,089 bytes of initcode, not 36,416 |
| 6 | info | no | `src/CDPVault.sol:326` | Paced-figures NatSpec states the dip condition without the remaining positions' secured value |
| 7 | info | no | `src/ParameterizedVault.sol:262` | Two comments state the follow bound as 'at most FOLLOW_BPS_PER_HOUR an hour' without the per-pacing compounding |

## 1. [HIGH] cash pays IMD at a one-step manipulated feed low: a 20% pool push held ~65 min takes ~18.75% of in-band debt from candidates (fall/redemption route missing from the accepted walk analysis)

`src/CDPVault.sol:742` — blocking: yes; citation: resolved

```solidity
        uint256 payoutScale = Math.mulDiv(_backingPerUnit(price), 10_000 - feeBps, 10_000);
```

CDPVault.cash pays gemOut = amount x min(backing,1) x (1-fee) / price. On a book with slack above par the paced backing is 1e18 and does not bind, so a redemption's IMD per imdUSD follows the attested price directly. SwarmFeed accepts a single step of 20% from a fresh anchor (FEED_MAX_DEVIATION_BPS 2000; 40% after two silent hours), and the primary (13-sample 2h median) and the spot (last block) both read IMD's one Uniswap v4 pool, so pushing the pool moves both and SKEW_BPS sees agreement. Sequence: hold imdUSD (drawn earlier at the honest price); sell ~12% of the pool's IMD side (~$240k against ~$2.0M) to drop the price 20% and hold it ~65 minutes so 7 of 13 median samples sit low; relay primary and spot (askPaid, or the Treasury's own 5% fall trigger buys it); cash(amount,0,candidate) against every in-band candidate (at -20% every position under ~275% honest CR is in band) and the reserve; buy IMD back. Gain 1.25 x 0.95 - 1 = 18.75% of redeemed volume (58% after two hours of feed silence), taken from candidates' collateral and the Treasury's sIMD; cost ~$5k pool fees plus whatever dip-buyers absorb during the hold, ~$9 attestations. With LINE $1M the takeable amount is up to ~$187k at fee cap. The accepted 'oracle walk cost' (docs/PARAMETERS-2026-10-05.md) prices only the over-borrowing walk (x1.7, several hourly steps, ~$40k); this route needs one step inside the committed allowance. Pacing and resecure bound backing per unit, not price per IMD, so they do not shorten its reach. Smallest fix: (a) floor the redemption fee at the primary feed's fall from its current epoch anchor (feeBps >= (anchor - price) x 10000 / anchor), or (b) pace the payout price (pay at max(price, pacedPrice) with pacedPrice falling at a bounded fraction per hour). Either makes the proof pass; both underpay redeemers for up to an hour after an honest fall, the conservative direction.

**Reproduction.** Proof below (test/scratch/OneStepFallRedemption.t.sol): ParameterizedVault over MockIMD at $1, NHI 0.85 (mat 170). BOOK locks 199,000/draws 99,500 (200%, candidate); HOLDER locks 300,000/draws 100,000; 24 hourly pacings; backingPerUnit()==1e18. Both feeds set to 0.80x price; next block HOLDER cash(50_000e18,0,BOOK). Expected <= 50,000 IMD (pre-fall price). Actual gemOut 59,375e18 (50,000 x 0.95 / 0.80), all from BOOK's collateral; BOOK loses $9,375 at the pre-fall price. Run on a3aa9e4: fails with 'a one-step feed fall pays the redeemer more than it burned: 59375000000000000000000 > 50000000000000000000000'. Reachable with committed constants; real-world feasibility depends on how much dip-buying the attacker must absorb during the 65-minute hold.

Proof attached; kept under `test/final-sweep-2/` with the specialists' proofs.

## 2. [LOW] _clampPacedDebt mismeasures cancellations: a draw in one tx and a cancellation of seasoned debt in the next counts zero-second debt in full; a self-redemption of the tx's own fresh draw zeroes the pac

`src/CDPVault.sol:907` — blocking: no; citation: resolved

```solidity
        uint256 live = _debtForPacing();
```

Merged from three specialist reports (d6e63b8b, db768696, f3224fb3): one root cause. _clampPacedDebt (after draw, cash, bite, cover) clamps _debtPaced to totalDebt + WIPED_THIS_TX - MINTED_THIS_TX. The tallies are transient, so (1) debt drawn in an EARLIER transaction is invisible: tx1 lock+draw(X) leaves paced at T; tx2 (next block) cash(X,0,victim) cancels X of seasoned debt, live = T, no clamp; the churner's one-block-old X now counts in full for ParameterizedVault.backedDebt, contrary to NatSpec at CDPVault 310-313 / 899-904 and ParameterizedVault 237-240 / 262-264 ('debt cancelled by a redemption or liquidation and drawn again by someone else backs nothing until it has been held'). A plain wipe by another borrower behaves the same way. (2) In the other direction, cancelling the transaction's OWN fresh draw nets MINTED out of a total that no longer contains it: lock(200k)+draw(100k)+cash(100k,0,self) in one call writes paced debt 0 though the seasoned book (99,500) is untouched; it then climbs ~10,000/hour, so earnLine falls to the reserve term (a gas-priced, repeatable denial of the work channel). The only consumer is the work ceiling and WAGE_WAD is 0 at launch, so nothing is takeable or blockable with the constants as committed (hence low); once a wage is set behind the 48h timelock, (1) is the sweep-panel high's round trip at one-block holding time (25% of cancelled seasoned debt minted as work against debt unwound next block) and (2) is a denial of earn. Smallest fix: record the paced debt and totalDebt as the transaction found them (ParameterizedVault already records debtAtTxStart in _debtChanged) and clamp to pacedAtTxStart - cancelledPreexisting, where cancelledPreexisting = debtAtTxStart - (totalDebt + WIPED - MINTED) saturated, with a per-position transient 'minted this tx' tally netted out of principal cancelled by cash/bite/cover so a tx cancelling its own fresh draw moves nothing.

**Reproduction.** (1) Proof below: BOOK 199,000/99,500 at 200%, 24 hourly pacings (backedDebt 99,500e18). CHURNER lock(40,000)+draw(20,000) (paced stays 99,500); next block cash(20,000,0,BOOK); next block backedDebt(). Expected <= 79,600e18; actual 99,512,105,242,694,063,896,500 wei (fails on a3aa9e4). Same result from the independent proof db768696 (100,066e18 > 50,100e18). (2) Same fixture; a contract with 200,000 IMD runs approve; lock(200_000e18); draw(100_000e18); cash(100_000e18,0,address(this)) in one tx. Next block: totalDebt 99,500e18, paced().debt 0, backedDebt() 33,333,333,333,333,333,333 wei. Expected ~99,500e18. Reproduced in test/scratch/SelfRedeem.t.sol.

Proof attached; kept under `test/final-sweep-2/` with the specialists' proofs.

## 3. [LOW] Seeded paced supply takes the whole live supply at the first pacing after the first draw, unpaced: whoever draws first sets the launch fee base in either direction

`src/CDPVault.sol:829` — blocking: no; citation: resolved

```solidity
        if (paced == 0) return live;
```

Merged from a57a6cb5 and dcc57c32. _pacedSupply returns the live supply while _supplyPaced == 0. The first borrower's own pacing sees supply 0, so the next capital-moving transaction by anyone writes that borrower's whole draw into the fee base with no follow-rate limit. (a) Large draw held one block: WHALE lock(1.6M)+draw(900k), BOOK draws 100k next block (seeds 900k), WHALE wipes and frees the block after: the fee base stays ~900k and decays only 10%/hour, so redemption fees are diluted for about a day (a 50,000 redemption pays 328 bps instead of 500), against the NatSpec 'principal drawn for a block cannot dilute the fee' (CDPVault 307-309) and the seed's comment 'there is no earlier base for a draw to dilute'. Redeemed-against borrowers lose the fee difference. (b) Small first draw (lock(10)/draw(1), by a front-runner or an honest test draw): the seed is ~1 and the base sits at the 100,000 floor for the first day while the live supply is several times it, exactly the state paced vault panel #5 marked 'Fixed' (redemptionFeeBps(5,000) 300 instead of 100 with a 500,000 book). The same reset recurs whenever the live supply returns to zero. Cost: gas plus one block of collateral. Smallest fix: seed no higher than the floor (`if (paced == 0) return Math.min(live, _feeBaseFloor());`), which makes (a) impossible and errs high on fees on day one (the borrower-protective direction), and restate panel #5 as accepted; or have the operator make the first draw the launch book in the deployment block sequence.

**Reproduction.** Proof below (SeededFeeBase.t.sol): fresh vault, IMD $1, NHI 0.85. Block 1 WHALE lock(1,600,000)+draw(900,000); block 2 BOOK lock(200,000)+draw(100,000) (seeds 900,000); block 3 WHALE wipe(900,000)+free(1,500,000); block 4 redemptionFeeBps(50,000). Expected 500 (control); actual 328, paced().supply 900,300e18. Fails on a3aa9e4 with 'a block-long draw diluted the redemption fee: 328 != 500'. Direction (b): lock(10e18)/draw(1e18), pace, WHALE lock(1.5M)/draw(500k), pace an hour later: paced supply ~10,001e18, redemptionFeeBps(5,000e18)=300 vs 100 intended.

Proof attached; kept under `test/final-sweep-2/` with the specialists' proofs.

## 4. [INFO] Runbook 7 step 5 'Only then open deposits' describes a gate the vault does not have

`docs/MAINNET-RUNBOOK.md:392` — blocking: no; citation: resolved

```solidity
5. **Only then** open deposits.
```

Merged 760cda55 and 8a726544. ParameterizedVault/CDPVault have no pause, allowlist or opening switch: lock, lockIMD and draw are open from the block runVault lands in, with feeds fresh from stage one. Steps 3-4 (keeper start and funding, ORACLE_ASKER prefund) are therefore not preconditions of borrowing, and the rollback window ('abandon only before anyone deposits') closes at block N+1 without the operator acting; together with the paced-supply seed the first borrower picks the launch fee base. Fix: say deposits are open from the vault's first block; move keeper start and asker prefund before runVault, and have the operator make the first position.

**Reproduction.** After runVault's CREATE2 tx is mined at block N, any EOA with sIMD calls vault.lock(x), vault.draw(y) at N+1: both succeed; grep finds no launch flag in src/CDPVault.sol or src/ParameterizedVault.sol. Expected per runbook: deposits refused until step 5.

## 5. [INFO] Stale initcode size in comments: ParameterizedVault is 47,089 bytes of initcode, not 36,416

`src/CDPVault.sol:418` — blocking: no; citation: resolved

```solidity
            // bytes and this vault's subclass is already at 36,416 of the 49,152 EIP-3860 permits.
```

Merged 6009be2d and b809730a. CDPVault constructor comment and WorkOracleFactory NatSpec (src/WorkOracleFactory.sol 10-11, '36,416 ... 52,880 bytes') state 36,416; actual is 47,089, 2,063 bytes of headroom, not ~12.7 KB. Conclusion holds (47,089 + 16,464 = 63,553 > 49,152) but the margin is overstated. Fix: update both figures.

**Reproduction.** forge inspect src/ParameterizedVault.sol:ParameterizedVault bytecode -> (hex length - 2)/2 = 47089 (run at a3aa9e4). Comment states 36,416.

## 6. [INFO] Paced-figures NatSpec states the dip condition without the remaining positions' secured value

`src/CDPVault.sol:326` — blocking: no; citation: resolved

```solidity
    /// book WITHOUT the leaving position is below par: reserve + mat x (debt - bad debt - its principal) less than
```

_liveBacking is (reserve + min(held x price, mat x (debt - bad)/100)) / supply (_securedCollateralValue). The NatSpec gives only the cap term, so a book whose remaining positions are underwater satisfies the stated 'no dip' condition and still dips (the repository's own test_aParBookDipsWhenThePositionCarryingTheCapLeavesAndReturns). Fix: 'reserve + min(the remaining positions' secured value at the price, mat x (debt - bad debt - its principal) / 100)'.

**Reproduction.** Kept test's numbers: reserve 20,000 IMD x $0.40 = 8,000; cap 1.7 x 99,500 = 169,150; 177,150 >= 99,500 so the sentence predicts no dip; the test asserts backingPerUnit() < 0.9e18 (secured term 79,600 + 8,000 over 99,500 = 0.88).

## 7. [INFO] Two comments state the follow bound as 'at most FOLLOW_BPS_PER_HOUR an hour' without the per-pacing compounding

`src/ParameterizedVault.sol:262` — blocking: no; citation: resolved

```solidity
        // D1: debt counts only up to the paced debt, which rises by at most FOLLOW_BPS_PER_HOUR an hour and falls
```

_step is a fraction of the current paced value per pacing, and pace() is permissionless, so paced every block the figures grow e^0.1-1 = 10.52%/hour. CDPVault 305-307 was corrected to 'compounding per pacing'; ParameterizedVault 238-239, 262 and CDPVault 1105 were not. Fix: use the corrected wording.

**Reproduction.** Paced debt 1,000,000e18, live far larger: one pace after 1h -> 1,100,000e18; 300 paces 12s apart -> 1,000,000 x (1+1/3000)^300 ~ 1,105,100e18 > the 1,100,000e18 the comments state. grep 'at most FOLLOW_BPS_PER_HOUR an hour' src/ finds CDPVault.sol:1105 and ParameterizedVault.sol:262 (and 238-239 wraps the same phrase).


## Resolution

All seven findings are answered in `92b873b`: the high and both lows in code, the four infos in the comments and the runbook.

| # | Severity | Outcome |
|---|---|---|
| 1 | high | **Fixed, by the judge's second option.** The price a redemption is PAID at is paced: `cash` pays IMD at the higher of the attested price and a paced price that falls at most `PAYOUT_PRICE_FALL_BPS_PER_HOUR` (5%) an hour, compounding per pacing, for at most one interval between pacings, and rises at once; eligibility, health and the collateral term stay at the attested price. A one-step fall of the attested price (the feed's allowance, 20% fresh, 40% after two silent hours) now reaches the payout only at that rate, so a pool held down through the median window pays at most the hour's 5% less the fee, which the attacker's own burn drives to the cap: about break-even before the cost of the push. After an honest fall redeemers are paid at the higher figure until the paid price has followed it down (a 20% fall in four paced hours): the direction that pays less, stated at `cash`, in the runbook and on the risks page. `payoutPrice()` exposes the figure; `paced()` returns it. The first option, a fee floor at the fall from the feed's epoch anchor, was not taken: a value accepted after a silent lifetime opens a new epoch and is its own anchor, so the floor would not see the very step the finding uses. The panel's proof passes (`test/final-sweep-2/judge_high_742_OneStepFallRedemption.t.sol`). |

**Correction (payout vault panel 2026-10-09, record 26):** "four paced hours" is five (0.95^4 = 0.8145), and the rate bounded the speed of the fall, not its size, so a pool held down for five paced hours was paid the whole step: the finding was delayed, not closed. The rate is now 1% an hour (`PAYOUT_PRICE_FALL_BPS_PER_HOUR` 100), with the panel's proofs kept under `test/payout-vault-panel/`.
| 2 | low | **Fixed, as the judge proposed.** `_clampPacedDebt` now caps the paced debt at the paced debt the transaction's pacing wrote, less the pre-existing principal cancelled in the transaction (`CANCELLED_PRE_SLOT`), and at the live figure; principal a position minted in the transaction (`MINTED_BY_SLOT`, keyed per position in transient storage) is netted out of what a cancellation or wipe retires, so cancelling the transaction's own fresh draw moves nothing. Both orderings across a block boundary and the self-redemption are kept as tests (the judge's and the math specialist's proofs). |
| 3 | low | **Fixed, as the judge proposed.** A paced supply of zero follows the live supply no higher than the fee-base floor, so neither a whale's block-long first draw nor a one-wei front-run sets the launch fee base; the first day's redemptions are measured against the floor until the paced supply has followed the book up (paced vault panel #5 restated as accepted, borrower-protective). The judge's proof passes; the public monetary-policy page says so. |
| 4 | info | **Fixed.** The runbook no longer describes a deposit gate: the vault takes `lock` and `draw` from the block it lands, and the step reads "only then announce". |
| 5 | info | **Fixed.** Both stale initcode figures replaced by the margin the size test keeps. |
| 6 | info | **Fixed.** The dip's condition includes the remaining positions' secured value. |
| 7 | info | **Fixed.** Both comments state the follow rate as per hour of elapsed time, compounding per pacing. |

Also in this commit, from the gas review asked for between the rounds: every entry point reads the price and NHI once and passes them down (`_requireFreshFeeds` returns the price; `_pace` returns the price it read; `_paceAt`, `_healthy`, `_clearIfRecoveredAt` take them), and the vault's and the relay's reentrancy guard is a transient-storage one (`TransientReentrancyGuard`, OpenZeppelin's error and modifier names). No behaviour changes; the price-read refactor keeps every read inside one entry point, never across calls.

**Coverage the judge did not reach.** The judge states it did not independently answer the launch-window question, the governance and Treasury regression pass, the deployment, or `resecure`'s griefing surface, which rest on the specialists' reading alone. Those areas are unchanged since the previous sweep (record 21) except the deploy script (record 22) and `resecure` (record 24); the next review's scope should name them.
