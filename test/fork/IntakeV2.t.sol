// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmFeed} from "src/SwarmFeed.sol";
import {SwarmRelay} from "src/SwarmRelay.sol";
import {OracleAsker} from "src/OracleAsker.sol";
import {ConfigurableSwarmFeed} from "../helpers/ConfigurableSwarmFeed.sol";
import {INTAKE, ORACLE_ACTION, ATTESTATION_RELAYER} from "src/DeploymentConfig.sol";

error FailureArgsMismatch(bytes32 requestId, uint8 status);

interface IIntakeV2 {
    function writer() external view returns (address);
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requests(bytes32 requestId) external view returns (address payer, address target, bytes4 selector, bool completed);
    function failureSelectorOf(bytes32 requestId) external view returns (bytes4);
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external;
}

/// @notice OracleAsker against the LIVE Intake v2 (no mock): it pays v2 through the unchanged `request`, and v2's
/// callback, which comes from v2's own address, is accepted. Plane `f5c0d20b`; mainnet 0xa43e…de82.
///   forge test --match-path test/fork/IntakeV2.t.sol --fork-url $MAINNET_RPC_URL
contract IntakeV2ForkTest is Test {
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    bytes constant BODY = '{"question":"IMD/ETH median"}';

    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    ConfigurableSwarmFeed feed;
    OracleAsker asker;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        assertEq(INTAKE, 0xa43e6F75ee006411F79Ac1C84120606C2330DE82, "the config names Intake v2");
        // The relay is not deployed yet on mainnet; the asker relays inside a try, but a call to an address
        // with no code reverts before the try can catch it, so the relay's code goes where it will be.
        vm.etch(ATTESTATION_RELAYER, address(new SwarmRelay()).code);
        feed = new ConfigurableSwarmFeed(address(0xA77E57), ATTESTATION_RELAYER, 1, 3, 1 days, 2000);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(BODY);
        asker = new OracleAsker(IMD, feeds, hashes, new bool[](1), new bool[](1));
    }

    function _ask() private returns (bytes32 id, uint256 price) {
        price = asker.price();
        assertEq(price, IIntakeV2(INTAKE).priceOf(ORACLE_ACTION, address(IMD)), "the asker reads v2's price");
        deal(address(IMD), address(this), price);
        IMD.approve(address(asker), price);
        id = asker.askPaid(address(feed), BODY, price);
    }

    function test_theAskerPaysV2AndNamesBothCallbacks() public {
        uint256 before = IMD.balanceOf(INTAKE) + IMD.balanceOf(0x4e0fA57Bde726079356537E2F34d671E9F41ADbc);
        (bytes32 id, uint256 price) = _ask();
        (address payer, address target, bytes4 selector, bool completed) = IIntakeV2(INTAKE).requests(id);
        assertEq(payer, address(asker));
        assertEq(target, address(asker));
        assertEq(selector, OracleAsker.onOracleResult.selector);
        assertFalse(completed);
        assertEq(IIntakeV2(INTAKE).failureSelectorOf(id), OracleAsker.onOracleFailure.selector, "and names the failure hook");
        assertEq(IMD.balanceOf(INTAKE) + IMD.balanceOf(0x4e0fA57Bde726079356537E2F34d671E9F41ADbc) - before, price, "paid");
        assertEq(IMD.balanceOf(address(asker)), 0, "the asker keeps nothing, and its approval is reset");
        assertEq(IMD.allowance(address(asker), INTAKE), 0);
    }

    /// @dev The answer path: v2's writer completes with status 0, v2 calls the asker from v2's own address, the
    /// asker accepts it (`msg.sender == INTAKE`) and clears the feed's in-flight slot. The attestation is a dummy,
    /// so the relay refuses it, inside the asker's try: the delivery still counts, as it would for any answer.
    function test_v2DeliversToTheAskerAndTheAskerAcceptsIt() public {
        (bytes32 id,) = _ask();
        assertEq(_inFlight(), id, "in flight until the answer comes back");
        SwarmFeed.OracleAttestation memory a;
        bytes memory args = abi.encode(id, a, bytes(""));
        vm.expectEmit(true, false, false, true, INTAKE);
        emit Completed(id, 0, bytes32(0), "", true);
        vm.prank(IIntakeV2(INTAKE).writer());
        IIntakeV2(INTAKE).complete(id, 0, bytes32(0), "", args);
        assertEq(_inFlight(), bytes32(0), "the asker took v2's callback and cleared the slot");
    }

    /// @dev The failure path on the REAL v2: the writer closes the request with status 1 or 2 and the arguments v2
    /// requires; v2 calls the asker's failure function from its own address; the asker clears the slot at once, and
    /// a caller may pay for a fresh answer in the next transaction instead of after ASK_TIMEOUT.
    function test_v2CallsTheFailureFunctionAndTheSlotClearsAtOnce() public {
        for (uint8 status = 1; status <= 2; ++status) {
            (bytes32 id, uint256 price) = _ask();
            assertEq(IIntakeV2(INTAKE).failureSelectorOf(id), OracleAsker.onOracleFailure.selector, "v2 recorded the hook");
            assertEq(_inFlight(), id);
            bytes memory args = abi.encode(id, uint256(status), keccak256("why"), uint16(3), uint16(20), bytes(""));
            vm.expectEmit(true, false, false, true, INTAKE);
            emit Completed(id, status, bytes32(0), "", true);
            vm.prank(IIntakeV2(INTAKE).writer());
            IIntakeV2(INTAKE).complete(id, status, bytes32(0), "", args);
            assertEq(_inFlight(), bytes32(0), "cleared by v2's callback, not by the timeout");
            // The next purchase of this feed goes through at once (a caller's; the Treasury's own is backed off).
            deal(address(IMD), address(this), price);
            IMD.approve(address(asker), price);
            bytes32 next = asker.askPaid(address(feed), BODY, price);
            assertEq(_inFlight(), next);
            // Read before the prank: a view's external call would consume it.
            bytes memory answer = abi.encode(next, _dummy(), bytes(""));
            address writer = IIntakeV2(INTAKE).writer();
            vm.prank(writer);
            IIntakeV2(INTAKE).complete(next, 0, bytes32(0), "", answer);
            assertEq(_inFlight(), bytes32(0));
        }
    }

    /// @dev v2 refuses to aim the hook with arguments that do not name this request and status (its check, our
    /// safety): the writer cannot make the asker clear another feed's slot.
    function test_v2RefusesFailureArgumentsThatNameAnotherRequest() public {
        (bytes32 id,) = _ask();
        bytes memory wrong = abi.encode(keccak256("other"), uint256(1), bytes32(0), uint16(0), uint16(0), bytes(""));
        vm.prank(IIntakeV2(INTAKE).writer());
        vm.expectRevert(abi.encodeWithSelector(FailureArgsMismatch.selector, id, uint8(1)));
        IIntakeV2(INTAKE).complete(id, 1, bytes32(0), "", wrong);
        assertEq(_inFlight(), id, "untouched");
    }

    function _dummy() private pure returns (SwarmFeed.OracleAttestation memory a) {}

    function test_onlyTheIntakeMayDeliver() public {
        (bytes32 id,) = _ask();
        SwarmFeed.OracleAttestation memory a;
        vm.expectRevert(OracleAsker.NotTheIntake.selector);
        asker.onOracleResult(id, a, "");
    }

    function _inFlight() private view returns (bytes32 inFlight) {
        (,,,,,,, inFlight) = asker.feeds(address(feed));
    }
}
