# Compute backing and redemption — initial design

Status: design agreed 2026-10-03, nothing built. This is the reference a build request points at.

## 0. What we measured first

The protocol's thesis is that COMP is backed by verified compute. Before designing the mechanism we
measured whether the input exists. It mostly does not, and that shaped every decision below.

| measurement | value | source |
|---|---|---|
| ERC-8004 `NewFeedback` events | 2,000 over blocks 26052429–26082616 | Blockscout, mainnet registry `0x8004baa1…` |
| that window | 2026-09-25 05:38 → 2026-09-29 10:46 (4.21 days) | block timestamps |
| rate | ~475/day | derived |
| distinct agents with any feedback | 218 | derived |
| network accepted work | 7,708/day | `GET /swarm` → `health.acceptedLastDay` |
| **share of accepted work recorded on chain** | **~6%** | 475 / 7,708 |
| most recent feedback | 2026-09-29 | none since, 4 days silent |
| **our seat (agent 51450, 1,211 accepted)** | **0 events, ever** | derived |

Two consequences:

1. **Verification is the easy part; the signal is the hard part.** `getSummary(agentId)` and
   `isController(agentId, claimant)` are same-chain view calls on mainnet — a real work oracle needs
   no oracle at all. But what they measure excludes oracle-assess, which is ~92% of network volume
   and effectively all of ours, because `docs/work-registry.md` says those reviews were 99% of the
   mainnet writer's gas and were dropped. Keyed to ERC-8004 alone, this channel mints us zero
   forever and minted the whole network zero for four days.
2. **The whitepaper's §5.3 fee flow does not exist yet.** Layer 1 says the minting rate is
   "calibrated to task fee revenue", and §5.3 routes 15% of an external task payment to a protocol
   reserve. That reserve is the backing. Swarm oracle traffic is the developer's unpaid calibration
   traffic, so measured revenue is ~0. Issuing mint rights per accepted task today would back COMP
   with nothing.

Also recorded because it invalidated an earlier reading: **publicnode silently returns an empty
array for historical `eth_getLogs` ranges** instead of erroring. A control query over the same range
returned 89,036 USDC transfers where the registry returned zero. Use Blockscout for any historical
log work, and never trust an empty log result without a control over the identical range.

Incidentally this independently validated the set-agreement probe we paid for: 218 distinct agents
measured here against the panel's 210, and the panel's reported event signature matches Blockscout's
decoding exactly. That probe was right.

## 1. Decisions taken

| # | decision | choice |
|---|---|---|
| 1 | what work entitles you to | **revenue-capped mint** — work sets your *share*, backing sets the *size* |
| 2 | what counts as work | **attested tally now, upstream leaf in parallel** |
| 3 | bound on `totalWorkMinted` | **aggregate: reserve value + a ratio of collateral-backed debt** |
| 4 | redemption | **in scope now, multi-asset, at a dollar of value minus a fee** |

## 2. The reserve is the Treasury

`src/Treasury.sol` already exists, already records what arrives (`sync` → `totalReceived`), and
already has a withdrawal pinned to `APPROVED_OPERATOR` with the destination as an argument. It
becomes the reserve. What it receives today: the protocol's share of liquidation bonuses, in IMD
collateral, and stability fees, in COMP.

**The Treasury's COMP balance is not reserve.** Redeeming COMP for COMP is a no-op, so only
non-COMP assets back anything. Today that means IMD only, and only as liquidations happen.

Reserve value must be computed, not assumed:

```
reserveValueUsd = Σ_assets  haircutBps[a]/10000 × balance[a] × priceUsd[a]
```

Each asset needs a USD price source and a haircut. IMD's price is the existing `PriceFeed`
(IMD/ETH) multiplied by Chainlink ETH/USD — on Sepolia `0x694AA1769357215DE4FAC081bf1f309aDC325306`,
verified live at $2,675.82, 8 decimals. The haircut is what stops a volatile reserve asset from
authorizing supply it cannot support; a stablecoin's haircut is near zero, IMD's is not.

**This makes reserve value oracle-dependent and reflexive.** If IMD falls, reserve value falls, and
COMP already minted against it becomes under-backed. The haircut is the only defence, so it belongs
in code with a hard floor, not in governance alone.

## 3. The work ceiling

```
workCeiling() = reserveValueUsd + totalDebt × workRatioBps / 10000

mintFromWork: require(totalWorkMinted + amount <= workCeiling())
```

An aggregate rather than a minimum, because the two terms are backed by genuinely different things:
the reserve term is backed 1:1 by assets the protocol owns, and the ratio term is backed by the
surplus collateral every borrower posts above their debt.

Let `D` = CDP principal, `W` = work-minted, `R` = reserve value, `r` = workRatioBps/10000, and take
the worst case where every position sits exactly at `minCR`:

```
supply = D + W,  W = R + rD,  collateral C = minCR × D

B = (C + R)/(D + W) = (minCR·D + R)/(D + R + rD)

numerator − denominator = (minCR − 1 − r)·D
```

So **B > 1 for all R if and only if r < minCR − 1.** `minCR` is 150 at NHI 0.9 and rises to 200 as
NHI falls, so the binding case is `r < 0.50`.

| r | R = 0 | R = 0.5D | R = 2D | R → ∞ |
|---|---|---|---|---|
| 0.25 | 1.200 | 1.143 | 1.077 | → 1 from above |
| 0.50 | 1.000 | 1.000 | 1.000 | 1.000 |

Pin `workRatioBps = 2500` and hard-bound it at 2500 in the parameters contract: half the breaking
point at the loosest NHI, 120% worst-case backing with an empty reserve. 5000 is the cliff, so it
must not be reachable by governance.

`workCeiling` and `workRatioBps` are new governed parameters, under the existing 48-hour delay.

## 4. The work signal

Two tracks, because one works today and the other fixes the cause.

**Now — attested tally.** An `oracle.request` whose answer is a per-agent accepted-work tally,
relayed into a `SwarmWorkOracle` through the existing `SwarmRelay` and verified by the same
attestation v2 path already proven end to end (request `50d9b023`, relayed in tx `0x15854076…`).
The set-agreement probe established the precondition: 20 of 20 panel members independently derived
the same 14,167-log set and the same 210-agent cardinality, so panels do agree on set-derived
integers with zero tolerance. Cost is 0.5 IMD per update.

**In parallel — the upstream leaf.** `whitepaper/oracle-sim/PROPOSAL-ORACLE-WORK-LEAF.md`: carry a
second Merkle root in the daily oracle batch receipt the plane already writes, over
`["uint256","uint32"] = (agentId, acceptedThatDay)`, schema `identitymd-oracle-batch-v2`. Zero
additional per-review gas — the receipt is already written, this adds one 32-byte root — which
directly answers the stated reason oracle reviews were excluded. If it lands, the work signal
becomes free, trustless and network-wide, and the attested tally becomes a fallback.

`workShare(agent)` then derives rights: an agent's share of the tally times the ceiling headroom.
`isController(agentId, claimant)` is what binds a tally entry to a wallet that may mint.

## 5. Redemption

The question that has to be answered honestly: without redemption, "1 COMP = 1 USD" is only a unit
of account plus a hope that arbitrage closes the gap. There is no floor. So redemption is what makes
the peg real, and there are two different channels because there are two different pools of assets.

**Channel A — IMD, redeemed against CDPs (Liquity-shaped).** `redeem(comp)` burns COMP, repays the
debt of the *lowest-collateral-ratio* position, and pays the redeemer that position's IMD at the feed
price minus a fee. This is the hard floor: it is backed by every borrower's collateral, not by the
reserve, so its capacity is total debt rather than a treasury balance. It also improves system health
by acting on the riskiest position first.

Its cost is real and must be stated: **a redeemed borrower has their position closed involuntarily**,
at face value, without being liquidated or doing anything wrong. That is the price Liquity pays for a
hard peg, and it is a borrower-facing tradeoff rather than a technical detail.

**Channel B — USDC / USDG / ETH, redeemed against the reserve (PSM-shaped).** Capacity is whatever
the Treasury holds of that asset. Free choice of asset against a heterogeneous reserve is adverse
selection — the redeemer always takes the best asset and leaves the protocol the worst — so the fee
per asset must rise as that asset falls below its target weight in the basket. Choice is allowed; the
choice is priced.

```
redeem(compAmount, asset):
    usdOut   = compAmount × (10000 − feeBps(asset)) / 10000
    amountOut = usdOut / priceUsd[asset]
    feeBps(asset) = baseRedemptionFeeBps + deviationPenalty(asset)
```

**Redemption must never reach CDP collateral except through channel A's debt repayment.** A
borrower's IMD is theirs; the protocol may only hand it over in exchange for retiring their debt.

Note what channel A implies for work-minted COMP: it has no CDP behind it, so redeeming it consumes
borrowers' collateral. That is exactly the dilution §3 bounds, and the 120% worst case is the
guarantee that the collateral pool absorbs it.

## 6. What to build, in order

1. `workCeiling()` + `workRatioBps` as governed parameters, and the ceiling check in `mintFromWork`.
   Smallest change, removes the largest unbounded risk in the protocol, independent of everything
   else here.
2. Reserve valuation on the Treasury: per-asset price source and haircut, `reserveValueUsd()`.
   Requires the USD price wrapper (IMD/ETH feed × Chainlink ETH/USD).
3. `SwarmWorkOracle` — attestation-verified per-agent tally replacing the `grantRights` faucet,
   with `isController` binding a tally entry to a claimant.
4. Redemption channel A (IMD against CDPs). The hard floor, and the largest new surface.
5. Redemption channel B (reserve assets, weight-priced fee).
6. Upstream: the oracle-batch second-root PR.

## 7. Open questions

- **Involuntary redemption of borrowers** (channel A) — accepted as the price of a hard peg, or
  should redemption be restricted to the reserve only, giving a weaker floor but no borrower risk?
- **Redemption fee shape** — a fixed base, or Liquity's decaying `baseRate` that rises with recent
  redemption volume so a run gets progressively more expensive?
- **Target basket weights**, which set channel B's fee curve and therefore what the reserve drifts
  toward.
- **Does the Treasury burn the COMP it receives from fees, or hold it?** Burning makes the fee
  deflationary and simplifies the supply identity; holding it gives the protocol a buffer it can
  deploy. Either way it is not reserve.
- **Who may call the oracle tally update**, and what happens to rights already issued if a later
  tally revises an agent's count downward.
