---
title: Contracts and addresses
section: reference
order: 1
audience: integrators
pending: true
sources:
  - docs/MAINNET-RUNBOOK.md:194-290
  - src/ParameterizedVault.sol:25-164
  - src/CDPVault.sol:274-328
  - src/ImdUSD.sol:19-75
  - src/SwarmFeed.sol:26-156
  - src/SwarmRelay.sol:37-134
  - src/Treasury.sol:36-323
  - src/WorkOracleFactory.sol:29-38
  - src/SwarmWorkOracle.sol:50-232
  - src/SharePriceFeed.sol:36-93
  - src/UsdPriceFeed.sol:23-96
  - src/OracleAsker.sol:1
---

# Contracts and addresses

`ParameterizedVault` is the imdUSD vault: it holds every position (an account's collateral and debt) and is the only contract that mints or burns imdUSD. Start with [What is imdUSD](../overview/what-is-imdusd.md) for the overview.

Some contracts are deployed on their own; the vault creates the rest in its constructor. To find a vault-created contract, read the vault's getter, then check that the contract names the vault back before you integrate with it. A listed address is not proof of a deployment until you have checked it on chain.

| Contract | Address | Fixed links and governed values |
|---|---|---|
| `SwarmRelay` | (waiting for mainnet launch) | No owner, settings or upgrade path. Each call names its own targets. |
| `WorkOracleFactory` | (waiting for mainnet launch) | Anyone may call it; no governor or settings. The vault's copy of its address is written into the contract. |
| `PriceFeed` | (waiting for mainnet launch) | Inherits `SwarmFeed`. Signer, relayer, data chain, answer type and question are written into the contract. Maximum age (—) and deviation bound (—) are set once at deployment. |
| `NhiFeed` | (waiting for mainnet launch) | Same setup as `PriceFeed`, with its own question. Maximum age (—) and deviation bound (—) are set once at deployment. |
| `SpotFeed` | (waiting for mainnet launch) | Same setup, with its own question. Maximum age (—) and deviation bound (—) are set once at deployment. |
| `OracleAsker` | (waiting for mainnet launch) | No owner or settings. Its feeds and their request bodies are fixed at deployment. Pays only when the health feed is close to stale or IMD's pool has fallen below a price feed (never for a rise); see [How updates are paid for](./oracle-and-question-binding.md#how-updates-are-paid-for). |
| `ParameterizedVault` | (waiting for mainnet launch) | Collateral (sIMD), stablecoin, the three feeds, `parameters`, `treasury`, `usdPriceFeed` and `collateralPriceFeed` are all fixed. Economic settings come from its own `Parameters`. No upgrade path and no way to swap a feed. The work oracle it creates can be replaced through `Parameters`, only while minting from work is off; `oracle()` returns whichever is in use. |
| `ImdUSD` | (waiting for mainnet launch) | Bound to the vault for good; only the vault mints and burns. No governor, pause or upgrade. |
| `Parameters` | (waiting for mainnet launch) | Its vault cannot be changed. The governor and every hard limit are written into the contract; changes go through the delay in [Parameters](../governance/parameters.md). |
| `Treasury` | (waiting for mainnet launch) | Serves only its vault; that vault's `Parameters` governs which reserve assets are listed and how they are priced. `feeRecipient()` returns it. The operator can never withdraw the collateral (sIMD) or a listed reserve asset, and can withdraw imdUSD only above what outstanding bad debt still needs. Anyone may call `payStream()` (a governed daily imdUSD payment to a governed payee) and `fundOracle()` (a governed daily IMD budget for price updates). |
| `TreasuryFactory` | (waiting for mainnet launch) | No owner or settings. It exists so the vault's deployment code stays under the network's size limit. |
| `UsdPriceFeed` | (waiting for mainnet launch) | Its IMD/ETH feed is fixed; the Chainlink address and its maximum age (—) are written into the contract. No settings or governor. |
| `SharePriceFeed` | (waiting for mainnet launch) | Fixed to sIMD and to the vault's `UsdPriceFeed`. No settings. Quotes USD per 1e18 raw sIMD units. |
| `SwarmWorkOracle` | (waiting for mainnet launch) | Vault, signer, relayer, question and identity adapter are fixed; maximum age (—) is set once. `wage()` reads the vault's governed settings. |

## Constructor and read-back checks

`ParameterizedVault(address imdToken_, address stablecoin_, address oracle_, address priceFeed_, address nhiFeed_, address spotFeed_)` takes six contract addresses. The three feeds must be different deployed contracts. The collateral must be a deployed contract and must not be the stablecoin. A work oracle passed in must answer `mintingRights(address)`, and if it has a `vault()` getter, that getter must name this vault. On mainnet the vault is given a reserved placeholder address for the work oracle instead, which tells it to build one through the factory.

Once deployed, `parameters().vault()`, `treasury().vault()` and `stablecoin().vault()` must all return the vault, and so must `oracle().vault()` for `SwarmWorkOracle`. No follow-up transaction is needed to link the contracts the vault created.

## Collateral is sIMD

The vault's collateral is sIMD (Staked IMD), the 24-decimal share token of IdentityMD's staking vault, which holds IMD. `gem()` returns its address. Because sIMD is a share, the vault creates a `SharePriceFeed` to price it: the staking vault's `convertToAssets(1e18)` times the IMD/USD price from `UsdPriceFeed`, quoted per 1e18 raw sIMD units. The vault never reads `decimals()`, so quoting per raw unit is what keeps the 24-decimal share correctly valued.

`lock` takes sIMD. `lockIMD` takes IMD, stakes it on the depositor's behalf and credits the sIMD that comes back. The vault never unstakes: `free`, `bite` and `cash` pay sIMD, and the staking vault's one-block hold applies to whoever unstakes it.

The Treasury values the vault's collateral per 1e18 raw units too, so sIMD listed as a reserve asset with `collateralPriceFeed()` as its price counts at the same value the vault gives it. Listing it is a governance proposal like any other reserve change; see [Parameters](../governance/parameters.md).

See [Oracle and question binding](./oracle-and-question-binding.md) for the price sources, [Vault functions](./vault-functions.md) for everything you can call, and [Risks and open questions](../economics/risks-and-open-questions.md) for who holds which powers.
