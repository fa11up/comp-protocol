// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwarmFeed} from "./SwarmFeed.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {
    ORACLE_ATTESTER,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    FEED_REPORTER_0,
    FEED_REPORTER_1,
    FEED_REPORTER_2,
    FEED_QUORUM,
    WORK_AGENT_ID,
    WORK_CLAIMANT,
    COMP_PER_TASK_WAD,
    WORK_ORACLE_FACTORY
} from "./DeploymentConfig.sol";

/// @notice Minting rights earned from attested swarm work, replacing the `grantRights` faucet.
/// @dev It EXTENDS SwarmFeed rather than reimplementing it, which is the whole design. Attestation
/// verification, the attester signature, replay protection, the panel floors, freshness and question
/// binding are the code already audited for the three price feeds, and are not written twice. What is
/// added here is only the accounting that turns a count into rights.
///
/// WHICH AGENT IS NOT A FIELD. The agentId and the claimant sit in the question TEXT, so both are
/// inside the question document `questionPolicy` pins and `_requireQuestion` recomputes. An
/// attestation about a different agent, or one naming a different claimant, fails the question check
/// with no agent field and no extra machinery. That is the reason to build this on SwarmFeed.
///
/// WHAT THE FIGURE PROVES, stated here rather than implied away. It is the cumulative count of
/// distinct accepted oracle jobs in the control plane's own daily receipts, attested by a panel that
/// read them. Those receipts are committed on chain through the receipt `documentHash` that
/// `WorkRegistry.recordWork` writes, and archived on IPFS, so the panel is reading frozen bytes
/// rather than a live mutable counter — which is why this question carries no tolerance band. But
/// this contract cannot verify that commitment itself: `documentHash` is keccak over a multi-megabyte
/// canonical document and the on-chain event carries no agent root, so the attestation is still the
/// bridge. It is evidence that the plane published the work, not proof the work happened.
///
/// ERC-8004 is not a usable alternative and was measured, not assumed: roughly 6% of swarm work
/// reaches the reputation registry, nothing since 2026-09-29, and this agent has never appeared at
/// all, because oracle reviews were dropped from the registry for being 99% of the writer's gas.
/// `getSummary` would return zero.
///
/// THE REPORTER FALLBACK IS STILL HERE, and cannot be removed: SwarmFeed requires at least one
/// reporter with a quorum of at least one. On Sepolia that reporter is the same source constant the
/// price feeds use. It is the same testnet affordance, stated plainly rather than hidden.
contract SwarmWorkOracle is SwarmFeed, IWorkOracle {
    error InvalidVault();
    error Unauthorized();
    error InvalidAccount();
    error ZeroAmount();
    error InsufficientRights();

    event RightsConsumed(address indexed account, uint256 amount, uint256 creditedTasks);

    /// @notice The agent whose work this oracle credits, and the only address that may claim it.
    uint256 public constant AGENT_ID = WORK_AGENT_ID;
    address public constant CLAIMANT = WORK_CLAIMANT;

    /// @notice The only consumer of rights.
    address public immutable vault;

    /// @notice The task count rights have already been computed against, never lowered.
    /// @dev The high-water mark. A later attestation reporting a LOWER count must not claw back
    /// rights already consumed, and the figure can move down for ordinary reasons — the feed can go
    /// stale and re-anchor, and a receipt only lists agents who worked that day. Pinning the count at
    /// the moment of consumption makes the accounting monotone without anyone having to call a poke.
    uint256 public creditedTasks;

    /// @notice COMP already minted against work, in wei.
    uint256 public consumedRights;

    /// @notice COMP credited for the tasks up to `creditedTasks`, priced at the rate in force when
    /// each of them was credited.
    /// @dev AUDIT FIX (round 5, `audit_judge` LOW: "a compPerTask change reprices work that was
    /// already credited and consumed, in both directions"). Entitlement used to be recomputed as
    /// `attestedTasks() * compPerTaskWad()` — a total derived from a FIXED ORIGIN at the CURRENT
    /// rate — so raising the rate re-granted rights for work already minted against, and cutting it
    /// made the total fall below what had been consumed.
    ///
    /// This is the same defect, in a new place, that `CDPVault.debtIndex()` had: an integral
    /// recomputed from its origin rather than accumulated. The rule written down after fixing that
    /// one — before making a rate governable, check whether the integral is recomputed from a fixed
    /// origin — was the rule this file broke. So the shape of the fix is the same: accumulate, and
    /// only ever price the SEGMENT that is new.
    uint256 public creditedRights;

    /// @param vault_ The only consumer. Three ways to be a legitimate one, and nothing else is:
    /// a vault that already has code; the vault creating this directly from its own constructor,
    /// which has no code yet and is recognised as the creator; or a vault mid-construction that
    /// reached here through `WorkOracleFactory`, which passes its OWN caller and so vouches for it.
    /// The factory clause grants nothing: anyone may call the factory, and what they get back is an
    /// oracle whose only consumer is themselves.
    constructor(address vault_, uint256 maxAge_)
        SwarmFeed(
            ORACLE_ATTESTER,
            ATTESTATION_RELAYER,
            ATTESTATION_CHAIN_ID,
            ATTESTATION_ANSWER_TYPE,
            FEED_REPORTER_0,
            FEED_REPORTER_1,
            FEED_REPORTER_2,
            FEED_QUORUM,
            maxAge_,
            // The loosest the base feed allows, and it is NOT unbounded: SwarmFeed caps this
            // argument at 10,000 bps, which permits at most a DOUBLING of the accepted figure per
            // update while the previous one is fresh. That is the honest description, and the
            // consequences both ways are worth stating.
            //   - In steady state it never binds: a seat with a four-figure cumulative count does
            //     not double in a day, and these receipts are published daily.
            //   - At bootstrap it does bind, because small numbers double easily — a jump from one
            //     accepted job to three is refused. The second attestation then carries it, and the
            //     bound lifts entirely once a value has aged past maxAge, which is one day here.
            // Keeping it rather than reaching for something looser is deliberate: it is one more
            // thing a wrong HIGH figure has to get past, and a wrong figure here mints COMP. The
            // real guards are question binding, the attester signature and the panel floors — the
            // pairing the HIGH finding of audit c71449d1 established — plus the work ceiling, which
            // asks whether backing exists regardless of what this feed says.
            10_000
        )
    {
        if (vault_ != msg.sender && vault_.code.length == 0 && msg.sender != WORK_ORACLE_FACTORY) {
            revert InvalidVault();
        }
        vault = vault_;
    }

    /// @notice The attested count rights are computed from: the live figure when fresh, never below
    /// what has already been credited.
    /// @dev A stale feed grants nothing NEW but does not retract what was consumed against.
    function attestedTasks() public view returns (uint256) {
        uint256 live = this.isStale() ? 0 : _latest();
        return live > creditedTasks ? live : creditedTasks;
    }

    /// @notice COMP earned by all attested work so far, in wei: what was credited at the rates it was
    /// credited at, plus the tasks since then at today's rate.
    /// @dev Two properties follow, and they are the whole point of accumulating rather than
    /// recomputing. A rate RISE cannot re-grant rights for work already consumed, because tasks at or
    /// below `creditedTasks` keep the price they were credited at. A rate CUT cannot take back
    /// anything, because `creditedRights` is only ever raised and is never below `consumedRights`.
    ///
    /// A change does reprice work that is attested but NOT YET consumed, and that is deliberate
    /// rather than overlooked: nobody but the governor can cause it, it travels under the 48-hour
    /// delay, and the claimant's remedy is to consume before it matures — the same exit the borrower
    /// has against a fee rise. Freezing it earlier would need a poke, and a permissionless poke would
    /// let a stranger deny the claimant a rate rise on work already attested.
    function accruedRights() public view returns (uint256) {
        uint256 tasks = attestedTasks();
        // attestedTasks() is the high-water mark, so this subtraction cannot underflow.
        return creditedRights + (tasks - creditedTasks) * compPerTaskWad();
    }

    /// @notice Accrued minus consumed, and zero for anyone but the claimant.
    /// @dev Never a stored balance that is topped up: a balance would have to be adjusted whenever
    /// the count moved, and the count can move either way.
    function mintingRights(address account) external view override returns (uint256) {
        if (account != CLAIMANT) return 0;
        uint256 accrued = accruedRights();
        uint256 spent = consumedRights;
        return accrued > spent ? accrued - spent : 0;
    }

    /// @notice COMP per accepted task, 1e18-scaled, from the vault's governed parameters if it has
    /// any and from the shipped constant otherwise.
    /// @dev Probed rather than required, so this oracle serves a plain CDPVault and a
    /// ParameterizedVault without a second artifact. The bound lives in Parameters, which refuses
    /// more than one COMP per task; a vault with no parameters cannot change the figure at all.
    function compPerTaskWad() public view returns (uint256) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("parameters()"));
        if (!ok || data.length != 32) return COMP_PER_TASK_WAD;
        address parameters = address(uint160(abi.decode(data, (uint256))));
        if (parameters == address(0)) return COMP_PER_TASK_WAD;
        (ok, data) = parameters.staticcall(abi.encodeWithSignature("compPerTaskWad()"));
        if (!ok || data.length != 32) return COMP_PER_TASK_WAD;
        return abi.decode(data, (uint256));
    }

    /// @notice Spend rights. Vault only.
    /// @dev Pins the high-water count AND the price of the work counted so far in the same call, so
    /// neither a later lower figure nor a later rate change can claw back what was spent or re-credit
    /// work already minted against.
    function consumeRights(address account, uint256 amount) external override {
        if (msg.sender != vault) revert Unauthorized();
        if (account != CLAIMANT) revert InvalidAccount();
        if (amount == 0) revert ZeroAmount();
        uint256 tasks = attestedTasks();
        uint256 accrued = creditedRights + (tasks - creditedTasks) * compPerTaskWad();
        uint256 spent = consumedRights;
        if (accrued < spent + amount) revert InsufficientRights();
        // Lock the price of everything counted so far, in the same call that spends against it. After
        // this, `creditedRights >= consumedRights` always, which is what makes a rate cut unable to
        // reach backwards.
        creditedTasks = tasks;
        creditedRights = accrued;
        consumedRights = spent + amount;
        emit RightsConsumed(account, amount, tasks);
    }

    function _latest() private view returns (uint256 value) {
        (value,) = this.latestValue();
    }

    /// @notice The exact question this oracle accepts answers to, and the window span it allows.
    /// @dev DERIVED, NEVER HAND-WRITTEN: emitted by `node oracle/question-prefix.mjs
    /// oracle/work-tally-quote.json`. Change one character of that payload's question or definitions
    /// and this must be regenerated, or the oracle refuses every attestation — the safe direction.
    ///
    /// BEFORE DEPLOYING: buy one request with that payload and run the generator with
    /// `--verify <requestId>`; it must print MATCH. Nothing has been bought with it yet, and it is
    /// not yet answerable — the control plane records no agent tally for this seat so far, so a panel
    /// must report inability. The contract is ready for the first receipt that carries one.
    ///
    /// The span bounds a 24-hour window on mainnet at roughly twelve seconds a block. The question
    /// does not name a day, so one constant serves every day and `lastToBlock` is what forces each
    /// attestation to cover newer ground than the last.
bytes internal constant QUESTION_PREFIX = hex"7b22616e7377657254797065223a2275696e74323536222c22636861696e4964223a312c22646566696e6974696f6e73223a7b2261726368697665223a224561636820726563656970742069732070696e6e656420746f204950465320616e6420697473206f776e20646f63756d656e742063617272696573206167656e74526f6f742c206167656e744c656166456e636f64696e6720616e64206167656e744c65617665732e20576865726520616e20656e747279206e616d65732061204349442c206665746368207468652072656365697074207468726f7567682068747470733a2f2f697066732e696d642e66756e206f7220616e79207075626c696320676174657761792c20636f6e6669726d2069747320736368656d61206973206964656e746974796d642d6f7261636c652d62617463682d76322c20616e6420636f6e6669726d20746865206167656e74526f6f7420696e2074686520617263686976656420646f63756d656e7420657175616c7320746865206167656e74526f6f7420696e207468652070726f6f662e205374617465207768696368206761746577617920616e7377657265642e222c22636f6e74726f6c6c6572223a224265666f726520616e73776572696e672c20766572696679206f6e20457468657265756d206d61696e6e65742074686174206973436f6e74726f6c6c65722835313435302c20307835313637443031346130353645343338383365314242456135353330633363306443393933323831292072657475726e732074727565206f6e207468652041646170746572383030342070726f7879206174203078646531353261666237646235333733663334383736653134393966626438393361383264643333362e205468617420616461707465722069732077686174204964656e7469747952656769737472792e6f776e65724f6628353134353029207265736f6c76657320746f2c20616e6420697420616e737765727320636f6e74726f6c206279206f776e657273686970206f6620746865206964656e74697479204e46542e2049662069742072657475726e732066616c73652c207265706f727420696e6162696c6974793a20746865207072656d697365206f6620746865207175657374696f6e2069732066616c736520616e64206e6f20636f756e742073686f756c6420626520676976656e2e222c2265786163746e657373223a22457665727920656e74727920697320612066726f7a656e20736e617073686f742c20736f206576657279206d656d626572206f6620746869732070616e656c207265616473206964656e746963616c20627974657320616e64206d757374207265706f727420746865206964656e746963616c20696e74656765722e20446f206e6f7420726f756e642c20646f206e6f7420617665726167652c20616e6420646f206e6f742061646a75737420746f7761726420616e6f74686572206d656d6265722e20496620796f757220766572696669636174696f6e20646973616772656573207769746820616e6f746865722072656164696e672c207265706f727420696e6162696c69747920726174686572207468616e2073706c697474696e672074686520646966666572656e63652e222c22666967757265223a2254686520616e73776572206973207468652047524541544553542076616c7565206f66207468652063756d756c6174697665206669656c64206163726f737320657665727920656e7472792074686174207061737365732074686520766572696669636174696f6e2062656c6f772e2063756d756c61746976652069732074686174206167656e74277320636f756e74206f662044495354494e4354206f7261636c65206a6f6273206576657220616363657074656420696e207265636f7264656420736e617073686f74733b206163636570746564206973206f6e6c792074686174206f6e6520646179277320636f756e7420616e64206d757374204e4f542062652073756d6d6564206163726f737320646179732c206265636175736520612072657669736564206a6f622072652d68617368657320696e746f2061206c617465722064617920616e6420776f756c6420626520636f756e7465642074776963652e222c227265667573616c223a225265706f727420696e6162696c69747920726174686572207468616e20737562737469747574696e6720616e6f7468657220736f757263652069662074686520726f7574652063616e6e6f7420626520726561636865642c206966206f7261636c654261746368657320697320656d7074792c206966206e6f20656e74727920737572766976657320766572696669636174696f6e2c206f72206966206973436f6e74726f6c6c65722072657475726e732066616c73652e20496e20706172746963756c617220616e20656d707479206c697374206d65616e732074686520636f6e74726f6c20706c616e6520686173207265636f72646564206e6f206f7261636c652072656365697074206361727279696e6720616e206167656e742074616c6c7920666f7220746869732073656174207965742c20616e642074686520636f727265637420616e73776572206973207468656e20696e6162696c6974792c204e4f54207a65726f2e20446f206e6f742066616c6c206261636b20746f20746865206163636570746564206669656c64206f66204745542068747470733a2f2f6170692e696d642e66756e2f737761726d3a20746861742069732061206c697665206d757461626c6520636f756e746572206f76657220616c6c20736b696c6c732c206974206973206e6f7420746865206669677572652074686973207175657374696f6e2061736b7320666f722c20616e64206974206973206e6f742076657269666961626c6520616761696e737420616e7920617263686976652e222c227363616c65223a2254686520616e73776572206973206120706c61696e2077686f6c65206e756d626572206f66206a6f62732c204e4f54207363616c6564206279203165313820616e64204e4f5420612073756d206f66206461696c7920636f756e74732e222c22736f75726365223a2252656164204745542068747470733a2f2f6170692e696d642e66756e2f6167656e74732f35313435302f6f7261636c652d7265636f726473206f6e63652c20617420616e737765722074696d652e204974206973207075626c696320616e64206e65656473206e6f206b65792e2049742072657475726e7320616e206f7261636c65426174636865732061727261793b206561636820656e747279206973206f6e6520555443206461792773206f7261636c65207265636569707420616e642063617272696573206461792c2061636365707465642c2063756d756c61746976652c206964656e7469747920616e6420612070726f6f66206f626a6563742e20466f6c6c6f77206e6578744265666f726520756e74696c20746865206c6973742069732065786861757374656420736f206e6f20646179206973206d69737365642e222c22766572696669636174696f6e223a22466f72206561636820656e7472792c2072656275696c6420697473206167656e74207472656520616e64207265667573652074686520656e74727920696620697420646f6573206e6f74207265636f6e7374727563742e205468652070726f6f66206f626a6563742063617272696573206167656e74526f6f7420616e642070726f6f662e20546865206c65616620656e636f64696e6720697320746865204f70656e5a657070656c696e205374616e646172644d65726b6c6554726565206f766572207468652074797065732075696e743235362c2075696e7433322c2075696e74363420696e2074686174206f726465722c20686f6c64696e67206167656e7449642c20616363657074656420616e642063756d756c61746976652c20736f2061206c6561662068617368206973206b656363616b323536286b656363616b323536286162692e656e636f64652875696e74323536206167656e7449642c2075696e7433322061636365707465642c2075696e7436342063756d756c617469766529292920616e6420696e7465726e616c2070616972732061726520636f6e636174656e6174656420696e20617363656e64696e672062797465206f726465722e20566572696679207468652070726f6f6620616761696e7374206167656e74526f6f742e20416e20656e7472792077686f73652070726f6f6620646f6573206e6f7420766572696679206973206e6f742065766964656e636520616e64206973206469736361726465642e227d2c2265766964656e6365223a2270616e656c222c227175657374696f6e223a2257686174206973207468652067726561746573742063756d756c617469766520636f756e74206f66206163636570746564206f7261636c65206a6f6273207265636f7264656420666f7220746865204964656e746974794d4420736561742077686f7365206167656e7449642069732035313435302c2074616b656e2066726f6d20746865206461696c79206f7261636c65207265636569707473207075626c697368656420627920746865204964656e746974794d4420636f6e74726f6c20706c616e6520616e6420766572696669656420616761696e737420746865697220495046532061726368697665732c20676976656e207468617420616464726573732030783531363744303134613035364534333838336531424245613535333063336330644339393332383120636f6e74726f6c732074686174206167656e74206f6e20457468657265756d206d61696e6e65743f222c2276223a312c2277696e646f77223a7b2266726f6d426c6f636b223a";

    function questionPolicy() internal pure override returns (bytes memory, uint64, uint64) {
        return (QUESTION_PREFIX, 5_000, 9_000);
    }
}
