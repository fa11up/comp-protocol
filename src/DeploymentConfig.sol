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

/// @dev Oldest ETH/USD answer UsdPriceFeed treats as fresh. Chainlink's Sepolia heartbeat is an hour,
/// but the IMD/ETH leg it is multiplied with is deployed with a one-day maxAge, so the composite is
/// bounded by its slower leg either way. A stale USD price only shrinks the work ceiling (a reserve
/// asset it prices counts for nothing); it never reaches a liquidation.
uint256 constant ETH_USD_MAX_AGE = 1 days;

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
/// At 3333 a keeper keeps roughly 70% more than the protocol takes, which leaves liquidation worth
/// doing on smaller positions — and liquidation happening is a solvency property, not a nicety.
/// The vault refuses any value above 10_000 minus CHIP_BPS. The borrower's loss is
/// unchanged at any setting: this divides the existing bonus rather than seizing more collateral.
uint256 constant CUT_BPS = 3_333;

/// @dev Annual stability fee on open debt, in basis points, accrued linearly from deployment.
/// Ships at zero so this increment changes no existing behaviour; a later deployment turns it on.
uint256 constant DUTY_BPS = 200;

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

// COMP earned per accepted task, 1e18-scaled. Governed through `Parameters`, hard-bounded there at one
// COMP per task. Shipped at a hundredth of a COMP; the work ceiling binds on top, so a claim is
// bounded twice -- by what was earned and by what backs the protocol.
uint256 constant WAGE_WAD = 0.01 ether;

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
address constant WORK_ORACLE_SENTINEL = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

// How long an attested work tally stays usable. A day, matching the daily cadence of the receipts the
// tally is read from: a feed asked for a figure that is published once a day should not demand one
// more often than it exists. A stale tally grants nothing NEW and retracts nothing already consumed.
uint256 constant WORK_ORACLE_MAX_AGE = 1 days;
