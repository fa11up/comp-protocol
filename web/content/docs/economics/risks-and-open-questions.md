---
title: Risks and open questions
section: economics
order: 3
audience: everyone
sources:
  - src/SwarmFeed.sol
  - src/UsdPriceFeed.sol
  - src/CDPVault.sol
  - src/ParameterizedVault.sol
  - src/Parameters.sol
  - src/Governed.sol
  - src/Treasury.sol
  - src/OracleAsker.sol
  - src/SwarmRelay.sol
  - docs/AUDIT-2026-10-03.md
  - docs/AUDIT-2026-10-04.md
  - docs/INTERNAL-AUDIT-2026-10-04.md
  - docs/AUDIT-VAULT-2026-10-05.md
  - docs/AUDIT-GOVERNANCE-2026-10-05.md
  - docs/AUDIT-ORACLE-2026-10-05.md
  - docs/AUDIT-ADVERSARIAL-2026-10-05.md
  - docs/AUDIT-GAS-2026-10-05.md
  - docs/AUDIT-FIX-PLAN-2026-10-05.md
  - docs/AUDIT-FINAL-VAULT-PANEL-2026-10-08.md
  - docs/AUDIT-FINAL-SWEEP-PANEL-2026-10-08.md
  - docs/RESEARCH-PARAMS-2026-10-04.md
  - docs/PARAMETERS-2026-10-05.md
  - docs/MAINNET-RUNBOOK.md
---

# Risks and open questions

The vault enforces its rules for collateral, prices and accounting. Those rules do not guarantee that imdUSD trades at $1, that the system stays solvent or that keepers show up. If backing falls below $1 per imdUSD, redemption pays less than $1.

## Prices and the oracle

**The price is signed by one key.** Each feed accepts a value only with a signature from the IdentityMD oracle service, for the feed's own question, from a panel at least as large as the feed's floor. The contract checks that signature. It cannot see the panel itself: it trusts the service's report of how many agents answered and agreed, and it cannot check that the agents worked independently or read the pool correctly.

**The second price is not independent.** The spot feed reads the same pool as the primary. It catches a bad or manipulated reading of that pool, not a pool that is itself mispriced.

**Large moves and stale feeds.** Within one feed lifetime, updates can move a feed only so far from where that period started, so a real, sudden move may be refused at first. Once a feed has been silent an hour past its maximum age, the allowed move doubles, and it keeps widening for every further hour of silence, so after a long enough gap the feed can follow any move. That recovery leans fully on the signer and the question, and whoever relays first after a silence sets the value the rest of that period is held around; the Treasury pays for an honest refresh once a feed's allowance has widened that far. A feed's very first value is bounded by nothing on chain, which is why the deployment checks the first values against the pool and an outside price before the vault exists.

**A stale or disagreeing feed halts most actions.** Borrowing, withdrawing against debt, marking, liquidating and redeeming all wait for live prices. Depositing and repaying do not. The ETH/USD price comes from Chainlink, and if it goes stale, no IdentityMD update can fix it.

**Updates cost money.** The Treasury pays for price updates through `OracleAsker`, up to a daily budget that governance sets ([How updates are paid for](../reference/oracle-and-question-binding.md#how-updates-are-paid-for)). A refused request still costs its fee. A budget too small for a volatile market lets feeds go stale, which halts actions rather than mispricing them. Someone still has to call the asker, and relay gas is not reimbursed.

## Collateral and liquidity

**Seized collateral may not sell at the feed's price.** IMD trades in one concentrated pool. Thin liquidity, withdrawn liquidity, congestion or many liquidations at once can turn the liquidation bonus into a loss.

**Bad debt can happen.** A fast fall can leave a position owing more than its collateral. That shortfall is recorded. `cover` can cancel it with imdUSD the Treasury holds from fees; if the Treasury holds too little, the shortfall stays and lowers backing for every holder. There is no insurance fund.

**Backing per imdUSD is a cautious measure.** It counts only collateral that stands behind debt, and what a redemption is paid can rise by at most two points of par an hour however much capital arrives (the paced backing), so capital brought in just to redeem against cannot lift it faster than that; a real recovery reaches redeemers at the same rate. The figure falls at once and remembers a fall: a position that leaves the book in one transaction and returns in the next leaves it where the book stood without that position, which is below par only when the rest of the book carries an underwater position, uncovered bad debt or work-minted supply, and it climbs back at two points an hour. That never overpays a redeemer; it underpays them for those hours, and the operators keep it rare by liquidating and covering promptly. A position's collateral term is fixed at the price it was last touched at; anyone may re-price any position (`resecure`), and the keeper does after every price update. It can fall after a redemption even when the system as a whole is better backed. A redemption can also fail if no eligible position can cover a reserve shortfall.

**Work-backed issuance is a limit at the moment of minting.** If minting from work is open, it is capped when imdUSD is minted. Later repayments, price falls or parameter changes can leave earlier work-minted imdUSD above the cap; nothing is burned to restore it.

## Governance and the Treasury

**One operator account governs.** It proposes parameter changes, which wait out a fixed delay before anyone may apply them. There is no vote. A proposal never expires, so a matured proposal can be applied long after its date; watch pending proposals until they are applied or cancelled.

**Valid settings can still be bad settings.** Every parameter has hard limits written into the contracts, but a value inside those limits can still leave liquidation unattractive (the protocol's and marker's shares together may take the whole bonus) or overvalue a listed reserve asset.

**What the operator can and cannot take from the Treasury.** The operator cannot withdraw sIMD or any listed reserve asset; removing a reserve asset takes a delisting proposal and its delay. It may withdraw imdUSD only above what outstanding bad debt needs, and other unlisted tokens freely. A governed daily stream can pay imdUSD to a governed payee.

## Keepers

**No one is paid to keep watch.** Keepers need ETH for gas and imdUSD to burn, and they are paid only from liquidation bonuses. A mark earns nothing unless the position is liquidated. If liquidation is not profitable after gas, price impact and the protocol's share, positions may sit unsafe.

**Bundling gives atomicity, not priority.** `relayAndBite` makes an update and a liquidation succeed or fail together, but another keeper can still act first.

**An empty loan book is not proof of no positions.** A public node can return nothing for a range it declines to search. See [Reading state](../reference/reading-state.md).

## Smart-contract bugs

The contracts are immutable. A bug cannot be fixed with a parameter change; it needs a new deployment.

The code has been through twenty-four reviews since 2026-10-03: two single audits, panel audits of the vault, governance and the Treasury, and the price path (four specialists and a judge who re-runs every claim), adversarial reviews of the whole system, a gas review and two in-house reviews. Every finding was fixed, or accepted with its reason stated, in the commit after the round that found it, and the next round was pinned to that commit. A panel over the whole system found nothing above low. The vault's backing figure then went through two more panels: the first found the lagged-capital design's latest repair wanting and it was replaced outright by paced figures with a one-sentence guarantee; the second, on that redesign, found no high, and its three mediums were fixed or restated in the commit after it, with every proof kept. The full chain, with each job, commit and record, is in [Audit history](../reference/audit-history.md). Reviews and tests reduce risk; they do not prove every sequence of calls safe.

## Not yet proven

- That each launch feed accepts a live, service-signed answer to its own question. One attestation per feed is bought and its receipt published with the addresses at launch.
- How much IMD the pool can absorb under stress, and how many keepers will compete.
- Whether the oracle service answers fast enough for the maximum price age the feeds allow.
- That the daily update budget is enough in a volatile market.
