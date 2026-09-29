# COMP protocol contracts

Sepolia proof of concept for borrowing **Compute Money (COMP)** against **Identity MD (IMD)** collateral and consumable work credits. This contribution implements MockIMD, CompToken, MockWorkOracle, CDPVault, `src/interfaces/IWorkOracle.sol`, and the separate LaunchToken required for project launch.

COMP has **zero initial supply**, no configured supply cap, and 18 decimals. Each borrow creates COMP; repayment and liquidation destroy it. There is no initial distribution. IMD also starts at zero supply and uses 18 decimals. The workflow's approved operator can mint test collateral on demand.

**LaunchToken (COMP Launch, CPL)** has 18 decimals and a fixed supply of exactly **1,000,000,000 tokens (10^27 minor units)**, minted entirely to `msg.sender` in its nonpayable, argument-free constructor. When a factory deploys it, that factory receives the supply. It has standard ERC-20 transfers and approvals and no external mint, burn, owner, pause, blocklist, fee, or upgrade functions. CPL is the launch distribution asset; it has no role in vault collateral, COMP debt, or oracle rights.

## Build and verify

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abi.py --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. Foundry and that compiler must be installed by the runner. All Solidity dependencies are ordinary vendored files: OpenZeppelin Contracts v5.0.2 (only the ten transitive files required here) and forge-std v1.9.6. Their licenses and archive hashes are in `lib/*/PROVENANCE.md` and the adjacent license files. Builds need no dependency download, FFI, filesystem cheatcode permission, keys, RPC, or environment configuration.

Unit and adversarial tests cover both initialization modes, rejected mismatched links, token behavior, authorization, oracle accounting, transaction rollback, boundary rounding, liquidation payouts, and reentrancy. Three fuzz tests run 256 cases each. The four-actor invariant test runs 128 sequences of 64 calls, including rejected unsafe borrowing and rejected healthy-position liquidations. It checks:

- COMP total supply equals the sum of all positions' debt and tracked wallet COMP balances.
- Every normal position with debt has collateral ratio at least 150%.
- The vault's IMD balance equals accounted collateral; aggregate IMD is conserved.
- Granted rights equal remaining plus consumed rights, including after repayment.

LaunchToken tests additionally check exact genesis supply, factory custody, fee-free transfers and allowances, rejected invalid transfers, absent mint/admin selectors for both deployer and stranger, and bounded runtime without forbidden instructions.

The price never changes and collateral is nonrebasing, so normal actions cannot create an unhealthy position. Liquidation tests **explicitly inject hypothetical collateral loss with test-only storage writes**. Production contracts have no equivalent mutation. These cases exercise liquidation math and failure handling without claiming that real price changes are supported. In particular, depositing 200 IMD and borrowing 100 COMP does not permit a 70 IMD withdrawal: that call reverts `UnsafeCollateralRatio`, leaves the position at 200% CR, and a subsequent 50 COMP liquidation reverts `HealthyPosition`. The 50 COMP repayment / 55 IMD payout scenario is tested only after a synthetic loss to 130 IMD. Withdrawal-triggered liquidation is not an end-to-end scenario supported by this model.

## Economic and integration assumptions

**1 IMD == 1 COMP**, fixed for this testnet, as documented in CDPVault NatSpec. Both values are measured in 18-decimal minor units. This is accounting, not an assertion about market prices or a guaranteed dollar peg. No price feed, interest, fee, work verification, or external ERC-8004 dependency is implemented.

Borrowing requires sufficient remaining work credits and `collateral * 100 >= resultingDebt * 150`. Withdrawing applies the same threshold to remaining collateral. Equality at 150% is valid. Arithmetic compares these values without intermediate multiplication overflow. The displayed integer percentage rounds down; debt-free positions return `uint256.max`. Ratios too large for a uint256 also saturate at that value.

IMD approvals are needed for deposits. COMP approval is **not** needed for repayment or liquidation: CompToken authorizes only the vault to burn, and CDPVault always burns from `msg.sender`. Transferring COMP does not transfer the sender's debt. Repayment consumes the caller's COMP and reduces their own debt; it does not restore work credits. Requests exceeding debt revert rather than silently clamping.

Anyone holding COMP may liquidate a position strictly below 150%. The caller repays an explicit positive amount no greater than the target debt and receives `floor(amount * 110 / 100)` IMD. This includes a 10% bonus rounded down to minor units. Liquidation reduces only the target's recorded collateral and debt. Self-liquidation is permitted. A request whose full payout exceeds that position's collateral reverts; no other user's collateral covers the difference. There is no bad-debt insurance or socialization mechanism. Partial liquidation need not fully restore health; future calls remain possible only while the position is unhealthy. Remaining collateral belongs to the borrower after debt is cleared.

Vault actions and mock-oracle credit changes reject zero amounts. ERC-20 operations retain normal zero-transfer behavior. Transfers have no fees or restrictions beyond standard balance, allowance, and zero-address checks. Dependencies are fixed after initialization. The supported collateral is the supplied MockIMD, not an arbitrary rebasing or fee-charging token; incoming exact-balance checks reject short deposits. Direct token donations are not credited to positions and cannot be recovered through an admin rescue function.

## Deployment and responsibilities

Target chain: **Ethereum Sepolia, chain ID 11155111**. The contracts do not enforce chain ID themselves. The approved operator is `miyagod.eth`, address `0x5167d014a056e43883e1bbea5530c3c0dc993281`, supplied by the workflow. **This release pins that explicit operator in `src/DeploymentConfig.sol`** for the deferred initialization path and the mock-faucet permissions. The named workflow operator, rather than the account executing CREATE/CREATE2, the transaction origin, or a policy owner argument, receives that authority. No constructor consumes a `$owner` argument. A different faucet operator requires a separately reviewed source build.

The token/vault/oracle dependency cycle can be closed in two ways. Both end with the same irreversible links and the same absence of administrative authority; they differ only in who closes the cycle.

**Mode A, self-contained (recommended for the constructor-only factory launch).** The factory deploys two contracts and makes no calls afterwards. CDPVault, given a zero `compToken` and a zero `oracle`, creates `CompToken(vault)` and `MockWorkOracle(vault)` from its own constructor. When the constructor returns, `comp.vault() == vault`, `vault.oracle() == oracle`, `oracle.vault() == vault`, and both `setVault` and `setOracle` already revert `AlreadyInitialized` for every caller, including the operator. Borrowing needs only the operator's normal faucet actions (mint IMD, grant rights).

| Step | Contract | Constructor arguments |
| --- | --- | --- |
| 1 | Deploy MockIMD | none |
| 2 | Deploy CDPVault | `($contract:MockIMD, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000)` |

The CompToken and MockWorkOracle addresses are read from `vault.compToken()` and `vault.oracle()`; both are also emitted during construction as `VaultSet` on the token and `OracleSet` on the vault. The frontend and the manifest reviewer take them from the vault rather than from the manifest. Test coverage: `test/FactoryDeployment.t.sol` deploys this way through CREATE and CREATE2 from an unrelated relayer and origin, then borrows, repays, and withdraws with no initialization call.

**Mode B, assembled (the workflow's literal deploy order).** Four deployments with zero links, then the approved operator's two one-time calls. This is the path for a deployer that can send transactions after construction; it is not usable by a factory that only executes constructors.

| Step | Contract or call | Constructor/call arguments |
| --- | --- | --- |
| 1 | Deploy MockIMD | none |
| 2 | Deploy CompToken | `(address(0))`; `vault()` initially zero |
| 3 | Deploy CDPVault | `(address(imd), address(comp), address(0))` |
| 4 | Deploy MockWorkOracle | `(address(vault))` |
| 5 | `comp.setVault` | `address(vault)` |
| 6 | `vault.setOracle` | `address(oracle)` |

Deploy `LaunchToken()` separately as the manifest's launch token, with no constructor arguments. It has no application dependencies or initialization calls. The manifest contributor must reference this artifact for the fixed-supply launch allocation. The service handles launch distribution according to policy; this source contribution does not generate `launch.json` or broadcast transactions.

Linking is validated before it is locked. `CompToken.setVault` (and a nonzero constructor vault other than the creating contract) requires a deployed target whose `compToken()` returns this token. `CDPVault.setOracle` (and a nonzero constructor oracle) requires a deployed target that answers `mintingRights(address)`; if the target also exposes `vault()`, as MockWorkOracle does, that value must be this vault, while a drop-in IWorkOracle without such a view is accepted. A rejected call reverts `InvalidVault` or `InvalidOracle` and leaves initialization available; only a successful call permanently erases the caller's authority. Every subsequent setter call reverts, including calls by the approved operator. A nonzero constructor oracle completes and locks oracle configuration immediately, so `setOracle` can never subsequently succeed. In self-contained mode a nonzero oracle is validated and locked instead of creating a mock.

Before opening the UI, the service checks both token references, `comp.vault() == vault`, `vault.oracle() == oracle`, `oracle.vault() == vault`, and that both mock `deployer()` values equal the approved operator. The ABI retains the name `deployer()` for compatibility; it reports the workflow operator, not the creating factory. The reciprocal checks above authenticate the links, not the implementation behind an address; choosing the correct artifacts remains the deployer's responsibility. Borrowing rejects unset oracle/token links. In mode B, deposits and debt-free withdrawals are possible before initialization; the frontend should wait until all links are verified.

After setup, **CompToken and CDPVault have no usable administrative authority**: no owner getter, ownership transfer, mint role setter, oracle replacement, pause, rescue, or upgrade function. The initialization selectors remain in the ABI but always revert after locking. MockIMD's approved operator intentionally retains `mint(address,uint256)`; MockWorkOracle's approved operator intentionally retains `grantRights(address,uint256)`. These permissions cannot be transferred. Only the immutable associated vault can consume rights. A later real oracle must implement IWorkOracle, but an existing initialized vault cannot be pointed at it: that change requires a new deployment and a separately reviewed migration.

Services handle source publication, attestation, admission, factory deployment, coordination of operator initialization and mock funding/credit grants, and frontend startup. Initialization and faucet transactions must be authorized by the approved operator; services cannot impersonate it or the factory. No transactions are broadcast by this project. The separate manifest assignment owns `launch.json`; it is not generated here. Independent review of source and the manifest remains a separate stage; this contributor's tests and [review notes](docs/REVIEW_NOTES.md) are not an independent audit.

## ABI exports

Frontend-ready ABI arrays live at `docs/abi/MockIMD.json`, `CompToken.json`, `IWorkOracle.json`, `MockWorkOracle.json`, and `CDPVault.json`. Regenerate with `python3 tools/export_abi.py`; check against the current build with `--check`. [ABI usage](docs/ABI.md) describes methods, events, units, and errors.

## Launch compatibility findings

The supplied generic launch floor requires a token with positive fixed genesis supply held by the factory. LaunchToken supplies that separate asset. CompToken retains the approved zero-genesis, elastic-supply behavior and must not be selected as the fixed-supply launch token. Manifest and source review must verify that these two distinct artifacts are linked to their intended roles.

The factory makes only constructor calls. A manifest that lists all four application contracts in the workflow order (mode B) leaves `comp.vault()` and `vault.oracle()` unset, so borrowing stays disabled until the operator's two calls, which no factory path performs. The manifest must therefore use mode A: list MockIMD and CDPVault with zero token and oracle arguments, and let the vault create and bind its CompToken and MockWorkOracle during construction. Nothing remains to initialize, the operator keeps only the two faucet functions, and the factory gains no application administration. The persistent CREATE/CREATE2 regression tests verify both modes, including faucet operation and borrowing. Source and manifest review still verify those concrete links; later service artifacts and on-chain outcomes are separate responsibilities.
