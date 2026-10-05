// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "src/interfaces/IIntake.sol";

/// @notice The Intake as PR #66 behaves: it collects the price from the caller, records where the result
/// goes, and when told to complete calls that target once with the same fixed gas stipend, recording
/// rather than trusting the outcome.
contract MockIntake {
    mapping(bytes32 action => mapping(address asset => uint256 amount)) public priceOf;
    mapping(bytes32 requestId => IIntake.Callback) public callbackOf;
    mapping(bytes32 requestId => bytes) public bodyOf;
    uint256 public nonce;
    uint64 public constant CALLBACK_GAS = 200_000;
    uint256 public lastCallbackGasUsed;

    function setPrice(bytes32 action, address asset, uint256 amount) external {
        priceOf[action][asset] = amount;
    }

    function request(bytes32 action, bytes calldata body, IIntake.Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        uint256 price = priceOf[action][asset];
        require(price != 0 && amount >= price, "not sold");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requestId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        callbackOf[requestId] = callback;
        bodyOf[requestId] = body;
    }

    function complete(bytes32 requestId, bytes calldata args) external returns (bool delivered) {
        IIntake.Callback memory c = callbackOf[requestId];
        uint256 before = gasleft();
        (delivered,) = c.target.call{gas: CALLBACK_GAS}(bytes.concat(c.selector, args));
        lastCallbackGasUsed = before - gasleft();
    }
}

/// @notice A v4 PoolManager that answers `extsload` only at the slot holding one pool's slot0, so a
/// caller computing the wrong slot reads zero.
contract MockPoolManager {
    bytes32 public slot;
    bytes32 public word;

    function set(bytes32 slot_, uint160 sqrtPriceX96) external {
        slot = slot_;
        word = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32 s) external view returns (bytes32) {
        return s == slot ? word : bytes32(0);
    }
}
