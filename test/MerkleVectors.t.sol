// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "./utils/Merkle.sol";

/// @dev The vector pinned by scripts/merkle_test.py, rebuilt with the Solidity leaf formula and the
/// test-side tree, so the keeper tooling and the contract agree on hashing, sorting and proofs.
/// The hook itself is exercised against these trees in PvPadHookWorkers.t.sol.
contract MerkleVectorsTest is Test {
    address constant HOOK = 0x1234000000000000000000000000000000005678;
    bytes32 constant ROOT = 0xc63582022d704e2d7105795af968b5f7160234198222979b08874b1d118b7cfc;
    bytes32 constant LEAF_A1 = 0x4496f48b4849da469d09a45dc5374f7627888fb6c8151c56c2782567a589a559;
    bytes32 constant LEAF_B2 = 0x4439f234e6513922f553ec4271a1be2f2b1664248f9689e8f1ac291732eeca3e;
    bytes32 constant LEAF_C3 = 0x4956d5fda344d35b9de26e9b790a98b6ebb7824dad9155e115be8bed788d2985;

    function leaf(uint256 epochId, address payee, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(uint256(31337), HOOK, epochId, payee, amount))));
    }

    function test_leavesMatchThePythonTool() public pure {
        assertEq(leaf(7, address(0xA1), 1000), LEAF_A1);
        assertEq(leaf(7, address(0xB2), 2000), LEAF_B2);
        assertEq(leaf(7, address(0xC3), 3000), LEAF_C3);
    }

    function test_rootAndProofsMatchThePythonTool() public pure {
        // The tool sorts leaves ascending before building: [B2, A1, C3].
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = LEAF_B2;
        leaves[1] = LEAF_A1;
        leaves[2] = LEAF_C3;
        assertEq(Merkle.root(leaves), ROOT);

        bytes32[] memory proofA1 = Merkle.proof(leaves, 1);
        assertEq(proofA1.length, 2);
        assertEq(proofA1[0], LEAF_B2);
        assertEq(proofA1[1], LEAF_C3);

        bytes32[] memory proofC3 = Merkle.proof(leaves, 2);
        assertEq(proofC3.length, 1);
        assertEq(proofC3[0], Merkle.hashPair(LEAF_B2, LEAF_A1));
        assertEq(proofC3[0], 0x07f8ad278329fa3d54c3b77d3683e533f5a2a9e0daba5e96ea79956e911d5e64);
    }
}
