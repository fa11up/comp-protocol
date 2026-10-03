# Auditor proofs for findings whose API no longer exists

These two tests came from the independent audit (job `c71449d1`) and both failed against commit
`cbd9e609`, exactly as the auditor described:

| proof | finding | result then |
|---|---|---|
| `BindHijack.t.sol` | `Parameters.bindVault` accepts any contract whose `parameters()` returns `address(this)`, so a front-run binds governance to an impostor forever | 2 failures: wrong vault bound, then arithmetic underflow |
| `SharedParameters.t.sol` | a vault accepts a `Parameters` already bound to a different vault, so it reads a rate it is never checkpointed for | 2 failures: construction not refused, then arithmetic underflow |

They live here, outside `test/`, because they no longer **compile**: the fix removed the API they
exercise. `ParameterizedVault` takes no `Parameters` argument and `Parameters.bindVault` is gone, so
a vault can only ever govern through the Parameters it created itself. Both attacks needed the
binding to be a separate transaction, and there is no fix that keeps one — a mid-construction
callback cannot verify its caller, because the vault has no code yet.

Kept verbatim as the record of what was wrong and how it was shown. `test/Parameters.t.sol` asserts
the property that replaces them: a vault's Parameters is its creator's, and nothing else can be
bound because nothing else can be passed.

The other two proofs stayed in `test/audit/` because they still compile:
`TreasuryLostReceipt.t.sol` now PASSES (the accounting bug is fixed) and is an ungated regression
test; `PermissionlessRelay.t.sol` still fails on purpose — its `TestFeed` pins no question, so it
describes a configuration no production feed uses any more.
