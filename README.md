# COMP Protocol

A compute-backed CDP stablecoin on Sepolia whose risk parameters are driven by IdentityMD swarm
attestations. IMD is the collateral; the vault mints against it, and both oracle inputs end up
controlling liquidation.

Forked from `identity-md-launches/launch-519-mockimd-pricefeed-nhifeed-cdpvault`, so the history
below the fork point is the swarm's own build across launches 458 → 493 → 517 → 519. Everything
above it is ours.

## The two numbers

| input | what it does | status |
|---|---|---|
| **price** | `collateralRatio = collateral * price * 100 / (debt * 1e18)` | reporter path; attested path ready |
| **NHI** | `minCR()` 150 at ≥0.85 rising to 200 at ≤0.60; `gracePeriod()` 6h falling to 0 | composite attested unanimously, not yet relayed |

Both are pure functions of the feeds. There is no admin, no parameter setter, and no key that can
change a ratio after deployment.

## Live on Sepolia

| | |
|---|---|
| CDPVault | `0x78f0c70896457F42A4D4891e4F4af4c4e370722B` |
| PriceFeed | `0x073c9A8Dc565f16A649448F85ec43048ea378f33` |
| NhiFeed | `0xf9F5AB38B2E1838542BD43f186Dd408Dd2C8e769` |
| CompToken | `0xD5014bF11B9B57b6d248f516B53F4e495Fe29eC1` *(created in CDPVault's constructor)* |
| MockWorkOracle | `0x24466446fc636d93551490542EAd07210b64D9b1` *(same)* |
| MockIMD | `0xe44ab81ce23d34e29383dd158a1dffeb1c10d439` |

Attestation v2 verified on chain: domain version 2, typehash matching the live service, panel floors
25/15.

## Oracle

IMD's only liquid market is Uniswap v4 on mainnet, both pools paired with native ETH. The v3 WETH
pool is drained — `liquidity()` is 0 — so anything priced from it is a frozen leftover.

`oracle/` holds the request payloads and the tooling:

```bash
cd oracle && npm install
node preflight-oracle.mjs <payload.json> <feedAddress>   # before paying
node relay-attestation.js <oracleRequestId>              # after it attests
```

**Run the preflight before every paid request.** It reads the destination feed's own constraints
from chain and refuses a payload the feed could never accept. It exists because a request attested
perfectly and still could not be relayed: `consumer` was missing, so the signature was under the
service's default domain instead of the feed's, and the panel was smaller than the feed's floor.
Both were knowable in advance.

Two things learned the expensive way:

- Ask chain reads as **`evidence: "panel"`** with the computation pinned in `definitions`.
  `evidence: "chain"` requires a recipe from a fixed catalogue, and a question it cannot express
  fails on clustering even when the agents all compute the right number.
- `consumer.verifyingContract` must be **lowercase**, or `/requests/quote` returns a bare 400.

## Testing

```bash
forge test --offline --no-match-path test/InHouse.t.sol   # 185 inherited
forge test --match-path test/InHouse.t.sol --fork-url $SEPOLIA_RPC_URL --fork-block-number <recent>
```

`test/InHouse.t.sol` covers the layer the inherited suite does not: the constructor arguments and the
deployment's own authorities. That is the layer that actually failed in production — an earlier
launch deployed with a manifest placeholder that resolved to the platform's address rather than ours,
and with an answer-type constant that was simply wrong, both immutable.

Most public Sepolia RPCs are not archive nodes; pin `--fork-block-number` near head.

## Known limits

- `maxDeviationBps` 2000 caps one update at 20% of the last value, and the bound is floor-based. A
  faster move needs successive updates, so the feed trails a crash — which is when liquidation
  accuracy matters most.
- Below the full 110% liquidation payout a position can only be partially liquidated and bad debt can
  remain. There is no insurance and no write-off path.
- The reporter and relayer are a single key. Until the attested path is live that key sets the price,
  which is custody of every position. **Mainnet must be a fresh deployment with a proper operator.**
