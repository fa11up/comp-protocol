# Naming: imdUSD, and the vocabulary we borrowed from MakerDAO

The stablecoin is **imdUSD** (`ERC20("imdUSD", "imdUSD")`, contract `ImdUSD`). Its development
name, COMP, is retired everywhere in source; it survives only in dated records (audits, research,
the internal audit) that describe the code as it was when they were written.

The vault's actions and economic parameters take their names from MakerDAO, as an homage to the
system that invented the collateralised stablecoin. The verbs come from Single-Collateral Dai (2017),
`bark` from Multi-Collateral Dai's liquidation 2.0, and the parameter names from MCD's `Spotter`,
`Jug`, `Vat` and `Dog`. Where Maker had no counterpart (redemption, clearing a mark, the work
channel), the name stays plain English.

## Actions

| Now | Was | Maker origin | What it does |
|---|---|---|---|
| `lock(amount)` | `depositCollateral` | SCD `lock` | Deposit IMD collateral into your position. |
| `free(amount)` | `withdrawCollateral` | SCD `free` | Withdraw collateral, if the position stays at or above `mat`. |
| `draw(amount)` | `mintCOMP` | SCD `draw` | Mint imdUSD against your collateral. |
| `wipe(amount)` | `repayCOMP` | SCD `wipe` | Burn imdUSD to repay fees first, then principal. |
| `bark(owner)` / `barkFor(owner, beneficiary)` | `markUnderwater` / `markUnderwaterFor` | MCD `Dog.bark` | Mark a position below `mat`; starts its grace period. |
| `bite(owner, amount)` | `liquidate` | SCD/MCD `bite` | Repay a marked position's debt after grace and take its collateral plus the bonus. |
| `drip()` | `pokeIndex` | MCD `Jug.drip` | Checkpoint the stability-fee index. |
| `redeem(...)` | unchanged | — | Burn imdUSD for IMD at the lesser of $1 and backing per unit, less the fee. |
| `clearRecoveredMark`, `mintFromWork` | unchanged | — | |
| `SwarmRelay.relayAndBark` / `relayAndBite` | `relayAndMark` / `relayAndLiquidate` | — | Relay an attestation and act on the fresh price in one transaction. |

Events follow the verbs, as Maker's own `Cat` and `Dog` emitted `Bite` and `Bark`:
`Lock`, `Free`, `Draw`, `Wipe`, `Bark`, `Bite` (were `CollateralDeposited`, `CollateralWithdrawn`,
`COMPMinted`, `COMPRepaid`, `UnderwaterMarked`, `Liquidated`).

## Parameters

| Now | Was | Maker origin | Meaning |
|---|---|---|---|
| `mat()` | `minCR()` | `Spotter.mat` | Minimum collateral ratio, set by network health. |
| `duty()` | `stabilityFeeBps()` | `Jug.duty` | Annual stability fee. `DUTY_BPS`, `MAX_DUTY_BPS` likewise. |
| `line()` | `debtCeiling()` | `Vat.line` | Debt ceiling. |
| `CHOP_PERCENT` | `LIQUIDATION_BONUS_PERCENT` | `Dog.chop` | Liquidation bonus, in percent of debt repaid. |
| `chi()` / `chiOf(owner)` | `debtIndex()` / `debtIndexOf` | `Pot.chi` / rate accumulator | Stability-fee index, and a position's checkpoint of it. |

## Other renames

| Now | Was |
|---|---|
| `stablecoin()` | `compToken()` |
| `backingPerUnit()` | `backingPerComp()` |
| `UNITS_PER_TASK_WAD`, `unitsPerTaskWad`, `proposeUnitsPerTask`, `UnitsPerTaskTooHigh` | `COMP_PER_TASK_WAD`, `compPerTaskWad`, `proposeCompPerTask`, `CompPerTaskTooHigh` |
| `StablecoinIsNotReserve` | `CompIsNotReserve` |
| `ImdUSDCreator`, `IStablecoinConsumer` | `CompTokenCreator`, `ICompTokenConsumer` |
| `script/DeployProtocol.s.sol` | `script/DeployComp.s.sol` |

Errors otherwise keep plain names (`DebtCeilingReached`, `UnsafeCollateralRatio`, …), because they are
read as messages.

**The deployed Sepolia contracts predate this rename**, so `web/` and its pinned ABIs keep the old
names until the next deployment; the terminal must not call functions the chain does not have.
