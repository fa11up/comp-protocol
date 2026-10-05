// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "./SwarmFeed.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {
    ORACLE_ATTESTER,
    ATTESTATION_RELAYER,
    ATTESTATION_CHAIN_ID,
    ATTESTATION_ANSWER_TYPE,
    ERC8004_ADAPTER,
    WAGE_WAD,
    WORK_ORACLE_FACTORY
} from "./DeploymentConfig.sol";

interface IAdapter8004 {
    function isController(uint256 agentId, address account) external view returns (bool);
}

/// @notice Minting rights earned from attested swarm work, for EVERY agent, replacing the faucet.
/// @dev It EXTENDS SwarmFeed, which is the whole design: the attester signature, replay protection,
/// panel floors, freshness and question binding are the code already audited for the three price
/// feeds and are not written twice. What is added here is the accounting that turns a published tally
/// into rights, and nothing else.
///
/// WHAT CHANGED, AND WHY IT HAD TO. The first version of this contract named one agentId and one
/// claimant as source constants. That made the compute channel a private faucet wearing a protocol's
/// clothes: a currency that mints for its author's own seat is not compute-backed, whatever the
/// attestation says. It also could not scale — a per-agent question costs 0.5 IMD per agent per
/// claim, so the whole swarm's work was unaffordable to put on chain one figure at a time.
///
/// THE FIGURE IS NOW A MERKLE ROOT COVERING EVERY AGENT. IdentityMD's daily oracle receipt carries a
/// second root over `["uint256","uint32","uint64"]` = (agentId, accepted, cumulative), which exists
/// because this protocol contributed it upstream (Identity-md/protocol PR #332, merged). One
/// attestation a day therefore carries the whole swarm's tally, and the cost stops scaling with the
/// number of agents: roughly 15 IMD a month for everyone rather than 0.5 IMD per agent per claim.
///
/// WHO MAY CLAIM IS ANSWERED BY THE REGISTRY, NOT BY US. `isController(agentId, msg.sender)` on the
/// ERC-8004 adapter answers control by ownership of the identity NFT, as a same-chain view call on
/// mainnet. So the claimant problem dissolves rather than being solved: no address is pinned, every
/// agent's controller claims their own credit, and a sale of the NFT reassigns future credit with no
/// action from anyone here.
///
/// WHAT IT STILL DOES NOT PROVE, stated here rather than implied away. The tally is the control
/// plane's own count of accepted oracle jobs, attested by a panel that read a receipt. Those receipts
/// are committed on chain through the `documentHash` that `WorkRegistry.recordWork` writes and pinned
/// to IPFS, so the panel reads frozen bytes rather than a mutable counter — which is why the question
/// carries no tolerance band. But this contract cannot verify that commitment itself: `documentHash`
/// is keccak over a multi-megabyte document and the on-chain event carries no root, so the attestation
/// remains the bridge. It is evidence that the plane published the work, not proof the work happened.
contract SwarmWorkOracle is SwarmFeed, IWorkOracle {
    error InvalidVault();
    error WorkMintingOff();
    error Unauthorized();
    error InvalidAccount();
    error ZeroAmount();
    error InsufficientRights();
    error UnknownRoot();
    error BadProof();
    error NotTheController();
    error NothingToClaim();

    event TallyClaimed(uint256 indexed agentId, address indexed controller, uint256 tasks, uint256 rights);
    event RightsConsumed(address indexed account, uint256 amount);
    event RootAccepted(bytes32 indexed root, uint64 toBlock);

    /// @notice The only consumer of rights.
    address public immutable vault;

    /// @notice Every tally root this feed has accepted, by value.
    /// @dev A SET rather than only the latest, and that is deliberate. A daily receipt lists only the
    /// agents that worked that day, so an agent idle today is absent from today's tree. Proving
    /// against an older root is always safe because `cumulative` is monotone: an old root can only
    /// under-credit, never over-credit, so nothing is gained by choosing one and nothing is lost by
    /// being absent from the newest.
    mapping(bytes32 root => bool accepted) public acceptedRoots;

    /// @notice The cumulative tally each agent has already been credited for.
    mapping(uint256 agentId => uint256 tasks) public creditedTasks;

    /// @notice Rights credited to an address, priced when they were claimed.
    /// @dev Priced AT CLAIM, which is what makes a later rate change unable to reach backwards. The
    /// predecessor recomputed entitlement as `tasks * rate` from a fixed origin, so raising the rate
    /// re-granted work already minted against and cutting it made the total fall below what had been
    /// consumed. Same defect as an accrual index recomputed from deployment; same shape of fix.
    mapping(address account => uint256 rights) public creditedRights;

    /// @notice imdUSD already minted against work, per address.
    mapping(address account => uint256 amount) public consumedRights;

    /// @param vault_ The only consumer. Three ways to be a legitimate one: a vault that already has
    /// code; the vault creating this from its own constructor, which has no code yet and is
    /// recognised as the creator; or a vault mid-construction that arrived through
    /// `WorkOracleFactory`, which passes its OWN caller and so vouches for it.
    constructor(address vault_, uint256 maxAge_)
        SwarmFeed(ORACLE_ATTESTER, ATTESTATION_RELAYER, ATTESTATION_CHAIN_ID, ATTESTATION_ANSWER_TYPE, maxAge_, 10_000)
    {
        if (vault_ != msg.sender && vault_.code.length == 0 && msg.sender != WORK_ORACLE_FACTORY) {
            revert InvalidVault();
        }
        vault = vault_;
    }

    /// @notice Record the tally root an attestation carried, so claims can prove against it.
    /// @dev Permissionless, and it has to be: the attestation was already verified by
    /// `submitAttestation` — signature, question, panel floors, freshness, replay — so this only
    /// copies an accepted figure into the set. Anyone may call it; a root that was never attested
    /// cannot be added, because `latestValue` is written only by the base.
    function recordRoot() external {
        (uint256 value,) = this.latestValue();
        if (value == 0) revert UnknownRoot();
        bytes32 root = bytes32(value);
        if (!acceptedRoots[root]) {
            acceptedRoots[root] = true;
            emit RootAccepted(root, lastToBlock);
        }
    }

    /// @notice THE DEVIATION BOUND DOES NOT APPLY TO A ROOT, and this is where that is said.
    /// @dev `SwarmFeed._checkValue` refuses a move larger than `maxDeviationBps` while the current
    /// value is fresh. That is the right guard for a PRICE, which moves continuously, so a large jump
    /// is evidence of a bad figure. A Merkle root has no magnitude: two consecutive honest roots are
    /// unrelated 256-bit numbers, so the bound would reject almost every truthful update.
    ///
    /// What is given up is real and is not hidden: the deviation bound is one of the things standing
    /// between a wrong figure and this feed's consumers. What remains is question binding, the
    /// attester signature and the panel floors — which per the HIGH finding of audit c71449d1 are
    /// what actually guard a feed, the deviation bound having been the fallback for a feed that pinned
    /// no question. This feed pins one. The zero check stays, because zero is not a tree.
    function _checkValue(uint256 value) internal view override {
        if (value == 0) revert ZeroValue();
    }

    /// @notice Claim an agent's published tally. Caller must control the agent.
    /// @param agentId The agent the leaf is about.
    /// @param accepted That day's count. Signed into the leaf but not used here; `cumulative` is.
    /// @param cumulative Distinct jobs ever accepted, which is the figure credit is computed from.
    /// @param proof The Merkle path to a root this feed has accepted.
    /// @dev Credit goes to `msg.sender`, who must be the agent's controller NOW. If the identity NFT
    /// has been sold, the new controller claims the untaken remainder and the previous one keeps what
    /// they already claimed — which is the right split, because credit is for work the controller
    /// held the agent through.
    function claim(uint256 agentId, uint32 accepted, uint64 cumulative, bytes32[] calldata proof, bytes32 root)
        external
        returns (uint256 rights)
    {
        if (!acceptedRoots[root]) revert UnknownRoot();
        // While the wage is zero (minting from work is off) a claim would mark the agent's tasks as
        // credited for nothing, and they could never earn once minting is switched on. Refused instead,
        // so every task stays claimable for the day the wage is set.
        if (wage() == 0) revert WorkMintingOff();
        if (!_controls(agentId, msg.sender)) revert NotTheController();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(agentId, accepted, cumulative))));
        if (!_verify(proof, root, leaf)) revert BadProof();

        uint256 already = creditedTasks[agentId];
        if (cumulative <= already) revert NothingToClaim();
        rights = (cumulative - already) * wage();
        creditedTasks[agentId] = cumulative;
        creditedRights[msg.sender] += rights;
        emit TallyClaimed(agentId, msg.sender, cumulative, rights);
    }

    /// @notice Claimed minus consumed.
    function mintingRights(address account) external view override returns (uint256) {
        uint256 credited = creditedRights[account];
        uint256 spent = consumedRights[account];
        return credited > spent ? credited - spent : 0;
    }

    /// @notice Spend rights. Vault only.
    function consumeRights(address account, uint256 amount) external override {
        if (msg.sender != vault) revert Unauthorized();
        if (account == address(0)) revert InvalidAccount();
        if (amount == 0) revert ZeroAmount();
        uint256 spent = consumedRights[account];
        if (creditedRights[account] < spent + amount) revert InsufficientRights();
        consumedRights[account] = spent + amount;
        emit RightsConsumed(account, amount);
    }

    /// @notice imdUSD per accepted task, 1e18-scaled, from the vault's governed parameters if it has
    /// any and from the shipped constant otherwise.
    /// @dev Probed rather than required, so one oracle serves a plain CDPVault and a ParameterizedVault
    /// without a second artifact. The bound lives in Parameters, which refuses more than one imdUSD per
    /// task; a vault with no parameters cannot change the figure at all.
    function wage() public view returns (uint256) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("parameters()"));
        if (!ok || data.length != 32) return WAGE_WAD;
        address parameters = address(uint160(abi.decode(data, (uint256))));
        if (parameters == address(0)) return WAGE_WAD;
        (ok, data) = parameters.staticcall(abi.encodeWithSignature("wage()"));
        if (!ok || data.length != 32) return WAGE_WAD;
        return abi.decode(data, (uint256));
    }

    /// @dev `isController` through a raw staticcall: an adapter that is absent (every testnet) or
    /// stops answering reads as "does not control", which refuses claims rather than reverting views.
    function _controls(uint256 agentId, address account) private view returns (bool) {
        (bool ok, bytes memory data) =
            ERC8004_ADAPTER.staticcall(abi.encodeCall(IAdapter8004.isController, (agentId, account)));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (uint256)) == 1;
    }

    /// @dev OpenZeppelin's sorted-pair proof, written out because this repository's checkout carries
    /// only the few utils it needs and `MerkleProof` is not among them. Sorted pairs are what
    /// `StandardMerkleTree` produces, and the leaf is double-hashed for the same reason it is there:
    /// a single hash lets an internal node be presented as a leaf.
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        return computed == root;
    }
bytes internal constant QUESTION_PREFIX = hex"7b22616e7377657254797065223a2275696e74323536222c22636861696e4964223a312c22646566696e6974696f6e73223a7b2265786163746e657373223a22457665727920726563656970742069732066726f7a656e20616e642070696e6e65642c20736f206576657279206d656d626572206f6620746869732070616e656c207265616473206964656e746963616c20627974657320616e64206d757374207265706f727420746865206964656e746963616c20696e74656765722e20446f206e6f7420726f756e642c20646f206e6f74206176657261676520616e6420646f206e6f742061646a75737420746f7761726420616e6f74686572206d656d6265722e20496620796f75722072656275696c6420646973616772656573207769746820616e6f746865722072656164696e672c207265706f727420696e6162696c69747920726174686572207468616e2073706c697474696e672074686520646966666572656e63652e222c22666967757265223a2254686520616e7377657220697320746865206167656e74526f6f74206669656c64206f66207468617420646f63756d656e742c20612033322d627974652076616c7565207772697474656e20617320307820666f6c6c6f7765642062792036342068657861646563696d616c20636861726163746572732c207265706f727465642061732074686520756e7369676e656420696e74656765722074686f736520627974657320726570726573656e7420696e206269672d656e6469616e206f726465722e20446f204e4f54207265706f72742074686520726f6f74206669656c642c207768696368206973206120646966666572656e7420726f6f74206f766572206a6f62206964656e746966696572732e222c2272656365697074223a22466574636820746865207265636569707420646f63756d656e742074686520576f726b5265636f72646564206576656e74277320757269206e616d65732e20416e20697066733a2f2f20757269207265736f6c766573207468726f75676820616e79207075626c696320676174657761792c20696e636c7564696e672068747470733a2f2f697066732e696d642e66756e2e2043616e6f6e6963616c697a652074686520646f63756d656e7420617320616e2052464320383738352073756273657420616e6420636f6e6669726d206b656363616b323536206f662074686f736520627974657320657175616c732074686520646f63756d656e744861736820726561642066726f6d207468652072656769737472792e204120646f63756d656e742077686f7365206861736820646f6573206e6f74206d61746368206973206e6f7420746865207265636569707420616e64206d757374206e6f7420626520757365642e222c227265667573616c223a225265706f727420696e6162696c69747920726174686572207468616e20737562737469747574696e6720616e797468696e67206966207468652072656769737472792063616e6e6f7420626520726561642c206966206e6f207175616c696679696e6720646179206578697374732c2069662074686520726563656970742063616e6e6f7420626520666574636865642c20696620697473206861736820646f6573206e6f74206d61746368207768617420746865207265676973747279207265636f726465642c206f7220696620697473206c656176657320646f206e6f7420726570726f6475636520697473206f776e206167656e74526f6f742e20416e20616273656e74206167656e742074616c6c79206d65616e732074686520636f6e74726f6c20706c616e6520686173206e6f74207075626c6973686564206f6e6520666f7220746861742077696e646f772c20616e642074686520636f727265637420616e7377657220697320696e6162696c6974792c204e4f54207a65726f2e222c227265676973747279223a2254686520576f726b52656769737472792069732074686520636f6e747261637420617420307862366430613138376230353066613562623062383730333361323033663337626563663461373735206f6e20457468657265756d206d61696e6e65742e204561636820555443206461792773206f7261636c652072656365697074206973207265636f7264656420756e6465722061206a6f624964206465726976656420617320746865206669727374207369787465656e206279746573206f66206b656363616b323536206f662074686520415343494920737472696e67206964656e746974796d642d6f7261636c652d62617463683a20666f6c6c6f776564206279207468652064617920696e20595959592d4d4d2d444420666f726d2c20776974682074686520555549442076657273696f6e20616e642076617269616e742062697473207365743a206279746520736978206f662074686f7365207369787465656e20686173206974732068696768206e6962626c65207265706c6163656420627920382c20616e64206279746520656967687420686173206974732074776f20686967682062697473207265706c616365642062792031302e2052656164206c6174657374286a6f6249642920666f72207468652063616e6f6e6963616c20646f63756d656e7448617368206f662074686174206461792e222c2273656c656374696f6e223a225768657265207365766572616c2064617973207175616c6966792c2074616b6520746865206f6e65207769746820746865206772656174657374206461792076616c75652077686f736520646f63756d656e7448617368206973207265636f72646564206174206f72206265666f7265207468652077696e646f772773206c61737420626c6f636b2e2041206461792077697468206e6f206167656e74526f6f7420617420616c6c2c20776869636820697320616e7920726563656970742077686f736520736368656d61206973206964656e746974796d642d6f7261636c652d62617463682d76312c20646f6573206e6f74207175616c6966792e222c22766572696669636174696f6e223a22496e646570656e64656e746c792072656275696c64207468652074726565206265666f726520616e73776572696e672e2054686520646f63756d656e742063617272696573206167656e744c656166456e636f64696e672c207768696368206d757374206265207468652074687265652074797065732075696e743235362c2075696e7433322c2075696e7436342c20616e64206167656e744c65617665732c20616e206172726179206f66206f626a656374732077697468206167656e7449642c20616363657074656420616e642063756d756c61746976652e204275696c6420616e204f70656e5a657070656c696e205374616e646172644d65726b6c6554726565206f7665722074686f7365206c656176657320696e20746865206f7264657220676976656e20616e6420636f6e6669726d2069747320726f6f7420657175616c73206167656e74526f6f742e204120646f63756d656e742077686f7365206c656176657320646f206e6f7420726570726f6475636520697473206f776e20726f6f74206d75737420626520726566757365642e227d2c2265766964656e6365223a2270616e656c222c227175657374696f6e223a225768617420697320746865206167656e742074616c6c79204d65726b6c6520726f6f74206f6620746865206d6f737420726563656e74206461696c79206f7261636c652072656365697074207468617420746865204964656e746974794d4420576f726b526567697374727920686173207265636f72646564206173206f6620746865206c61737420626c6f636b206f66207468652070696e6e65642077696e646f772c206578707265737365642061732074686520756e7369676e6564203235362d62697420696e74656765722077686f7365206269672d656e6469616e20627974657320617265207468617420726f6f743f222c2276223a312c2277696e646f77223a7b2266726f6d426c6f636b223a";

    /// @notice The exact question this oracle accepts answers to, and the window span it allows.
    /// @dev DERIVED, NEVER HAND-WRITTEN: emitted by `node oracle/question-prefix.mjs
    /// oracle/work-root-quote.json`. Change one character of that payload's question or definitions
    /// and this must be regenerated, or the oracle refuses every attestation — the safe direction.
    ///
    /// BEFORE DEPLOYING: buy one request with that payload and run the generator with
    /// `--verify <requestId>`; it must print MATCH. Nothing has been bought with it yet.
    ///
    /// The span bounds a 24-hour window on mainnet at roughly twelve seconds a block. The question
    /// names no day, so one constant serves every day, and `lastToBlock` is what forces each
    /// attestation to cover newer ground than the last.

    function questionPolicy() internal pure override returns (bytes memory, uint64, uint64) {
        return (QUESTION_PREFIX, 5_000, 9_000);
    }
}
