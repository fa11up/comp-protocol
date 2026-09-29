# Source-contributor review notes

These notes record implementation reasoning and handoff findings. They are not an independent adversarial review or an approval to deploy.

## Verified local properties

The local suite exercises successful and rejected operations, every initialization authority, ERC-20 allowance behavior, rounding at 150%, the uint256 range, and rollback on external-call failure. Malicious oracle and collateral test doubles attempt all five guarded vault actions during callbacks; the ReentrancyGuard rejects each attempt. Runtime scans check all four application contracts and LaunchToken for EIP-170 size and forbidden DELEGATECALL, CALLCODE, and SELFDESTRUCT instructions while skipping PUSH operands.

All funds-moving vault functions use the guard and settle position effects before interactions. Oracle work-credit queries are view calls. The mint path checks rights and health, updates debt, consumes rights, then mints; a failure in any step reverts all steps. Repayment and liquidation burn only the transaction caller's COMP. IMD uses SafeERC20, and deposits additionally validate the actual received amount. Authority references cannot be changed after initialization.

The health comparison is equivalent to `collateral >= debt + ceil(debt/2)` but avoids overflow in the addition by checking `collateral >= debt` first, then comparing the difference. Ratio display computes quotient and remainder separately, preserving fractional percentage precision without overflowing `collateral * 100`. Liquidation computes `amount + floor(amount/10)` only after checking the full payout fits within target collateral.

Forge's heuristic build lints may warn about post-interaction events, ReentrancyGuard's final `_status` write, address validation via code length, initializer deletion, balance-delta equality, and division before multiplication. The guard is active before external calls; initialization emits the linking event; zero addresses fail the code-length checks; exact incoming collateral is intentional; the ratio explicitly includes the remainder. Callback, initialization, short-transfer, and arithmetic tests exercise those cases. Slither and Mythril were not run.

## Launch asset and stablecoin separation

Deploy `new CompToken()`: `totalSupply()` and the deployer's balance are both zero, as required. The supplied generic token floor instead applies to the separate `LaunchToken`, which mints exactly 10^27 minor units to its deployer and has no post-construction supply-changing entry points. Tests cover both direct and factory deployment, transfers, invalid calls, and absent common administration selectors. The manifest must select LaunchToken as the launch asset while CDPVault continues to reference CompToken. Selecting COMP as the fixed-supply token would still fail the supplied floor. This distinction resolves the missing launch artifact without changing stablecoin economics; it does not resolve the application initialization conflict below.

## Finding: constructor-only factory cannot complete initialization

Deploy MockIMD and CompToken through a factory that cannot call application methods. Deploy CDPVault with zero oracle, then MockWorkOracle with the vault address. Calling `setVault` or `setOracle` from the intended human operator reverts `Unauthorized`, because the factory is the actual deployer. Leaving them unset makes `mintCOMP` revert `NotInitialized`. The same factory also owns the two mock faucet permissions and cannot exercise them. Nonzero constructor oracle configuration does not resolve CompToken's separate one-time setter or both faucet authorities.

The approved operational sequence requires the actual deploying account to make two initialization calls and later operate the mock faucets. The manifest reviewer should flag any factory path that cannot realize those permissions. Resolving this conflict requires approved deployment capability or a separately approved constructor/authority design; this contribution does not silently change the specified constructors or hard-code an operator.

## Operational boundaries

Under the requested fixed price and supplied nonrebasing collateral, all normal borrowing and withdrawal transitions preserve health. Unhealthy positions in liquidation tests are artificial. A production price feed and migration policy would require a separate design and review. At collateral below the full 110% liquidation payout, a full repayment through liquidation reverts; partial liquidation may leave bad debt. No insurance, collateral seizure beyond the target balance, or privilege to erase debt is included.

The mock faucet authorities are retained intentionally and can mint arbitrary test collateral or grant arbitrary test work credits. They cannot change the initialized vault or COMP permissions. Oracle availability is required for borrowing; an oracle failure does not block ordinary repayment or healthy withdrawals. Direct token donations and accidental transfers have no rescue path. Correct dependency selection and reciprocal address checks are deployment responsibilities.

Services own policy artifacts, signed source linkage, attestation, admission, deployment, and frontend launch. Those later outcomes were not simulated or claimed by the local tests. The source and eventual `launch.json` still need the independently assigned review.
