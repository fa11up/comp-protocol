// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Explicit operator named in the approved Sepolia workflow (miyagod.eth).
/// Preserves the specified constructor signatures while allowing a constructor-only factory
/// to deploy. The operator completes the two one-time links and operates the mock faucets.
/// This release is specific to that operator; neither msg.sender nor tx.origin selects authority.
address constant APPROVED_OPERATOR = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;

/// @dev Receives the protocol's share of liquidation bonuses, when a deployment turns that share on.
/// Pinned in source for the same reason APPROVED_OPERATOR is: a manifest placeholder resolved to the
/// platform's own address on launch 519, not to the requester.
/// MUST NOT be the feed's reporter or relayer — whoever sets the price would otherwise profit from
/// liquidations they can trigger. Nothing on chain enforces that; see SPEC-ceiling-and-fee.md.
/// Read only by the plain CDPVault: ParameterizedVault creates a Treasury in its constructor and
/// routes both the bonus share and the minted stability fees there instead (`feeRecipient()`).
address constant FEE_RECIPIENT = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;

/// @dev Chainlink ETH/USD on Sepolia (8 decimals), the USD leg of UsdPriceFeed. A price authority, so
/// it is pinned in source like the attester and the feeds rather than supplied by a deployer.
address constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

/// @dev Oldest ETH/USD answer UsdPriceFeed treats as fresh. Chainlink publishes mainnet ETH/USD at least
/// hourly and whenever it moves 0.5%, so while the aggregator is healthy its answer is never more than
/// 0.5% off. Two hours is that heartbeat plus one missed round: a single late update does not halt the
/// vault, and a dead aggregator halts it within two hours rather than a day. It matches the one-hour
/// IMD/ETH lifetime (PRICE_MAX_AGE) instead of outliving it 24 times. A stale USD price makes the
/// collateral price stale, so it halts every price-dependent action — draw, priced free, cash, bark and
/// bite included — until Chainlink answers again; a reserve asset it prices counts for nothing meanwhile.
uint256 constant ETH_USD_MAX_AGE = 2 hours;

/// @dev Feed lifetimes, the constructor arguments every deployment script passes. A price older than an
/// hour refuses every price-dependent action until someone buys a fresh one: on demand, by the caller
/// (OracleAsker.askPaid) or by the Treasury when IMD's pool drifts (OracleAsker.ask). The protocol does
/// NOT keep prices fresh on a clock — 24 updates a day per feed is ~$37k a year — so a quiet market is
/// paused for borrowing between updates, never mispriced. NHI moves slowly and stays daily, and
/// Treasury-funded staleness asks apply to it alone. `tail()` is the shorter of PRICE and NHI.
uint256 constant PRICE_MAX_AGE = 1 hours;
uint256 constant SPOT_MAX_AGE = 1 hours;
uint256 constant NHI_MAX_AGE = 1 days;

// ---------------------------------------------------------------------------------------------
// Feed authority and attestation policy — pinned in source, never supplied by a deployer.
// ---------------------------------------------------------------------------------------------
// Launch 519 is the whole argument for this block. Every authority the source named landed on us
// (APPROVED_OPERATOR above; MockWorkOracle's deployer). Every authority a template supplied landed
// wrong, and silently:
//   * launch.json's `$owner` resolved to the platform's policy owner, not the requester, so the
//     feeds' `relayer` and `reporter0` were addresses we hold no key for.
//   * `attestationAnswerType` arrived as 1 (`address`) where a uint256 price attestation carries 3.
// Each of those is immutable, so 519's feeds are permanently inert. Nothing reverted and nothing
// on chain pointed at the cause; the loss only surfaced when the first seed transaction failed.
//
// PriceFeed and NhiFeed therefore accept NO authority and NO attestation policy as constructor
// arguments. There is no slot for a template to fill in, correctly or otherwise, and a deploy
// script that tries to pass one does not compile. Changing any of these is a source edit: it shows
// up in a diff, goes through review, and is checked against chain state by DeployProtocol.verify().

/// @dev Signer of every IdentityMD oracle attestation, recovered from live attestation signatures.
address constant ORACLE_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

/// @dev Sole address permitted to submit an attestation. Zero would mean permissionless relay,
/// which SwarmFeed.submitAttestation documents as unsafe for as long as questionHash binds a
/// moving block window and so cannot identify WHICH question an attestation answers.
///
/// This is SwarmRelay, deployed to Sepolia at the address below, NOT an externally owned account.
/// Anyone may call it, so the trust is the same as a zero relayer, but the nonzero-relayer guarantee
/// survives and two things become possible that a key cannot do: several feeds update in one
/// transaction, and a keeper bundles an update with the action it enables.
///
/// ORDER MATTERS. This is a compile-time constant, so the relay must already exist before the feeds
/// are compiled — a launch manifest cannot deploy the relay and then build feeds against it. Deploy
/// the relay, write its address here, then deploy the feeds.
///
/// The feeds live on Sepolia TODAY still pin the old W0 account, because their bytecode was fixed at
/// deployment. Only a redeployment picks this up. deploy/relay-attestation.js therefore still relays
/// straight to those feeds, and must go through the relay once they are replaced.
address constant ATTESTATION_RELAYER = 0xe36FFc2688Bf5974f2187AC9086492e372926D40;

// THE REPORTER FALLBACK IS GONE. `SwarmFeed.report()` let an allowlisted key set a feed's value
// directly, bounded by maxDeviationBps only while the current value was fresh; past maxAge the bound
// lifted and the next value re-anchored the band to anything. On mainnet that is one key holding
// custody of every position. Attestations are now the only way a value is ever set, and the constants
// FEED_REPORTER_0/1/2 and FEED_QUORUM no longer exist.

/// @dev Answer-type enum of the signed payload, recovered empirically against live signatures:
/// bool=0, address=1, bytes32=2, uint256=3. This is the field 519 was handed as 1.
uint8 constant ATTESTATION_ANSWER_TYPE = 3;

/// @dev The chain a question is asked ABOUT — the payload's `chainId`, which our price and NHI
/// questions both read from Ethereum mainnet because the oracle serves no Sepolia RPC. It is NOT
/// the chain the feed runs on: the EIP-712 domain uses block.chainid and address(this), and
/// SwarmFeed's constructor derives that itself.
uint256 constant ATTESTATION_CHAIN_ID = 1;

// ---------------------------------------------------------------------------------------------
// Vault risk parameters for the unattended-liquidation increment — pinned for the same reason.
// ---------------------------------------------------------------------------------------------
// These were going to be constructor words supplied by a launch manifest. They are constants
// instead, so the manifest's only remaining degree of freedom over the vault is the spot feed's
// address, which cannot be a constant because it is deployed in the same run. None of them carries
// a setter: an immutable with no setter and a constant with no setter are equally unchangeable, and
// a constant cannot be mis-supplied at deployment. Turning the stability fee on is a source edit
// and a redeployment, which is the intent — "do not add any authority to change the rate".

/// @dev Maximum tolerated gap between the primary average price and the spot price, in basis points
/// of the primary. Beyond this the two feeds disagree and every price-dependent action is refused.
uint256 constant SKEW_BPS = 500;

/// @dev Share of the liquidation bonus paid to whoever marked the position underwater, in basis
/// points of the bonus. Never taken from principal: the borrower's loss is identical at zero.
uint256 constant CHIP_BPS = 1_000;

/// @dev The protocol's own share of the same bonus, in basis points of it, paid to FEE_RECIPIENT.
/// This is revenue WITHOUT the protocol supplying capital or becoming the liquidator: the keeper
/// still brings the stablecoin, takes the inventory risk on seized collateral and pays the gas.
/// At 1000 with a 20% bonus the protocol takes 2% of the debt repaid and a keeper who did not mark
/// keeps 16%. The former 3333 left a keeper 5.67%, below one sale's loss in IMD's pool for any
/// liquidation over ~$100k — and liquidation happening is a solvency property, not a nicety.
/// The vault refuses any value above 10_000 minus CHIP_BPS. The borrower's loss is
/// unchanged at any setting: this divides the existing bonus rather than seizing more collateral.
uint256 constant CUT_BPS = 1_000;

/// @dev Total imdUSD principal the vault may mint at launch, before governance raises it: $1M. IMD's
/// pool (~$2.3M a side, full range, 1% fee) absorbs a profitable liquidation of ~$290k at a time, so
/// debt is kept within what liquidators can actually clear (docs/PARAMETERS-2026-10-05.md).
uint256 constant LINE = 1_000_000e18;

/// @dev Each redemption raises the fee's base by redeemed / supply / this. At 2, redeeming 10% of
/// supply at once costs 5.0% (the cap); at the former 4 it cost 3%. Chosen 2026-10-05.
uint256 constant REDEMPTION_DIVISOR = 2;

/// @dev The operator stream at launch: who the Treasury pays imdUSD to, and how much per UTC day.
/// Off until governance proposes a payee and an amount (48-hour timelock, capped in Parameters).
address constant STREAM_PAYEE = address(0);
uint256 constant STREAM_PER_DAY = 0;

/// @dev Annual stability fee on open debt, in basis points. 444 at launch (2026-10-05). It accrues through the `chi` index from
/// that index's last checkpoint (`indexCheckpointAt`), so a governed change in `duty` applies from the
/// moment it lands. The base vault reads this constant; ParameterizedVault reads `duty()` instead.
uint256 constant DUTY_BPS = 444;

/// @dev The ratio term of the work-minting ceiling, in basis points of collateral-backed debt:
/// earnLine = reserveValueUsd + totalDebt * EARN_MAT_BPS / 10000. Section 3 of
/// docs/COMPUTE-BACKING-DESIGN.md derives the bound: backing stays above one for every reserve size
/// exactly when this ratio is below mat - 1, which is 5000 at the loosest NHI. 2500 is half that
/// cliff, 120% worst-case backing with an empty reserve. Parameters refuses any proposal above
/// MAX_EARN_MAT_BPS, which is also 2500, so governance can lower it and never raise it past here.
uint256 constant EARN_MAT_BPS = 2_500;

// The ERC-8004 adapter that answers who controls an agent. IdentityRegistry.ownerOf resolves to it,
// and isController(agentId, account) answers control by ownership of the identity NFT.
//
// THIS REPLACED TWO PINNED CONSTANTS, and the replacement is the point. The work oracle used to name
// one agentId and one claimant in source, which made the compute channel a private faucet: a protocol
// that mints for its author's own seat is not a compute-backed currency. Asking the registry instead
// means every agent's controller claims their own credit, a sale of the identity NFT reassigns it with
// no action from us, and no address is privileged anywhere in this file.
//
// MAINNET ONLY. The adapter lives at this address on Ethereum mainnet and has no Sepolia deployment,
// so on a testnet `isController` is unreachable and no claim can succeed. The compute channel is
// therefore inert on testnet, which is the honest state rather than a gap.
address constant ERC8004_ADAPTER = 0xde152AfB7db5373F34876E1499fbD893A82dD336;

// imdUSD earned per accepted task, 1e18-scaled. Governed through `Parameters`, hard-bounded there at one
// imdUSD per task; the work ceiling binds on top, so a claim is bounded twice -- by what was earned and
// by what backs the protocol.
// ZERO AT LAUNCH: minting from work stays off until the upstream integration is complete (decided
// 2026-10-05). Rights are tasks x wage, so no task earns any, and SwarmWorkOracle.claim refuses while
// the wage is zero so no agent's tasks are spent for nothing. Governance turns it on by proposing a
// wage behind the 48-hour timelock. Raising it also switches on the lagged backing that closes audit
// finding D1 (CDPVault.laggedNow), built in and tracked from deployment.
uint256 constant WAGE_WAD = 0;

// The pre-deployed WorkOracleFactory, and the sentinel a vault passes as its oracle to ask for a real
// attested work oracle from it.
// ORDER MATTERS, as it does for ATTESTATION_RELAYER: the factory must exist before a vault that asks
// for one. The sentinel is EXPLICIT rather than zero for the reason the collateral sentinel is: zero
// is what an unset manifest field looks like, and a vault that quietly fell back to the grantRights
// faucet because a constant was mistyped would be the $owner bug that bricked launch 519 all over
// again. Zero still means the faucet, which every test and the testnet manifest want; the sentinel
// means the real oracle, and reverts rather than downgrading if the factory is not there.
// NOT YET DEPLOYED. This is a placeholder, and the sentinel path reverts while it has no code, so a
// vault asking for a real work oracle cannot be deployed until DeployPrereqs puts the factory on
// chain and this line names it. Deliberately not the zero address: zero is indistinguishable from an
// unset field, and a nonzero placeholder with no code fails exactly as loudly while being something
// a test can etch over.
address constant WORK_ORACLE_FACTORY = 0x0000000000000000000000000000000000000f05;

/// @dev The contract every ParameterizedVault creates its Treasury through, for the same EIP-3860
/// reason as WORK_ORACLE_FACTORY. Holds nothing and has no authority: the Treasury it creates serves
/// its caller. A deployment prerequisite with no dependencies, so its CREATE2 address is computable
/// up front. NOT YET DEPLOYED: a placeholder; a vault cannot be constructed until it has code.
address constant TREASURY_FACTORY = 0x0000000000000000000000000000000000000f09;
address constant WORK_ORACLE_SENTINEL = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

// How long an attested work tally stays usable. A day, matching the daily cadence of the receipts the
// tally is read from: a feed asked for a figure that is published once a day should not demand one
// more often than it exists. It sets when the feed's latest tally reads stale; claims against an accepted
// root are NOT gated on it (deferred with minting from work, which is off at launch: see WAGE_WAD).
uint256 constant WORK_ORACLE_MAX_AGE = 1 days;

// --- The oracle budget: price updates bought on chain through the Intake, paid from the Treasury ---
//
// The Intake (upstream Identity-md/protocol PR #66) sells swarm work for one transaction and calls back
// with the result. OracleAsker buys this protocol's feed updates through it and hands each attestation
// to SwarmRelay, so the feeds keep their single relayer and keepers keep relayAndBite. The Treasury
// streams it IMD, unwrapped from its sIMD, under a daily budget governed through Parameters.
// NOT YET DEPLOYED: INTAKE and ORACLE_ASKER are placeholders with no code. The asker refuses to be
// built against an Intake with no code, and fundOracle refuses to send to an asker with no code, so a
// placeholder fails loudly instead of streaming IMD into an empty address.
address constant INTAKE = 0x0000000000000000000000000000000000000F06;
address constant ORACLE_ASKER = 0x0000000000000000000000000000000000000f07;
// The Intake's action id: the action, an at sign and its version, right-padded to 32 bytes.
bytes32 constant ORACLE_ACTION = "oracle.request@oracle-1";
// The plane's mainnet ProjectFactory: the only contract the Treasury will ever ask to move a launch's
// LP-fee share (`handOffLaunchFees`). Pinned (internal audit, 2026-10-06, low) so the reserve-holding
// contract never makes an external call to an address chosen at call time. The custom-token launch whose
// requester the Treasury becomes must go through this factory; a successor factory needs a source change.
address constant LAUNCH_FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
// IMD's deepest market, read on chain to decide whether a feed has drifted: the Uniswap v4 PoolManager
// and the native-ETH/IMD pool. MAINNET ONLY; on a testnet the drift trigger reads as "no drift".
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
bytes32 constant IMD_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
// IMD the Treasury may stream to the asker per UTC day, and the hard cap governance can never exceed.
// 15 IMD: the worst day in 50 days of simulated history under the launch trigger (median 2), see
// docs/oracle-guards/ORACLE-GUARDS-2026-10-05.md. Exceeding it only defers asks to the next UTC day.
uint256 constant ORACLE_BUDGET_PER_DAY = 15 ether;
uint256 constant MAX_ORACLE_BUDGET_PER_DAY = 100 ether;
// The asker's anti-spam policy. A feed may be paid for at most once per ASK_MIN_INTERVAL, never while
// a request for it is in flight (until ASK_TIMEOUT), and never above ASK_MAX_PRICE IMD per request. A
// drift must be armed and still present ARM_DELAY_BLOCKS later, within ARM_WINDOW_BLOCKS, so a pool
// pushed off-price and back inside one transaction cannot trigger a paid update (two pushes five blocks
// apart can; accepted, see OracleAsker). A staleness ask needs
// no arming: it is allowed once a value is STALE_AT_BPS of the way to its maxAge.
uint256 constant ASK_MIN_INTERVAL = 10 minutes;
uint256 constant ASK_TIMEOUT = 2 hours;
uint256 constant ASK_MAX_PRICE = 1 ether;
uint256 constant ARM_DELAY_BLOCKS = 5;
uint256 constant ARM_WINDOW_BLOCKS = 100;
uint256 constant STALE_AT_BPS = 7_500;
// A feed whose allowance has widened with staleness to this many basis points (a value that far from
// its anchor would now be accepted) is refreshed by the Treasury whatever its trigger policy, so the
// allowance is reset for one request before a single purchase could re-anchor the price far from the
// market (final review 2026-10-07, high + medium). 6,000 at a 2,000 bps cap is nine lifetimes of
// silence. The keeper does the same with its own IMD when the Treasury cannot pay.
uint256 constant WIDE_ALLOWANCE_BPS = 6_000;
// The drift that justifies a Treasury-paid update, as a share (bps) of the feed's own deviation cap, and
// DIFFERENT BY DIRECTION. A fall (pool below the feed) over-values collateral — over-borrowing, late
// liquidation — so it is bought early, at a quarter of the cap (5% at a 20% cap). A rise only
// under-values collateral, which limits borrowing and endangers no one, so the Treasury NEVER pays for
// one (zero = off): whoever wants the borrowing room buys the update (OracleAsker.askPaid). Measured on
// 50 days of IMD history (docs/oracle-guards/): against the former symmetric half-cap trigger this cuts
// the worst over-valuation from 21% to 9.0% and the cost from 3.9 to 2.2 IMD a day; paying for rises at
// the full cap bought nothing but refusals (a rise past the cap on a fresh feed is refused).
uint256 constant DRIFT_FALL_TRIGGER_OF_CAP_BPS = 2_500;
uint256 constant DRIFT_RISE_TRIGGER_OF_CAP_BPS = 0;
