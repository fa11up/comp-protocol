---
title: Contracts and addresses
section: reference
order: 1
audience: integrators
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
---

# Contracts and addresses

`ParameterizedVault` is the launch vault for imdUSD, a dollar-denominated collateralised debt position (CDP) stablecoin. A position records collateral and debt for an account. Start with [What is imdUSD](../overview/what-is-imdusd.md) for the overview and naming homage.

The inventory follows the runbook's section 6. An address placeholder is not deployment evidence. Discover constructor-created contracts through the vault's getters and verify reciprocal links before integrating.

| Contract | Address | Created by; role | Fixed links and governed values |
|---|---|---|---|
| `SwarmRelay` | (waiting for mainnet launch) | Deployment prerequisite; forwards attestations and can bundle marking or liquidation. | No owner, configuration setter or upgrade path. Each call names its targets. |
| `WorkOracleFactory` | (waiting for mainnet launch) | Deployment prerequisite; `create(maxAge_)` constructs a work oracle for its caller. | Permissionless creation, no governor or mutable configuration. Factory identity used by the vault is source-pinned. |
| `PriceFeed` | (waiting for mainnet launch) | Deployer; attested window-median IMD/ETH price. | Inherits `SwarmFeed`; signer, relayer, data chain, answer type and question policy are source-pinned. Maximum age and deviation bound are immutable constructor inputs, both (under consideration). |
| `NhiFeed` | (waiting for mainnet launch) | Deployer; attested network health index. | Same authority pattern as `PriceFeed`, with its own fixed question. Maximum age and deviation bound are (under consideration), immutable after construction. |
| `SpotFeed` | (waiting for mainnet launch) | Deployer; attested closing-block IMD/ETH price, used for the agreement guard. | Same authority pattern; distinct question and deployment. Maximum age and deviation bound are (under consideration), immutable after construction. |
| `ParameterizedVault` | (waiting for mainnet launch) | Deployer; positions, issuance, repayment, liquidation and redemption. | Immutable collateral (sIMD), stablecoin, work oracle, primary/NHI/spot feeds, `parameters`, `treasury`, `usdPriceFeed`, `collateralPriceFeed`. Economics read from its own `Parameters`; no upgrade or feed-replacement path. |
| `ImdUSD` | (waiting for mainnet launch) | Vault constructor when `stablecoin_` is the zero-address sentinel; imdUSD ERC-20. | Vault binding is permanent; only that vault mints and burns. Name and symbol are imdUSD, with 18 decimals. No governor, pause or upgrade. The one-time deferred `setVault` path is not used by constructor creation. |
| `Parameters` | (waiting for mainnet launch) | `ParameterizedVault` constructor; bounded economic configuration. | Linked vault has no setter. Source-pinned governor and hard limits; delayed changes listed in [Parameters](../governance/parameters.md). |
| `Treasury` — vault-created reserve | (waiting for mainnet launch) | `TreasuryFactory`, called by the `ParameterizedVault` constructor; receives protocol revenue and supplies reserve collateral for redemption. | Serves only that vault; its `Parameters` governs reserve listings, feeds and retained-value factors. `feeRecipient()` returns this Treasury. The operator may withdraw neither the collateral token nor any listed reserve asset, and may withdraw imdUSD only down to the outstanding realized bad debt. Anyone may call `payStream()` (a governed daily imdUSD stream to a governed payee) and `fundOracle()` (a governed daily IMD budget for price updates). |
| `TreasuryFactory` | (waiting for mainnet launch) | Deployment prerequisite; `create()` deploys a Treasury serving its caller. | No owner or setting. Exists so the vault's deployment code stays within the network's size limit. |
| `UsdPriceFeed` | (waiting for mainnet launch) | `ParameterizedVault` constructor; combines its primary IMD/ETH price with Chainlink ETH/USD. | Immutable `imdEthFeed`; source-pinned `ETH_USD` and maximum age, (under consideration). No setter or governor. |
| `SharePriceFeed` | (waiting for mainnet launch) | `ParameterizedVault` constructor, because the collateral is a staking-vault share; the vault's `collateralPriceFeed()`. | Immutable `shareVault` (sIMD) and `assetFeed` (the vault's `UsdPriceFeed`); no governance or setter. USD per 1e18 raw sIMD units. |
| `OracleAsker` | (waiting for mainnet launch) | Deployer, after the feeds and before the vault (the Treasury names it in source); buys feed updates through the IdentityMD Intake with IMD the Treasury streams to it, and delivers them through `SwarmRelay`. | No owner or setter. Its feeds and their request bodies are fixed at construction. Pays only when a feed is near stale or IMD's pool has drifted from it; see [Oracle and question binding](./oracle-and-question-binding.md#how-updates-are-paid-for). |
| `SwarmWorkOracle` | (waiting for mainnet launch) | `WorkOracleFactory.create` when the vault receives `WORK_ORACLE_SENTINEL`; attested tally roots and work rights. | Immutable consumer vault, signer, relayer, question and identity-adapter reference; immutable maximum age, (under consideration). `wage()` reads the vault's governed parameters. |

## Constructor and read-back boundaries

`ParameterizedVault(address imdToken_, address stablecoin_, address oracle_, address priceFeed_, address nhiFeed_, address spotFeed_)` takes six contract references. The primary, health and spot feeds must be distinct deployed contracts. The collateral must have code and differ from a supplied stablecoin. A supplied work oracle must answer `mintingRights(address)`; if it exposes a well-formed `vault()`, that getter must name this vault. The sentinel factory path creates the reciprocal link during construction.

`parameters().vault()`, `treasury().vault()` and `stablecoin().vault()` must identify the vault. `oracle().vault()` identifies it for `SwarmWorkOracle`. All these addresses are (waiting for mainnet launch). No follow-up transaction is needed to bind the constructor-created contracts.

## Collateral is sIMD

The vault's collateral token is sIMD (Staked IMD), the 24-decimal share token of IdentityMD's staking vault, which holds IMD. `gem()` returns the sIMD address. Because it is a share, the vault's constructor creates a `SharePriceFeed` and prices collateral through it: `convertToAssets(1e18)` from the staking vault times the IMD/USD price from `UsdPriceFeed`, per 1e18 raw sIMD units. The vault's arithmetic never reads `decimals()`, so expressing the price per raw unit is what keeps 24-decimal shares correctly valued.

`lock` takes sIMD. `lockIMD` takes IMD, stakes it in the staking vault on the depositor's behalf and credits the sIMD received. The vault never unstakes: `free`, `bite` and `cash` pay sIMD, and the staking vault's one-block hold applies to whoever unstakes it.

The Treasury values the vault's own collateral per 1e18 raw units as well, so sIMD listed as a reserve asset through `collateralPriceFeed()` counts at the same value the vault gives it. Listing is a governance proposal like any other reserve change; see [Parameters](../governance/parameters.md).

See [Oracle and question binding](./oracle-and-question-binding.md) for external price dependencies, [Vault functions](./vault-functions.md) for the callable surface, and [Risks](../economics/risks-and-open-questions.md) for authority assumptions.
