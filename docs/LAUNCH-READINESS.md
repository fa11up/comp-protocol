# Launch readiness (2026-10-05)

The goal: deployable on short notice. Each area says what is done, the evidence, and what is still owed.
**Blocking** = cannot deploy without it. **Before freeze** = must be decided before the deploy commit is
frozen, because the contracts are immutable. **After deploy** = first operational acts.

## 1. Contracts

| item | status | evidence |
|---|---|---|
| External audit, three panels (vault, governance + Treasury, oracle) | done, all fixed or accepted | `AUDIT-{VAULT,GOVERNANCE,ORACLE}-2026-10-05.md`, `AUDIT-FIX-PLAN-2026-10-05.md` |
| Adversarial review of the fixes + gas review | done, merged `9dd2149` | `AUDIT-ADVERSARIAL-2026-10-05.md`, `AUDIT-GAS-2026-10-05.md` |
| Internal suites | green: forge 528/0; `script/checks` failure set unchanged by name (23/116, stale assertions); AUDIT_PROOFS 1 known demonstration (an unbound test feed — every shipped feed binds its question and `DeployMainnet.verify` checks it) | |
| Redemption invariant, the 1-wei rounding note | **closed**: 40 fresh seeds, 0 failures, after the handler model was corrected to the vault's payout scale (`9dd2149`) | |
| **Scoped pre-deploy review** (everything after `03e8d0c`: phase-2 fixes, the `SwarmWorkOracle` creator change, `DeployMainnet` + `plan.py`, and whatever §8 decides) | **owed — blocking**, sent when the deploy commit is frozen | payload built by `whitepaper/requests/audit/build_audits.py` |
| Accepted residuals | D2 chunked-redemption fee, D3 non-monotone backing figure, D4 two-push drift arming, D5 sIMD same-block hold griefing, D6 self-mark 18% penalty, D9 recapitalised drained borrower | `AUDIT-FIX-PLAN-2026-10-05.md` |

## 2. Deployment

| item | status |
|---|---|
| `script/DeployMainnet.s.sol` (CREATE2 plan, refuse-unless-matching, resumable, read-back, record for the keeper) | built `9314830` |
| `deploy/mainnet/plan.py` converges the config (4 passes) | built |
| Fork rehearsal `deploy/mainnet/rehearse-fork.sh` | **passing** end to end, incl. the keeper |
| Intake bodies match the feeds' pinned questions | `node deploy/mainnet/check-bodies.mjs` passes |
| **Intake deployed by the dev, address known** | **blocking** (upstream) |
| Cold governance address, throwaway deployer (~0.05 ETH) | **blocking** — user |
| Live attestation for NHI and SPOT with the frozen payloads (only PRICE has one, `e2c85027`) | **owed, ~1 IMD** — buy against the Sepolia launch-688 feeds (same prefixes, verified) and compare `questionHash` to `expectedQuestionHash`; closes runbook §5 step 4 |

## 3. Oracle operations

| item | status |
|---|---|
| Guard analysis on 50 days of IMD history | done: `oracle-guards/ORACLE-GUARDS-2026-10-05.md` |
| Asymmetric trigger (5% on falls / 20% on rises): halves worst over-valuation at lower cost | **before freeze — decision** (small `OracleAsker` change) |
| `ORACLE_BUDGET_PER_DAY` 10 → 15 IMD | **before freeze — decision** (the governed value opens at the constant; governance can move it later behind 48h) |
| Feeds kept live at launch | ours: the keeper drives the Treasury-paid path (drift + NHI keep-alive) and pays itself (`askPaid`) when positions are at risk |
| Sponsor points for anyone who pays for updates | no contract change needed: `AskedPaid(feed, requestId, payer, price)` is already emitted, so the points engine can credit payers off chain; a co-op hub can come later without touching the protocol |

## 4. Keeper

| item | status |
|---|---|
| Mainnet mode (deployment record, asker path, sIMD pricing, inventory-capped bites, guarded sends, one-at-a-time loops) | done `fa11up/imd-keeper@c9b8eaa`, rehearsed on the fork |
| Review | internal only (private repo; the swarm cannot read it). Its failure modes cost the keeper's own funds, not the protocol's solvency |
| Host (NOT the swarm worker box), hot key, three balances (ETH gas, imdUSD inventory, IMD for `askPaid`), Blockscout API key | **after deploy** — user |

## 5. Frontend and docs

| item | status |
|---|---|
| Public site (homepage + docs) live on imdusd.com, terminal gated off | done |
| QA + accessibility review | done on the terminal before the sIMD / maker changes (`QA-REVIEW-2026-10-05.md`) |
| Browser suite against the **maker** ABIs | **owed**: now runnable — point `web/deployment-source.json` at the fork rehearsal's deployment |
| Launch values on the homepage and docs read "Pending" | **after deploy**: fill `LAUNCH` in `web/src/Landing.tsx` from `deployment.json`, publish addresses |

## 6. Governance, first acts (runbook §7)

Seed the three feeds (3 attestations), list sIMD as a reserve asset (48h), fund the keeper, start it, then
announce. The window to abandon closes at the first user deposit.

## 7. Upstream

Drafts in `docs/upstream/`: stability promises (issue), imdUSD as payment (issue), window-free question id
(issue, discussion), and the direct asks led by the Intake.

## 8. Work integration — the one migration risk

**Accepting imdUSD as payment needs nothing from our contracts**: imdUSD is a plain ERC-20 and acceptance is
the plane's listing (x402 / Intake `priceOf`). The swarm's payment door is already on Ethereum mainnet.

**Minting from work is different.** The vault's work oracle is `immutable` and pins, in bytecode: the
WorkRegistry address, the daily-receipt jobId scheme, the `identitymd-oracle-batch-v2` schema and its leaf
encoding, and the attester. Minting ships off (wage 0), so nothing is at risk at launch — but if the
"full circle" integration needs ANY of those to differ, turning minting on would need a new vault and a
migration of every position.

The same class of risk covers the price feeds through the pinned attester key: an in-place key rotation
upstream bricks every feed. That one is not ours to make governable (price authority is never governed —
a design rule), so it is handled upstream: the stability issue asks for additive versioning and a key
rotation overlap.

**Option, before freeze:** a governed work-oracle slot — `Parameters` may replace the vault's work oracle
behind the 48-hour timelock, **only while the wage is zero** (so no rights are ever outstanding in the old
oracle, which makes double-claiming impossible by construction). Governance already sets the wage, so this
adds no new trust: a governor who could mint through a malicious oracle can already raise the wage.
Cost: one governed address in `Parameters`, one read in the vault (initcode margin 6,134 bytes), one
proposal path and tests, all inside the scoped review. It removes the only known forced migration.
