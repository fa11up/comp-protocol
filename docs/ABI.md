# ABI integration

The JSON files in `docs/abi/` contain complete Solidity ABI arrays, including constructor inputs, functions, events, and custom errors. All token, collateral, debt, and credit amounts are uint256 **minor units with 18 decimals**; `1 ether` in Solidity examples means 10^18 units, not an ETH payment. All constructors and state-changing methods are nonpayable. There is no payable fallback or receive function.

| Contract | Function | Caller and effect |
| --- | --- | --- |
| LaunchToken, MockIMD, CompToken | `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance` | Public ERC-20 views |
| LaunchToken, MockIMD, CompToken | `transfer(to, amount)`, `approve(spender, amount)`, `transferFrom(from, to, amount)` | Standard ERC-20 behavior; return bool |
| MockIMD | `deployer()` | Permanent faucet authority |
| MockIMD | `mint(account, amount)` | Approved workflow operator only; increases balance and supply |
| CompToken | `vault()` | Registered vault or zero before initialization |
| CompToken | `setVault(vault)` | Approved workflow operator, once, if constructed with a zero vault; requires a deployed vault whose `compToken()` is this token |
| CompToken | `mint(account, amount)`, `burn(account, amount)` | Registered vault only; burn does not spend allowance |
| IWorkOracle, MockWorkOracle | `mintingRights(account)` | Remaining spendable rights |
| IWorkOracle, MockWorkOracle | `consumeRights(account, amount)` | Associated vault only; reduces remaining rights |
| MockWorkOracle | `deployer()`, `vault()` | Immutable authority and associated consumer |
| MockWorkOracle | `grantRights(account, amount)` | Approved workflow operator only; adds to existing rights |
| ISwarmFeed, SwarmFeed, PriceFeed, NhiFeed | `latestValue()`, `isStale()`, `maxAge()` | Latest `(uint256 value, uint64 updatedAt)`, freshness, and immutable maximum age in seconds |
| SwarmFeed, PriceFeed, NhiFeed | `attester()`, `relayer()`, `attestationChainId()`, `attestationAnswerType()`, `reporter0()`, `reporter1()`, `reporter2()`, `quorum()`, `maxDeviationBps()` | Immutable attestation and reporter configuration |
| SwarmFeed, PriceFeed, NhiFeed | `ATTESTATION_TYPEHASH()`, `DOMAIN_SEPARATOR()` | EIP-712 type hash and immutable consumer domain |
| SwarmFeed, PriceFeed, NhiFeed | `round()`, `reportCount()`, `lastReportedRound(account)`, `usedRequests(requestId)`, `isReporter(account)` | Fallback round, replay, and reporter views |
| SwarmFeed, PriceFeed, NhiFeed | `submitAttestation(attestation, signature)` | Configured relayer, or anyone when zero, submits a fresh attestation signed by `attester()` with matching payload chain and answer type |
| SwarmFeed, PriceFeed, NhiFeed | `report(value)` | Allowlisted reporter submits one value per round; quorum publishes the median |
| CDPVault | `imdToken()`, `compToken()`, `oracle()`, `priceFeed()`, `nhiFeed()`, `spotFeed()` | Immutable linked contract addresses |
| CDPVault | `LIQUIDATION_BONUS_PERCENT()` | 10 |
| CDPVault | `maxDivergenceBps()`, `markerShareBps()`, `stabilityFeeBps()` | Source-pinned basis points: 500, 1000, and 0 respectively |
| CDPVault | `positions(account)` | Tuple `(collateral, debt)`; debt includes accrued unpaid stability fees |
| CDPVault | `liquidationMarks(account)` | Tuple `(markedAt, grace, marked, marker)`; times are seconds |
| CDPVault | `deployedAt()`, `debtIndex()`, `debtIndexOf(account)` | Deployment timestamp, current linear index scaled by 1e18, and account's last debt-change index |
| CDPVault | `debtOf(account)`, `stabilityFeeOf(account)` | Current principal plus unpaid fees, and current unpaid fees alone |
| CDPVault | `totalDebt()`, `debtCeiling()` | Outstanding minted principal and its unchanged borrowing cap; neither includes unpaid fees |
| CDPVault | `protocolBonusShareBps()` | Protocol share of the liquidation bonus; zero by default |
| CDPVault | `badDebtOf(account)`, `totalBadDebt()` | Current uncovered accrued debt, and recorded residual debt from liquidations exhausting collateral |
| CDPVault | `collateralRatio(account)` | Price-derived integer percent; uint256.max for no debt or unrepresentably large ratio |
| CDPVault | `minCR()`, `gracePeriod()`, `liquidationWindow()` | NHI-derived minimum ratio and grace, and the shorter primary/NHI feed maximum age |
| CDPVault | `totalWorkMinted()` | Cumulative COMP minted by consuming work rights |
| CDPVault | `totalFeesMinted()` | Cumulative paid stability fees minted to FEE_RECIPIENT |
| CDPVault | `depositCollateral(amount)` | Moves caller's approved IMD into their position |
| CDPVault | `withdrawCollateral(amount)` | Returns caller's IMD if debt is zero or the remaining position meets `minCR()` |
| CDPVault | `mintCOMP(amount)` | Increases caller's debt and mints COMP if the resulting position meets `minCR()`; consumes no work rights |
| CDPVault | `mintFromWork(amount)` | Consumes caller's work rights and mints COMP without collateral or debt |
| CDPVault | `repayCOMP(amount)` | Burns caller's COMP, pays unpaid fees first then principal, and mints paid fees to FEE_RECIPIENT; no approval and no rights refund |
| CDPVault | `markUnderwater(owner)` | Anyone may mark an unhealthy position and record themselves with its grace snapshot |
| CDPVault | `clearRecoveredMark(owner)` | Anyone may clear a healthy position's mark |
| CDPVault | `liquidate(owner, debtToRepay)` | Burns caller's COMP against accrued debt after grace, mints paid fees to FEE_RECIPIENT, and splits the IMD bonus among liquidator, marker, and protocol |

`LaunchToken()` takes no constructor arguments and mints exactly 10^27 minor units to its deployer. Its metadata is `COMP Launch` / `CPL` / 18 decimals. Its public functions are only the standard ERC-20 views, transfers, and approval; it has no mint/burn or administration API. Use `docs/abi/LaunchToken.json` for the launch asset and `docs/abi/CompToken.json` for the stablecoin borrowed from CDPVault.

The token and oracle constructor signatures are `MockIMD()`, `CompToken(address vault)`, and `MockWorkOracle(address vault)`. `CompToken(0x0)` defers the one-time `setVault`, while a nonzero vault is validated (or recognized as the creating contract) and locked at construction. MockIMD starts with zero supply and metadata `Identity MD` / `IMD`; CompToken starts with zero supply and metadata `Compute Money` / `COMP`. Neither has a configured supply cap. MockWorkOracle requires a deployed vault or its creating contract and permanently limits rights consumption to that address.

`CDPVault(address imdToken, address compToken, address oracle, address priceFeed, address nhiFeed, address spotFeed)` requires a deployed IMD token and three deployed, distinct feed contracts. The sixth address is the only new constructor argument; divergence, marker share, and stability fee come from `src/DeploymentConfig.sol`. Zero COMP creates a fresh `CompToken(address(this))`, immediately bound to the vault; a nonzero COMP must have code and differ from IMD. Any identical feed addresses revert `InvalidFeed`. Zero oracle creates and binds a fresh MockWorkOracle; a supplied oracle must answer `mintingRights(address)` and, if it exposes `vault()`, name this vault. An existing, uninitialized CompToken must separately authorize the vault through its reciprocal `setVault` check before borrowing or work minting can succeed.

With both COMP and oracle zero, construction closes both links: no post-deployment initialization transaction is needed or available, and `CompToken.setVault` reverts `AlreadyInitialized` for every caller from genesis. The oracle is immutable; this vault has no `setOracle` or parameter setter. The requester retains no initialization authority, and the operator retains only the MockIMD and MockWorkOracle test faucets. Feeds still require an accepted update through their configured reporter or attestation path before feed-dependent vault operations.

Deferred CompToken initialization and mock faucet authority is the explicit workflow operator `0x5167D014a056E43883e1BBEa5530c3c0dC993281`, pinned in `src/DeploymentConfig.sol`. The mock `deployer()` getters return that operator even when a factory or the vault creates the contracts. The factory and transaction origin gain no permissions.

`SwarmFeed` is abstract. `PriceFeed` and `NhiFeed` are concrete pass-through subclasses with no added state or logic. Each constructor takes `(address attester, address relayer, uint256 attestationChainId, uint8 attestationAnswerType, address reporter0, address reporter1, address reporter2, uint8 quorum, uint256 maxAge, uint256 maxDeviationBps)`, forwarding every argument unchanged. The attester must be nonzero; nonzero reporters must be distinct; quorum must be between one and the number of nonzero reporters; maxAge must be positive; and maxDeviationBps must be at most 10,000. A zero relayer permits anyone to submit an otherwise valid attestation; a nonzero relayer is the sole permitted submitter. No setter or administrator can change the configuration. Neither subclass adds application-specific value bounds. NhiFeed has no validated oracle question in this release: reporters supply its values, while the attestation path remains live but unused.

Feed values use 18 decimals. Before the first update, `latestValue()` returns `(0, 0)` and `isStale()` is true. A value is stale only when its age is greater than maxAge, so the exact age boundary is still fresh. Zero updates revert. While the previous value is fresh, each submitted report and accepted update must differ by at most `floor(previousValue * maxDeviationBps / 10000)`; once stale, the next update may re-anchor at any positive value. Reaching reporter quorum publishes the median (the floored mean for quorum two), dated at the oldest contributing report. An unfinished round expires after maxAge. A quorum-one reporter can complete multiple rounds in the same block; the deviation bound is per update, not per unit of time.

`submitAttestation` takes an `OracleAttestation` tuple in this exact order: `(bytes32 requestId, uint256 chainId, bytes32 questionHash, uint8 answerType, bytes answer, uint256 figure, uint64 fromBlock, uint64 toBlock, bytes32 blockHash, bytes32 panelJobId, uint64 issuedAt, uint64 expiresAt)`, followed by a 65-byte signature. The EIP-712 domain is `IdentityMD Oracle`, version `1`, with the deployment chain ID and the receiving feed's address, computed once in its constructor. Payload chainId and answerType must equal `attestationChainId()` and `attestationAnswerType()`; the payload data chain may differ from the consumer chain (for example, mainnet data consumed on Sepolia). requestId is consumed once per feed; issuedAt cannot be in the future, exceed expiresAt, precede the last accepted update, or be older than maxAge. Delivery after expiresAt is rejected. The feed publishes figure and uses signed issuedAt for freshness, then discards any unfinished reporter round.

The signed questionHash binds a changing pinned block window and is emitted with each accepted attestation; there is no immutable questionHash gate or getter. The contract cannot verify which question was answered. Once seeded and while the last value is fresh, the deviation guard bounds a wrong-question figure. A nonzero relayer covers the unseeded first value and stale re-anchors. The consumer domain prevents cross-feed replay but does not identify the question; a stable per-question identifier would remove the need for a relayer entirely.

The vault treats primary price as COMP per IMD scaled by 1e18. `collateralRatio` is `floor(collateral * price * 100 / (debt * 1e18))`, using accrued debt. Only NHI determines requirements: at or below `0.60e18`, minCR is 200% and grace is zero; at or above `0.85e18`, minCR is 150% and grace is six hours. Between these points, minCR is `150 + ceil((0.85e18 - nhi) * 50 / 0.25e18)` and grace is `floor((nhi - 0.60e18) * 21600 / 0.25e18)` seconds. These views read latest values without enforcing freshness. Borrowing, work minting, withdrawals with debt, marking, clearing recovered marks, and liquidation still require primary and NHI feeds fresh and primary price nonzero.

Borrowing, withdrawals with debt, marking, and liquidation additionally require a fresh, nonzero spot price with `abs(primary - spot) <= floor(primary * maxDivergenceBps / 10000)`. The exact boundary passes. The primary is a window average; spot only checks disagreement and never determines valuation. A pinned closing block and an attestation valid for its TTL let an attacker target a known block and use the signature later, motivating this independent sanity bound. Work minting and clearing recovered marks retain their original primary/NHI guards. Deposits, repayment, and debt-free withdrawals remain available with stale or diverging feeds.

The stability fee is an annual, immutable rate with a zero default. `debtIndex()` is `1e18 + floor((block.timestamp - deployedAt) * stabilityFeeBps * 1e18 / (365 days * 10000))`. Before borrowing, repayment, or liquidation changes debt, the vault checkpoints unpaid fees as `floor(principal * (debtIndex() - debtIndexOf(account)) / 1e18)` plus earlier unpaid fees, then records the current index. Fees do not themselves earn interest. Views compute the same accrual without changing the checkpoint; deposits, withdrawals, and marking do not capitalize fees. `positions(account)` preserves its two-value ABI but returns full accrued debt, as does `debtOf(account)`; `stabilityFeeOf(account)` returns only its unpaid fee component. `totalDebt()` and the existing debt ceiling continue to track minted principal.

Both repayment paths pay fees first and principal second. They burn the full requested COMP amount, mint the paid fee portion to FEE_RECIPIENT, and increase `totalFeesMinted()` by that portion. Unpaid fees create no token supply. Amounts above accrued debt still revert `ExcessRepayment`; zero-fee deployments perform the original burn without fee minting.

An active mark preserves its original grace snapshot and marker address. Liquidation is allowed from `markedAt + grace` through `markedAt + grace + liquidationWindow()`, inclusive, while the position remains unhealthy; after that the mark must be retaken and grace restarts. The window remains the shorter primary/NHI maximum age. Payout is exactly `floor(debtToRepay * 1.1e18 / price)` IMD minor units, and the position must cover the full payout. Successful borrowing and withdrawals clear marks; deposits, repayment, and liquidation clear them on observed recovery (or zero debt). Anyone can call `clearRecoveredMark` to record recovery from a feed change. An unobserved recovery followed by another fall does not reset grace within the mark's bounded lifetime.

Liquidation bonus is the full payout minus `floor(debtToRepay * 1e18 / price)`. Marker and protocol each receive their basis-point share of this same bonus, rounded down. The liquidator receives the remainder including principal; if the marker is the liquidator, their payments use one combined transfer. The sum of marker and protocol shares cannot exceed 10,000 basis points. Neither share increases the borrower's collateral loss. The existing `Liquidated` event reports total collateral seized, including all recipients' shares; the marker is available from `liquidationMarks` while the mark remains stored.

`badDebtOf(account)` measures accrued debt exceeding what collateral can cover at the current primary price, including the full 10% liquidation payout and its exact integer rounding. For positive collateral, repayable capacity is `ceil((collateral + 1) * price / 1.1e18) - 1`; uncovered debt is any excess above capacity. An exhausted position reports all remaining debt. This view does not enforce freshness. `totalBadDebt()` records residual accrued debt when liquidation exhausts collateral and refreshes that record during repayment of an exhausted position, including newly accrued fees. Depositing collateral does not erase the record; after a deposit, actual repayment reduces the historical residual only when remaining debt falls below it. The accumulator is a record at its last updates, not a continuously repriced sum of `badDebtOf`. These APIs provide measurement only: no insurance, debt forgiveness, or change to the full-payout guard.

Events:

- All three tokens emit standard `Transfer` and `Approval`; mint/burn use the zero-address convention. LaunchToken emits its only mint during construction.
- CompToken emits `VaultSet(vault)` with indexed vault once, during construction or the one-time `setVault`.
- MockWorkOracle emits `RightsGranted(account, amount)` and `RightsConsumed(account, amount)` with indexed account.
- SwarmFeed and both subclasses emit `ValueUpdated(value, updatedAt)`, `Reported(round, reporter, value)` with indexed round and reporter, and `AttestationAccepted(requestId, questionHash)` with indexed requestId and the accepted pinned-window hash in event data.
- CDPVault emits `OracleSet(oracle)`, `CollateralDeposited(account, amount)`, `CollateralWithdrawn(account, amount)`, `COMPMinted(account, amount)`, `WorkMinted(account, amount)`, and `COMPRepaid(account, amount)` with indexed addresses.
- `UnderwaterMarked(owner, markedAt, grace)` and `UnderwaterMarkCleared(owner)` index owner.
- `Liquidated(owner, liquidator, debtRepaid, collateralSeized)` indexes owner and liquidator. Actual payout is included, so consumers need not reconstruct rounded amounts.

Custom errors have no arguments unless indicated in the generated ABI. `Unauthorized` indicates a caller outside the permitted authority; `AlreadyInitialized` indicates permanently closed CompToken setup. Invalid contract addresses, and targets that fail the reciprocal-link checks, produce `InvalidToken`, `InvalidVault`, `InvalidOracle`, or `InvalidFeed`. A failed `setVault` does not consume initialization authority. `NotInitialized` means CompToken has not authorized this vault. MockWorkOracle additionally uses `InvalidAccount` for zero recipients, `ZeroAmount`, and `InsufficientRights`.

Feed errors are `InvalidConfiguration`, `UnauthorizedReporter`, `UnauthorizedRelayer`, `InvalidAttestationChain`, `InvalidAnswerType`, `AlreadyReported`, `ZeroValue`, `ExcessDeviation`, `InvalidSignature`, `InvalidTimestamp`, `ExpiredAttestation`, `StaleAttestation`, and `ReplayedAttestation`. InvalidSignature includes malformed length, high-s signatures, invalid v, and a signer other than the configured attester. Relayer, payload-chain and answer-type policy failures revert before consuming the request or updating the feed.

Vault operation errors are `ZeroAmount`, `InsufficientCollateral`, `InsufficientRights`, `UnsafeCollateralRatio`, `HealthyPosition`, `ExcessRepayment`, `UnexpectedCollateralReceived`, `StaleFeed`, `InvalidPrice`, `PositionNotMarked`, `GracePeriodNotElapsed`, `MarkExpired`, `UnderwaterPosition`, `DebtCeilingReached`, `PriceDivergence`, and `InvalidBonusShares`. PriceDivergence rejects a gap beyond the primary-relative bound; InvalidBonusShares rejects combined bonus shares above 10,000 basis points. UnexpectedCollateralReceived detects an unsupported collateral deposit whose balance increase differs from the requested amount. External token/oracle/feed reverts propagate; ERC-20 custom errors include balances and allowances. SafeERC20 false returns produce `SafeERC20FailedOperation(token)`. Reentry produces `ReentrancyGuardReentrantCall`. A reverted transaction rolls back position changes, work credits, token supply, and emitted events together.

Suggested frontend sequence: approve the desired IMD deposit, deposit, check feed freshness, divergence, and collateral headroom against `minCR()`, then borrow with `mintCOMP`. Work minting uses `mintFromWork` and available rights independently of collateral. On repayment, call repay directly from the indebted wallet and withdraw any newly available collateral. Show debt-free ratios as debt-free rather than rendering uint256.max as a percentage. Display primary and spot prices, their divergence, NHI, the effective minimum ratio, accrued debt and fees, total bad debt, and the stored grace countdown and mark expiry. Refresh balances, rights, feeds, and position after each confirmed transaction. Restrict the grant-rights panel to `MockWorkOracle.deployer()` and show Sepolia only.

To regenerate every committed ABI export from the repository root, build sources explicitly. The unchanged `tools/export_abi.py` lists only the original six contracts; this uses its JSON formatting for all current exports. The vault ABI includes the sixth constructor address, appended marker field, and new accounting views:

```sh
forge build src --offline --out test/scratch/abi-out --cache-path test/scratch/abi-cache
python3 - <<'PY'
import json
from pathlib import Path

for destination in sorted(Path("docs/abi").glob("*.json")):
    name = destination.stem
    artifact = Path("test/scratch/abi-out") / f"{name}.sol" / f"{name}.json"
    abi = json.loads(artifact.read_text())["abi"]
    destination.write_text(json.dumps(abi, indent=2) + "\n")
PY
```
