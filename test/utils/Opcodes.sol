// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Scans runtime code for the escape-hatch opcodes, stepping over PUSH immediates the same way
/// the admission floor does.
library Opcodes {
    function hasEscapeHatch(bytes memory code) internal pure returns (bool) {
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (op == 0xff || op == 0xf4 || op == 0xf2) return true;
        }
        return false;
    }
}
