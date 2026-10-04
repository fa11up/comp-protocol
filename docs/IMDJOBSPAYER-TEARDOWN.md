# `IMDJobsPayer`: trade volume paying for swarm work

Teardown of `0xd60483Eb8004e3DE3e283b3efF0e67FBb57f9B21` (si-md.xyz), read from verified source and
live state on 2026-10-04. Written because it is the mechanism our own oracle budget is missing, and
because it is what has been silently paying for our swarm requests.

## What it does, in its own words

> Receives 1.2% of every $SIMD trade, converts it into the token Identity.md charges for tasks
> (`paymentToken`, IMD today), and refunds a share of what people pay for their tasks. ETH only ever
> leaves this contract in two ways: swapped into the payment token (`buyToken`), or by the dev's own
> rescue functions.

So: a token's trade fee funds a demand subsidy for the compute network that token is about.

```
$SIMD trade ──1.2%──▶ ETH in this contract
                         │
                         │ buyToken(ethIn, minOut)   Uniswap v4, price floor + slippage cap
                         ▼
                      IMD held here
                         │
   keeper observes payments to the plane's payment endpoints
                         │ refund(Payment[])  onlyOperator
                         ▼
                 payer gets refundBps of what they paid
```

## Live state

| | |
|---|---:|
| `refundBps` (base) | **5000** = 50% |
| `countBoostBps` / `countBoostRemaining` | **10000** = 100%, **19 left** |
| `boostActive` (the time-based boost) | false |
| `maxPaidPerPayment` | 5 IMD |
| `maxRefundPerDay` | 500 IMD (484.25 left today) |
| `totalRefunded` / `refundCount` | 15.75 IMD over 32 refunds |
| `totalEthSpent` / `totalTokenBought` | 0.01 ETH → 2.945 IMD |
| `launchpadForwardBps` | 7500 |
| holdings | 0 ETH, 481.97 IMD |
| `refundedTo(miyagod.eth)` | **2.5 IMD** |

**The 100% is temporary and the counter is global.** `--countBoostRemaining` decrements inside
`refund()` per payment, so every other submitter on the network consumes the same 19. After that the
rebate halves to the 50% base.

## What it corrected about our own records

We read the 0.5 IMD arriving 84–108 seconds after each payment as the plane auto-refunding a failed
admission, and concluded a failed request costs time but not money. That was wrong, and it mattered:
the plane refunded nothing — both stuck orders are still `admission_pending` with no refund — and
**both of the orders that ADMITTED FINE were rebated too**. A failed admission really does cost
0.5 IMD; we were coincidentally covered by somebody's promotion.

## The three things worth taking

### 1. A funded oracle budget — the gap we already measured

This is the mechanism our protocol is missing, and the research report
(`docs/RESEARCH-PARAMS-2026-10-04.md`) priced the hole: **24 updates/day × $4.25 × 365 = $37,230/yr
against $20,000/yr of stability-fee revenue at 200 bps on $1M of debt.** Our fee does not cover our
oracle. Raising the fee to 1,000 bps is one answer; funding the budget from a different stream is
the other, and they are not exclusive.

The Treasury already accrues the protocol's liquidation cut and its minted stability fees. **Nothing
spends them on updates.** The missing piece is a funder that converts protocol revenue into oracle
requests on a price-movement trigger, with per-request and per-day caps so a bug or a griefer cannot
drain it — exactly the caps this contract uses.

PR #66's Intake is what makes that possible at all: `ask()` is a plain contract call, so a funder
contract can buy its own updates. Today `submit.js` needs a browser, which is why the watcher in
`docs/COMPUTE-BACKING-DESIGN.md` has never been built end to end. See
`docs/ONCHAIN-INTAKE-INTEGRATION.md`.

**This does NOT argue for launching a token.** Round 5 deliberately shipped `evm_contracts` with no
token and no pool; adding one back reintroduces the launch surface we removed and an LP fee split we
do not control. The transferable part is *a capped contract that turns revenue into updates*, and
the revenue we would use is revenue we already earn.

### 2. Count-based boosts beat time-based ones

`setRefundBoost(bps, duration)` and `setRefundBoostCount(bps, count)` sit side by side, and the count
variant is the better instrument. A time window with no traffic wastes the budget; a count window
spends exactly the budget and cannot overrun. If we ever bootstrap keepers or subsidise early
borrowers, this is the shape — and it is the first incentive design I have seen that gets this right
by construction rather than by monitoring.

### 3. An enumerable exit surface, stated as a promise

"ETH only ever leaves this contract in two ways" is a claim a reader can check against the code in
under a minute. That is the same discipline as our `Treasury.withdraw` being operator-only with the
destination an argument, and our feeds taking no authority arguments at all. Convergent, and worth
keeping as a house style: say what can leave, and make the list short enough to verify.

## One thing they have that we keep deferring

`refund()` is `onlyOperator`, driven by an off-chain keeper that watches the plane's payment
endpoints and submits batches. That is the same shape as our price-movement watcher — a daemon
observing chain state and calling a permissioned entry point — and theirs is running in production
right now. If we wanted evidence the shape works before building ours, it is live.

## Risk to us, stated plainly

The rebate makes our request costs read as zero, which invites buying more loosely than we should.
The budget is global, the 100% boost has 19 refunds left across the whole network, and the base is
50%. Price every future request at **0.5 IMD** and treat anything that comes back as a windfall.
