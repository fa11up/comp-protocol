# Direct asks for the dev (small; message, not issue)

Ready to paste, most urgent first.

1. **Intake (PR #66) — the only thing our mainnet deploy waits on.** When will it merge and deploy on
   mainnet, and at what address? We deploy against it as an external address; our script refuses until it
   has code. Four details we build on, please confirm:
   - action id `oracle.request@oracle-1` (bytes32, right-padded) and its IMD price via `priceOf`;
   - the callback stipend stays ≥ 200,000 gas (our first delivery into a bound feed measures 146,460);
   - a body with a relative window (`"window":{"hours":N}`) is resolved afresh per request, as on the
     HTTP door (our pinned bodies depend on it: a literal window could be answered once);
   - whether an Intake request id maps to an `/oracle/requests/<id>` record, so a keeper can find and
     relay an answer whose callback failed.
2. **Oracle consumer stability** — opened as issue (attester rotation policy is the part that matters most;
   one-line answer welcome: "additive only, N-day overlap, announced on the inbox").
3. **Scheduled oracle requests priced below spot.** A `schedule.create` request is predictable load; a
   discount would let consumers keep feeds alive on a clock instead of only on movement.
4. **`agentRoot` as its own field in `WorkRecorded`** (one field): lets a consumer verify a tally proof
   against chain state with no oracle request. Not a blocker; offering it.
5. **`draft.contracts` cap 4 vs manifest 8.** Requests approve manifests, so the extra manifest slots are
   unreachable through `workflow.open`. A number to raise when convenient.
6. **ERC-8004 coverage of oracle work** — a yes/no we can plan against: will oracle reviews ever be recorded
   there, or is the daily receipt the only work signal? (Measured ~6% coverage, none since 2026-09-29.)
