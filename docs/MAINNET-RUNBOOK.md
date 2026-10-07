# Mainnet runbook

*Drafted 2026-10-04, while the tenth testnet increment was still executing. Nothing here has been
run on mainnet.*

This is the operational document for moving this protocol from Sepolia to Ethereum mainnet: what has
to be true before the first transaction, which keys exist and what each can do, the deployment
sequence, and what to read back off chain after each step. It exists partly to be **audited** — the
configuration layer has never had independent review, and an audit needs files to review.

**What this is not.** It is not a decision record (`docs/COMPUTE-BACKING-DESIGN.md` is), not a
contract reference (`README.md` and `docs/ABI.md` are), and not a schedule. It says how, not when.

---

## 0. The name changes first

Mainnet launches as **INFER** — *Inference-Backed Endogenous Financial Reserve* — and the stablecoin
is **imdUSD**. "COMP" was a testnet placeholder and must not reach mainnet: COMP is Compound's
governance token, listed on every major venue, so shipping a second one guarantees mislabelling by
aggregators, refused listings, and a domain and ENS name that belong to someone else.

The on-chain cost of the rename is **one line** — `ERC20("imdUSD", "imdUSD")` in
`src/ImdUSD.sol` — because the Solidity identifier never appears in a launch manifest (the vault
creates the token in its own constructor). Everything else is identifiers and prose.

Nothing else in this runbook depends on the name, but the name must be settled before the deploy,
because the token's `name()` and `symbol()` are immutable once constructed.

---

## 1. Prerequisites, in order

Each step assumes the previous one is merged and green. Steps 2 and 3 are independent of each other.

| # | step | why it blocks mainnet |
|---|---|---|
| 1 | Rename COMP → imdUSD | the token's identity is immutable once deployed |
| 2 | sIMD as the collateral token (wrap on deposit) — **built** | decides what collateral *is*. Deploy the vault with `StakedIMD` `0x9Efa934D9fAd4AE28c998a40195646b965a97247` as its collateral token: it then prices collateral through a `SharePriceFeed` it creates, and `lockIMD` wraps plain IMD on deposit. Fork-tested against the live vault (`test/ShareCollateralFork.t.sol`). |
| 2b | Oracle paid from the Treasury (`OracleAsker` + `Treasury.fundOracle`) — **built, waits on upstream** | without it every price update is bought by hand in a browser. `OracleAsker` buys through the IdentityMD Intake only when the chain shows a need (a feed 75% of the way to stale, or IMD's v4 pool armed-and-still >half the deviation cap away) and delivers through SwarmRelay inside the Intake's 200k-gas callback stipend (measured 76,807). `fundOracle` streams at most `Parameters.oracleBudget` IMD per UTC day to it — keyless, unwrapping sIMD on the way. **Blocked on Intake PR #66 merging and deploying:** `INTAKE` and `ORACLE_ASKER` are placeholders (`0x…F06`/`0x…f07`) and the asker's constructor refuses an `INTAKE` with no code. |
| 3 | **Delete the reporter fallback** | a single key can otherwise re-anchor the price — see §4 |
| 4 | CREATE2 deployment script with address assertions — **built** (`script/DeployMainnet.s.sol`, `deploy/mainnet/`), rehearsed on a fork | removes the silent-misconfiguration failure mode — see §6 |
| 5 | Independent audit of this configuration — **done** (three panels + adversarial + gas, `docs/AUDIT-*-2026-10-05.md`, fixes through `9dd2149`). **Still owed, by decision (2026-10-05): one scoped `adversarial-review` of everything after `03e8d0c`, sent right before the deploy commit is frozen** | the phase-2 fixes (notably the always-lagged redemption cap) have had no outside review |
| 6 | Keeper / watcher daemon — **mainnet-ready** (`fa11up/imd-keeper@c9b8eaa`), rehearsed bark → bite → Treasury-paid ask on a fork | the protocol is not operable without it — see §7 |

---

## 2. Keys

Only **two** keys need provisioning, plus one throwaway. Contracts replaced the rest, which is the
point: an authority held by a contract with no owner cannot be lost, stolen or mis-set.

| name | what it can do | where it lives |
|---|---|---|
| `APPROVED_OPERATOR` | propose parameter changes (48 h timelock), list and delist reserve assets, withdraw from the Treasury anything that is not the collateral or a listed reserve asset, and imdUSD only down to outstanding bad debt (for governor-managed LP) | **cold / multisig. Never on a server.** |
| keeper daemon | relay attestations, bite, mark, buy oracle requests | **hot, on its own machine.** Never the swarm worker box: tasks from strangers execute as that user. |
| deployer | one-time broadcast; needs ETH only | throwaway, discard after §6 |

Held by contracts, not keys:

| constant | points at | consequence |
|---|---|---|
| `feeRecipient()` | the **Treasury the vault creates** in its constructor | protocol revenue cannot land in a wallet. `ParameterizedVault` overrides `feeRecipient()`, so the `FEE_RECIPIENT` constant is read only by the plain `CDPVault`, which mainnet does not deploy. **No standalone Treasury is needed** (docs job 2f5a387d found the runbook deploying one that would receive nothing). |
| `ATTESTATION_RELAYER` | the **SwarmRelay** contract | relaying is permissionless; no relayer key to lose |
| `WORK_ORACLE_FACTORY` | the **WorkOracleFactory** contract | the work oracle's creation code lives outside the vault |

Not ours:

| constant | whose | documented assumption |
|---|---|---|
| `ORACLE_ATTESTER` | the IdentityMD operator's signer | **a single key signs every attestation.** Question binding means a signature must answer *our* pinned question and clear the panel floors, which bounds it considerably — but it is one signer on the price path, and that is a trust assumption of this protocol, not a bug in it. |

### What the keeper needs funded

Three separate balances, and they are not interchangeable:

* **ETH** for gas.
* **imdUSD inventory** — `bite` burns the *caller's* stablecoin. A keeper with no imdUSD cannot
  bite anything. This is working capital, not an expense.
* **IMD** for oracle requests, 0.5 IMD each.

Oracle requests are no longer the keeper's to fund: `Treasury.fundOracle()` streams up to
`Parameters.oracleBudget` IMD a day to `OracleAsker`, which pays the Intake (prereq 2b). That is the
budgeted, keyless route the earlier "spender role" note asked for — a destination fixed in source and
a governed daily cap, not an authority. The keeper still needs ETH for gas and imdUSD inventory to
bite. `Treasury.withdraw` stays `APPROVED_OPERATOR`-only; do not put that key on the daemon.

---

## 3. Constants, classified

Every value in `src/DeploymentConfig.sol`, and what has to happen to it. **A constant that is wrong
is immutable and silent** — this is exactly how launch 519 shipped two dead feeds.

### Must change for mainnet

| constant | now (Sepolia) | mainnet |
|---|---|---|
| `CHAINLINK_ETH_USD` | `0x694AA176…` (Sepolia) | **`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`** |
| `APPROVED_OPERATOR` | miyagod.eth EOA | the cold governance address |
| `FEE_RECIPIENT` | miyagod.eth EOA | unused by `ParameterizedVault`; set it to the cold governance address so nothing names a hot wallet |
| `ATTESTATION_RELAYER` | the Sepolia SwarmRelay | the mainnet SwarmRelay (CREATE2, §6) |
| `WORK_ORACLE_FACTORY` | `0x…0f05` placeholder, no code | the mainnet factory (CREATE2, §6) |

### Must be deleted

| constant | why |
|---|---|
| `FEED_REPORTER_0/1/2`, `FEED_QUORUM` | §4. Removing the fallback removes these and four constructor arguments from every feed. |

### Verify, do not assume

| constant | check |
|---|---|
| `ORACLE_ATTESTER` | the live service's signer. Confirm against a real attestation before deploying; `test/InHouse.t.sol` pins the typehash and domain against the live service and must pass on a **mainnet** fork. |
| `ATTESTATION_CHAIN_ID` | already `1`. The data chain was always mainnet, even while the consumer was Sepolia — do not "fix" it. |
| `ATTESTATION_ANSWER_TYPE` | `3` = uint256. Launch 519 shipped `1` (address) and the feeds were permanently unusable. |

### Economic, carry over unchanged unless deliberately revised

Values as in `src/DeploymentConfig.sol` and `script/DeployMainnet.s.sol` on 2026-10-06 (the source is
authoritative; this list is checked against it, not the other way round):
`SKEW_BPS` 500 · `CHIP_BPS` 1000 · `CUT_BPS` 1000 · `DUTY_BPS` 444 · `LINE` $1M · `REDEMPTION_DIVISOR` 2 ·
`ETH_USD_MAX_AGE` 2 hours · `PRICE_MAX_AGE` / `SPOT_MAX_AGE` 1 hour · `NHI_MAX_AGE` 1 day ·
feed `maxDeviationBps` 2000 (stale: 2x, `SwarmFeed.STALE_DEVIATION_MULTIPLE`) · `ORACLE_BUDGET_PER_DAY` 15 IMD.

### The compute channel does not ship in this deployment

`EARN_MAT_BPS`, `WAGE_WAD`, `WORK_ORACLE_MAX_AGE` and the work oracle's own constants are
**out of scope for a mainnet launch**, and the reason is not readiness. `SwarmWorkOracle` as built
credits **one** agent named in source, which is a private faucet wearing a protocol's clothes, not a
compute-backed currency. A protocol that mints for its author's own seat cannot be launched as one
that mints for work.

Launch with the work ceiling in place and the channel unused — a vault whose `earnLine()` binds and
whose work oracle grants nothing is sound and honest. The channel opens when it can serve agents in
general, which needs the per-day tally root rather than a pinned claimant (§5b of
`docs/COMPUTE-BACKING-DESIGN.md`). Until then nothing about anyone's agent identity belongs in this
deployment's configuration.

All but the last two are governable through `Parameters` under a 48-hour delay, so a wrong value here
is a correctable mistake rather than a permanent one. That asymmetry is the design: economics are
governable, authority never is.

---

## 4. Why the reporter fallback must not ship

`SwarmFeed.report()` lets `FEED_REPORTER_0` set a feed's value directly. The deviation bound caps
the move at `maxDeviationBps` **while the current value is fresh** — but once the value ages past
`maxAge`, the bound lifts entirely and the next accepted value re-anchors the band to anything. On
mainnet that is one key able to set the price of all collateral after a day of staleness, which is
custody of every position.

It cannot simply be pointed somewhere harmless and left in: the honest fix is deletion. The
machinery is ~60 of `SwarmFeed`'s 352 lines — `report`, the reporter constants, `quorum`, `_median`,
`_nextRound`, `round`, `reportCount`, `lastReportedRound`, `_reports`, `_roundStartedAt` — and
removing it drops four arguments from every feed constructor. `_accept` and `_checkValue` stay,
because the attestation path shares them.

**Two consequences to plan for.**

* `submitAttestation` calls `_nextRound()` to discard an unfinished fallback round. That call goes too.
* **A freshly deployed feed is inert until its first attestation.** Today a reporter seeds it. On
  mainnet the first operational act is buying three attestations (1.5 IMD) — see §7 — and until they
  land the vault refuses everything. That is the safe direction, and it is a sequence item, not a bug.
* `script/DeployGoverned.s.sol:44` currently requires the broadcaster to **be** the reporter
  (`require(operator == FEED_REPORTER_0, …)`). That is a testnet convenience and must be removed:
  on mainnet the broadcaster is a throwaway deployer and is neither the operator nor a reporter.

**The trade, stated plainly.** The reporter is a liveness fallback *and* a trust hole. Testnet wants
the fallback. Mainnet wants it gone and accepts that a stalled attestation pipeline halts the vault —
which is already how a stale feed behaves, so the failure mode is one we have tested.

---

## 5. Pre-flight, before any mainnet transaction

Run every one of these. Each has failed for real at least once in this project's history.

```bash
# 1. the suite, under the runner test/README.md documents
forge test                                   # expect 362+ pass, 0 fail

# 2. the fork suite against LIVE mainnet state, not Sepolia
forge test --match-path test/InHouse.t.sol         --fork-url $MAINNET_RPC_URL
forge test --match-path test/SharePriceFeedFork.t.sol --fork-url $MAINNET_RPC_URL

# 3. both deploy scripts dry-run against mainnet, with the real operator
OPERATOR=<cold> forge script script/DeployGoverned.s.sol --rpc-url $MAINNET_RPC_URL

# 4. every question prefix verified against a LIVE attestation, per feed
node oracle/question-prefix.mjs oracle/<payload>.json --verify <requestId>   # must print MATCH

# 5. the oracle payloads, against the feed they will actually target
node oracle/preflight-oracle.mjs <payload>.json <feedAddress> --rpc $MAINNET_RPC_URL
```

**Step 4 has never been done.** No prefix has been verified against a live attestation bought with
the frozen payloads. It costs 0.5 IMD per feed to find out, and the alternative is discovering a
one-character mismatch after deploying an immutable feed that refuses every attestation.

---

## 6. Deployment: one broadcast, with assertions

The prereq contracts (`SwarmRelay`, `WorkOracleFactory`, `TreasuryFactory`, and `OracleAsker` — see step 4) are read by other contracts as **source constants**, so their addresses
must be in the bytecode before the feeds compile. That looks like it forces two broadcasts. It does
not, because CREATE2 makes an address a pure function of initcode and salt:

```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]
```

None of SwarmRelay and the two factories references a feed, so there is no cycle — their addresses are computable with no
prior transaction. The canonical deterministic deployer
**`0x4e59b44847b379578588920cA78FbF26c0B4956C`** is live on mainnet and Sepolia with identical
bytecode (verified 2026-10-04), so the same salts give the same addresses on both, and later on Base
and Robinhood Chain.

### As built (2026-10-05): `script/DeployMainnet.s.sol`

```bash
node deploy/mainnet/check-bodies.mjs                     # the 3 Intake bodies: prefixes match, relative windows, no guards
git switch -c release/mainnet                            # plan.py rewrites constants the Sepolia fork tests use
python3 deploy/mainnet/plan.py --write --operator <cold governance> --intake <the swarm's Intake>
#   sets APPROVED_OPERATOR, FEE_RECIPIENT, INTAKE, then converges ATTESTATION_RELAYER, WORK_ORACLE_FACTORY,
#   ORACLE_ASKER, TREASURY_FACTORY and CHAINLINK_ETH_USD on the CREATE2 plan (4 passes from the Sepolia config)
forge test && <suites> ; git commit                      # THIS commit is what the scoped review and the broadcast use
KEEPER_DIR=../imd-keeper deploy/mainnet/rehearse-fork.sh # full rehearsal on an anvil fork (does not touch the tree)
FOUNDRY_PROFILE=deploy OPERATOR=<cold governance> forge script script/DeployMainnet.s.sol --rpc-url $MAINNET_RPC_URL \
    --broadcast --slow --account <throwaway deployer>
```

`run()` refuses unless: chain id 1; Chainlink is mainnet's and fresh; every planned address equals its
source constant; `INTAKE` has code; `OPERATOR` equals `APPROVED_OPERATOR`; the broadcaster is NOT the
operator; StakedIMD wraps IMD; the wage and the stream ship off. It is resumable (an address that already
has code is skipped) and it reads the whole stack back off chain before writing
`deploy/mainnet/out/deployment.json` + `bodies/`, which is what the keeper runs from.

Choices fixed in the script, part of the deploy commit: salts `infer-protocol/mainnet/v1/<Contract>`; feed
`maxDeviationBps` **2000** (the asker asks on drift at 10%); the asker treats price and spot as
pool-tracked and keeps only NHI alive on the Treasury.

Rehearsed on a mainnet fork: 8 transactions, **26.2M gas** in total, the largest the vault at **12.7M**
(block limit 60M) — about 0.026 ETH at 1 gwei.

FOUND WHILE BUILDING IT: `SwarmWorkOracle`'s constructor compared its creator to `WORK_ORACLE_FACTORY`, so
the factory's initcode contained the factory's own address and no CREATE2 address could ever satisfy it.
It now accepts any contract creator; `CDPVault._validateOracle` is what binds the oracle to the vault.

### Why the swarm does not deploy this (checked against plane `b5dd2eb`, 2026-10-05)

Mainnet launches are open (chain 1, all four kinds), but a swarm launch cannot run this script. The
deployer service only calls `ProjectFactory.launchContracts`: up to 8 contracts, **one transaction**,
each at `CREATE2(factory, contractSalt(launchNumber, i), initcode)`, constructors run as the factory.
Three things rule it out for this stack:

1. **Gas.** The stack is 26.2M gas; EIP-7825 caps a transaction at 16,777,216 (the plane's own
   `MAX_TRANSACTION_GAS`). It would take three separate launches.
2. **Addresses.** Four addresses are compile-time constants read by immutable code. A launch's
   addresses depend on a launch number the plane assigns at admission, so each launch would need the
   previous one's numbers compiled in first: three paid, sequential swarm jobs with a recompile and a
   re-pinned commit between each — or rewriting those constants as constructor arguments, which is the
   manifest-supplied-authority shape that bricked launch 519.
3. **Nothing gained on cost.** Our own broadcast is ~0.006 ETH at today's 0.12 gwei.

The dev's ceiling is honoured here instead: `run()` refuses unless (base fee + 0.1 gwei) x 28M gas
≤ **0.05 ETH** (i.e. base fee ≤ ~1.7 gwei), and checks each deployment stays under the EIP-7825 cap
(largest, the vault, 12.7M). Broadcast with `--priority-gas-price` ≤ 0.1 gwei.

### The sequence

1. **Compute** the CREATE2 addresses of `SwarmRelay`, `WorkOracleFactory` and `TreasuryFactory` from their
   initcode and chosen salts. No transaction.
2. **Write** them into `src/DeploymentConfig.sol`, along with every value in §3. Commit — the commit
   hash is what the configuration audit reviews.
3. **Compile.** The feeds now embed the right addresses.
4. **Dry-run.** The script recomputes each CREATE2 address from the compiled initcode and
   **asserts it equals the source constant.** A mistyped address fails here, before any gas is spent.
   This assertion is the whole reason to prefer CREATE2 over two broadcasts.
   **`ORACLE_ASKER` is a fourth computed address, and it comes AFTER the feeds:** its constructor
   takes the feed addresses and their body hashes, so its initcode (and CREATE2 address) depends on
   them, while the Treasury the vault creates reads it as a source constant. Feeds do not reference
   it, so there is no cycle: compute the feeds' addresses, then the asker's, then write the constant.
   Every body must use a RELATIVE window (`"window":{"hours":N}`): a literal block window can be answered
   only once, then every repeat is refused as not advancing. Its body hashes are `keccak256` of the frozen oracle.request bodies — the same bytes the feeds'
   pinned questions were generated from.
5. **Broadcast once**: the prereqs at their computed addresses, then the three feeds, then the
   vault — which creates imdUSD, `Parameters`, the Treasury's sibling and `UsdPriceFeed` in its own
   constructor, so the stack comes up linked with no follow-up transaction.
6. **Read it back off chain.** Not the script's own logs — the chain:
   * each feed's `attester`, `relayer`, `attestationChainId`, `attestationAnswerType`, `maxAge`,
     `maxDeviationBps`
   * each feed's `expectedQuestionHash(from, to)` against the JavaScript hash for the same window
   * the vault's `gem`, `stablecoin`, `oracle`, `priceFeed`, `nhiFeed`, `spotFeed`,
     `parameters`, `treasury`, `usdPriceFeed`, `feeRecipient`
   * `treasury.vault() == vault` and `parameters.vault() == vault`
   * `vault.earnLine() == 0` — correct on an empty stack, and proof the ceiling is live

### Rollback position

| after step | what exists | how to abandon |
|---|---|---|
| 1–4 | nothing on chain | delete the branch |
| 5, prereqs deployed | ownerless contracts holding nothing | **abandon them.** They cost gas and hold no funds or authority. Pick new salts and start again — do not try to reuse them. |
| 5, feeds deployed | immutable feeds, unseeded | abandon. An unseeded feed is inert and holds nothing. |
| 5, vault deployed | the whole stack, no positions | abandon **only before anyone deposits.** After the first deposit there is no rollback, only migration. |
| 7, seeded | a live protocol | no rollback. |

The practical implication: **the window to abandon closes at the first user deposit, not at the
deploy.** Deploy, verify, and only then announce.

---

## 7. First operational acts, in order

1. **Buy one attestation per feed** and relay it. Until each feed holds a value it is stale and the
   vault refuses every action. Three requests, 1.5 IMD. Order matters: walk the feeds to the live
   market *before* pinning any guards — a request bought with guards around a stale level was refused
   by a panel when IMD moved 44.6% in a day.
2. **Verify on chain** that each feed's value is the attested figure and not a reporter value, that
   `usedRequests[requestId]` is true, and that divergence between primary and spot is inside
   `SKEW_BPS`.
3. **List the reserve assets** through `Parameters.proposeReserveAsset` — each needs a price source
   and a haircut, and each waits 48 hours. Until the register is non-empty, `reserveValueUsd()` is
   zero and so is the first term of `earnLine`.
4. **Start the keeper** before announcing. An unattended protocol with live positions and no
   liquidator accumulates bad debt.
5. **Only then** open deposits.

---

## 7b. Minting from work: off at launch, switchable later — with one deploy-time requirement

Minting from work ships OFF (`WAGE_WAD = 0`; `SwarmWorkOracle.claim` refuses while the wage is zero, so
no agent's tasks are spent for nothing). Turning it on later is a governance action, not a redeploy:
`Parameters.proposeWage(wad)` (at most one imdUSD per task), visible for 48 hours, then anyone applies it.
`earnMat` and the reserve listings (also governed) set how much it can ever mint.

**Two things governance cannot do, so they are decided now:**

1. **The vault must be deployed with the real work oracle.** Pass `WORK_ORACLE_SENTINEL` as the vault's
   `oracle_` so it creates a `SwarmWorkOracle` through `WORK_ORACLE_FACTORY`. The oracle is immutable on
   the vault. `DeployGoverned`/`DeployProtocol` pass zero, which builds the TEST FAUCET (`MockWorkOracle`);
   the mainnet CREATE2 script must not.
2. ~~The deferred audit finding needs code.~~ **DONE.** D1's lagged capital is built (`laggedNow`,
   `BACKING_WARMUP`): the redemption cap reads it at every wage, `backedDebt` once the wage is nonzero.
   Nothing about minting from work needs a new vault.

## 8. Open decisions this runbook does not make

* ~~Whether the Treasury's reserve holds IMD or sIMD.~~ **DECIDED: sIMD only.** It falls out of the
  collateral choice rather than needing a policy — if collateral is sIMD then the protocol's bonus
  share arrives as sIMD, and stability fees arrive as imdUSD which the register refuses as a reserve
  asset on principle. So the reserve is sIMD by construction. One registered asset, priced by
  `SharePriceFeed`, and `reserveValueUsd()` sums over a single entry.
  **It is not listed automatically**: after deploy, propose `proposeReserveAsset(sIMD,
  vault.collateralPriceFeed(), haircut)` and apply it 48h later. Until then the reserve backs nothing in
  `earnLine` (redemption is unaffected — it prices the collateral it pays out itself). The Treasury
  values the vault's own collateral per 1e18 raw units, like the vault, so listing it through
  `collateralPriceFeed` is correct; before that fix it counted for a millionth of its value.
* ~~Redemption asset ordering.~~ **Obsolete.** With one reserve asset there is no order to establish,
  and the `Treasury._remove` swap-and-pop hazard — a delisting silently reordering the register — stops
  mattering. A redeemer receives sIMD from the reserve and sIMD from positions: the same asset either
  way, so the route is invisible to them.
* **Chains after mainnet.** `docs/DEPLOYMENT-PLAN.md` covers Base and Robinhood Chain. CREATE2 with
  fixed salts gives identical addresses, which is worth preserving deliberately rather than by luck.
* **Multi-collateral beyond sIMD.** Adding an uncorrelated asset (ETH, USDC) needs per-asset risk
  parameters and a restated solvency bound. sIMD does not, because it is the same risk asset in a
  wrapper. Do not let the second be used as precedent for the first.
* **Redemption channel B is now unnecessary, not merely deferred.** Its whole purpose is to price a
  redeemer's CHOICE among heterogeneous reserve assets by how far each sits below a target basket
  weight. With a single-asset reserve there is no choice to price, so the mechanism and the undecided
  basket weights both go away. It returns only if the reserve ever diversifies.
