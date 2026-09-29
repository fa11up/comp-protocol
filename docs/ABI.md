# ABI integration

The JSON files in `docs/abi/` contain complete Solidity ABI arrays, including constructor inputs, functions, events, and custom errors. All token, collateral, debt, and credit amounts are uint256 **minor units with 18 decimals**; `1 ether` in Solidity examples means 10^18 units, not an ETH payment. All constructors and state-changing methods are nonpayable. There is no payable fallback or receive function.

| Contract | Function | Caller and effect |
| --- | --- | --- |
| LaunchToken, MockIMD, CompToken | `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance` | Public ERC-20 views |
| LaunchToken, MockIMD, CompToken | `transfer(to, amount)`, `approve(spender, amount)`, `transferFrom(from, to, amount)` | Standard ERC-20 behavior; return bool |
| MockIMD | `deployer()` | Permanent faucet authority |
| MockIMD | `mint(account, amount)` | Approved workflow operator only; increases balance and supply |
| CompToken | `vault()` | Registered vault or zero before initialization |
| CompToken | `setVault(vault)` | Approved workflow operator, once; requires deployed code |
| CompToken | `mint(account, amount)`, `burn(account, amount)` | Registered vault only; burn does not spend allowance |
| IWorkOracle, MockWorkOracle | `mintingRights(account)` | Remaining spendable rights |
| IWorkOracle, MockWorkOracle | `consumeRights(account, amount)` | Associated vault only; reduces remaining rights |
| MockWorkOracle | `deployer()`, `vault()` | Immutable authority and associated consumer |
| MockWorkOracle | `grantRights(account, amount)` | Approved workflow operator only; adds to existing rights |
| CDPVault | `imdToken()`, `compToken()`, `oracle()` | Linked contract addresses |
| CDPVault | `MIN_COLLATERAL_RATIO()`, `LIQUIDATION_BONUS_PERCENT()` | 150 and 10 |
| CDPVault | `positions(account)` | Tuple `(collateral, debt)` |
| CDPVault | `collateralRatio(account)` | Integer percent; uint256.max for no debt or unrepresentably large ratio |
| CDPVault | `setOracle(oracle)` | Approved workflow operator once if constructed with zero oracle; otherwise always reverts |
| CDPVault | `depositCollateral(amount)` | Moves caller's approved IMD into their position |
| CDPVault | `withdrawCollateral(amount)` | Returns caller's IMD if remaining position stays at least 150% |
| CDPVault | `mintCOMP(amount)` | Consumes caller's rights, increases debt, mints COMP to caller |
| CDPVault | `repayCOMP(amount)` | Burns caller's COMP, decreases their debt; no approval and no rights refund |
| CDPVault | `liquidate(owner, debtToRepay)` | Burns caller's COMP against an unhealthy owner's debt and pays caller IMD |

`LaunchToken()` takes no constructor arguments and mints exactly 10^27 minor units to its deployer. Its metadata is `COMP Launch` / `CPL` / 18 decimals. Its public functions are only the standard ERC-20 views, transfers, and approval; it has no mint/burn or administration API. Use `docs/abi/LaunchToken.json` for the launch asset and `docs/abi/CompToken.json` for the stablecoin borrowed from CDPVault.

The four application constructor signatures are unchanged: `MockIMD()`, `CompToken()`, `CDPVault(imdToken, compToken, oracle)`, and `MockWorkOracle(vault)`. Initialization and faucet authority is the explicit workflow operator `0x5167D014a056E43883e1BBEa5530c3c0dC993281`, pinned in `src/DeploymentConfig.sol`. The mock `deployer()` getters return that operator even when a factory creates the contracts. After construction the operator calls `setVault` and (with zero constructor oracle) `setOracle` once; the factory and transaction origin gain no permissions. No public function, event, error, or ABI constructor input changed in this revision.

Events:

- All three tokens emit standard `Transfer` and `Approval`; mint/burn use the zero-address convention. LaunchToken emits its only mint during construction.
- CompToken emits `VaultSet(vault)` with indexed vault once.
- MockWorkOracle emits `RightsGranted(account, amount)` and `RightsConsumed(account, amount)` with indexed account.
- CDPVault emits `OracleSet(oracle)`, `CollateralDeposited(account, amount)`, `CollateralWithdrawn(account, amount)`, `COMPMinted(account, amount)`, and `COMPRepaid(account, amount)` with indexed addresses.
- `Liquidated(owner, liquidator, debtRepaid, collateralSeized)` indexes owner and liquidator. Actual payout is included, so consumers need not reconstruct rounded amounts.

Custom errors have no arguments unless indicated in the generated ABI. `Unauthorized` indicates a caller outside the permitted authority; `AlreadyInitialized` indicates permanently closed setup. Invalid contract addresses produce `InvalidToken`, `InvalidVault`, or `InvalidOracle`. `NotInitialized` means the vault's borrowing links are incomplete. MockWorkOracle additionally uses `InvalidAccount` for zero recipients.

Vault operation errors are `ZeroAmount`, `InsufficientCollateral`, `InsufficientRights`, `UnsafeCollateralRatio`, `HealthyPosition`, `ExcessRepayment`, and `UnexpectedCollateralReceived`. The last detects an unsupported short collateral deposit. External token/oracle reverts propagate; ERC-20 custom errors include balances and allowances. SafeERC20 false returns produce `SafeERC20FailedOperation(token)`. Reentry produces `ReentrancyGuardReentrantCall`. A reverted transaction rolls back position changes, work credits, token supply, and emitted events together.

Suggested frontend sequence: approve the desired IMD deposit, deposit, check rights and collateral headroom, then mint. On repayment, call repay directly from the indebted wallet and withdraw any newly available collateral. Show debt-free ratios as debt-free rather than rendering uint256.max as a percentage. Health bands are green at >=170%, amber at >=150% and <170%, and red below 150%. Refresh balances, rights, and position after each confirmed transaction. Restrict the grant-rights panel to `MockWorkOracle.deployer()` and show Sepolia only.
