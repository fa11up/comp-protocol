# Internal review: the work-root epoch fix (2026-10-10)

The only contract change since the fourth final-sweep panel (job `6229d0fc`): `549dfdd` on main, `4d7e494` on
`release/mainnet`. Reviewed in house rather than by a panel, by the operator's decision, for its size: one
virtual boolean, one block moved into a private function, one override. This note is what was checked.

## The change

`SwarmFeed._accept` ran the epoch bookkeeping for every subclass, `SwarmWorkOracle` included, although that
contract's `_checkValue` override had dropped the deviation bound for roots (a root is an identifier, not a
quantity: audit `c71449d1`, HIGH, is why the bound is not applied to it). On a rollover the bookkeeping calls
`_fitsEpoch`, which computes `mulDiv(anchor, allowance, 10_000)`. Once the feed had been stale for a lifetime
and one `STALE_GROWTH_PERIOD`, the allowance passed 10,000 bps and the product overflowed for any root above
`2^256 / multiple`: one late daily root and `_accept` reverted on almost every root after, for good.

Now `_hasMagnitude()` (virtual, `true`) gates the bookkeeping and the `accepts()` view; the work oracle returns
`false`. The bookkeeping itself moved, unchanged, into `_openEpoch`.

## Checked

| What | Result |
|---|---|
| The moved block equals the old inline block | yes, line for line; it runs at the same point (after `_checkValue`, before `_value` moves) |
| Price, spot and NHI feeds behave as before | 649 tests, 650 with `AUDIT_PROOFS`, 116 in `script/checks`: all pass. Delivery gas inside the Intake stipend: 147,114 / 136,509 / 143,212 of 200,000 (was 146,871 / 135,993), +0.2–0.4% for the new gate |
| The bug reproduces on the parent commit | `test/WorkRootAfterSilence.t.sol` on `ef91db1`: `MathOverflowedMulDiv()` after one missed day and after a month; on-time roots pass there too, so the test discriminates |
| Readers of the dropped state on the work oracle | none: `OracleAsker` calls `epoch()` only on its registered feeds, the keeper on `dep.feeds` (price, NHI, spot), the vault never. On the work oracle `epoch()` answers `(value, allowance, now)` and `accepts()` is the zero check; neither reverts |
| Sizes | vault initcode 47,946 B before and after (margin 1,206 B, pre-existing); feeds +15 B runtime each; work oracle −443 B |
| Addresses | `plan.py` reconverged (`56372be`); `DeployMainnet.check()` reports every constant `ok`; `check-bodies.mjs` ok; rehearsal 3 (deploy + keeper on an anvil fork) 10/10 on `fc4b66b` |
| Comments | the `accepts()` NatSpec still said a magnitude-less feed "must not be read through this"; corrected. `bytecode_hash = "none"` and the trailer carries only the compiler version, so the edit moved no bytecode (hashes compared before and after) |

## Not changed, noted

* The work oracle's `epoch()` view is meaningless for a root feed (it reports the current value as an anchor).
  Nothing reads it; a future reader should not.
* The vault's initcode margin, 1,206 bytes, caps how much can still be added to `ParameterizedVault` before
  launch. It was not consumed by this change.

## Conclusion

A bounded fix in the direction the earlier audit already set, with a discriminating regression test and no
observable change to the three price feeds. No panel round.
