# Upstream: a window-free question identifier

Status: investigated 2026-10-03, **nothing opened**. Read both repos first, as asked. The conclusion
is that the gap is real and the fix is probably additive, but the right SHAPE is the maintainer's
call, so this belongs in a discussion issue rather than a PR.

## The gap is the plane's own stated design, unachievable as specified

`packages/contracts/src/OracleAttestation.sol`, on `questionHash`:

> keccak-256 of the canonical question document. **A consumer that pins its question compares this**,
> so an answer to a different question cannot be presented as its own.

That is exactly the pattern COMP's feeds now implement, so the intent is not in doubt. But a consumer
*cannot* pin "its question", because the document includes the resolved window
(`apps/control-plane/src/oracle/engine.ts`):

```ts
const questionHash = `0x${canonicalKeccak(questionDocument({ ...input, window }))}`;
```

and `questionDocument` (`packages/protocol/src/schemas/oracle.ts`) is
`{v, question, chainId, window: {fromBlock, toBlock}, answerType, head?, definitions?, evidence?}`.

So the hash changes every request. A one-shot consumer — one question, answered once — can pin a
literal and compare, which is what the docstring imagines. A **recurring** consumer such as a price
feed cannot: there is no value to pin.

What we had to do instead: pin the canonical document's *prefix* (1,963 bytes of JSON in contract
bytecode), splice the attestation's own signed `fromBlock`/`toBlock` onto the end, and recompute the
keccak in Solidity — reimplementing an RFC 8785 canonicalisation boundary inside a contract. It
works, it is tested against a live attestation, and no consumer should have to do it.

## Why the window in `questionHash` looks redundant

`fromBlock` and `toBlock` are **already separate signed fields of the attestation struct**. A
consumer that cares which blocks were read checks them directly — COMP does, for span and
monotonicity. Including them a second time inside `questionHash` adds no commitment that the struct
does not already carry; it only makes the question's identifier unstable.

Checked for anything relying on per-request uniqueness of `questionHash`, and found none in the plane:

| where | use | survives a window-free hash? |
|---|---|---|
| `db/schema.ts` | plain `char(66)` column, **not unique, not indexed** | yes |
| `engine.ts:507` | asserts the attestation's hash equals the row's | yes |
| `engine.ts:194` | stored on the row at creation | yes |
| `submissionKey` | `.unique()` — the real dedup key | unaffected |
| `requestHash` | `canonicalHash(input)` — the request's own identity | unaffected |

Nothing keys, indexes, or looks up by `questionHash`.

## Why this is still not a PR

Two honest objections a maintainer would raise, and neither is ours to settle:

1. **Changing the semantics changes every future hash value silently.** The domain version is "2",
   and `DOMAIN_VERSION`'s own comment notes that v2 broke v1 consumers deliberately and visibly. A
   hash-meaning change with no version bump is the kind of break that is invisible until someone's
   pinned literal stops matching. Doing it honestly means v3 — which breaks every deployed consumer
   on the network, for a problem only recurring consumers have.
2. **Add-a-field is not free either.** A separate `topicHash` over the window-free document is purely
   additive in meaning, but it changes `TYPEHASH`, so it is still a v3 signature break.

So the choice is between two versions of the same cost, and which is right depends on how many
consumers exist and what they pin — which cannot be known from inside one repository. We also cannot
rule out an external consumer that treats `questionHash` as per-request, however unlikely.

## What to propose, if anything

A discussion issue stating the gap (the docstring promises a pattern the schema prevents for
recurring consumers), the redundancy argument, the evidence that nothing upstream keys on the hash,
and the two candidate shapes — then let the maintainer pick. Not a PR, because a PR implies the
shape is decided and it is not.

We are not blocked either way: the splice works, it is verified against a live attestation, and
`expectedQuestionHash` lets any operator confirm a feed and a payload agree before paying.
