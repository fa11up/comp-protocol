# CDPVault increment: implementation and local checks

The vault adds a sixth constructor address, `spotFeed`, and reads all three new scalars from the unchanged `DeploymentConfig.sol`. Primary-price valuation, the NHI curve, snapshotted grace, mark expiry, the full liquidation payout requirement, and the existing ceiling and protocol-share hooks remain. Debt-bearing withdrawals also check divergence; repayment and debt-free withdrawal remain available during disagreement. No feed, token, production configuration, or manifest was changed.

The marker is preserved with an active mark and receives its configured share of the existing bonus. Protocol and marker cuts cannot consume principal or increase collateral seized. A common marker/liquidator receives one combined collateral transfer.

Fees accrue linearly on borrowed principal using the deployment index delta, without interest on unpaid fees. Debt views and solvency checks include fees; debt-changing operations checkpoint them. Both repayment paths burn the entire payment and mint only its paid fee component to `FEE_RECIPIENT`. `totalDebt` continues to measure minted principal for the existing ceiling.

The workflow's literal supply equation cannot hold for accrued debt: before a fee is paid, debt increases but token supply does not. The corrected equation, including cumulative fees minted and subtracting cumulative fees accrued, is stated in `mintFromWork` NatSpec. The tests check its equivalent principal-based invariant. No fee is minted just because time passes.

`badDebtOf` accounts for the exact integer liquidation payout, including its bonus. `totalBadDebt` records residual obligations when collateral is exhausted; it is not a continuously repriced aggregate. Repayment of an exhausted position includes newly accrued fees in that record. Depositing collateral cannot hide a recorded residual. There is no forgiveness or insurance, and the existing insufficient-collateral revert remains.

## Reproducible checks

Use the existing vendored dependencies, Foundry, Python 3, and locally installed Solidity 0.8.26. No network or new package is needed:

```sh
python3 script/checks/check_vault.py
forge build src script/DeployComp.s.sol script/SeedAndSmoke.s.sol --offline \
  --out test/scratch/build-out --cache-path test/scratch/build-cache
```

The runner uses the shipped configuration first. It then makes isolated copies under `test/scratch` for a 10% annual stability fee and a zero marker share. Production constants remain unchanged. Tests are delivered under `script/checks` because the assignment excludes ordinary `test/` edits; scratch files are disposable.

Results observed locally:

| Check | Result |
| --- | --- |
| Shipped configuration | 21 passed; two nonzero-fee tests skipped intentionally |
| 10% fee scratch variant | 7 passed, including both previously skipped cases |
| Zero marker-share scratch variant | 5 passed |
| Bad-debt payout boundary fuzz | 256 cases passed in the shipped suite |
| Source and deployment scripts | Offline compilation passed |
| CDPVault deployed runtime | 10,700 bytes; no DELEGATECALL, CALLCODE, or SELFDESTRUCT at opcode boundaries |

Coverage includes primary-relative divergence at either exact boundary and one unit beyond, full-width prices, stale/zero spot, borrower exits, marker preservation/expiry, combined transfers, payout conservation, bonus-share bounds, linear fees, fee-first payments, fee-aware health/liquidation, principal ceiling headroom, shortfall rounding, and residual persistence.

A separate scratch copy of the original suite passed **160 tests, zero failures, one expected off-fork skip**. Its only adaptations were the new constructor/mark-getter interfaces, a distinct mirror of the primary feed for legacy fixtures, and a scratch-only zero marker share to isolate the old fee-zero behavior. Existing assertions were retained, including the two invariant suites: 40,960 calls with zero reverts. These adaptations are verification scaffolding, not submitted replacements for the legacy tests.

A separate local read-only review examined the source changes and checked the inverse payout formula against 46,550 small integer cases. Findings about rounded shortfalls and erasing residual records through recapitalization were repaired before the final tests. These local checks are evidence, not an independent certification.

## Remaining integration findings outside this contribution

- Plain `forge build` still encounters five-argument vault constructors and three-value mark getters in the original tests. Changing those tests is forbidden by this assignment's write scope; the required constructor change cannot preserve their compile-time arity. Source and deployment scripts compile, and the delivered isolated suite exercises the new interface.
- `launch.json` still contains obsolete ten-argument feed constructors and the five-argument vault constructor. The manifest assignment must use the accepted source, add the separately deployed spot feed, and append its reference to the vault. This contribution does not edit the manifest or infer policy approval.
- Unrelated inherited feed prose in `docs/ABI.md` still describes old constructor and attestation formats. Only the vault integration sections were updated here; feed logic and authority constants remain untouched.

`docs/abi/CDPVault.json` was regenerated from the compiled vault. No other contract ABI changed.
