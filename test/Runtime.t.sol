// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./ProtocolFixture.sol";

contract RuntimeTest is ProtocolFixture {
    function test_runtimeBoundedAndNoForbiddenInstructions() public view {
        address[4] memory contracts = [address(imd), address(comp), address(oracle), address(vault)];
        for (uint256 i; i < contracts.length; ++i) {
            bytes memory code = contracts[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                } else {
                    assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
                }
            }
        }
    }
}
