---
title: Glossary
section: overview
order: 3
audience: everyone
sources:
  - docs/NAMING.md:1-68
  - src/CDPVault.sol:44-49
  - src/CDPVault.sol:776-848
  - src/SwarmFeed.sol:26-42
  - src/SwarmFeed.sol:210-221
  - src/ParameterizedVault.sol:120-199
---

# Glossary

Each entry gives the plain meaning first, then the identifier where one exists. Parameter values are (under consideration) throughout.

**attestation.** A signed answer from an IdentityMD panel, in the struct `SwarmFeed.OracleAttestation`. A feed accepts a value only from a valid attestation. See [Relay oracle updates](../keepers/relay-oracle-updates.md).

**backing per imdUSD.** Reserve value plus the collateral that stands behind debt, divided by imdUSD supply, capped at $1. Read with `backingPerUnit()`. Redemption pays the lesser of $1 and this figure, less the fee.

**bark.** Mark an unsafe position so it can later be liquidated. The terminal button is Mark. Function `bark(owner)`, or `barkFor(owner, beneficiary)` to credit another address.

**bite.** Liquidate: burn your imdUSD to cancel a marked position's debt and receive its collateral plus the bonus. The terminal button is Liquidate. Function `bite(owner, debtToRepay)`.

**bonus.** The extra collateral a liquidator receives on top of the debt repaid, set by `CHOP_PERCENT`. Split into `chip`, `cut` and the biter's remainder.

**cash.** Redeem: burn imdUSD for sIMD. The terminal button is Redeem. Function `cash(amount, minGemOut, candidate)`.

**chi.** The stability-fee index. It starts at 1 and only rises, linearly with time at the rate `duty`. A position's own checkpoint is `chiOf(owner)`. `drip()` records the current value; anyone may call it.

**chip.** The marker's share of the liquidation bonus. Paid to the address recorded when the position was marked.

**collateral ratio.** Collateral value in dollars divided by debt, as a whole-number percentage. Read with `collateralRatio(owner)`. A debt-free position reads as the maximum integer.

**CHOP_PERCENT.** The liquidation bonus, as a percent of the debt repaid. A source constant.

**clear mark.** Remove a mark from a position that has recovered. The terminal button is Clear mark. Function `heel(owner)`.

**cut.** The protocol's share of the liquidation bonus, paid to the Treasury.

**duty.** The annual stability fee rate. A governed parameter.

**earn.** Mint imdUSD against attested swarm work. The terminal button is Mint from work. Function `earn(amount)`. It is bounded by `earnLine` and needs minting rights from the work oracle.

**earnLine / earnMat.** `earnLine` is the ceiling on cumulative work-backed issuance: the reserve value plus backed debt scaled by `earnMat`.

**gap.** The spread above `mat` that sets the redemption eligibility ceiling: positions below `mat` plus `gap` can be redeemed against.

**grace.** The wait between a mark and the first moment the position can be liquidated. Its length is `lull()` at the time of marking, and it is stored with the mark.

**heel.** See *clear mark*.

**keeper.** Anyone who relays attestations, marks unsafe positions or liquidates them. Permissionless; paid through the liquidation bonus. See [Keeper economics](../keepers/keeper-economics.md).

**line.** The debt ceiling: the most principal that can be outstanding. Read with `line()`.

**liquidation window.** How long a mark stays usable after its grace ends. After that the mark has expired and must be retaken. Function `tail()`; error `MarkExpired`.

**lull.** The grace length derived from the network health index. See *grace*.

**mark.** A record that a position was unsafe at a moment, held in `liquidationMarks(owner)` with its time, its grace and the marker's address. Cleared by Deposit or Repay when the position is safe again, by Borrow or Withdraw when they succeed, or by Clear mark.

**mat.** The minimum collateral ratio, derived from the network health index. Read with `mat()`.

**network health index.** A figure scaled to one that the IdentityMD panels attest about the swarm. It sets `mat` and `lull`. Held by the `NhiFeed`. See [Network health](../governance/network-health.md).

**question hash.** The hash of the question document a panel answered. A feed rebuilds the expected hash from the block window and refuses answers to any other question. Read with `expectedQuestionHash(fromBlock, toBlock)`. See [Oracle and question binding](../reference/oracle-and-question-binding.md).

**reserve.** The assets the Treasury holds: sIMD plus any asset governance lists. Redemption draws on its sIMD first.

**skew.** The most the primary and spot prices may differ before price-dependent actions pause.

**spot feed.** A second IMD/ETH feed, read at the last block of its window. Used only to check the primary.

**stability fee.** The interest charged on debt, at `duty`, accrued through `chi`. It is paid first when you Repay.

**tail.** See *liquidation window*.

**wage.** The imdUSD earned per attested work task. Governed, with a hard maximum.
