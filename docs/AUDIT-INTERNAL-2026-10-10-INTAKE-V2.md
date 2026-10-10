# Internal review: Intake v2 and the failure callback (2026-10-10)

Two changes after the fourth final-sweep panel, both in `OracleAsker` and its Intake interface, reviewed in house
by the operator's decision. Nothing else in `src/` changed.

## 1. `INTAKE` = Intake v2 (`0xa43e6F75ee006411F79Ac1C84120606C2330DE82`)

The plane's own upgrade (`f5c0d20b`, its `deployments/mainnet.json`, through the canonical CREATE2 deployer, verified
source). Every v1 function, event and getter is unchanged; live owner, writer, signer, 200,000-gas callback stipend and
0.5 IMD price are identical to v1's; v1 stays served. The constant had to follow the address because the asker accepts
deliveries only from `INTAKE`. Changing it moved the asker's and the Treasury factory's planned addresses; relay, work
factory and feeds kept theirs.

## 2. The failure callback

Before: a request the plane refused (status 1) or that ended without a result (status 2) reached the asker never. The
feed's in-flight slot stayed set until `ASK_TIMEOUT` (two hours), during which `ask`, `askPaid` and `askPaidMany`
refused that feed for everyone. The only sign was the Intake's `Completed` event, off chain.

Now every request is made with `requestWithFailure`, naming `onOracleFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)`.
The Intake calls it under the same stipend when it closes such a request, after checking that the arguments name that
request and that status (`FailureArgsMismatch` otherwise) and that the caller is its writer. The asker:

* refuses any caller but `INTAKE` and any unknown request (the result callback's two checks), then never reverts;
* deletes `feedOf[requestId]`; if the request is the feed's live one, clears `inFlight` / `inFlightAt`, and, only if
  the Treasury paid for it, writes the same back-off a refused relay writes (`lastAsk = now + ASK_TIMEOUT -
  ASK_MIN_INTERVAL`): the request was not refunded, so the Treasury does not buy that feed again before the timeout. A
  caller's purchase or a superseded request writes no back-off (their answers' refusals never did either);
* emits `AskFailed(feed, requestId, status, reason, agreed, answered)`.

The result callback is untouched. The `Feed` struct and every view are unchanged, so the keeper and the dashboard read
as before; the keeper's "in flight" wait simply ends sooner.

## Checked

| What | Result |
|---|---|
| Unit, with the Intake stand-in extended to v2 | 39 in `OracleAsker.t.sol` (five new: the hook is named on every request; a refusal clears the slot at once, a caller may pay immediately, the Treasury backs off until the timeout; a caller-paid failure clears the slot and holds the Treasury back no further; a superseded request's failure clears nothing and holds nothing back; only the Intake, only for a known request, and a second report after the first finds nothing) |
| Gas | failure callback 22,815 of the 200,000 stipend; result-callback figures unchanged (147,114 / 136,509 / 143,212) |
| Against the LIVE v2 on a mainnet fork (`test/fork/IntakeV2.t.sol`) | payment through `requestWithFailure` records both callbacks; `complete` with status 0 reaches the asker from v2's address and clears the slot; with status 1 and 2 it reaches `onOracleFailure`, the slot clears, and a purchase of the same feed lands in the next transaction; v2 refuses failure arguments naming another request, leaving the slot untouched |
| Suites | forge 654/0 (4 skipped), `AUDIT_PROOFS` 655/0, `script/checks` 116/116, fork 6/6 |
| Plan | `plan.py` reconverged; `DeployMainnet.check()` every constant `ok`; `check-bodies.mjs` ok; asker initcode 10,666 B, vault 47,946 B (unchanged) |
| ABIs | `docs/abi/OracleAsker.json`, `docs/abi/IIntake.json` regenerated (`forge inspect … abi --json`) |

## Not changed, noted

* `reason`, `agreed`, `answered` and `signature` are the plane's account of the failure. They are recorded in the
  event and not verified: the Intake already verified its writer, and the asker's only decision (clear the slot,
  back the Treasury off) does not depend on them.
* The keeper could read `AskFailed` to say why a feed's purchase ended; it does not need to, and does not yet.

## Conclusion

A small addition on the delivery path, mirroring the existing callback's checks and back-off, tested against the
live Intake. No panel round, by the operator's decision.
