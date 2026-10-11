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

The network health index (NHI) is a single figure, scaled to one, that describes how well the IdentityMD swarm is running. `NhiFeed` stores it. The vault turns it into two things: the minimum collateral ratio `mat()` and the grace period `lull()` between a mark and a liquidation. That mapping is written into the vault and cannot be changed by governance.

## What the panel measures

The feed's fixed question asks the panel to read `https://api.imd.fun/swarm` when it answers and combine three ratios:

- **Participation:** agents online divided by seats enrolled, at most one. No enrolled seats counts as zero.
- **Service availability:** the share of the verifier, publisher and deployer services that are up.
- **Reliability:** completed jobs divided by completed plus blocked plus cancelled jobs. Jobs still running are left out, and with no finished jobs at all reliability counts as full.

The question fixes the arithmetic (whole-number maths, rounding down at each division) and takes a weighted average of the three: 40% participation, 30% service availability and 30% reliability. It is a live reading of the swarm's published counters, not something measured on chain. The feed checks the signature and the question; it cannot re-fetch the counters itself.

## How `mat` and `lull` move

| Network health | `mat` (required ratio) | `lull` (grace) |
|---|---|---|
| 0.60 or below | 200% | None |
| Between 0.60 and 0.85 | Falls steadily from 200% to 170% as health rises, rounded up to a whole percent | Grows steadily from none to six hours as health rises, rounded down to a whole second |
| 0.85 or above | 170% | Six hours |

Outside the breakpoints both values stay at their end points. The feed rejects a zero figure; a figure above one is treated as the top of the range.

A fall in network health can make a position unsafe with no change in the IMD price or its debt. A higher `mat` applies at once to new borrowing, to withdrawals while in debt, to marking and liquidation, and to redemption eligibility (which uses `mat` plus the governed spread `gap`).

## Grace is fixed when a position is marked

A mark stores the `lull()` in force at the moment of marking. Later changes in health do not shorten or lengthen it. Marking again while the mark is still live changes nothing; once a mark has expired, a new one takes the grace in force at that time.

The liquidation window that follows grace, `tail()`, is the shorter of the price feed's and the health feed's maximum ages. How marks are cleared and expire is covered in [How liquidation works](../keepers/how-liquidation-works.md).

## Reading the figures

`mat()` and `lull()` return a value even when the health feed is stale, so a ratio read on its own is not permission to act: every price-dependent action separately requires live feeds. A healthier swarm also says nothing about IMD's market depth, and the [parameter research](../economics/swarm-evidence.md) questions whether health should lower collateral requirements at all.
