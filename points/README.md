# Genesis points

Off-chain points for INFER's genesis season. Nothing is stored or computed on chain: points come from
the imdUSD token's standard `Transfer` events and the vault's liquidation event, and anyone can rerun
this and get the same numbers.

## The rule

**1 point = 1 imdUSD held for 1 day.**

| Who | Earns | Rate |
|---|---|---|
| imdUSD in a wallet | balance × days held | 1× |
| imdUSD provided to the imdUSD/USDC pool | position × days | 3× (default), because the launch needs liquidity |
| Liquidators | debt repaid × 3 days | flat credit per liquidation |
| Borrowing, redeeming | nothing by themselves | a borrower earns by holding or providing what they mint |

- **Points belong to an address, not to the token.** A buyer earns from the block the imdUSD arrives;
  the seller keeps what it earned and stops. Nothing moves with the token.
- **Flat and linear.** Splitting across wallets earns exactly the same, and a late entrant earns at the
  same rate as an early one. Only the balance at the end of a block counts, so a flash loan earns
  nothing.
- **Excluded:** the vault, the Treasury (stability fees are minted to it) and the Uniswap v4
  PoolManager, whose imdUSD belongs to the LPs and is credited to them at the liquidity rate.
- **Season:** from the stablecoin's deployment until the swarm's mainnet launch and our token launch.

**Time is measured in blocks**: a day is 7,200 blocks at 12 seconds. Every holder sees the same block
count, so each share is exact. Only the absolute figure moves with a missed slot. No timestamps are
needed, so any RPC or explorer reproduces the same numbers.

**Liquidity is not live yet.** The pool does not exist, so `lp` events have no reader: liquidity
earns nothing until the pool's LP reader is built, and the terminal says so.

## Files

- `engine.ts`: the rule. Pure; the terminal imports it through Vite and the CLI runs it under Node's
  type stripping, so both always agree.
- `logs.ts` + `chains.ts`: read logs from Blockscout, never a public RPC's `eth_getLogs`, which can
  silently return an empty array. Zero logs is an error, never "nobody holds anything".
- `cli.ts`: writes the leaderboard as JSON.

## Run

```bash
node points/cli.ts --stablecoin 0x.. --vault 0x.. --chain ethereum --exclude <treasury> --out points.json
node --test points/engine.test.ts
```

**Only mainnet counts.** Testnet balances cost nothing to fake.
