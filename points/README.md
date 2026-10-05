# Genesis points

Off-chain points for INFER's genesis season. No points are stored on chain; the vault only emits
the one event needed to compute them exactly, and anyone can rerun this and get the same numbers.

## The rule

| Who | Earns | Unit |
|---|---|---|
| Borrowers | principal × seconds held | 1 point = 1 imdUSD of principal held for 1 day |
| Liquidators | debt repaid × a flat credit (default 7 days) | same unit |
| Redeemers | nothing | |

- **Flat and linear.** Splitting a position across wallets earns exactly the same, and a late
  entrant earns at the same rate as an early one. A borrow held for one block earns one block.
- **Principal only.** Stability fees are a cost of borrowing, not borrowing, so they earn nothing.
- **Season:** from the vault's deployment (or `--start`) until the swarm's mainnet launch and our
  token launch (`--end`). A run mid-season is a live leaderboard.

## How it is computed

The vault emits `Principal(owner, debt)` whenever a position's principal changes, by any path: draw,
repay, liquidation or redemption. It carries the new total, because repayments pay fees before
principal and no other event says how a repayment split. `test/PrincipalEvent.t.sol` proves the
stream equals the vault's principal after every step of a fuzzed draw/repay sequence.

`engine.mjs` is pure (events in, points out) so the terminal can import the same code.
`logs.mjs` reads the vault's logs from Blockscout. It never uses a public RPC's `eth_getLogs`, which
can silently return an empty array, and it treats zero logs as an error rather than as "nobody
borrowed".

## Run

```bash
node points/cli.mjs --vault 0x... --chain ethereum --out points.json
node points/cli.mjs --vault 0x... --chain ethereum --end 2026-12-01T00:00:00Z   # a fixed season end
node --test points/engine.test.mjs                                             # engine tests
```

Set `BLOCKSCOUT_API_KEY` to raise the explorer's rate limit.

**Only the mainnet vault counts.** Testnet collateral comes from a free faucet, so testnet activity
costs nothing to fake.
