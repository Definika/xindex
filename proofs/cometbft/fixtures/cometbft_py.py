"""CometBFT's hashes and signatures, and ICS-23's paths, written from the specifications for the fixture generator: an
implementation separate from tendermint-rs and ics23, which the Rust statement uses, so the two check each other.

- A header's hash is the simple Merkle root of its 14 fields, each written as CometBFT's `cdcEncode` writes it
  (`types/block.go` `Header.Hash`); a validator set's is the root over `SimpleValidator` messages
  (`types/validator_set.go`); the tree is RFC 6962's, a leaf `sha256(0x00 ++ item)` and a node `sha256(0x01 ++ l ++ r)`,
  split at the largest power of two below the count (`crypto/merkle/tree.go`).
- A precommit signs `MarshalDelimited(CanonicalVote)` (`types/vote.go` `VoteSignBytes`), with ed25519.
- An ICS-23 proof is an existence proof's leaf and inner operations (`cosmos/ics23` `proofs.proto`), or a non-existence
  proof's two neighbours, which must be adjacent: no key lies between them (`ensure_left_neighbor`).
"""

import base64
import hashlib
from datetime import datetime, timezone

import nacl.exceptions
import nacl.signing
from Crypto.Hash import keccak as _keccak


def sha256(b):
    return hashlib.sha256(b).digest()


def keccak(b):
    h = _keccak.new(digest_bits=256)
    h.update(b)
    return h.digest()


# ---------------------------------------------------------------------------
# protobuf, as much of it as the hashes and sign bytes need
# ---------------------------------------------------------------------------


def varint(n):
    assert n >= 0
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field_varint(num, n):
    """A varint field; proto3 omits a zero."""
    return b"" if n == 0 else varint(num << 3) + varint(n)


def field_bytes(num, b, keep_empty=False):
    """A length-delimited field; proto3 omits an empty one, unless it is a non-nullable message."""
    if not b and not keep_empty:
        return b""
    return varint(num << 3 | 2) + varint(len(b)) + b


def field_sfixed64(num, n):
    return b"" if n == 0 else varint(num << 3 | 1) + (n % (1 << 64)).to_bytes(8, "little")


def read_varint(b, i):
    n = 0
    shift = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7F) << shift
        shift += 7
        if c < 0x80:
            return n, i


def parse(b):
    """A protobuf message's fields, in order: (number, wire type, value)."""
    out = []
    i = 0
    while i < len(b):
        tag, i = read_varint(b, i)
        num, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = read_varint(b, i)
        elif wt == 2:
            n, i = read_varint(b, i)
            v = bytes(b[i : i + n])
            i += n
        else:
            raise ValueError("wire type %d" % wt)
        out.append((num, wt, v))
    return out


# ---------------------------------------------------------------------------
# times
# ---------------------------------------------------------------------------


def parse_time(s):
    """RFC 3339 with up to nanoseconds, as CometBFT writes it: (unix seconds, nanoseconds)."""
    assert s.endswith("Z")
    body = s[:-1]
    if "." in body:
        whole, frac = body.split(".")
        nanos = int(frac.ljust(9, "0")[:9])
    else:
        whole, nanos = body, 0
    dt = datetime.strptime(whole, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return int(dt.timestamp()), nanos


def timestamp(s):
    seconds, nanos = parse_time(s)
    return field_varint(1, seconds) + field_varint(2, nanos)


# ---------------------------------------------------------------------------
# Merkle trees
# ---------------------------------------------------------------------------


def merkle_root(items):
    n = len(items)
    if n == 0:
        return sha256(b"")
    if n == 1:
        return sha256(b"\x00" + items[0])
    k = 1
    while k * 2 < n:
        k *= 2
    return sha256(b"\x01" + merkle_root(items[:k]) + merkle_root(items[k:]))


def hx(s):
    return bytes.fromhex(s) if s else b""


def block_id(bid):
    psh = field_varint(1, bid["parts"]["total"]) + field_bytes(2, hx(bid["parts"]["hash"]))
    return field_bytes(1, hx(bid["hash"])) + field_bytes(2, psh, keep_empty=True)


def header_hash(h):
    """`Header.Hash()`: each field `cdcEncode`d (a wrapper message for scalars), the block id and version as their
    own messages."""
    version = field_varint(1, int(h["version"]["block"])) + field_varint(2, int(h["version"].get("app", "0")))
    fields = [
        version,
        field_bytes(1, h["chain_id"].encode()),
        field_varint(1, int(h["height"])),
        timestamp(h["time"]),
        block_id(h["last_block_id"]),
    ] + [
        field_bytes(1, hx(h[k]))
        for k in (
            "last_commit_hash",
            "data_hash",
            "validators_hash",
            "next_validators_hash",
            "consensus_hash",
            "app_hash",
            "last_results_hash",
            "evidence_hash",
            "proposer_address",
        )
    ]
    return merkle_root(fields)


def pubkey(v):
    assert v["pub_key"]["type"] == "tendermint/PubKeyEd25519", v["pub_key"]["type"]
    return base64.b64decode(v["pub_key"]["value"])


def ordered(validators):
    """CometBFT's order: voting power descending, then address ascending."""
    return sorted(validators, key=lambda v: (-int(v["voting_power"]), bytes.fromhex(v["address"])))


def validators_hash(validators):
    leaves = []
    for v in ordered(validators):
        key = field_bytes(1, pubkey(v))  # PublicKey { ed25519 = 1 }
        leaves.append(field_bytes(1, key) + field_varint(2, int(v["voting_power"])))
    return merkle_root(leaves)


def address(v):
    return sha256(pubkey(v))[:20]


# ---------------------------------------------------------------------------
# commits
# ---------------------------------------------------------------------------

PRECOMMIT = 2
FLAG_COMMIT = 2


def vote_sign_bytes(chain_id, commit, sig):
    bid = commit["block_id"]
    canonical_bid = field_bytes(1, hx(bid["hash"])) + field_bytes(
        2, field_varint(1, bid["parts"]["total"]) + field_bytes(2, hx(bid["parts"]["hash"])), keep_empty=True
    )
    msg = (
        field_varint(1, PRECOMMIT)
        + field_sfixed64(2, int(commit["height"]))
        + field_sfixed64(3, int(commit["round"]))
        + field_bytes(4, canonical_bid)
        + field_bytes(5, timestamp(sig["timestamp"]), keep_empty=True)
        + field_bytes(6, chain_id.encode())
    )
    return varint(len(msg)) + msg


def signed_power(signed_header, validators):
    """The power of `validators` whose precommit for the header is in its commit, every one of those signatures
    checked. Returns (signed, total)."""
    header, commit = signed_header["header"], signed_header["commit"]
    assert commit["height"] == header["height"]
    assert bytes.fromhex(commit["block_id"]["hash"]) == header_hash(header), "the commit is for another block"
    by_address = {}
    for sig in commit["signatures"]:
        if sig["block_id_flag"] != FLAG_COMMIT:
            continue
        a = sig["validator_address"]
        assert a not in by_address, "a validator signed twice"
        by_address[a] = sig
    total = signed = 0
    for v in validators:
        assert address(v) == bytes.fromhex(v["address"]), "an address that is not its key's"
        total += int(v["voting_power"])
        sig = by_address.get(v["address"])
        if sig is None:
            continue
        message = vote_sign_bytes(header["chain_id"], commit, sig)
        try:
            nacl.signing.VerifyKey(pubkey(v)).verify(message, base64.b64decode(sig["signature"]))
        except nacl.exceptions.BadSignatureError:
            raise AssertionError("a bad signature from %s" % v["address"])
        signed += int(v["voting_power"])
    return signed, total


def more_than_two_thirds(signed, total):
    return 3 * signed > 2 * total


# ---------------------------------------------------------------------------
# ICS-23
# ---------------------------------------------------------------------------

SHA256 = 1
VAR_PROTO = 1


def existence(b):
    """An `ExistenceProof`: key, value, leaf operation and path (leaf to root)."""
    p = {"key": b"", "value": b"", "leaf": None, "path": []}
    for num, _, v in parse(b):
        if num == 1:
            p["key"] = v
        elif num == 2:
            p["value"] = v
        elif num == 3:
            leaf = {"hash": 0, "prehash_key": 0, "prehash_value": 0, "length": 0, "prefix": b""}
            for n, _, x in parse(v):
                leaf[["", "hash", "prehash_key", "prehash_value", "length", "prefix"][n]] = x
            p["leaf"] = leaf
        elif num == 4:
            op = {"hash": 0, "prefix": b"", "suffix": b""}
            for n, _, x in parse(v):
                op[["", "hash", "prefix", "suffix"][n]] = x
            p["path"].append(op)
    return p


def commitment_proof(b):
    """A `CommitmentProof`, which must be a plain existence or non-existence proof."""
    (num, _, v), = parse(b)
    if num == 1:
        return "exist", existence(v)
    assert num == 2, "neither an existence nor a non-existence proof"
    non = {"key": b"", "left": None, "right": None}
    for n, _, x in parse(v):
        if n == 1:
            non["key"] = x
        elif n == 2:
            non["left"] = existence(x)
        elif n == 3:
            non["right"] = existence(x)
    return "nonexist", non


# The two specs: IAVL's (a node's prefix is its height, size and version as varints, 4 to 12 bytes, then a child's
# length byte) and the multistore's simple tree (a node's prefix is 0x01).
IAVL = {"child_size": 33, "min_prefix": 4, "max_prefix": 12}
SIMPLE = {"child_size": 32, "min_prefix": 1, "max_prefix": 1}


def existence_root(p):
    leaf = p["leaf"]
    assert (leaf["hash"], leaf["prehash_key"], leaf["prehash_value"], leaf["length"]) == (SHA256, 0, SHA256, VAR_PROTO)
    assert leaf["prefix"][:1] == b"\x00"
    assert p["value"], "an empty value"
    node = sha256(
        leaf["prefix"] + varint(len(p["key"])) + p["key"] + varint(32) + sha256(p["value"])
    )
    for op in p["path"]:
        assert op["hash"] == SHA256
        node = sha256(op["prefix"] + node + op["suffix"])
    return node


def branch(spec, op):
    """Which child an inner step hashes: 0 if its sibling follows it, 1 if its sibling precedes it."""
    c = spec["child_size"]
    if len(op["suffix"]) == c and spec["min_prefix"] <= len(op["prefix"]) <= spec["max_prefix"]:
        return 0
    if len(op["suffix"]) == 0 and spec["min_prefix"] + c <= len(op["prefix"]) <= spec["max_prefix"] + c:
        return 1
    raise AssertionError("an inner step of neither shape")


def adjacent(spec, left, right):
    """No key lies between two leaves under one root: above their meeting point the paths agree, there the left one
    takes the left child and the right one the right, and below it the left path is right-most and the right path
    left-most."""
    lp, rp = list(left["path"]), list(right["path"])
    tl, tr = lp.pop(), rp.pop()
    while tl["prefix"] == tr["prefix"] and tl["suffix"] == tr["suffix"]:
        tl, tr = lp.pop(), rp.pop()
    assert branch(spec, tl) == 0 and branch(spec, tr) == 1, "not neighbours at their meeting point"
    assert all(branch(spec, op) == 1 for op in lp), "the left neighbour is not right-most below it"
    assert all(branch(spec, op) == 0 for op in rp), "the right neighbour is not left-most below it"


def prove_slot(proof_bytes, key, root):
    """The value an ICS-23 proof gives `key` under `root`: the leaf's value, or empty for a proven absence."""
    kind, p = commitment_proof(proof_bytes)
    if kind == "exist":
        assert p["key"] == key, "the proof is of another key"
        assert existence_root(p) == root, "the proof is under another root"
        return p["value"]
    left, right = p["left"], p["right"]
    if left is not None:
        assert existence_root(left) == root and left["key"] < key
    if right is not None:
        assert existence_root(right) == root and right["key"] > key
    if left is not None and right is not None:
        adjacent(IAVL, left, right)
    elif left is not None:
        assert all(branch(IAVL, op) == 1 for op in left["path"]), "the left neighbour is not the last key"
    else:
        assert right is not None and all(branch(IAVL, op) == 0 for op in right["path"]), "not the first key"
    return b""


def evm_value(raw):
    """What the EVM reads for a stored value: zero if absent, else `common.BytesToHash` (left-padded, or the last 32
    bytes), the keeper's `GetState`."""
    return raw[-32:].rjust(32, b"\x00")


# ---------------------------------------------------------------------------
# ABI
# ---------------------------------------------------------------------------


def word(n):
    return n.to_bytes(32, "big")


def abi_slots_values(slots, values):
    """`abi.encode(bytes32[] slots, bytes32[] values)`."""
    n = len(slots)
    return (
        word(0x40)
        + word(0x40 + 32 * (n + 1))
        + word(n)
        + b"".join(slots)
        + word(len(values))
        + b"".join(values)
    )
