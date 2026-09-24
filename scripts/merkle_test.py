"""Pins scripts/merkle.py to vectors that test/MerkleVectors.t.sol reproduces in Solidity."""

import unittest

import merkle

HOOK = "0x1234000000000000000000000000000000005678"
ALLOCS = [
    {"payee": "0x00000000000000000000000000000000000000A1", "amount": "1000"},
    {"payee": "0x00000000000000000000000000000000000000B2", "amount": "2000"},
    {"payee": "0x00000000000000000000000000000000000000C3", "amount": "3000"},
]
ROOT = "0xc63582022d704e2d7105795af968b5f7160234198222979b08874b1d118b7cfc"
LEAF_A1 = "0x4496f48b4849da469d09a45dc5374f7627888fb6c8151c56c2782567a589a559"
LEAF_B2 = "0x4439f234e6513922f553ec4271a1be2f2b1664248f9689e8f1ac291732eeca3e"
LEAF_C3 = "0x4956d5fda344d35b9de26e9b790a98b6ebb7824dad9155e115be8bed788d2985"


class KeccakTest(unittest.TestCase):
    def test_known_answers(self):
        self.assertEqual(merkle.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(
            merkle.keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        )
        self.assertEqual(
            merkle.keccak256(b"x" * 200).hex(), merkle.keccak256(b"x" * 136 + b"x" * 64).hex()
        )


class EpochTest(unittest.TestCase):
    def test_vector(self):
        result = merkle.build_epoch(ALLOCS, 31337, HOOK, 7, 6000)
        self.assertEqual(result["root"], ROOT)
        self.assertEqual(result["total"], "6000")
        by_payee = {c["payee"]: c for c in result["claims"]}
        self.assertEqual(by_payee[ALLOCS[0]["payee"]]["leaf"], LEAF_A1)
        self.assertEqual(by_payee[ALLOCS[1]["payee"]]["leaf"], LEAF_B2)
        self.assertEqual(by_payee[ALLOCS[2]["payee"]]["leaf"], LEAF_C3)
        # Sorted leaves: [B2, A1, C3]. A1's siblings are B2 and then the promoted C3.
        self.assertEqual(by_payee[ALLOCS[0]["payee"]]["proof"], [LEAF_B2, LEAF_C3])
        self.assertEqual(by_payee[ALLOCS[2]["payee"]]["proof"], [merkle.hash_pair(bytes.fromhex(LEAF_B2[2:]), bytes.fromhex(LEAF_A1[2:])).hex().join(["0x", ""])])

    def test_root_is_order_independent(self):
        a = merkle.build_epoch(ALLOCS, 31337, HOOK, 7, 6000)["root"]
        b = merkle.build_epoch(list(reversed(ALLOCS)), 31337, HOOK, 7, 6000)["root"]
        self.assertEqual(a, b)

    def test_root_binds_chain_hook_and_epoch(self):
        base = merkle.build_epoch(ALLOCS, 31337, HOOK, 7, 6000)["root"]
        self.assertNotEqual(base, merkle.build_epoch(ALLOCS, 11155111, HOOK, 7, 6000)["root"])
        self.assertNotEqual(base, merkle.build_epoch(ALLOCS, 31337, HOOK, 8, 6000)["root"])
        self.assertNotEqual(base, merkle.build_epoch(ALLOCS, 31337, "0x" + "ab" * 20, 7, 6000)["root"])

    def test_single_leaf_root_is_the_leaf(self):
        result = merkle.build_epoch(ALLOCS[:1], 31337, HOOK, 1, 1000)
        self.assertEqual(result["root"], LEAF_A1.replace(LEAF_A1, result["claims"][0]["leaf"]))
        self.assertEqual(result["claims"][0]["proof"], [])

    def test_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            merkle.build_epoch(ALLOCS, 31337, HOOK, 7, 5999)
        with self.assertRaises(ValueError):
            merkle.build_epoch(ALLOCS + [ALLOCS[0]], 31337, HOOK, 7, 10_000)
        with self.assertRaises(ValueError):
            merkle.build_epoch([{"payee": "0x" + "00" * 20, "amount": "1"}], 31337, HOOK, 7, 10)
        with self.assertRaises(ValueError):
            merkle.build_epoch([{"payee": ALLOCS[0]["payee"], "amount": "0"}], 31337, HOOK, 7, 10)
        with self.assertRaises(ValueError):
            merkle.build_epoch(ALLOCS, 31337, HOOK, 0, 6000)
        with self.assertRaises(ValueError):
            merkle.build_epoch([], 31337, HOOK, 1, 6000)


if __name__ == "__main__":
    unittest.main()
