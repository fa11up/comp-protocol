# Launch audit — aggregated fix plan (2026-10-05)

Sources, all at `e52a025`: vault panel `414e25cc` (judged, `AUDIT-VAULT-2026-10-05.md`); oracle panel
`f6faeaf9` (the judge ran out of budget after ONE finding, so the four specialists' other findings are
unjudged; `AUDIT-ORACLE-2026-10-05.md`); governance retry `ae08d373` (judged; `AUDIT-GOVERNANCE-2026-10-05.md`: 1 medium, 3 low, 11 info, all already in this plan) plus the blocked `10a1f886`'s two accepted specialists. Where several
reports describe one defect it appears once, with how many found it.

Standing decision: **minting from work stays off until upstream integration**, enforced at launch by
`WAGE_WAD = 0` (rights are tasks × wage, so no task earns any; governance raises it behind the 48-hour
timelock). Paired with **`SwarmWorkOracle.claim` refusing while the wage is zero**: otherwise a claim
made at wage 0 would mark the agent's tasks as used, credit nothing, and those tasks could never earn
once minting is switched on.

## Fix

| # | Sev | Finding | Found by | Fix |
|---|---|---|---|---|
| F1 | **high** | `SwarmFeed` never relates the signed window to the chain head: an answer signed now over a window that closed days ago (or one 1,000,000 blocks in the future) is accepted and dated now. With price feeds bought on demand, anyone can re-anchor a lapsed feed to a past price of their choosing and redeem or borrow against it in the same transaction. The service was observed signing a window that closed 5 h earlier. | oracle judge + 4/4 specialists | When the attested data chain is this chain, require `toBlock <= block.number` and `block.number - toBlock <= maxAge / 12` (the feed's own lifetime, in blocks). The future bound also closes the "a far-future window bricks `lastToBlock`" low. Testnet feeds (data chain 1, deployed on Sepolia) cannot see the data chain's head; documented as a testnet limit. |
| F2 | medium | A drained borrower calls `lock(1)` (or dust is left after a further price fall): `bite` cannot seize a sub-one-wei remainder, `cover` refuses non-zero collateral, so the bad debt is frozen and the Treasury imdUSD behind `BadDebtFirst` with it. | vault judge + 5 governance specialists | The judge's tested fix: in `bite`, when the seizure exceeds collateral but the collateral is below the one-wei seizure, take the whole remainder (bonus saturating), so a one-wei bite always drains dust and records the bad debt. **As built:** `cover` also accepts a position holding dust below that seizure, sweeping it to the Treasury first. The judge's broader option (any position worth less than its debt) was NOT taken: it would seize collateral with no mark and no grace. |
| F3 | medium | `fundOracle` sends the full daily budget whatever `OracleAsker` already holds; unspent IMD piles up in a contract with no way out. | 3 oracle specialists | Top up instead: send at most `oracleBudget − asker's balance`, so the asker never holds more than a day's budget. |
| F4 | medium | If a bought attestation is relayed by hand before the Intake's callback, `onOracleResult` reverts, the feed's in-flight slot stays held for `ASK_TIMEOUT`, and `ask` / `askPaid` are refused for two hours. | 3 oracle specialists | `onOracleResult` clears the slot first and wraps the relay in `try`/`catch`, emitting whether it was delivered. |
| F5 | medium | `CHAINLINK_ETH_USD` and `ATTESTATION_RELAYER` are Sepolia addresses; compiled unchanged for mainnet, every feed is inert and the USD leg reads stale forever, silently. | 4 oracle specialists | **As built:** `script/DeployPreflight.sol`, called first by both deploy scripts, refuses to broadcast unless `ATTESTATION_RELAYER`, `TREASURY_FACTORY` and `CHAINLINK_ETH_USD` have code and Chainlink answers fresh. Not in the constructors: a relayer may legitimately be an EOA. |
| F6 | low | `cover` burns Treasury imdUSD outside its receipt accounting, so revenue that arrived since the last `sync` is lost from `totalReceived` (the class the 2026-10-03 audit fixed in `withdraw`). | 6 governance specialists | `cover` calls `treasury.sync(stablecoin)` before burning. |
| F7 | low | The register accepts the vault's own collateral against any feed; listed against `usdPriceFeed` it is valued 125,786× and inflates `earnLine` and backing. | vault judge + 4 governance specialists | `validateReserveAsset` requires the collateral to be listed with the vault's `collateralPriceFeed()`. |
| F8 | low | `earn` then `cash` in one transaction dilutes the redemption fee base: work-minted imdUSD is not netted like drawn principal. | vault judge | Count `earn` in the same transient slot as `draw`. Unreachable while work minting is off, but one line. |
| F9 | low | `reserveValueOf` can revert on a listed feed answering an extreme value, taking `earnLine`, `backingPerUnit` and `cash` down with it, contrary to its "never reverts" promise. | 3 governance specialists | Treat a product that would overflow as unpriced (counts for nothing), like any other bad answer. |
| F10 | low | The vault trusts whatever `TREASURY_FACTORY` returns. | governance flow | Revert unless `treasury.vault() == address(this)`. |
| F11 | info | NatSpec and docs that state old values or false properties: `bite` 110% / 1.1e18; contract header (18-decimal MockIMD); bad-debt "no forgiveness"; `ImdUSD.burn`; `fundOracle` "last way out"; misattached docs on `proposeRedemptionDivisor` / `redeemIMD` / `withdrawer`; `Governed`'s live-ceiling reason; divisor "5.5%" (it is 5.0%); `MAX_EARN_MAT_BPS` rationale; `SpotFeed` "tighter"; `OracleAsker` "flash push cannot trigger"; `SwarmWorkOracle` maxAge claims; `cash` "strictly improves backing"; runbook constants; `docs/ABI.md`. | many | One documentation pass. |

## Decide, not fix

| # | Sev | Finding | Recommendation |
|---|---|---|---|
| D1 | medium | Redemption backing cap and `backedDebt` excluded only same-transaction capital; borrow → redeem/earn → unwind across adjacent transactions paid the reserve at par while backing was 0.4, or minted unbacked work imdUSD. | **BUILT, DORMANT until the wage is raised (user's call).** Lagged capital in `CDPVault` (`laggedNow`, `BACKING_WARMUP` = 1 day): increases are credited linearly over a day, decreases at once, and backing reads min(live, lagged) in both places — only while `wage() != 0`. Tracked from deployment so it is warm when switched on. `test/LaggedBacking.t.sol` replays the attack one block apart; with the lag disabled backing jumps 0.29 → 1.00 in one block, with it on it does not. |
| D2 | low | Splitting one redemption into chunks pays about a third less than the fee for its size (each call is charged at its own post-increase rate). | Accept and document: the fee still rises with every chunk, and the base persists for 12 hours. |
| D3 | low | `backingPerUnit` can fall across a redemption funded from a position when the mat cap binds. | Accept (known: the conservative measure is not monotone); fix the false comment under F11. |
| D4 | low | The drift trigger can be armed and asked by two single-transaction pool pushes five blocks apart. | Accept: each push pays the 1% pool fee both ways, the result is only an honest attestation, and spend is capped by the daily budget. Correct the NatSpec. |
| D5 | low | One-wei sIMD transfers into the Treasury can keep `fundOracle` hitting sIMD's same-block hold. | Accept: griefing only, costs the griefer gas every block, and a later block succeeds. |
| D6 | info | A borrower who marks its own position recovers the marker's share: an effective 18% penalty, not 20%. | Accept and document. |
| D7 | low/info | `SwarmWorkOracle`: `maxAge` gates nothing; a root accepted but not recorded before the next is unrecoverable. | Defer with work minting (D1); correct NatSpec now. |
| D9 | medium (variant) | Governance judge: a drained borrower who re-collateralises to HEALTH keeps the bad-debt record, so `cover` stays refused and Treasury imdUSD equal to it stays behind the floor until they repay. | Accept. The record is deliberately realized loss that collateral cannot erase (an invariant counts each shortfall once); releasing it was built and backed out for that reason. Holding the floor costs the borrower a real, fee-paying loan. |
| D8 | info | A first delivery into a production-sized bound feed costs ~150k of the Intake's 200k stipend; the test asserts headroom on a small feed. | Add a test with the real question prefix. |

## After the fixes

Re-run every tree (main, `script/checks`, `AUDIT_PROOFS`, forks, web), then send the phase-2
`adversarial-review` pinned to the fixed commit (`build_audits.py e52a025… <fixed>`), weighted to this
diff. The oracle panel's judge never ran over the specialists' findings, so the adversarial pass should
also be told to re-check the oracle path in full.
