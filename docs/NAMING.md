# Naming: imdUSD, and the vocabulary we borrowed from MakerDAO

The stablecoin is **imdUSD** (`ERC20("imdUSD", "imdUSD")`, contract `ImdUSD`). Its development
name, COMP, is retired everywhere in source; it survives only in dated records (audits, research,
the internal audit) that describe the code as it was when they were written.

The vault's actions and economic parameters take their names from MakerDAO, as an homage to the
system that invented the collateralised stablecoin. The verbs come from Single-Collateral Dai (2017),
`bark` from Multi-Collateral Dai's liquidation 2.0, and the parameter names from MCD's `Spotter`,
`Jug`, `Vat`, `Dog`, `Clipper` and `End`. Where Maker had no counterpart, we coined a word in the same
spirit: short, physical, and of a piece with the rest (`heel` calls the dog off after `bark` and
`bite`; `earn`, `wage`, `lull`, `skew`, `cut`).

## Actions

| Name | Maker origin | What it does |
|---|---|---|
| `lock(amount)` | SCD `lock` | Deposit sIMD collateral into your position (`lockIMD` takes IMD and stakes it). |
| `free(amount)` | SCD `free` | Withdraw collateral, if the position stays at or above `mat`. |
| `draw(amount)` | SCD `draw` | Mint imdUSD against your collateral. |
| `wipe(amount)` | SCD `wipe` | Burn imdUSD to repay fees first, then principal. |
| `bark(owner)` / `barkFor(owner, beneficiary)` | MCD `Dog.bark` | Mark a position below `mat`; starts its grace period. |
| `bite(owner, amount)` | SCD/MCD `bite` | Repay a marked position's debt after grace and take its collateral plus the bonus. |
| `drip()` | MCD `Jug.drip` | Checkpoint the stability-fee index. |
| `cash(amount, minGemOut, candidate)` | MCD `End.cash` | Burn imdUSD for sIMD at the lesser of $1 and backing per unit, less the fee. |
| `heel(owner)` | coined | Clear the mark on a position that has recovered above `mat`. |
| `cover(owner, amount)` | MCD `Vow.heal` (renamed: `heal` is one letter from `heel`) | Burn Treasury imdUSD to repay a drained position's realized bad debt. Anyone may call it. |
| `earn(amount)` | coined | Mint imdUSD against attested swarm work, within `earnLine`. |
| `SwarmRelay.relayAndBark` / `relayAndBite` | — | Relay an attestation and act on the fresh price in one transaction. |

Events follow the verbs, as Maker's own `Cat` and `Dog` emitted `Bite` and `Bark`:
`Lock`, `Free`, `Draw`, `Wipe`, `Bark`, `Bite`, `Cash`, `Heel`, `Earn`.

## Parameters

| Name | Maker origin | Meaning |
|---|---|---|
| `gem()` | `Vat.gem` / `GemJoin.gem` | The collateral token (sIMD). Also `gemOut` in `Cash` and the return of `cash`, and the `cash` argument `minGemOut`. |
| `mat()` | `Spotter.mat` | Minimum collateral ratio, set by network health. |
| `duty()` | `Jug.duty` | Annual stability fee. `DUTY_BPS`, `MAX_DUTY_BPS` likewise. |
| `line()` | `Vat.line` | Debt ceiling. |
| `CHOP_PERCENT` | `Dog.chop` | Liquidation bonus, in percent of debt repaid. |
| `chi()` / `chiOf(owner)` | `Pot.chi` / rate accumulator | Stability-fee index, and a position's checkpoint of it. |
| `chip()` | `Clipper.chip` | Share of the bonus paid to whoever barked. `CHIP_BPS` likewise. |
| `cut()` | coined | Share of the bonus kept by the protocol. `CUT_BPS` likewise. |
| `tail()` | `Clipper.tail` | How long after grace a mark stays biteable before it must be barked again. |
| `gap()` | SCD `gap` | Spread above `mat` that sets the redemption ceiling. `proposeGap`, `pendingGap`, `MIN_GAP`, `MAX_GAP`, `GapOutOfRange`. |
| `lull()` | coined | Wait between `bark` and `bite`, set by network health. |
| `skew()` | coined | How far primary and spot may disagree before price actions pause. `SKEW_BPS`, `MAX_SKEW_BPS`. |
| `wage()` | coined | imdUSD earned per attested task. `WAGE_WAD`, `MAX_WAGE_WAD`, `proposeWage`, `WageTooHigh`. |
| `earnLine()` / `earnMat()` | coined, after `line` and `mat` | Ceiling on work-backed issuance, and the ratio that sets it. `EARN_MAT_BPS`, `proposeEarnMat`, `EarnMatTooHigh`; `totalEarned`. |

Errors keep plain names (`DebtCeilingReached`, `GracePeriodNotElapsed`, `WorkCeilingReached`,
`UnsafeCollateralRatio`, …), because they are read as messages; only those that validate a
parameter take its name. `redeem` survives in prose only where it means sIMD's own ERC-4626 unwrap.

**The terminal speaks these names and translates at the chain boundary.** `web/src/names.ts` maps
each name above to its pre-rename spelling, and a deployment file declares `"interface": "maker"` or
`"legacy"`; Sepolia launch 688 is legacy, every later deployment and mainnet are maker. Users see
neither vocabulary: the terminal labels actions in plain words (Deposit, Borrow, Repay, Withdraw,
Redeem, Mark, Liquidate, Clear mark, Mint from work), and amounts carry the token's own `symbol()`.
`web/tests/names.test.mjs` checks every row against the current ABIs and the deployed ones.
