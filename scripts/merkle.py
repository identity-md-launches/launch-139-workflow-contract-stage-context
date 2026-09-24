#!/usr/bin/env python3
"""Offline PvPadHook worker-epoch builder. Standard library only; no network, no chain access.

Input: a JSON array of {"payee": "0x...", "amount": "<integer wei>"} entries.
Output: JSON with the epoch root, the budget check and one proof per payee, ready for
`PvPadHook.setEpoch(root, windowStart, windowEnd)` and
`PvPadHook.claimWorker(epochId, payee, amount, proof)`.

Leaf  = keccak256(keccak256(abi.encode(chainId, hook, epochId, payee, amount)))
Pairs = keccak256(min(a, b) || max(a, b)); an unpaired node is promoted unchanged.
Leaves are sorted before building so the same allocation always yields the same root.
"""

import argparse
import json
import re
import sys

# ---- keccak-256 (pure Python, so keepers need nothing beyond the interpreter) ----

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_MASK = (1 << 64) - 1


def _rol(v, n):
    n %= 64
    return ((v << n) | (v >> (64 - n))) & _MASK if n else v


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y] & _MASK) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data) + b"\x01"
    while len(padded) % rate:
        padded.append(0)
    padded[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i : 8 * i + 8], "little")
        a = _keccak_f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out[:32]


# ---- leaves, tree, proofs ----

_ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")


def parse_address(value: str) -> bytes:
    if not isinstance(value, str) or not _ADDRESS.match(value):
        raise ValueError(f"not an address: {value!r}")
    return bytes.fromhex(value[2:])


def leaf(chain_id: int, hook: bytes, epoch: int, payee: bytes, amount: int) -> bytes:
    encoded = (
        chain_id.to_bytes(32, "big")
        + hook.rjust(32, b"\x00")
        + epoch.to_bytes(32, "big")
        + payee.rjust(32, b"\x00")
        + amount.to_bytes(32, "big")
    )
    return keccak256(keccak256(encoded))


def hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b) if a < b else keccak256(b + a)


def build(leaves):
    """Returns (root, proofs) where proofs[i] is the sibling list for leaves[i]."""
    if not leaves:
        raise ValueError("no leaves")
    levels = [list(leaves)]
    while len(levels[-1]) > 1:
        level = levels[-1]
        nxt = [hash_pair(level[i], level[i + 1]) if i + 1 < len(level) else level[i] for i in range(0, len(level), 2)]
        levels.append(nxt)
    proofs = []
    for index in range(len(leaves)):
        proof, i = [], index
        for level in levels[:-1]:
            sibling = i ^ 1
            if sibling < len(level):
                proof.append(level[sibling])
            i //= 2
        proofs.append(proof)
    return levels[-1][0], proofs


def build_epoch(allocations, chain_id: int, hook: str, epoch: int, budget: int):
    hook_bytes = parse_address(hook)
    if epoch <= 0:
        raise ValueError("epoch ids start at 1")
    seen, entries, total = set(), [], 0
    for entry in allocations:
        payee = entry["payee"]
        payee_bytes = parse_address(payee)
        if payee_bytes == b"\x00" * 20:
            raise ValueError("zero payee")
        if payee.lower() in seen:
            raise ValueError(f"duplicate payee {payee}")
        seen.add(payee.lower())
        amount = int(entry["amount"])
        if amount <= 0:
            raise ValueError(f"non-positive amount for {payee}")
        total += amount
        entries.append((payee, amount, leaf(chain_id, hook_bytes, epoch, payee_bytes, amount)))
    if total > budget:
        raise ValueError(f"allocations total {total} exceed budget {budget}")
    entries.sort(key=lambda e: e[2])
    root, proofs = build([e[2] for e in entries])
    return {
        "chainId": chain_id,
        "hook": hook,
        "epochId": epoch,
        "budget": str(budget),
        "total": str(total),
        "root": "0x" + root.hex(),
        "claims": [
            {
                "payee": payee,
                "amount": str(amount),
                "leaf": "0x" + lf.hex(),
                "proof": ["0x" + p.hex() for p in proof],
            }
            for (payee, amount, lf), proof in zip(entries, proofs)
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("allocations", help="JSON file: [{\"payee\": \"0x…\", \"amount\": \"wei\"}, …]")
    parser.add_argument("--hook", required=True, help="PvPadHook address")
    parser.add_argument("--epoch", required=True, type=int, help="epoch id the root is for (currentEpoch + 1)")
    parser.add_argument("--budget", required=True, type=int, help="availableForNextEpoch() in wei")
    parser.add_argument("--chain-id", type=int, default=11155111, help="default: Sepolia")
    args = parser.parse_args(argv)
    with open(args.allocations) as f:
        allocations = json.load(f)
    result = build_epoch(allocations, args.chain_id, args.hook, args.epoch, args.budget)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
