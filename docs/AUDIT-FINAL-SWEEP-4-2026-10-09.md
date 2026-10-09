# Final sweep panel 4 — 2026-10-09

Job `6229d0fc-c6a5-4c3e-bb56-64461d50b1cb` (explorer: https://explorer.imd.fun/jobs/6229d0fc-c6a5-4c3e-bb56-64461d50b1cb), `template: audit` (four specialists and a judge who reproduces every claim), pinned to `c7d50ee0376885bc3413cffa16415425ed95c13e`.

Scope: the whole protocol, every mechanism in turn (the oracle, borrowing and liquidation, redemption and the paced figures, the Treasury, governance and minting from work, ImdUSD, the factories, the deployment and the launch window, reentrancy across every contract, and every comment claim), as the last review before launch. The payload's facts were corrected for this round: IMD trades in other pools and on Base and Robinhood Chain, not only in the pool the oracle reads. Payload: `whitepaper/requests/audit/audit-final-sweep-4-quote.json` (`build_audits.py`, Phase 16).

| Seat | Role | Outcome | Findings reported | Turns | Output tokens |
|---|---|---|---|---|---|
| 281 (agent 51163) | audit_judge | completed | 7 | 46 | 31,313 |
| 225 (agent 52158) | audit_economics | completed | 2 | 61 | 116,694 |
| 481 (agent 52256) | audit_math | completed | 1 | 37 | 51,125 |
| 879 (agent 51509) | audit_permissions | completed | 4 | 33 | 59,569 |
| 869 (agent 52163) | audit_flow | completed | 3 | 43 | 106,645 |

The judge's merged list: **no critical, no high**, 1 medium, 2 low, 4 info. Judge submission hash `197c469eab1ddb97b7fc9fd219d7b866ac00ae39ca99a6439330f3ee1a77302d`; raw record of every seat beside this file (`audit-final-sweep-4-2026-10-09-submission.json`). Between them the specialists read every file in `src/` and `src/interfaces/`, the deploy scripts, `plan.py`, the pinned bodies and the runbook's launch sections; none could reach the external contracts (sIMD, IMD, the Intake, the live Chainlink aggregator). No seat re-reported an accepted item.

## Findings and resolution

Answered in `df82607`.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | medium | `SwarmFeed`: a value relayed at the end of a live epoch anchors the next epoch, so one block of a pushed pool, attested honestly to the spot feed in the epoch's last minute, refuses the honest spot for two hours. The vault refuses every priced action for disagreement, then staleness, long enough to expire a liquidation mark: a marked borrower could hold off their own liquidation for the cost of one block's push every seven hours. The same premise (a far re-anchor costs hours of silence) was stated in three comments. Two seats found it. | **Fixed: the way back** (`SwarmFeed._returnAnchor`). Once an epoch has expired, a value the epoch rule refuses is still accepted if it lies within the cap of the level the expired epoch held its values to (its first value if it opened wide, else its anchor), and the new epoch is anchored there. It reaches no level the expired epoch did not already allow, and applies only until that epoch is older than two lifetimes and one growth period, when the stale allowance from the last value takes over. Every value accepted before is accepted and anchored exactly as before. The panel's proof is kept and passes (`test/final-sweep-4/judge_medium_LateEpochAnchorLockout.t.sol`), with a second test that the way back never widens the band, and `accepts(value)`, a view that tells a buyer whether an update would land. `test_staleValueReanchorsOnlyWithinTheWidenedBound` now asserts the refusal of a value beyond both bands. The three comments now say a late push needs no silence and the way back is what keeps it from locking the honest level out. |
| 2 | low | `Parameters` and `DeploymentConfig` described the work ceiling's ratio term as a share of `totalDebt`; the code uses `backedDebt`, which can be far lower the day after a large draw. | **Fixed (wording).** |
| 3 | low | `bite`'s "a bite never seizes more than the formula" omitted the remainder sweep. | **Fixed (wording)** at the line and in the NatSpec. |
| 4 | info | `bite`'s dust branch accepts any `debtToRepay`, so a caller repaying the full debt against dust burns it for one raw unit (retiring bad debt at their own expense). | **Stated** in the NatSpec. Nobody else can take anything, and the keeper already sizes a dust bite at one wei (`maxRepayable`). |
| 5 | info | `heel` and the `bite` defence line said deposit and repayment clear a mark; they do only at fresh, agreeing feeds. | **Fixed (wording):** both say so, and tell a borrower to call `heel` once the feeds are fresh. The site's marked-borrower warning already said "when the price feeds are fresh". |
| 6 | info | `UsdPriceFeed` said a dead ETH/USD leg only degrades the work ceiling; on the deployed vault it halts every price action, `earn` included. | **Fixed (wording).** |
| 7 | info | `DeploymentConfig`'s header described the testnet release's roles (one-time links, faucets, a reporter) and said "Sepolia" above constants `plan.py` rewrites; `OracleAsker` quoted an update at $4.25. | **Fixed (wording):** the operator's comment names what the key holds on the mainnet path; the reporter sentence is removed; "Sepolia" is dropped; the price reads 0.5 IMD. |

**Review of the fix, before deciding on another round.** The change was audited in house rather than sent to another panel; what was checked:
- *It only widens what is accepted, and only once an epoch has expired.* The way back runs only for a value the epoch rule refuses, so every value accepted before is accepted and anchored as before; inside a live epoch, and inside a `relayMany` bundle after its first value, nothing changes.
- *It reaches no new extreme.* Every value it accepts lies within the cap of a level the expired epoch held, and that epoch had already allowed every such value. Measured from the CURRENT value it can be one larger step, up to 1.5x toward a level held within the last two to three lifetimes (a value at 0.8 of a 1.0 anchor may return as far as 1.2); a straddle of two epochs already reached 1.44x. Up, that over-borrows at most to 113% real collateral at mat 170, short of the 70% rise the oracle record found needed for a profit; down, it is the held-down liquidation already accepted with its bound.
- *It closes.* After two lifetimes and one growth period the stale allowance from the last value takes over, so it cannot reach back to an old level.
- *Edges.* A wide epoch whose first value exceeds `type(uint80).max` keeps no first value, and the way back would use its stale anchor; the shipped price, spot and NHI values are below 1e19, so unreachable. The Intake callback's gas test passes.
- *One gap, off chain, fixed.* `epoch()` reports only the current anchor, and the keeper's refusal pre-check read it, so in the very lockout the fix ends the keeper would have judged the honest update refused and waited. The feed gains `accepts(value)`, the rule itself as a view, and the keeper asks it (falling back to the anchor check for a feed without it).
The conclusion: no further panel. The change is a strict, bounded widening on one path with its proof and a no-new-extreme test, and the one gap was a reader's.

**Verification:** `forge test --match-path "test/**" --no-match-path "test/{fork,scratch}/**"`: 650 tests, 646 passed, 0 failed, 4 skipped; the Intake callback's gas test passes with the way back; initcode 47,874 bytes.
