# Delta panel audit — 2026-10-08

Job `fc96f209-e004-42c6-bea0-728288548eee` (explorer: https://explorer.imd.fun/jobs/fc96f209-e004-42c6-bea0-728288548eee), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `07905bb419eb856975e19c77a7b4006575d3b2c2`.

Scope: what the final sweep panel's fixes (`77d8878`) changed and what it touches: the reserve's share in the backing figure, the 100,000 fee-base floor, and the vault's deploy salt read from the environment. Payload: `whitepaper/requests/audit/audit-delta-panel-quote.json` (`build_audits.py`, Phase 10).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 92 (agent 52130) | audit_judge | completed | 7 | 27 | 32,934 |
| 29 (agent 51423) | audit_permissions | completed | 4 | 48 | 75,243 |
| 671 (agent 51143) | audit_flow | completed | 3 | 36 | 66,245 |
| 595 (agent 51142) | audit_math | completed | 3 | 45 | 78,547 |
| 528 (agent 51166) | audit_economics | completed | 3 | 39 | 56,498 |

The judge's merged list is the result: 1 medium, 2 low, 4 info. Judge submission hash `2b3f8953da425f5a057b4fa2f8a1e2ff09592aa841d67a19eb617df3cf182a1c`; raw record of every seat beside this file (`audit-delta-panel-2026-10-08-submission.json`).

**Judge's summary, verbatim:**

> I found one medium, two lows and four informational items. All seven are in `.imd-findings.json`, and each was reproduced against 07905bb. The full suite passes (601 passed, 0 failed, 4 skipped, excluding my scratch tests). `ParameterizedVault` initcode is 46,679 bytes, 2,473 under the limit. I've deleted my scratch tests, but the medium finding's proof is embedded in the JSON.
>
> **Medium: a band position's draw lets a redemption be paid more than the book's real backing** (`src/CDPVault.sol` `draw`, line 492; affects `_backingPerUnit`)
> - **Cause:** a position at 170–200% that draws gets its new debt marked "cold" (excluded from the lagged figure until it ages). Its collateral term doesn't change, so none of the collateral is marked cold. The lagged figure therefore drops the new imdUSD but keeps all the collateral behind it, and reads high.
> - **Exploit:** a newcomer locks and draws at 200% in one transaction, which raises the live figure. A redemption in the next transaction is then paid the inflated lagged figure, and the newcomer unwinds. This is the round trip the lag (the D1 fix) was meant to close.
> - **Not already accepted:** the `_cool` item covers the same arithmetic only after the position has sat untouched for a day. Here the whole fresh draw counts.
> - **Reproduction:** the attached proof, re-run unchanged, fails as claimed. Honest backing is 0.897; after the newcomer it reads 1.0. Redeeming 5,000 imdUSD pays 9,700 IMD from the reserve where at most 8,705 is honest, about $497 over.
> - **Fix:** in `draw`, when the collateral term is unchanged, mark a matching share of it cold along with the new debt. I applied this in a scratch copy and the proof passes (0.878 against an honest 0.897).
>
> **Low**
> 1. **The vault's salt is not private** (`docs/MAINNET-RUNBOOK.md:351`). The runbook names MEV Blocker's default endpoint. MEV Blocker's docs say it "shares the transaction (without signature) with a permissioned or permissionless set of searchers", and the calldata contains the salt.
>    - **Consequence:** whoever front-runs gets an identical, correctly wired vault, so no funds are at risk. But if they also draw 1 wei, the operator's `verify` reverts and `deployment.json`, which the keeper runs from, never records the vault.
>    - **Fix:** use `/fullprivacy` or Flashbots Protect, generate the salt with `openssl rand -hex 32`, and add a path that records a vault that already exists. Four specialists reported this; it's merged into one finding.
> 2. **New capital lifts the payout to par within minutes** (`src/CDPVault.sol:321`). A loan nine times the warm book takes a book backed at 0.84 to par in 10 minutes in my test. That contradicts the comments saying capital brought in and withdrawn a few transactions later can't do this. The gain is limited by how much sIMD the Treasury holds, and it needs about $3.8M of collateral.
>
> **Info**
> - **Dilution not documented:** a 900,000 loan cuts an honest redeemer's figure from 0.88 to 0.812 for about two hours. The comment says this happens "as it does in the live figure" (the live figure actually rises), and its "two accepted cases" leaves this one out.
> - **Fee-pin cost overstated:** the `_feeBase` comment says pinning the fee at the cap costs 450 imdUSD of fee. Split into 90 small burns it costs 249.75.
> - **Second vault on rerun:** running `runVault` again with a different `VAULT_SALT` deploys a second vault and overwrites `deployment.json`.
> - **Stale comments:** `tail()` says the feed lifetimes "all agree" (they don't). The runbook still lists the vault's salt as `infer-protocol/mainnet/v1/<Contract>`. It also says `run()` reads the whole stack back, which stopped being true after the two-stage split.
>
> **Questions where nothing is wrong:**
> - The repaid-this-transaction supply and the reserve share interact correctly.
> - `cash` computes the payout figure once and every route reads it.
> - The fee-base floor only applies while the warm base is under 100,000, so it can't dilute anyone's fee once pas

| # | Severity | Blocking | Where | Title |
|---|---|---|---|---|
| 1 | medium | no | `src/CDPVault.sol:492` | CDPVault.draw/_backingPerUnit: a band position's debt-only draw adds cold debt but no cold secured term, so the lagged figure keeps that collateral against the warm supply and overstates backing; a on |
| 2 | low | no | `docs/MAINNET-RUNBOOK.md:351` | Runbook 7.2 sends the salt-carrying stage-two transaction to MEV Blocker's default endpoint, which shares transactions with searchers; the 'salt is not public before the vault exists' property the fin |
| 3 | low | no | `src/CDPVault.sol:321` | CDPVault lag: new capital is counted by its warmed fraction in an average, so a loan k times the warm book lifts a below-par book's redemption figure to par in minutes (10 min at k = 9), contradicting |
| 4 | info | no | `src/CDPVault.sol:765` | CDPVault._backingPerUnit NatSpec: the new-borrower dilution is not 'as it does in the live figure' (the live figure rises), and 'two accepted cases' omits it; measured 0.88 -> 0.812 for an honest rede |
| 5 | info | no | `src/CDPVault.sol:1066` | CDPVault._feeBase NatSpec: storing the cap from the 100,000 floor does not cost 'the cap paid on all of it'; split into ninety 100 imdUSD burns the same 9,000 pays 249.75 of fee, not 450 |
| 6 | info | no | `script/DeployMainnet.s.sol:160` | DeployMainnet.runVault: a rerun with a different VAULT_SALT deploys a second vault stack and overwrites deployment.json; the header's 'resumable ... never redeployed' no longer holds for the vault, an |
| 7 | info | no | `src/CDPVault.sol:1347` | Changed or adjacent comments that claim what the code does not: tail() 'all agree', runbook 'salts infer-protocol/mainnet/v1/<Contract>' for the vault, and run() 'reads the whole stack back' after the |

## 1. [MEDIUM] CDPVault.draw/_backingPerUnit: a band position's debt-only draw adds cold debt but no cold secured term, so the lagged figure keeps that collateral against the warm supply and overstates backing; a on

`src/CDPVault.sol:492` — blocking: no; citation: resolved

```solidity
        _lag(position, false, position.debt, position.debt + amount);
```

Root cause. draw() records the new principal as cold debt (line 492), then _resecure re-derives the term as min(collateral, 2 x principal / price). For any position whose term is already its whole collateral (ratio <= 200% at the term's price, which is every position in the 170-200% band) the term does not change, so _lag(position, true, before, current) returns at after_ == before and no cold secured is recorded. _backingPerUnit's lagged figure (line 790) is reserve x warm / supply + lagSecured / warm with warm = supply - fresh: the new debt and its imdUSD leave the warm supply, but the collateral that now also stands behind them stays whole in lagSecured. The lagged figure therefore keeps the pre-draw backing while the honest (live) figure falls by up to fresh_band / supply (a draw from 200% to 170% adds 17.6% of the principal). While the live figure binds nothing happens; but the live figure is exactly what fresh capital raises: a newcomer's lock + draw at or above 200% in one transaction lifts the live figure above the lagged one (its own collateral and debt are cold, so the lagged figure is untouched), and a cash() in the next transaction is paid min(live, lagged) = the overstated lagged figure, capped at par, from the reserve (or a candidate). The newcomer unwinds afterwards: the D1 round trip the lag exists to close. This is not any of the three accepted items: the repay-then-redeem premium is the repay direction; the _cool item (final sweep panel #4) is the same arithmetic only after the position has gone stale for a day (a sixteenth of it); here the full fresh draw counts, decaying with the 6-hour half-life. The NatSpec at 757-759 ('An attacker's capital can raise the live figure but not the lagged one ... new debt and the imdUSD minted against it are excluded together') is the property the code lacks: the imdUSD is excluded, the collateral it was drawn against is not. Preconditions: a band position's draw within the last hours and a book below par (a price fall after the draw, or a book already below par from underwater positions/bad debt, in which case a warm band borrower can run the whole sequence itself); a reserve (Treasury sIMD) or an eligible candidate. Bounded by fresh_band / warm and by the gap to par; the fee (>= 0.5%) is the only cost besides gas and a one-block collateral lock. Loser: every holder (reserve) or the candidate. Reachable with the committed constants (mat 170 at NHI >= 0.85, LINE 1M, wage 0). The redemption invariant cannot catch it: its _laggedPerUnit (test/Redemption.invariant.t.sol:277) mirrors the code's formula. Smallest fix (write side, in draw): remember termBefore = position.secured before _resecure; if the term is unchanged and nonzero, cool a pro-rata slice of it with the new debt: `if (position.secured == termBefore && termBefore > position.coldSecured) _lag(position, true, termBefore, termBefore + Math.min(Math.mulDiv(termBefore, amount, position.debt), termBefore - position.coldSecured));` (moves the position's and the vault's cold secured, not securedCollateral). Checked on a copy: with it the proof passes (after the newcomer 0.878 against an honest 0.897; paid 8,518 raw IMD against at most 8,705). A read-side fix (scaling lagSecured by lagDebt/totalDebt) would double-exclude a newcomer whose collateral is already cold.

**Reproduction.** forge test --match-path test/scratch/BandDraw.t.sol (the proof below; specialist proof Proof_75bcc4265fd5 re-run unchanged). ParameterizedVault over MockIMD at $1 (Chainlink 2000e8 etched), NHI 0.85 (mat 170), Treasury holds 10,000 IMD. BORROWER lock(200_000e18), draw(100_000e18); +2 days. BORROWER draw(17_000e18) (term stays 200,000). Next block IMD to $0.50: backingPerUnit() == 897435897435897435 = (5,000 + 100,000)/117,000 (lagged reads 1.043). NEWCOMER lock(400_000e18), draw(100_000e18) in one tx; next block backingPerUnit() == 1e18 and NEWCOMER cash(5_000e18, 0, address(0)) is paid 9,700e18 raw IMD from the reserve. EXPECTED: at most 0.897e18 and 8,705.1e18 raw IMD. ACTUAL: 1.0e18 and 9,700e18 (995 IMD, $497, over the honest payout). Test fails on 07905bb with 'fresh capital lifted a redemption's backing: 1000000000000000000 > 897435897435897435'; passes with the fix above applied in a scratch copy.

Proof attached; kept as `test/delta-panel/BandDraw.t.sol`.

## 2. [LOW] Runbook 7.2 sends the salt-carrying stage-two transaction to MEV Blocker's default endpoint, which shares transactions with searchers; the 'salt is not public before the vault exists' property the fin

`docs/MAINNET-RUNBOOK.md:351` — blocking: no; citation: resolved

```solidity
   (`--rpc-url https://rpc.mevblocker.io`), never a public mempool: the transaction carries the salt, and
```

Merged from audit_math (low), audit_flow (info), audit_economics (low), audit_permissions (low). runVault() calls CREATE2_FACTORY with bytes.concat(salt, _vaultInit(p)) (script/DeployMainnet.s.sol:268); the canonical deployer binds the address to (salt, initcode) only, so anyone holding the calldata can land the identical vault from any account. The runbook names https://rpc.mevblocker.io. MEV Blocker's own documentation (docs.mevblocker.io/concepts/order-flow-auction, fetched 2026-10-08): 'MEV Blocker RPC shares the transaction (without signature) with a permissioned or permissionless set of searchers'; the endpoint list (reference/api/transaction-endpoints) offers https://rpc.mevblocker.io/fullprivacy, 'Maximum privacy, no rebates', as the private option. An unsigned copy is enough: the salt is in the calldata. So the claims at script/DeployMainnet.s.sol:81-82 ('stage two is sent through a private relay (MEV Blocker), so the salt is not public before the vault exists'), src/SwarmFeed.sol:239 ('from a salt no one else knows, so no one else can deploy it first') and runbook 251-252 / 331-334 rest on a third party's no-frontrun policy, not on the transaction being private. Consequence if a recipient front-runs (after verifySeeded passed, so the feeds are honest): the copy is byte-identical and correctly wired (every child is created by the vault), the operator's transaction reverts inside the deployer (CREATE2 collision) after spending its gas, a rerun prints 'exists, skipped'; if the front-runner also locked and drew 1 wei in its bundle, verify() reverts at line 290 ('imdUSD: nonzero opening supply') or 319 and _record never writes the vault, parameters, treasury or stablecoin into deployment.json, which the keeper runs from; no entry point re-records an existing vault. No funds at risk, hence low. Also unstated: how to make the salt (the rehearsal uses cast keccak of a date and $RANDOM; a salt derived from a phrase is guessable). Smallest fix: runbook 7.2 and the script header name https://rpc.mevblocker.io/fullprivacy (or Flashbots Protect with hints off) and say builders still see it; generate VAULT_SALT as 32 random bytes (openssl rand -hex 32); give runVault a path that, when p.vault already has code, checks the codehash and records it without the opening-state requires. Or deploy the vault with plain CREATE from the deployer, which nobody can pre-empt.

**Reproduction.** State: stage one landed, first values relayed, verifySeeded passed. Operator runs, per runbook 7.2: VAULT_SALT=0x<secret> REFERENCE_IMD_ETH_WEI=... FOUNDRY_PROFILE=deploy forge script script/DeployMainnet.s.sol --sig runVault() --rpc-url https://rpc.mevblocker.io --broadcast. EXPECTED (DeployMainnet.s.sol:81-82, runbook 351-352): no one but the operator sees the salt until the vault exists. ACTUAL: the default endpoint forwards the transaction (unsigned) to its searcher set; calldata = salt ++ ParameterizedVault initcode to 0x4e59b44847b379578588920cA78FbF26c0B4956C. A recipient replaying it plus lock and draw(1) lands first; the operator's run then logs 'exists, skipped' (DeployMainnet.s.sol:263-266) and reverts in verify at 'imdUSD: nonzero opening supply' (line 290), so deployment.json gets no vault. Not a Foundry-reproducible property (off-chain relay policy); verified against docs.mevblocker.io on 2026-10-08, and the deploy-side consequences by reading _deploy, verify and _record (lines 262-272, 276-319, 458).

## 3. [LOW] CDPVault lag: new capital is counted by its warmed fraction in an average, so a loan k times the warm book lifts a below-par book's redemption figure to par in minutes (10 min at k = 9), contradicting

`src/CDPVault.sol:321` — blocking: no; citation: resolved

```solidity
    /// position's own cold first and counts at once. So capital brought in one transaction and withdrawn a
```

From audit_permissions (low), reproduced. The lagged figure is (reserve x warm/supply + warm secured)/warm. A newcomer's cold capital halves every 6 hours, so after t seconds a fraction 1 - 2^(-t/6h) of both its debt and its secured term is warm. A newcomer at >= 200% contributes about 2 of secured value per warm unit of its debt, so averaged with a warm book backed at b < 1 the lagged figure reaches par once its warm fraction reaches about (1-b)/((2-b)k) for a loan k times the warm book: about 1.5% for k = 9 at b = 0.84, i.e. 10 minutes. The live figure is above par throughout (the newcomer's collateral), so min(live, lagged) = par and a reserve-funded cash() in that window pays par; the newcomer then wipes and frees. The NatSpec at 321-322 ('capital brought in one transaction and withdrawn a few later cannot authorise work minting or a redemption at par') and at 757-758 ('An attacker's capital can raise the live figure but not the lagged one') state it as a property; 'a day' (316-320) is how long the newcomer takes to count in full, not how long it takes the payout to reach its cap. Gain bounded by (1 - b - fee) x the Treasury's sIMD (position-funded payouts stay pro rata via RedemptionWorsensRatio); cost: collateral worth ~2k times the warm book locked for the window (9,000,000 IMD, about $3.8M at $0.42, against a $2.3M-a-side market, so k = 9 is hard to source; k = 3 takes 29 minutes per the specialist), price exposure and duty. Hence low. Smallest fix: state the warm-fraction behaviour and its k-dependence at the lines above and in runbook section 7 (keep Treasury sIMD small while the book is thin); a code change (e.g. capping each fresh unit's lagged contribution at par, or counting new capital only after a half-life) is an economic-rule decision for the requester.

**Reproduction.** test/scratch/Q1Probe.t.sol::test_timeToPar (passes, logs): ParameterizedVault over MockIMD at $1, NHI 0.85, no reserve. OLD lock(200_000e18), draw(100_000e18); +2 days; IMD to $0.42: backingPerUnit() == 0.84e18. NEW lock(9_000_000e18), draw(900_000e18) in one tx; then backingPerUnit() is read every 60 s. EXPECTED per lines 321-322: capital brought in and withdrawn a few transactions later cannot authorise a redemption at par (the figure stays near 0.84 for hours). ACTUAL: backingPerUnit() == 1e18 after 10 minutes.

## 4. [INFO] CDPVault._backingPerUnit NatSpec: the new-borrower dilution is not 'as it does in the live figure' (the live figure rises), and 'two accepted cases' omits it; measured 0.88 -> 0.812 for an honest rede

`src/CDPVault.sol:765` — blocking: no; citation: resolved

```solidity
    /// figure and the live one stands. The lag underpays honest redemptions for hours in two accepted cases:
```

Merged from audit_flow (2 infos), audit_economics (info), audit_permissions (info). Q1's underpayment side: a fresh loan D dilutes the lagged figure's reserve term by D/(supply+D) while adding no warm collateral, so an honest reserve-funded redeemer is underpaid by about (reserve/supply_before) x D/(supply_before + D) until the loan warms. In the live figure the same dilution is outweighed by the newcomer's collateral, so the live figure RISES; 'as it does in the live figure' (line 764) is true of the reserve term only. The sentence at 765 then counts 'two accepted cases' of underpayment, leaving out this third (work-minted warm supply with no collateral would be a fourth, unreachable at launch with wage 0). Not a cheap grief: it needs a loan comparable to the whole supply with collateral at >= 170%, it only bites below par, and it reverses within a couple of hours as the same loan warms (and then lifts the figure, see the low finding on warm-up). The payout stays capped at backing, so the peg floor is not harmed. Q1 otherwise holds: REPAID_THIS_TX_SLOT is added to supply in both the reserve share and the divisor, so the reserve term stays reserve/supply exactly as in the live figure; cash() computes payoutScale once (line 716) and the reserve route and mixed route both read it. Smallest fix: reword 762-767 to count the dilution among the accepted underpayments with its bound, and drop 'as it does in the live figure'.

**Reproduction.** test/scratch/Q1Probe.t.sol::test_dilution (passes, logs): Treasury holds 20,000 IMD; OLD lock(200_000e18), draw(100_000e18); +2 days; IMD to $0.40: backingPerUnit() == 0.88e18. NEW lock(5_000_000e18), draw(900_000e18); next block backingPerUnit() == 812143724142315685 (lagged 8,000/1,000,000 + 80,000/100,000 plus one block of warming) while the live figure is par; +2 h: 1e18. EXPECTED per 764-765: the dilution is as in the live figure and not among the accepted underpayments. ACTUAL: the live figure is par, the payout figure 0.812, 7.7% under the book the redeemer found.

## 5. [INFO] CDPVault._feeBase NatSpec: storing the cap from the 100,000 floor does not cost 'the cap paid on all of it'; split into ninety 100 imdUSD burns the same 9,000 pays 249.75 of fee, not 450

`src/CDPVault.sol:1066` — blocking: no; citation: resolved

```solidity
    /// of it times the divisor (9,000 at 2), the cap paid on all of it. Under the floor a redemption's
```

Merged from audit_math and audit_economics (info). _redemptionRate adds each burn's increase to the decayed stored rate, and each burn pays the floor plus the rate including only its own increase, so slices pay 50, 55, ... 500 bps and store the same 0.045e18. The 9,000 threshold is right; the price is about 1.8x overstated (and the same row in docs/AUDIT-FINAL-SWEEP-PANEL-2026-10-08.md Resolution #1). With a 12-hour-seasoned own position in the 170-220% band as the candidate (accepted b952037a) the fee stays in the pinner's collateral. Q2 otherwise: the floor is a max, inert once the warm base passes 100,000, so it dilutes nobody's fee; while the warm supply W is under 100,000 a run raises the rate by W/200,000 at most, a weaker brake, but the payout is capped at backing so remaining holders lose nothing. Fix: reword to 'about 250 imdUSD of fee in small burns, 450 in one'.

**Reproduction.** test/scratch/PinSplit.t.sol (passes, logs): ParameterizedVault at $1, B lock(400_000e18) draw(100_000e18), Treasury 100,000 IMD, +12 s. test_oneBurn: cash(9_000e18) -> redemptionBaseRate 45000000000000000, fee 450.0. test_ninetyBurns: 90 x cash(100e18) in one block -> redemptionBaseRate 45000000000000000, fee 249.75. EXPECTED per line 1066: the cap paid on all of it (450). ACTUAL: 249.75.

## 6. [INFO] DeployMainnet.runVault: a rerun with a different VAULT_SALT deploys a second vault stack and overwrites deployment.json; the header's 'resumable ... never redeployed' no longer holds for the vault, an

`script/DeployMainnet.s.sol:160` — blocking: no; citation: resolved

```solidity
        bytes32 salt = vm.envOr("VAULT_SALT", bytes32(0));
```

From audit_permissions (info) and audit_flow. plan() derives p.vault from the environment; _deploy skips only when that address has code; nothing reads the stage-two record back. Same salt: 'exists, skipped', verify, record (fine). Any other nonzero salt (lost, retyped, regenerated as rehearse-fork.sh does per run) passes verifySeeded, deploys a second correct ParameterizedVault with its own imdUSD, Parameters, Treasury, oracle and feeds (~12.7M gas), and _record overwrites deployment.json, so the keeper follows the second vault while the first stays live. Operator-only, no funds lost. Fix: in runVault refuse when deployment.json already records a vault with code at a different address, or record keccak256(salt) in stage one and check it; add 'rerun with the same VAULT_SALT' to runbook 7.2.

**Reproduction.** On a fork after a successful stage two: VAULT_SALT=0xaa..aa forge script ... --sig runVault() --broadcast (vault A, deployment.json vault = A); then VAULT_SALT=0xbb..bb ... --sig runVault() --broadcast. EXPECTED per header lines 89-91: 'exists, skipped'. ACTUAL by the code path (lines 160-161, 224, 262-271, 458): p.vault is a new address with no code, the deployer is called, vault B is created, verify(p) passes, deployment.json now names B.

## 7. [INFO] Changed or adjacent comments that claim what the code does not: tail() 'all agree', runbook 'salts infer-protocol/mainnet/v1/<Contract>' for the vault, and run() 'reads the whole stack back' after the

`src/CDPVault.sol:1347` — blocking: no; citation: resolved

```solidity
    /// feeds' lifetimes (the spot feed and Chainlink are not read; at the shipped constants all agree).
```

(1) CDPVault 1347: tail() = min(price, NHI maxAge) = 1 hour; the four lifetimes do not agree (PRICE 1 h, SPOT 1 h, NHI 1 day, ETH_USD 2 h, DeploymentConfig 30, 39-41); presumably 'the minimum would be the same' was meant. (2) docs/MAINNET-RUNBOOK.md 242: 'salts infer-protocol/mainnet/v1/<Contract>' is now false for the vault, whose salt is the operator's secret (the paragraph below it says so). (3) runbook 238-240 and DeployMainnet header 89-92: run() 'reads the whole stack back off chain before writing deployment.json, which is what the keeper runs from'; since the split run() reads back only the feeds and asker (verifyFeeds, line 209) and records no vault; the keeper's record comes from runVault. Everything else changed in the diff was checked and holds: divisor NatSpec (CDPVault 183-185, Parameters 110-113, DeploymentConfig 128-130); BACKING_WARMUP 331-332 (_cool returns 0 at a day for banks too); cover 590-596 against the burn at 616; cash @notice; the premium figures 773-777; _cool 1035-1038 for the stale orphan (but see the medium finding for the unstale case); redemptionReserve (gem only); Treasury.fundOracle NatSpec against its try/catch; 'prior is never zero' (floor). Contract size: ParameterizedVault initcode 46,679 B (2,473 under EIP-3860), runtime 22,466 B (forge build --sizes). forge test (excluding test/scratch): 601 passed, 0 failed, 4 skipped. The redemption invariant's _laggedPerUnit mirrors the new formula exactly, so it cannot detect the band-draw gap. Read in full: src/CDPVault.sol (the lag, backing, fee, draw/wipe/cover/cash paths), script/DeployMainnet.s.sol (plan, run, runVault, _deploy, verify, _record), the diff 6085c8a..07905bb, runbook sections 6-7. Read in part: ParameterizedVault, Treasury.fundOracle, DeploymentConfig, Parameters, SwarmFeed (changed lines). Not reached: UsdPriceFeed, SharePriceFeed, ImdUSD, the factories, SwarmWorkOracle, OracleAsker beyond ask, deploy/mainnet/plan.py beyond the vault regex.

**Reproduction.** (1) read CDPVault.sol 1350-1352 against DeploymentConfig.sol 30, 39-41: min(1 hours, 1 days) = 1 hour while ETH_USD_MAX_AGE = 2 hours and NHI_MAX_AGE = 1 day. (2) runbook 242 against DeployMainnet.s.sol 220-224 (vault salt from VAULT_SALT). (3) DeployMainnet.s.sol 195-213 (run(): verifyFeeds(p, true); _record; no vault) against runbook 238-240.


## Resolution

All seven findings are answered in the commit after `07905bb`. The medium and both lows' code parts are fixed; one low is accepted with its bound, a runbook rule and a public note; the infos are fixed.

| # | Severity | Outcome |
|---|---|---|
| 1 | medium | **Fixed, as the judge proposed.** `draw` remembers the term before re-securing; when a band position's term does not move, the new debt's share of it (`term x amount / debt`, at most what is not already cold) goes cold with the new debt through `_lag`, so the lagged figure excludes the collateral behind the new imdUSD as well as the imdUSD. It only ever lowers the lagged figure, by the position's own capital. The panel's proof passes as written (`test/delta-panel/BandDraw.t.sol`: after the newcomer 0.878 against an honest 0.897; 8,518 raw IMD paid against at most 8,705). The `_backingPerUnit` NatSpec now states the property with the band case included. |
| 2 | low | **Fixed in the runbook and the script.** Stage two is broadcast through MEV Blocker's full-privacy endpoint (`https://rpc.mevblocker.io/fullprivacy`), never the default endpoint, which shares transactions with searchers; the salt is generated fresh (`openssl rand -hex 32`). `runVault` records the vault before `verify` runs, so a vault that is already at the address is in `deployment.json` even when `verify` refuses it, and the runbook says to stop there and decide from what is at the address. |
| 3 | low | **Accepted, bound stated.** New capital counts by its warmed fraction, averaged with the warm book, so a loan many times a thin, below-par book lifts the lagged figure toward par in minutes. It needs collateral worth about twice the loan locked for the window, at the market's price risk, and gains at most the gap to par on the Treasury's sIMD, since a position-funded payout stays pro rata. Every code change considered (a slower warm-up for collateral than for debt, or each new unit capped at par) underpays honest redeemers for hours after every honest loan. The `BACKING_HALF_LIFE` NatSpec states it (replacing the claim that such capital "cannot authorise a redemption at par"), `docs/MAINNET-RUNBOOK.md` section 7 says to keep the Treasury's sIMD small while the book is thin, and the public risks page says so. |
| 4 | info | **Fixed.** The `_backingPerUnit` NatSpec lists the new-loan dilution as a third accepted underpayment, with the panel's figure (0.88 to 0.812 for about two hours), and no longer says it happens "as in the live figure". |
| 5 | info | **Fixed.** The `_feeBase` NatSpec gives the cost of storing the cap from the floor as about 250 imdUSD of fee split into small burns (450 in one). |
| 6 | info | **Fixed.** Neither stage runs while `deployment.json` names a deployed vault other than the one `VAULT_SALT` gives (`_refuseAnotherVault`), so a rerun with another salt, or stage one without it, can neither deploy a second vault nor drop the first from the keeper's record. The script header says which stage is resumable and what each records. |
| 7 | info | **Fixed.** `tail()` states the spot feed's and Chainlink's lifetimes; the runbook's salt line excludes the vault, and its stage description says each stage reads back what it deployed. |
Verification: `forge test` 602 passed, 0 failed (4 skipped); with `AUDIT_PROOFS=true` 603 passed, 0 failed; the invariants clean under six further seeds; `script/checks` failure set unchanged by name (23); `docs/abi` unchanged; ParameterizedVault initcode 46,795 bytes (2,357 under EIP-3860); `deploy/mainnet/rehearse-fork.sh` green through both stages with a random salt, the keeper's bark and bite and the Treasury-paid ask.
