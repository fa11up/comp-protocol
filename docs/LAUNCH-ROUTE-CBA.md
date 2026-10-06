# Deploying the protocol: swarm launch vs our deploy script (2026-10-05)

The protocol stack is eight contracts: SwarmRelay, WorkOracleFactory, PriceFeed, NhiFeed, SpotFeed,
OracleAsker, TreasuryFactory and ParameterizedVault (which creates imdUSD, Parameters, its Treasury, the
work oracle and both price adapters in its own constructor). Facts below are read from the plane at
`b5dd2eb` and the live `/requests/capabilities`, and from our fork rehearsal.

## Verdict

**Deploy with our script.** The swarm route is not just slower: as the plane stands today it cannot
deploy this stack at all (its pre-launch safety suite runs constructors on a bare chain, where ours
must fail). If on-chain provenance from the swarm is wanted, buy it after the fact: a 0.5 IMD
verification job that rebuilds our commit and checks it against the deployed bytecode.

## What each route costs

| | our script | swarm `evm_contracts` launch |
|---|---|---|
| Direct cost | ~26.2M gas: **~0.006 ETH** at today's 0.12 gwei base fee (+0.1 gwei tip); refuses above **0.05 ETH** | **0.5 IMD per launch** (~$6.70) x at least **5 launches** = 2.5 IMD (~$34); gas paid by the plane's launch wallet, each launch capped at 0.05 ETH |
| Launches / transactions | 8 transactions, one sitting, resumable | ≥5 launches, strictly sequential (see constraints) |
| Elapsed time | minutes | days: each launch is a paid swarm job (planning, build, review, admission); the swarm is saturated today, and 16 of the last 30 network workflows ended blocked |
| Our engineering | done: script, plan converger, read-back verification, fork rehearsal with the keeper | refactor or ~5 recompile-and-repin cycles; new manifests; re-review of whatever changes |
| Failure mode | a failed transaction is resumed; nothing is live until the vault exists, and the deployment can be abandoned before the first deposit | a launch that parks mid-sequence leaves half a stack on chain under addresses compiled into the next layer; a submitted launch cannot be cancelled by us |

## Hard constraints on the swarm route

1. **The safety suite fails our constructors (blocking).** `packages/floors/suites/evm_contracts/Contracts.protected.t.sol`
   deploys every contract on a plain `forge test` chain, no fork, and requires each constructor to
   succeed. The plane's own admission notes say the fork rehearsal is "not built". Our OracleAsker
   refuses an Intake and a pay token with no code, and the vault needs StakedIMD, the factories and the
   Chainlink feed to exist — so admission parks the launch with `protected_invariants`, exactly how
   round 4 parked. Removing those checks would turn "fails loudly on a wrong address" back into "deploys
   a dead stack silently", the launch-519 failure.
2. **Per-transaction gas.** A launch is one transaction; EIP-7825 caps that at 16,777,216 gas. The stack
   is 26.2M (the vault alone 12.7M).
3. **Four contracts per request.** The launch manifest takes eight, but the paid request's
   `draft.contracts` takes four (`job-request.ts`), and the request is what approves the manifest.
4. **Addresses the code depends on are unknown until admission.** A launch deploys each contract at
   `CREATE2(factory, contractSalt(launchNumber, i), initcode)`, and the plane assigns `launchNumber`.
   Our feeds compile in the relay's address, the Treasury compiles in the asker's, and the vault
   compiles in both factories'. So the dependency layers — {relay, work factory} → {three feeds} →
   {asker} → {treasury factory} → {vault} — become five launches, each needing the previous launch's
   addresses compiled in, a new commit, and a re-pinned request.
5. **Cross-chain addresses.** Our script uses the canonical CREATE2 deployer with fixed salts, so the
   same build lands at the same addresses on Base and Robinhood Chain later. Launch addresses depend on
   each chain's factory and launch number, so that property is lost.
6. **Constructors run as the factory.** Not a problem for us (no authority comes from `msg.sender`;
   the work-oracle creator check accepts a contract), and none of our runtime code uses the opcodes the
   suite forbids (`DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`) — scanned, all eight plus the five the
   vault creates are clean. Listed so it is not re-checked.

## What the swarm route would buy

| benefit | worth | can we get it another way? |
|---|---|---|
| A `LaunchRegistry` record on chain: source commit, manifest hash, attestation hash | provenance: "the swarm built and deployed exactly this" | **yes**: a 0.5 IMD verification job after our deploy, whose public work record states the deployed bytecode matches commit X |
| Listed on explorer.imd.fun as a launch | visibility in the swarm's own UI | partly: announce through the dev; the work record and repo are public |
| Plane pays gas | ~0.006 ETH saved | no, but it is ~$16 |
| Agents review/test the code during the job | an extra review pass | we already have three audit panels, an adversarial review, a gas review, and the scoped pre-deploy review still to come |
| Token-launch rewards (2% / 8% to workers) | none: `evm_contracts` launches have no token | n/a (relevant to INFER, not here) |

## What our script buys

- Addresses known before anything is spent: docs, keeper, terminal and the Intake bodies are prepared in
  advance, and the plan converges in four passes from the current config.
- One broadcast, minutes, rehearsed end to end on a mainnet fork including the keeper (bark, bite,
  Treasury-paid ask), with an on-chain read-back of every link before the deployment record is written.
- The dev's 0.05 ETH ceiling and the EIP-7825 cap enforced in code.
- The same addresses on later chains.
- Full control of timing: we deploy the moment the Intake is ready and gas is cheap.

## Recommendation

1. Deploy with `script/DeployMainnet.s.sol` (runbook §6), after the scoped review.
2. Same day, buy a `job.open` verification job (0.5 IMD): rebuild the deploy commit, compare every
   deployed runtime against it, and re-run the read-back checks against chain state. Its public work
   record is the third-party provenance a launch record would have given, at a fraction of the cost and
   with none of the constraints.
3. If the plane later builds its fork rehearsal (L3b) and lifts the request cap, constraints 1 and 3 fall
   away; 2 and 4 remain structural for a stack this size.
