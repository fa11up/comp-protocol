# Internal adversarial audit and site QA (2026-10-06)

Reviewed at `a4c22a5` (HEAD of `main`), Claude Fable 5.1, in-house. Scope: every contract under `src/`,
the mainnet deploy path (`script/DeployMainnet.s.sol`, `deploy/mainnet/`), the oracle payloads under
`oracle/` and `deploy/mainnet/bodies/`, the verified StakedIMD source on mainnet, and the public site at
imdusd.com with its build. No tracked file was changed. `dist/` and `dist-public/` were rebuilt by the web
check and came out byte-identical to what the site serves.

Baseline: `forge test` passes **536 of 540**, the 4 skips being the fork suites. `node deploy/mainnet/check-bodies.mjs`
passes for all three bodies. `forge build --sizes`: ParameterizedVault initcode 44,210 of 49,152.

## Reviewer's summary

One high, one medium, five low and a handful of informational findings on the contracts; four medium and
seven low on the site. Nothing critical. The five prior rounds (`AUDIT-2026-10-03` through
`AUDIT-ADVERSARIAL-2026-10-05`) were read first so that nothing below repeats a finding already fixed or
accepted; the targets were the areas those rounds listed as unreviewed: the always-lagged redemption cap,
the governed work-oracle slot, the oracle path as a whole (the oracle panel judged one finding before its
budget ran out), and the real sIMD contract, which no earlier reviewer could reach.

The headline is not a bug in a function but a property of the oracle design taken as a whole: the price
feeds are stale most of the time by design, the deviation bound is off while they are stale, the buyer of
an attestation chooses the block window, and the primary's thirteen samples sit at predictable blocks. Put
together, the cost of steering the price is the cost of seven one-block pushes into one pool, which at
today's depth is in the same range as what the debt ceiling lets an attacker take out.

## Findings — contracts

### 1. [high] The primary price can be steered by a buyer-chosen, sample-aligned window whenever the feed is stale, which is its normal state

**Where.** `src/SwarmFeed.sol:313-319` (`_checkValue`), `src/SwarmFeed.sol:246-260` (`_requireQuestion`),
`src/DeploymentConfig.sol:32-40` (feed lifetimes, "the protocol does NOT keep prices fresh on a clock"),
`deploy/mainnet/bodies/price.template.json` (median of 13 evenly spaced samples), `spot.template.json`
(the window's last block alone), `oracle/question-prefix.mjs` ("any window produces the same prefix").

**The four facts that combine.**

1. The deviation bound applies only while the last value is fresh. Past `maxAge` (one hour for the price
   and spot feeds) the next accepted value re-anchors to anything. `test_staleValueCanReanchorThroughFreshAttestation`
   in `test/SwarmFeed.t.sol:332` pins exactly this, and the NatSpec calls it deliberate. Since price
   updates are bought on demand and not on a clock, the feeds are stale for most of any quiet day, so the
   *first* attestation after any quiet hour is unbounded.
2. Question binding pins the question text, not the window. `_requireQuestion` accepts any window whose
   span is 300 to 1,200 blocks (`PriceFeed.questionPolicy`), whose `toBlock` advances, and whose `toBlock`
   is within `maxAge / 12` = 300 blocks of head. The generator proves the prefix is identical whatever the
   window, and the service accepts literal `{fromBlock, toBlock}` bodies (`oracle/vwap-oracle-quote.json`,
   `oracle/nhi-composite-quote.json` carry them). So the buyer, not the service, chooses which 300 to 1,200
   blocks are answered over, from a set of roughly 300 × 900 candidate windows.
3. The primary is "the median of 13 evenly spaced samples" over that window, so the sample blocks are a
   deterministic function of the window the buyer chose. The spot feed reads the window's last block
   alone, which the buyer also chooses. The divergence guard compares the two.
4. Panel members read chain state faithfully. A pool whose end-of-block state was pushed is attested
   honestly, with full agreement, at the pushed price. Nothing in the attestation path distinguishes a
   manipulated reading from a real one, and nothing is supposed to: that was the deviation bound's job.

**The attack.** Wait for the price feeds to go stale (any quiet hour). Make seven end-of-block pushes of the
IMD/ETH v4 pool, 25 blocks apart, restoring the pool in the following block each time. Buy a primary
attestation over the 300-block window whose 25-block sample grid lands on those seven blocks (seven of
thirteen is a majority, so the median is a pushed sample), and a spot attestation whose `toBlock` is one of
them. Relay both through `SwarmRelay.relayMany`. Both feeds now read the pushed price, fresh, within 5% of
each other.

**Cost, from the pool as it stood on 2026-10-06.** Pool `0xb07d…fb3` on the v4 PoolManager held about
741 ETH and 174k IMD of virtual reserves at the current price (about $2.0M a side at ETH $2,698 and IMD
$11.49; read via `extsload`, slot 6 and 6+3). Moving a constant-product price by a factor *k* needs
`R·(√k − 1)` of the input side; the round trip pays the 1% fee twice:

| push | ETH in | round-trip fee | seven pushes |
|---|---|---|---|
| ×1.5 | ~167 ETH ($450k) | ~$9k | ~$63k |
| ×2 | ~307 ETH ($828k) | ~$17k | ~$116k |
| ×3 | ~542 ETH ($1.46M) | ~$29k | ~$205k |

plus, per push, one block of exposure in which an arbitrageur who lands ahead of the restore captures the
attacker's slippage. The attacker needs top-of-block placement seven times, which is a real but
purchasable risk.

**Payoff.** Upward: at ×3 the vault values collateral worth $570k at $1.7M and lends the full $1M ceiling
against it; the attacker keeps roughly $430k over cost. Downward (a liquidator's version): halve the feed,
`barkFor` every position, and at the end of grace re-push and `relayAndBite` in one transaction. The
seizure formula pays `debt × 1.2 / price`, so at half price the liquidator takes about $2.40 of real
collateral per $1 of imdUSD burned, bounded by each position's collateral and by the open debt. Honest
actors have the grace window to buy a correct attestation, but once the fake value is fresh the deviation
bound limits each correction to 20%, the attacker can answer each one, and the Treasury never pays to
correct a feed that reads low (finding 2). At today's ceiling the upward case is marginal to positive and
the downward case is clearly positive once there is debt to liquidate; both scale linearly with any ceiling
raise, and `docs/PARAMETERS-2026-10-05.md` sized the ceiling against *liquidation* capacity, not against
this.

**Why the existing defences do not cover it.** The HIGH finding of 2026-10-03 was answered with question
binding, which closes "answer a different question"; this is "answer the right question over a window I
chose, about a pool I pushed". The F1 recency bound closes windows hours old; a 300-block window is recent.
`SKEW_BPS` compares two readings of the same pool, which the risks page already says catches "a bad or
manipulated reading of that pool, not a pool that is itself mispriced". The deviation cap is the one
defence that targets this, and it is off whenever it matters.

**Fixes, cheapest first.**

- In the recipe, derive the sample blocks from the signed `blockHash` of `toBlock` (the attestation
  already carries it), so the attacker cannot know which blocks will be sampled and must hold the price
  across the whole window. That turns seven one-block pushes into a 150-block hold against arbitrage,
  which is the cost model the median was meant to impose.
- Bound re-anchors after staleness: keep a wider cap against the last value when stale (say 50%), or
  require two attestations at least N blocks apart within the cap before price-dependent actions resume.
- Require `toBlock` within a few blocks of head rather than 300, which removes most of the window
  shopping (an attacker must then time the pushes to the request rather than fit the request to the
  pushes).
- Size `LINE` against manipulation cost at the measured pool depth, and re-measure before any raise.

### 2. [medium] The Treasury never pays to correct a feed that reads below the pool, so borrowers can be liquidated at an under-valuation

**Where.** `src/OracleAsker.sol:293-298` (`_drifted`), `src/DeploymentConfig.sol:237-246`
(`DRIFT_RISE_TRIGGER_OF_CAP_BPS = 0`), `docs/oracle-guards/ORACLE-GUARDS-2026-10-05.md`.

The asymmetric trigger pays for a fall (pool below feed) and never for a rise (pool above feed). The
rationale, "a rise only under-values collateral, which limits borrowing and endangers no one", considers
only the borrowing side. A feed below market also makes healthy positions read underwater and lets a
liquidator seize `debt × 1.2 / price` of collateral at the low price. Keepers are the parties best placed to
buy a correcting update and are paid not to. With NHI at or below 0.6 the grace is zero, so there is no
window for the borrower to act. The oracle-guards simulation measured only worst-case over-valuation and
cost, so this side was never modelled.

**Fix.** Pay for rises at the same 5% threshold, under the same daily budget (the simulation's objection
was that rises past the 20% cap were refused; a 5% trigger is inside the cap). Failing that, state on the
risks page that a borrower who sees the feed below market must call `askPaid` themselves.

### 3. [low] `Treasury.handOffLaunchFees` is an arbitrary-target external call from the reserve-holding contract

**Where.** `src/Treasury.sol:450-455`.

The operator names any `factory` and the Treasury calls it with `setRequester(uint64,address)`. The selector
is fixed and no value or approval travels with it, so the reach is bounded, but it is still the Treasury
calling an address of the operator's choosing. Pin the launch factory as a source constant like every
other authority, or at least require the target to have code.

### 4. [low] The runbook's economic constants still contradict source

**Where.** `docs/MAINNET-RUNBOOK.md:121-122` says `CUT_BPS 3333`, `DUTY_BPS 200`, `ETH_USD_MAX_AGE 1 day`;
`src/DeploymentConfig.sol:122/141/30` say 1,000, 444 and 2 hours. The governance panel raised this as G14
and the fix plan recorded it done; it was not. The docs site cites the runbook as a source
(`web/content/docs/reference/contracts-and-addresses.md:8`).

### 5. [low] Stability-fee NatSpec still sits on `redemptionDivisor()`, and `duty()` has none

**Where.** `src/CDPVault.sol:160-175`. The vault panel's V12 named this and F11 claimed it. The block
beginning "Annual stability fee on open debt" documents `redemptionDivisor()`.

### 6. [low] ParameterizedVault has 4,942 bytes of initcode headroom

**Where.** `forge build --sizes`: 44,210 of the 49,152 EIP-3860 limit. Any of the fixes above that touch
the vault, and any further audit fix, risks an undeployable vault. Measure after every change; move
anything optional (the `lockIMD` wrapper is the obvious candidate) behind a factory if it gets tight.

### 7. [low] `script/DeployProtocol.s.sol` still deploys feeds with a 5,000 bps deviation cap

**Where.** `script/DeployProtocol.s.sol:45` versus `script/DeployMainnet.s.sol:96` (2,000). Stale script;
anyone rehearsing with it gets different feed behaviour from mainnet.

### 8. [info] Fees accrue forever on drained positions and raise the Treasury's imdUSD floor

`_reduceDebt` and `_recordBadDebt` record `debtOf`, which keeps accruing on a drained position, so
`totalBadDebt` and with it the `BadDebtFirst` floor on `Treasury.withdraw` and `payStream` grow without
bound until someone calls `cover`. Covering the fee part burns and remints the same amount to the
Treasury, so it costs nothing; this is accounting growth, not a loss. Worth a line in the runbook's
operations section.

### 9. [info] Redemption is redeemer-targeted, not thinnest-first

`src/CDPVault.sol:728` requires only that the candidate's ratio is below `mat + gap`. Any holder of imdUSD
can force-deleverage any eligible position of their choosing (the fee stays in that position, so the
borrower is not harmed financially). This is a design choice, but the docs say otherwise (site finding 1).

### 10. [info] What was checked and found sound

Listed so the next reviewer can skip it.

- **The lag clamp cannot be gamed.** The hypothesis was that cancelling warm debt (wipe, bite or cash)
  clamps `laggedDebt`/`laggedSecured` to the live figures and so instantly warms a fresh position. Worked
  through both legs: `laggedSecured` only clamps when the live figure *falls*, which requires the fresh
  position's secured term to be smaller than what was removed, so the lagged numerator never exceeds its
  warm base; `laggedDebt` clamps only to a total that the cancellation has already reduced by the same
  amount. The net effect is rotation of equal size, never a lift. `_backingPerUnit` and `backedDebt` hold.
- Redemption at backing below par is pro-rata neutral by construction, including self-redemption.
- `cover` cannot spend Treasury imdUSD on a position that still holds reachable collateral; the dust path
  sweeps first and records.
- Fee index: `chi` is monotone, `_accrue` precedes every principal change, `Parameters._apply` drips before
  writing the rate.
- `bite`: seizure, bonus split, dust sweep and `relayAndBite`'s balance-delta forwarding all reconcile,
  including a marker that is the relay itself.
- Signature path: low-`s`, `v ∈ {27, 28}`, zero-address recovery excluded by the nonzero attester,
  domain bound to chain and feed, replay by `requestId`, `issuedAt` monotone.
- Governance: every bound is a constant, one slot, `_validate` at both ends, `cancel` the only instant
  action; `proposeWorkOracle` refused while the wage is nonzero at both ends and requires `predecessor`
  once anything was minted.
- Treasury exits: collateral and listed reserves never leave through `withdraw`; imdUSD only above
  `totalBadDebt`; `fundOracle` tops up to the budget and handles a paused share vault (`maxWithdraw` 0).
- `DeployMainnet`: the CREATE2 plan converges in dependency layers, `_refuseUnlessReady` catches every
  Sepolia constant, and `verify()` reads back every link in both directions.
- **StakedIMD on mainnet** (`0x9Efa…7247`, verified source from Sourcify): `owner()` is the zero address,
  so the `setPaused` and `rescueERC20` hatches in its source are permanently gone and `paused` is false
  forever. `totalAssets` is the IMD balance; a donation raises every holder's rate irreversibly, so there is
  no transient exchange-rate attack on `SharePriceFeed`. The one-block hold is on the withdraw path only
  and travels with transferred shares, so `lock`, `free`, `bite`, `cash` and the relay are unaffected and
  the `fundOracle` dust-griefing (D5) remains the only exposure.

## Findings — imdusd.com

Build, typecheck, `npm test` (16/16) and `npm run test:browser` (50/50, zero console errors) pass. All 74
link targets from the built public HTML return 200. No horizontal overflow at 320 or 375 px. HSTS,
nosniff, `X-Frame-Options: DENY`, Referrer-Policy and Permissions-Policy are served on every response and
match `dist-public/_headers`. The six terminal items from `QA-REVIEW-2026-10-05.md` were not re-verified:
the terminal is not deployed publicly.

### W1. [medium] Four factual errors in live docs

- `web/content/docs/reference/vault-functions.md:284`: `securedCollateral` is capped at **twice** the
  principal's worth (`SECURED_COLLATERAL_MULTIPLE = 2`, `src/CDPVault.sol:259,801`), not the principal.
- `web/content/docs/governance/parameters.md:43`: sIMD "is listed" with the collateral price feed. The
  register starts empty; listing is a governance proposal, as `contracts-and-addresses.md:57` says.
- `web/content/docs/reference/contracts-and-addresses.md:47`: the constructor's first parameter is `gem_`,
  and a zero `stablecoin_` makes the vault create its own imdUSD, which is what `DeployMainnet` does.
- `web/content/docs/overview/how-it-holds-a-dollar.md:33`: redemption does not land on "the thinnest
  positions first"; the redeemer names any eligible candidate (contract finding 9).

Incomplete but true: `vault-functions.md:38` omits the dust case where `bite` takes the whole remainder;
`how-it-holds-a-dollar.md:49` omits the relayer, agreement floor, replay and deviation checks;
`contracts-and-addresses.md:39` omits `withdrawNative`, `syncNative` and `handOffLaunchFees`.

### W2. [medium] The documented verification path is red

`web/README.md` tells a reviewer to run three things that fail on `main`:

- `node --test tests/theme.test.mjs`: "component paint has no literal colors" trips on `background: transparent`
  (`src/style.css:1344,1460,1521`) and the gradients at `:1583-1584,1694-1695`.
- `node --test tests/history.test.mjs`: `ERR_MODULE_NOT_FOUND …/names`. `src/history.ts:8` now imports
  `./names`; `tests/history.test.mjs:24` only shims `config` and `state`. Add `"names"`.
- `node scripts/check-package.mjs`: "Insufficient bundle budget". It bundles the whole repo
  (92 MiB, of which 36 MiB is the untracked `artifacts/`) against an 8 MiB limit.

`npm test` passes only because `package.json` excludes the two failing files.

### W3. [medium] No Content-Security-Policy header

`curl -sI https://imdusd.com/ | grep -i content-security` returns nothing. The only inline script is the
theme bootstrap in `web/index.html`; a hash-pinned `script-src 'self'` policy with `connect-src 'none'`
and `frame-ancestors 'none'` fits the site as built. Add it to `PUBLIC_HEADERS` in `web/vite.config.ts`.

### W4. [medium] Unknown paths return a bodyless 404

`web/wrangler.jsonc` sets `not_found_handling: "none"`, so `/no-such-page` is an empty white page with
no title and no nav. Ship a `404.html` in `dist-public` and set `not_found_handling: "404-page"`.

### W5–W11. [low]

- The pulsing "staging" chip (`src/style.css:2138-2149`) fades to 0.25 opacity, 1.4:1 contrast at 10 px
  text; axe flags it on every page. Pulse a dot or border, or floor the opacity near 0.75.
- Footer links render 17 px tall (`.site-footer a`, `src/style.css:2037`), under the 24 px target minimum.
- No `rel="canonical"`, no OpenGraph or Twitter tags, no `sitemap.xml`; `www.` and the apex both serve 200
  with identical bytes, so crawlers see duplicate hosts. 301 one to the other in `web/worker/index.js`.
- `dist-public/manifest.webmanifest` is still named "imdUSD Terminal" with `display: standalone`; only
  `start_url` and `description` are rewritten (`web/vite.config.ts:38-43`).
- Docs front matter cites stale line ranges (`vault-functions.md:8-9`, `parameters.md:8-12`,
  `how-it-holds-a-dollar.md:7`, which points at `lock` while describing `draw`).
- The runbook contradiction in contract finding 4 is reachable from the site's source citations.
- Terminal build only: the `h1` sits outside any landmark (axe `region`, moderate).

## What I read

In full: every file under `src/` and `src/interfaces/`; `script/DeployMainnet.s.sol`, `DeployPreflight.sol`,
`deploy/mainnet/plan.py`, `check-bodies.mjs`, the three body templates; `oracle/question-prefix.mjs`, the
four quote payloads and `attestation-e2c85027.json`; `test/LaggedBacking.t.sol`, `test/SwarmFeed.t.sol`
(stale re-anchor and relayer tests), the share-collateral fork tests and `MockShareVault`; the verified
StakedIMD source. Summarised rather than read line by line: the fourteen prior audit and review documents,
`test/README.md`, the web build, tests and content pages. Not reached: the Intake (unreleased upstream),
the swarm's `univ4-spot` recipe source (the sample-block formula is inferred from "evenly spaced"; if the
service already randomises sample blocks, finding 1 reduces to the stale re-anchor and the spot leg).
