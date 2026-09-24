// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal sorted-pair Merkle tree for tests. Commutative pair hash, as OpenZeppelin `MerkleProof`
/// and `PvPadHook._verify` expect; an unpaired node is promoted unchanged. Matches scripts/merkle.py.
library Merkle {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < level.length; i += 2) {
                next[i / 2] = i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i];
            }
            level = next;
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        require(index < leaves.length, "index");
        bytes32[] memory level = leaves;
        bytes32[] memory buffer = new bytes32[](64);
        uint256 n;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) buffer[n++] = level[sibling];
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < level.length; i += 2) {
                next[i / 2] = i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i];
            }
            level = next;
            index /= 2;
        }
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = buffer[i];
        }
    }
}
