"""Builds `mainnet.json`, the NEAR state verifier's fixtures, from mainnet's RPC (read-only), checking each link with
`borsh_near` as it goes, an implementation separate from the Rust statement and the Solidity verifier.

    uv run --with pynacl python3 generate.py [rpc-url]

- the anchor: an epoch E-1, its ordered block producers (`EXPERIMENTAL_validators_ordered`), checked against the
  `next_bp_hash` of a block of E-2, whose time is when the set was named;
- the blocks: E-1's last final block (`next_light_client_block` from E-2), carrying E's producers, then the head
  (`next_light_client_block` from it), every approval checked with PyNaCl;
- a real receipt's outcome proof under the head (`EXPERIMENTAL_light_client_proof`), checked to the head's
  `block_merkle_root`, and the block the receipt executed in;
- the public values the statement must commit for that input, and a synthetic `attest` outcome under a synthetic head
  for the verifier's own checks, its tree computed here.
"""

import base64
import json
import sys

import nacl.signing
from Crypto.Hash import keccak

from borsh_near import (
    ALPHABET,
    approval_message,
    b58_32,
    block_hash,
    key,
    producers_hash,
    sha256,
    sig,
    u32,
    u64,
    u128,
)
from rpc import MAINNET, call
from solidity_view import flatten

URL = sys.argv[1] if len(sys.argv) > 1 else MAINNET
EPOCH_LENGTH = 43_200

# The interfaces doc (`design/2026-10-03-near-stellar-interfaces.md`), for the synthetic attest.
ATTEST_DOMAIN = bytes.fromhex("b0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c")
NEAR_MAINNET = 339552387624818629


def enc58(b):
    n = int.from_bytes(b, "big")
    s = ""
    while n:
        n, r = divmod(n, 58)
        s = ALPHABET[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\x00"))) + s


def h(b):
    return "0x" + b.hex()


def rpc(method, params):
    return call(method, params, URL)


def producers_json(ps):
    return [{"account_id": p["account_id"], "public_key": h(key(p["public_key"])), "stake": p["stake"]} for p in ps]


def check_block(lcb, ps):
    """Every present approval verifies and they hold strictly more than two thirds of the whole set's stake."""
    msg, current = approval_message(lcb)
    total = sum(int(p["stake"]) for p in ps)
    approved = 0
    for i, p in enumerate(ps):
        s = lcb["approvals_after_next"][i] if i < len(lcb["approvals_after_next"]) else None
        if s is None:
            continue
        nacl.signing.VerifyKey(key(p["public_key"])).verify(msg, sig(s))
        approved += int(p["stake"])
    assert approved > total * 2 // 3, (approved, total)
    if lcb.get("next_bps"):
        assert producers_hash(lcb["next_bps"]) == b58_32(lcb["inner_lite"]["next_bp_hash"])
    return current, approved, total


def lite_json(lite):
    return {
        "height": lite["height"],
        "epoch_id": h(b58_32(lite["epoch_id"])),
        "next_epoch_id": h(b58_32(lite["next_epoch_id"])),
        "prev_state_root": h(b58_32(lite["prev_state_root"])),
        "outcome_root": h(b58_32(lite["outcome_root"])),
        "timestamp": int(lite["timestamp_nanosec"]),
        "next_bp_hash": h(b58_32(lite["next_bp_hash"])),
        "block_merkle_root": h(b58_32(lite["block_merkle_root"])),
    }


def block_json(lcb):
    return {
        "prev_block_hash": h(b58_32(lcb["prev_block_hash"])),
        "next_block_inner_hash": h(b58_32(lcb["next_block_inner_hash"])),
        "inner_lite": lite_json(lcb["inner_lite"]),
        "inner_rest_hash": h(b58_32(lcb["inner_rest_hash"])),
        "next_bps": producers_json(lcb["next_bps"]) if lcb.get("next_bps") else None,
        "approvals_after_next": [h(sig(s)) if s else None for s in lcb["approvals_after_next"]],
    }


def path_json(items):
    return [{"hash": h(b58_32(i["hash"])), "left": i["direction"] == "Left"} for i in items]


def path_root(leaf, items):
    out = leaf
    for i in items:
        s = b58_32(i["hash"])
        out = sha256(s, out) if i["direction"] == "Left" else sha256(out, s)
    return out


def outcome_leaf(receipt_id, receipt_ids, gas_burnt, tokens_burnt, executor, value, logs):
    """`hash_borsh(ExecutionOutcomeWithId::to_hashes())`: the id, the hash of `PartialExecutionOutcome` (receipt ids,
    gas, tokens, executor, `PartialExecutionStatus::SuccessValue` = tag 2), then each log's hash."""
    partial = (
        u32(len(receipt_ids))
        + b"".join(receipt_ids)
        + u64(gas_burnt)
        + u128(tokens_burnt)
        + u32(len(executor))
        + executor
        + b"\x02"
        + u32(len(value))
        + value
    )
    hashes = [receipt_id, sha256(partial)] + [sha256(log) for log in logs]
    return sha256(u32(len(hashes)) + b"".join(hashes))


def word(x):
    return x.to_bytes(32, "big")


def attest_record(chain_id, vault_id, height, timestamp, slots, values):
    """`abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestamp, slots, values)`, written word by word."""
    head = ATTEST_DOMAIN + word(chain_id) + vault_id + word(height) + word(timestamp)
    slots_at = 7 * 32
    values_at = slots_at + 32 + 32 * len(slots)
    body = word(len(slots)) + b"".join(slots) + word(len(values)) + b"".join(values)
    return head + word(slots_at) + word(values_at) + body


def main():
    start = rpc("validators", [None])["epoch_start_height"]
    in_e2 = rpc("block", {"block_id": start - 2 * EPOCH_LENGTH + 100})["header"]
    in_e1 = rpc("block", {"block_id": start - EPOCH_LENGTH + 100})["header"]

    lcb1 = rpc("next_light_client_block", {"last_block_hash": in_e2["hash"]})
    assert lcb1["inner_lite"]["epoch_id"] == in_e1["epoch_id"], "E-1's light-client block"
    bps1 = rpc("EXPERIMENTAL_validators_ordered", [in_e1["hash"]])
    assert producers_hash(bps1) == b58_32(in_e2["next_bp_hash"]), "E-2 names E-1's producers"
    hash1, a1, t1 = check_block(lcb1, bps1)

    head = rpc("next_light_client_block", {"last_block_hash": enc58(hash1)})
    assert head["inner_lite"]["epoch_id"] == lcb1["inner_lite"]["next_epoch_id"], "the head is in E"
    head_hash, a2, t2 = check_block(head, lcb1["next_bps"])
    print("blocks", lcb1["inner_lite"]["height"], head["inner_lite"]["height"], "stake", a1 / t1, a2 / t2)

    # A real receipt with a value, executed a little before the head.
    found = None
    top = head["inner_lite"]["height"]
    for back in range(40, 600, 9):
        b = rpc("block", {"block_id": top - back})
        for c in b["chunks"]:
            if c["tx_root"] == "11111111111111111111111111111111":
                continue
            ch = rpc("chunk", {"chunk_id": c["chunk_hash"]})
            for tx in ch["transactions"][:4]:
                st = rpc("EXPERIMENTAL_tx_status", {"tx_hash": tx["hash"], "sender_account_id": tx["signer_id"], "wait_until": "NONE"})
                for ro in st.get("receipts_outcome", []):
                    s = ro["outcome"]["status"]
                    if isinstance(s, dict) and s.get("SuccessValue") and ro["outcome"]["executor_id"] != tx["signer_id"]:
                        found = ro
                        break
                if found:
                    break
            if found:
                break
        if found:
            break
    proof = rpc(
        "EXPERIMENTAL_light_client_proof",
        {"type": "receipt", "receipt_id": found["id"], "receiver_id": found["outcome"]["executor_id"], "light_client_head": enc58(head_hash)},
    )
    o = proof["outcome_proof"]["outcome"]
    value = base64.b64decode(o["status"]["SuccessValue"])
    leaf = outcome_leaf(
        b58_32(proof["outcome_proof"]["id"]),
        [b58_32(r) for r in o["receipt_ids"]],
        o["gas_burnt"],
        int(o["tokens_burnt"]),
        o["executor_id"].encode(),
        value,
        [log.encode() for log in o["logs"]],
    )
    lite = proof["block_header_lite"]
    root = path_root(sha256(path_root(leaf, proof["outcome_proof"]["proof"])), proof["outcome_root_proof"])
    assert root == b58_32(lite["inner_lite"]["outcome_root"]), "the outcome is under its block's outcome root"
    including = block_hash(lite["inner_lite"], lite["inner_rest_hash"], lite["prev_block_hash"])
    assert path_root(including, proof["block_proof"]) == b58_32(head["inner_lite"]["block_merkle_root"])
    executed = rpc("block", {"block_id": found["block_hash"]})["header"]

    # The statement's public values for anchor (E-1, its producers) and blocks [lcb1, head].
    epoch_out = b58_32(head["inner_lite"]["next_epoch_id"]) if head.get("next_bps") else b58_32(head["inner_lite"]["epoch_id"])
    producers_out = producers_hash(head["next_bps"]) if head.get("next_bps") else producers_hash(lcb1["next_bps"])
    named_at = int(head["inner_lite"]["timestamp_nanosec"]) if head.get("next_bps") else int(lcb1["inner_lite"]["timestamp_nanosec"])
    public_values = (
        b58_32(in_e1["epoch_id"])
        + producers_hash(bps1)
        + epoch_out
        + producers_out
        + word(named_at)
        + word(head["inner_lite"]["height"])
        + word(int(head["inner_lite"]["timestamp_nanosec"]))
        + b58_32(head["inner_lite"]["block_merkle_root"])
    )

    # A synthetic attest by a vault at `xindex-vault.near`: its outcome second in its chunk's tree, the chunk first in
    # its block's, the block second of three under a synthetic head's `block_merkle_root`.
    account = b"xindex-vault.near"
    vault_id = keccak.new(digest_bits=256, data=account).digest()
    slots = [bytes.fromhex("11" * 32), word(25)]
    values = [bytes.fromhex("22" * 32), word(0)]
    height, timestamp = 218_000_001, 1_791_000_000_123_456_789
    record = attest_record(NEAR_MAINNET, vault_id, height, timestamp, slots, values)
    receipt_id = sha256(b"synthetic receipt")
    gas, tokens = 2_428_000_000_000, 242_800_000_000_000_000_000
    s_leaf = outcome_leaf(receipt_id, [], gas, tokens, account, record, [])
    other_outcome, other_chunk = sha256(b"another outcome"), sha256(b"another chunk")
    chunk_root = sha256(other_outcome, s_leaf)
    s_outcome_root = sha256(sha256(chunk_root), other_chunk)
    s_lite = {
        "height": height + 1,
        "epoch_id": enc58(b58_32(in_e1["epoch_id"])),
        "next_epoch_id": enc58(b58_32(in_e1["next_epoch_id"])),
        "prev_state_root": enc58(sha256(b"state")),
        "outcome_root": enc58(s_outcome_root),
        "timestamp_nanosec": str(timestamp + 600_000_000),
        "next_bp_hash": enc58(producers_hash(bps1)),
        "block_merkle_root": enc58(sha256(b"older blocks")),
    }
    s_rest, s_prev = sha256(b"inner rest"), sha256(b"executed in")
    s_block = block_hash(s_lite, enc58(s_rest), enc58(s_prev))
    first, third = sha256(b"first block"), sha256(b"third block")
    s_head_root = sha256(sha256(first, s_block), third)
    s_head_height, s_head_time = height + 9, timestamp + 6_000_000_000
    s_public_values = (
        b58_32(in_e1["epoch_id"])
        + producers_hash(bps1)
        + b58_32(in_e1["epoch_id"])
        + producers_hash(bps1)
        + word(0)
        + word(s_head_height)
        + word(s_head_time)
        + s_head_root
    )
    synthetic = {
        "account": account.decode(),
        "vault_id": h(vault_id),
        "chain_id": NEAR_MAINNET,
        "slots": [h(x) for x in slots],
        "values": [h(x) for x in values],
        "height": height,
        "timestamp": timestamp,
        "record": h(record),
        "receipt_id": h(receipt_id),
        "gas_burnt": gas,
        "tokens_burnt": str(tokens),
        "outcome_path": [{"hash": h(other_outcome), "left": True}],
        "outcome_root_path": [{"hash": h(other_chunk), "left": False}],
        "block": {"inner_lite": lite_json(s_lite), "inner_rest_hash": h(s_rest), "prev_block_hash": h(s_prev)},
        "block_path": [{"hash": h(first), "left": True}, {"hash": h(third), "left": False}],
        "head": {"height": s_head_height, "timestamp": s_head_time, "block_merkle_root": h(s_head_root)},
        "public_values": h(s_public_values),
    }

    out = {
        "source": URL,
        "anchor": {
            "epoch_id": h(b58_32(in_e1["epoch_id"])),
            "producers": producers_json(bps1),
            "producers_hash": h(producers_hash(bps1)),
            "named_at": int(in_e2["timestamp_nanosec"]),
            "named_by_height": in_e2["height"],
        },
        "blocks": [block_json(lcb1), block_json(head)],
        "public_values": h(public_values),
        "head_hash": h(head_hash),
        "outcome": {
            "receipt_id": h(b58_32(proof["outcome_proof"]["id"])),
            "receipt_ids": [h(b58_32(r)) for r in o["receipt_ids"]],
            "gas_burnt": o["gas_burnt"],
            "tokens_burnt": o["tokens_burnt"],
            "executor": o["executor_id"],
            "value": h(value),
            "logs": [h(log.encode()) for log in o["logs"]],
            "outcome_path": path_json(proof["outcome_proof"]["proof"]),
            "outcome_root_path": path_json(proof["outcome_root_proof"]),
            "block": {
                "inner_lite": lite_json(lite["inner_lite"]),
                "inner_rest_hash": h(b58_32(lite["inner_rest_hash"])),
                "prev_block_hash": h(b58_32(lite["prev_block_hash"])),
            },
            "block_path": path_json(proof["block_proof"]),
            "executed_in": {"hash": h(b58_32(executed["hash"])), "height": executed["height"], "timestamp": int(executed["timestamp_nanosec"])},
        },
        "synthetic": synthetic,
    }
    with open("mainnet.json", "w") as f:
        json.dump(flatten(out), f, indent=1)
        f.write("\n")
    print("wrote mainnet.json: receipt", found["id"], "by", o["executor_id"])


if __name__ == "__main__":
    main()
