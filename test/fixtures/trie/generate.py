#!/usr/bin/env python3
"""Builds random.json, a differential fixture for MerklePatricia: random Merkle-Patricia tries built by a reference
implementation written here, independently of the Solidity, with a proof for every key and for absent keys near them.
Run: python3 test/fixtures/trie/generate.py. Deterministic, no dependencies: keccak is implemented below and checked
against two known digests before anything is written.

The tries cover the shapes real proofs rarely show together: a root that is a single leaf, extensions of every length,
leaves and branches small enough to be embedded in their parent, keccak keys of 64 nibbles and receipt keys of 2 to 6,
and absent keys that diverge at a leaf, inside an extension or at an empty branch slot.
"""
import json
import os
import random

# ---------------------------------------------------------------------
# keccak-256
# ---------------------------------------------------------------------

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1


def _rol(x, n):
    n %= 64
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate:
        padded.append(0)
    padded[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(padded), rate):
        block = padded[off:off + rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[8 * i:8 * i + 8], "little")
            a[i % 5][i // 5] ^= lane
        a = _keccak_f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
assert keccak256(b"abc").hex() == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
assert keccak256(bytes(200)).hex() == keccak256(bytes(200)).hex()

# ---------------------------------------------------------------------
# RLP
# ---------------------------------------------------------------------


def _prefix(n, base):
    if n <= 55:
        return bytes([base + n])
    be = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([base + 55 + len(be)]) + be


def rlp_str(b: bytes) -> bytes:
    if len(b) == 1 and b[0] < 0x80:
        return b
    return _prefix(len(b), 0x80) + b


def rlp_list(items) -> bytes:
    payload = b"".join(items)
    return _prefix(len(payload), 0xC0) + payload


def rlp_int(x: int) -> bytes:
    return rlp_str(b"" if x == 0 else x.to_bytes((x.bit_length() + 7) // 8, "big"))


# ---------------------------------------------------------------------
# The trie
# ---------------------------------------------------------------------


def hex_prefix(nibbles, is_leaf):
    flag = 2 if is_leaf else 0
    if len(nibbles) % 2:
        out = [((flag + 1) << 4) | nibbles[0]]
        rest = nibbles[1:]
    else:
        out = [flag << 4]
        rest = nibbles
    for i in range(0, len(rest), 2):
        out.append((rest[i] << 4) | rest[i + 1])
    return bytes(out)


class Node:
    def __init__(self, kind, path=(), children=None, value=b""):
        self.kind = kind  # leaf | ext | branch
        self.path = tuple(path)
        self.children = children or {}
        self.value = value
        self.rlp = self._encode()

    def _encode(self):
        if self.kind == "leaf":
            return rlp_list([rlp_str(hex_prefix(self.path, True)), rlp_str(self.value)])
        if self.kind == "ext":
            return rlp_list([rlp_str(hex_prefix(self.path, False)), self.children[0].ref()])
        slots = [self.children[i].ref() if i in self.children else rlp_str(b"") for i in range(16)]
        return rlp_list(slots + [rlp_str(b"")])

    def embedded(self):
        return len(self.rlp) < 32

    def ref(self):
        return self.rlp if self.embedded() else rlp_str(keccak256(self.rlp))


def build(items, depth):
    """`items`: (nibbles, value) pairs that agree on their first `depth` nibbles; no key is another's prefix."""
    if len(items) == 1:
        nibs, value = items[0]
        return Node("leaf", nibs[depth:], value=value)
    lcp = 0
    while all(len(n) > depth + lcp for n, _ in items) and len({n[depth + lcp] for n, _ in items}) == 1:
        lcp += 1
    if lcp:
        return Node("ext", items[0][0][depth:depth + lcp], {0: _branch(items, depth + lcp)})
    return _branch(items, depth)


def _branch(items, depth):
    groups = {}
    for nibs, value in items:
        assert len(nibs) > depth, "a key that is another's prefix"
        groups.setdefault(nibs[depth], []).append((nibs, value))
    return Node("branch", children={k: build(v, depth + 1) for k, v in groups.items()})


def prove(node, nibs, depth, proof, top):
    """Walks `nibs` from `node`, appending every hashed node to `proof`; returns (found, value)."""
    if top or not node.embedded():
        proof.append(node.rlp)
    if node.kind == "leaf":
        return (True, node.value) if tuple(nibs[depth:]) == node.path else (False, b"")
    if node.kind == "ext":
        n = len(node.path)
        if tuple(nibs[depth:depth + n]) != node.path:
            return False, b""
        return prove(node.children[0], nibs, depth + n, proof, False)
    if depth == len(nibs):
        return False, b""
    child = node.children.get(nibs[depth])
    if child is None:
        return False, b""
    return prove(child, nibs, depth + 1, proof, False)


def nibbles_of(key: bytes):
    out = []
    for b in key:
        out += [b >> 4, b & 0x0F]
    return out


def key_word(nibs):
    """The key as the bytes32 the Solidity takes: its nibbles from the top, zero to the right."""
    padded = list(nibs) + [0] * (64 - len(nibs))
    return bytes((padded[2 * i] << 4) | padded[2 * i + 1] for i in range(32))


# ---------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------

rng = random.Random(2026)
cases = []


def emit(root, node, nibs):
    proof = []
    found, value = prove(node, nibs, 0, proof, True)
    cases.append({
        "root": "0x" + root.hex(),
        "key": "0x" + key_word(nibs).hex(),
        "nibbles": len(nibs),
        "proof": ["0x" + p.hex() for p in proof],
        "found": found,
        "value": "0x" + value.hex(),
    })
    return found


def add_trie(items, absent, sample=None):
    """Emits a proof of every key, or of `sample` of them, and of every `absent` key, checking the reference's own
    verdicts."""
    root_node = build(items, 0)
    root = keccak256(root_node.rlp)
    present = {tuple(n) for n, _ in items}
    chosen = items if sample is None or len(items) <= sample else rng.sample(items, sample)
    for nibs, _ in chosen:
        assert emit(root, root_node, nibs)
    for nibs in absent:
        assert tuple(nibs) not in present
        assert not emit(root, root_node, nibs)


def random_value():
    return bytes(rng.getrandbits(8) for _ in range(rng.choice([1, 1, 2, 5, 20, 31, 32, 33, 40, 100])))


def keccak_keys(n):
    return [nibbles_of(keccak256(rng.getrandbits(64).to_bytes(8, "big"))) for _ in range(n)]


def near(nibs):
    """Keys that diverge from `nibs` late: at its last nibble, in its middle, or one nibble in."""
    out = []
    for at in (len(nibs) - 1, len(nibs) // 2, rng.randrange(len(nibs)), 0):
        k = list(nibs)
        k[at] = (k[at] + 1 + rng.randrange(15)) % 16
        out.append(k)
    return out


# A root that is a single leaf, long and short values.
for value in (bytes(40), b"\x07", bytes(32)):
    k = keccak_keys(1)[0]
    add_trie([(k, value)], near(k))

# Two keys sharing a long prefix: an extension to a branch holding two leaves, embedded where small.
for shared in (1, 7, 30, 62, 63):
    base = keccak_keys(1)[0]
    other = list(base)
    other[shared] = (other[shared] + 1) % 16
    for tail in range(shared + 1, 64):
        other[tail] = rng.randrange(16)
    items = [(base, random_value()), (other, random_value())]
    add_trie(items, near(base) + near(other))

# Chains of extensions: groups that share prefixes at several depths.
for _ in range(3):
    items = []
    stem = keccak_keys(1)[0]
    for depth in (6, 20, 40):
        for _ in range(3):
            k = list(stem[:depth]) + [rng.randrange(16) for _ in range(64 - depth)]
            items.append((k, random_value()))
    seen = set()
    unique = []
    for k, v in items:
        if tuple(k) not in seen:
            seen.add(tuple(k))
            unique.append((k, v))
    absent = []
    for k, _ in unique:
        absent += near(k)
    add_trie(unique, [a for a in absent if tuple(a) not in seen])

# Wider tries of keccak keys, with every value length.
for n in (3, 17, 64, 200):
    keys = keccak_keys(n)
    items = [(k, random_value()) for k in keys]
    absent = keccak_keys(5)
    for k in keys[:3]:
        absent += near(k)
    present = {tuple(k) for k in keys}
    add_trie(items, [a for a in absent if tuple(a) not in present], sample=24)

# Receipt tries: keys are the RLP of the transaction index, of 1 to 3 bytes.
for n in (1, 2, 3, 128, 129, 300):
    items = [(nibbles_of(rlp_int(i)), random_value()) for i in range(n)]
    absent = [nibbles_of(rlp_int(j)) for j in (n, n + 1, n + 100, 70_000)]
    add_trie(items, absent, sample=24)

out = {"count": len(cases), "cases": cases}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "random.json")
with open(path, "w") as f:
    json.dump(out, f, indent=1)
print(f"wrote {len(cases)} cases, {sum(1 for c in cases if c['found'])} present, to {path}")
