"""NEAR's light-client encodings, written from nearcore's definitions, for the fixture generator and its checks.

- `BlockHeaderInnerLite` (core/primitives/src/block_header.rs): height u64, epoch_id, next_epoch_id, prev_state_root,
  prev_outcome_root, timestamp u64, next_bp_hash, block_merkle_root; Borsh, integers little-endian.
- A block's hash: sha256(sha256(sha256(inner_lite) ++ inner_rest_hash) ++ prev_block_hash) (`BlockHeader::compute_hash`
  with `combine_hash(a, b) = sha256(a ++ b)`).
- The light client's approval message: borsh(ApprovalInner::Endorsement(next_block_hash)) ++ (height + 2) as u64 LE,
  next_block_hash = sha256(next_block_inner_hash ++ current_block_hash) (chain/chain/src/lightclient.rs, Nomicon).
- A producer set's hash: sha256(borsh(Vec<ValidatorStake>)), each `ValidatorStake::V1 {account_id, public_key, stake}`
  with its enum tag (core/primitives/src/types.rs).
"""

import hashlib
import struct

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58(s):
    n = 0
    for c in s:
        n = n * 58 + ALPHABET.index(c)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00" * pad + raw


def b58_32(s):
    out = b58(s)
    assert len(out) <= 32, s
    return out.rjust(32, b"\x00")


def key(s):
    kind, body = s.split(":")
    assert kind == "ed25519", s
    raw = b58(body)
    assert len(raw) == 32
    return raw


def sig(s):
    kind, body = s.split(":")
    assert kind == "ed25519", s
    raw = b58(body)
    assert len(raw) == 64
    return raw


def sha256(*parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def u32(x):
    return struct.pack("<I", x)


def u64(x):
    return struct.pack("<Q", x)


def u128(x):
    return x.to_bytes(16, "little")


def inner_lite(v):
    return (
        u64(v["height"])
        + b58_32(v["epoch_id"])
        + b58_32(v["next_epoch_id"])
        + b58_32(v["prev_state_root"])
        + b58_32(v["outcome_root"])
        + u64(int(v["timestamp_nanosec"]))
        + b58_32(v["next_bp_hash"])
        + b58_32(v["block_merkle_root"])
    )


def block_hash(lite, inner_rest_hash, prev_block_hash):
    return sha256(sha256(sha256(inner_lite(lite)), b58_32(inner_rest_hash)), b58_32(prev_block_hash))


def approval_message(lcb):
    current = block_hash(lcb["inner_lite"], lcb["inner_rest_hash"], lcb["prev_block_hash"])
    nxt = sha256(b58_32(lcb["next_block_inner_hash"]), current)
    return b"\x00" + nxt + u64(lcb["inner_lite"]["height"] + 2), current


def producer(p):
    assert p.get("validator_stake_struct_version", "V1") == "V1", p
    account = p["account_id"].encode()
    return b"\x00" + u32(len(account)) + account + b"\x00" + key(p["public_key"]) + u128(int(p["stake"]))


def producers(ps):
    return u32(len(ps)) + b"".join(producer(p) for p in ps)


def producers_hash(ps):
    return sha256(producers(ps))
