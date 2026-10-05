---
title: Network health
section: governance
order: 3
audience: governance
sources:
  - src/NhiFeed.sol:17-46
  - src/SwarmFeed.sol:160-185
  - src/CDPVault.sol:676-721
  - src/CDPVault.sol:832-849
  - src/CDPVault.sol:1001-1048
---

# Network health

`NhiFeed` stores a network health index (NHI), a unitless measure scaled by 1e18. `mat()` translates it into the minimum collateral ratio; `lull()` translates it into the wait between marking and liquidation. The mapping is fixed in the vault's code, not editable through `Parameters`.

## What the panel is asked to measure

The pinned question reads `https://api.imd.fun/swarm` at answer time and combines three ratios:

- Participation: `health.agentsOnline` divided by `health.seatsEnrolled`, capped at full participation. No enrolled seats gives no participation.
- Service availability: the fraction of `health.verifierUp`, `health.publisherUp` and `health.deployerUp` that are true.
- Reliability: completed jobs divided by completed plus blocked plus cancelled jobs in `counts.jobStates`. Missing categories count as absent. With no completed, blocked or cancelled jobs, reliability is full; executing jobs are excluded.

The question specifies integer fixed-point arithmetic, truncation at each division and a weighted mean of these components. The weights are (under consideration). This is a live reading of published service counters, not a chain measurement at the question window. The feed verifies the signed answer and pinned question; it does not fetch or independently recompute those counters.

## How `mat` and `lull` move

| Health region | `mat` behavior | `lull` behavior |
|---|---|---|
| At or below lower breakpoint | Highest required collateral ratio. | Shortest grace. |
| Between breakpoints | Linearly decreases as health rises; rounds up to a whole percentage point. | Linearly increases as health rises; integer seconds round down. |
| At or above upper breakpoint | Lowest required collateral ratio. | Longest grace. |

The health breakpoints, ratio endpoints, grace endpoints and every bound are (under consideration). Both mappings clamp outside the interpolation interval. `NhiFeed` does not enforce the question's full unit interval on chain: it rejects zero and applies its deviation rules, while `mat` and `lull` clamp large accepted figures to the upper branch.

A drop in NHI can make a position unsafe without any change in collateral price or debt. The higher `mat` immediately affects new `draw`, indebted `free`, marking, liquidation and redemption eligibility. The last of these uses `mat + gap`, where `gap` is the governed spread, (under consideration).

## Grace is a snapshot

`barkFor` records `lull()` as the mark's `grace`. Changes in health do not shorten or lengthen that existing mark. Re-marking an unexpired unsafe position preserves its timestamp, grace and beneficiary. An expired mark can be replaced and then uses the new health-derived grace.

`tail()` is the separate liquidation window after grace, derived from the shorter primary/NHI feed age allowance. Its value is (under consideration). Liquidation is permitted at both window endpoints, subject to fresh agreeing prices and continuing unsafety. An unobserved recovery and later decline does not reset the mark; `heel` records recovery. See [How liquidation works](../keepers/how-liquidation-works.md).

## Availability and economic interpretation

`mat()` and `lull()` return a result even from stale or unset feed data. Price-dependent writes separately require usable NHI, primary, spot and dollar-price legs. Do not treat a ratio read alone as permission to act.

A healthier swarm does not prove deeper IMD liquidity or a safer market price. The health-to-ratio curve is a protocol design choice; the [parameter research](../economics/swarm-evidence.md) questions whether health should relax collateral requirements for a concentrated, thinly traded asset. That recommendation is not an enacted parameter change.
