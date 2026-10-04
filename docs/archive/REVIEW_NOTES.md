# Source-contributor review notes

These notes record implementation reasoning and handoff findings. They are not an independent adversarial review or an approval to deploy.

## Verified local properties

The local suite exercises successful and rejected operations, every initialization authority, ERC-20 allowance behavior, rounding at 150%, the uint256 range, and rollback on external-call failure. Malicious oracle and collateral test doubles attempt all five guarded vault actions during callbacks; the ReentrancyGuard rejects each attempt. Runtime scans check all four application contracts and LaunchToken for EIP-170 size and forbidden DELEGATECALL, CALLCODE, and SELFDESTRUCT instructions while skipping PUSH operands.

All funds-moving vault functions use the guard and settle position effects before interactions. Oracle work-credit queries are view calls. The mint path checks rights and health, updates debt, consumes rights, then mints; a failure in any step reverts all steps. Repayment and liquidation burn only the transaction caller's COMP. IMD uses SafeERC20, and deposits additionally validate the actual received amount. Authority references cannot be changed after initialization.

The health comparison is equivalent to `collateral >= debt + ceil(debt/2)` but avoids overflow in the addition by checking `collateral >= debt` first, then comparing the difference. Ratio display computes quotient and remainder separately, preserving fractional percentage precision without overflowing `collateral * 100`. Liquidation computes `amount + floor(amount/10)` only after checking the full payout fits within target collateral.

Forge's heuristic build lints may warn about post-interaction events, ReentrancyGuard's final `_status` write, address validation via code length, initializer deletion, balance-delta equality, and division before multiplication. The guard is active before external calls; initialization emits the linking event; zero addresses fail the code-length checks; exact incoming collateral is intentional; the ratio explicitly includes the remainder. Callback, initialization, short-transfer, and arithmetic tests exercise those cases. Slither and Mythril were not run.

## Launch asset and stablecoin separation

Deploy `new CompToken()`: `totalSupply()` and the deployer's balance are both zero, as required. The supplied generic token floor instead applies to the separate `LaunchToken`, which mints exactly 10^27 minor units to its deployer and has no post-construction supply-changing entry points. Tests cover both direct and factory deployment, transfers, invalid calls, and absent common administration selectors. The manifest must select LaunchToken as the launch asset while CDPVault continues to reference CompToken. Selecting COMP as the fixed-supply token would still fail the supplied floor. This distinction resolves the missing launch artifact without changing stablecoin economics; the operator authorization resolution is described below.

## Resolved: factory deployment stranded initialization and faucet authority

The supplied factory proof reproduced `Unauthorized` at the approved operator's first `CompToken.setVault` call on the starting implementation. Both initialization slots and both faucet authorities were assigned to the creating factory, which cannot call application methods.

The four constructors now assign those permissions to the exact operator named in the approved workflow, via `src/DeploymentConfig.sol`. Constructor signatures, ERC-20 behavior, borrowing accounting, and one-time setter locks are unchanged. This release is specific to that operator. The named address is an explicit authorization choice from the workflow, not a wallet inferred from `msg.sender`, `tx.origin`, or a factory getter. The mock `deployer()` ABI continues to expose the permanent faucet operator. CompToken and CDPVault erase their initializer on successful setup as before; they gain no ongoing operator authority.

The unchanged supplied proof now passes. `test/FactoryDeployment.t.sol` additionally exercises CREATE and CREATE2 from an unrelated relayer/origin, then operator initialization, funding/rights, and a borrow/repay/withdraw round trip. Negative tests reject factory, relayer, origin, and unrelated callers, including an intermediary whose transaction origin is the operator. After initialization the operator cannot replace links, mint/burn COMP directly, or consume oracle rights.

That release implemented the operator-initialization fallback only. The independent review then reported that the constructor-only factory launch still ends with `comp.vault()` and `vault.oracle()` unset, because no launch path performs the two operator calls. The section below records the constructor-compatible resolution; the operator fallback remains for the workflow's literal deploy order.

## Resolved: constructor-only launch left borrowing uninitialized

Reproduced exactly as reported: after a factory deploys MockIMD, `CompToken()`, `CDPVault(imd, comp, 0)`, and `MockWorkOracle(vault)`, a funded borrower's `mintCOMP` reverts `NotInitialized`, and only the pinned operator can complete the links. A four-contract manifest cannot close the token/vault/oracle cycle with constructor arguments alone, so the resolution lets the vault close it.

`CDPVault(imd, 0, 0)` now creates `CompToken(address(this))` and `MockWorkOracle(address(this))` inside its constructor and validates and locks the oracle before returning. `CompToken` takes a constructor vault: zero keeps the deferred operator path; the creating contract is accepted while it has no code; any other target must pass the reciprocal check. `MockWorkOracle` likewise accepts its creator as the vault. In this self-contained mode both setters revert `AlreadyInitialized` from genesis for every caller, so the operator holds only the two faucet functions and the policy owner holds nothing; no constructor consumes `$owner`. The manifest should list MockIMD and `CDPVault($contract:MockIMD, 0x0, 0x0)`. `test/FactoryDeployment.t.sol` exercises this through CREATE and CREATE2 from an unrelated relayer and origin and borrows without any initialization call; `test/Runtime.t.sol` scans the self-contained vault and its two created contracts. The CDPVault runtime is 4,903 bytes; the child creation code lives only in its init code.

The workflow's literal order (assembled mode) is unchanged: `CompToken(0)`, `CDPVault(imd, comp, 0)`, `MockWorkOracle(vault)`, then the operator's `setVault` and `setOracle`. The pinned operator constant remains for that path and for the mock faucets.

## Resolved: one-time setters accepted incompatible targets

Both advisories reproduced. `setOracle(address(imd))` succeeded and burned the initializer although MockIMD cannot answer `mintingRights`; `comp2.setVault(vault1)` succeeded although `vault1.compToken()` is `comp1`. Both now revert `InvalidOracle` / `InvalidVault` and leave initialization available. The vault requires a successful `mintingRights(address)` staticcall and, if the target exposes `vault()`, that it equals the vault; a drop-in IWorkOracle without that view (tested as `PlainOracle`) stays acceptable, so the interface is unchanged. The token requires `compToken()` to return itself, except for the creating contract in self-contained mode, which has no code yet. The same checks run on nonzero constructor arguments. These checks authenticate links, not implementations: a contract that answers the probes with the right values is still accepted.

## Withdrawal/liquidation scenario clarification

The advisory's exact sequence reproduces the documented health checks: Alice deposits 200 IMD, borrows 100 COMP, and transfers the COMP to Bob. Her attempted 70 IMD withdrawal reverts `UnsafeCollateralRatio`; Bob's subsequent 50 COMP liquidation reverts `HealthyPosition`. The position remains 200 IMD / 100 COMP. `test_unsafeWithdrawalCannotEnableLiquidation` preserves that regression. No health or liquidation logic changed. The 50 COMP / 55 IMD liquidation case requires the existing, explicitly synthetic 130 IMD collateral fixture; it is not a withdrawal-triggered production path.

## Operational boundaries

Under the requested fixed price and supplied nonrebasing collateral, all normal borrowing and withdrawal transitions preserve health. Unhealthy positions in liquidation tests are artificial. A production price feed and migration policy would require a separate design and review. At collateral below the full 110% liquidation payout, a full repayment through liquidation reverts; partial liquidation may leave bad debt. No insurance, collateral seizure beyond the target balance, or privilege to erase debt is included.

The mock faucet authorities are retained intentionally and can mint arbitrary test collateral or grant arbitrary test work credits. They cannot change the initialized vault or COMP permissions. Oracle availability is required for borrowing; an oracle failure does not block ordinary repayment or healthy withdrawals. Direct token donations and accidental transfers have no rescue path. Reciprocal address checks now run on-chain before a link is locked; selecting the correct artifacts remains a deployment responsibility.

Services own policy artifacts, signed source linkage, attestation, admission, deployment, and frontend launch. Those later outcomes were not simulated or claimed by the local tests. The source and eventual `launch.json` still need the independently assigned review.
