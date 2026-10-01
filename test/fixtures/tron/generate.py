#!/usr/bin/env python3
"""Builds the Tron fixture of test/TronStateVerifier.t.sol from TronGrid's public API, read-only.

    python3 test/fixtures/tron/generate.py [api-url] [boundary-ms]

Needs pycryptodome. It writes chain.json next to itself: the blocks around one 6-hour maintenance boundary (the old
period's last 40, the maintenance block, and the new period's first round and the blocks that vouch for it), the
producer list of each period as their blocks show it, and in each period a block with a TriggerSmartContract
transaction, its Merkle path and the transaction's fields.

Everything is checked here first, independently of the Solidity: each header's protobuf, written from its fields,
hashes to its block id; each signature recovers to a key; each block names its parent; each period's list is read
from a full round of its own blocks; and each proof block's transaction tree, rebuilt from all its transactions with
their results, matches its header, with the chosen transaction written from its fields exactly as the block holds
it. A fixture that reaches the Solidity tests is already known to be real.
"""
import hashlib
import json
import os
import sys
import time
import urllib.request

from Crypto.Hash import keccak as _keccak

API = sys.argv[1] if len(sys.argv) > 1 else "https://api.trongrid.io"
# The boundary of 1 October 2026 at 12:00 UTC; any maintenance time on the grid works.
BOUNDARY = int(sys.argv[2]) if len(sys.argv) > 2 else 1790856000000
HERE = os.path.dirname(os.path.abspath(__file__))
SLOT = 3000
ROUND = 27
QUORUM = 19
BEFORE = 40
TYPE_URL = b"type.googleapis.com/protocol.TriggerSmartContract"


def post(path, body):
    for attempt in range(6):
        try:
            req = urllib.request.Request(
                API + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except Exception as e:  # rate limits and timeouts: back off and retry
            if attempt == 5:
                raise
            time.sleep(1 + 2 * attempt)


def header(num):
    time.sleep(0.12)
    return post("/wallet/getblock", {"id_or_num": str(num), "detail": False})


def full_block(num):
    time.sleep(0.12)
    return post("/wallet/getblockbynum", {"num": num})


# ---------------------------------------------------------------------
# protobuf, as Java writes it: fields ascending, zero scalars and empty strings left out
# ---------------------------------------------------------------------


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def vfield(f, n):
    return varint(f << 3) + varint(n) if n else b""


def bfield(f, b):
    return varint(f << 3 | 2) + varint(len(b)) + b if b else b""


sha = lambda x: hashlib.sha256(x).digest()


def keccak(b):
    k = _keccak.new(digest_bits=256)
    k.update(b)
    return k.digest()


def header_raw(h):
    return (
        vfield(1, h["timestamp"])
        + bfield(2, bytes.fromhex(h["txTrieRoot"]))
        + bfield(3, bytes.fromhex(h["parentHash"]))
        + vfield(7, h["number"])
        + vfield(8, h.get("witness_id", 0))
        + bfield(9, bytes.fromhex(h["witness_address"]))
        + vfield(10, h.get("version", 0))
        + bfield(11, bytes.fromhex(h.get("accountStateRoot", "")))
    )


RESULTS = {"DEFAULT": 0, "SUCCESS": 1, "REVERT": 2, "OUT_OF_ENERGY": 10}


def tx_bytes(t):
    """A transaction as its block holds it: raw_data, signatures, and results (TransactionCapsule.getMerkleHash)."""
    b = bfield(1, bytes.fromhex(t["raw_data_hex"]))
    for s in t.get("signature", []):
        b += bfield(2, bytes.fromhex(s))
    for r in t.get("ret", []):
        extra = set(r) - {"fee", "ret", "contractRet"}
        assert not extra, extra
        result = vfield(1, r.get("fee", 0)) + vfield(2, 1 if r.get("ret") == "FAILED" else 0)
        result += vfield(3, RESULTS[r.get("contractRet", "DEFAULT")])
        b += bfield(5, result)
    return b


def trigger_raw(raw, owner, target, data, permission):
    """`Transaction.raw` of a TriggerSmartContract call, as TronStateVerifier writes it."""
    trigger = bfield(1, owner) + bfield(2, target) + bfield(4, data)
    any_ = bfield(1, TYPE_URL) + bfield(2, trigger)
    contract = vfield(1, 31) + bfield(2, any_) + vfield(5, permission)
    return (
        bfield(1, bytes.fromhex(raw.get("ref_block_bytes", "")))
        + bfield(4, bytes.fromhex(raw.get("ref_block_hash", "")))
        + vfield(8, raw.get("expiration", 0))
        + bfield(11, contract)
        + vfield(14, raw.get("timestamp", 0))
        + vfield(18, raw.get("fee_limit", 0))
    )


def merkle(leaves, index):
    """Tron's transaction tree (`MerkleTree`): pairs hashed, an odd node promoted, no domain separation. Returns the
    root and leaf `index`'s path: its siblings bottom up, and bit i set where path[i] is the left one."""
    path, sides = [], 0
    while len(leaves) > 1:
        sibling = index ^ 1
        if sibling < len(leaves):
            if index & 1:
                sides |= 1 << len(path)
            path.append(leaves[sibling])
        leaves = [sha(leaves[i] + leaves[i + 1]) if i + 1 < len(leaves) else leaves[i] for i in range(0, len(leaves), 2)]
        index //= 2
    return leaves[0], path, sides


# ---------------------------------------------------------------------
# secp256k1 public-key recovery
# ---------------------------------------------------------------------

P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def ec_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        l = 3 * a[0] * a[0] * pow(2 * a[1], P - 2, P) % P
    else:
        l = (b[1] - a[1]) * pow(b[0] - a[0], P - 2, P) % P
    x = (l * l - a[0] - b[0]) % P
    return (x, (l * (a[0] - x) - a[1]) % P)


def ec_mul(k, pt):
    r = None
    while k:
        if k & 1:
            r = ec_add(r, pt)
        pt = ec_add(pt, pt)
        k >>= 1
    return r


def recover(z, sig):
    r, s, v = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:64], "big"), sig[64]
    assert v in (0, 1), v
    y = pow((r * r * r + 7) % P, (P + 1) // 4, P)
    if y % 2 != v:
        y = P - y
    q = ec_mul(pow(r, N - 2, N), ec_add(ec_mul(s, (r, y)), ec_mul((-int.from_bytes(z, "big")) % N, G)))
    return keccak(q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big"))[12:]


# ---------------------------------------------------------------------
# the chain
# ---------------------------------------------------------------------


def checked(block):
    """A header's fields, checked: its id is its number and its protobuf's hash, and its signature recovers."""
    h = block["block_header"]["raw_data"]
    raw = header_raw(h)
    hh = sha(raw)
    assert block["blockID"] == h["number"].to_bytes(8, "big").hex() + hh[8:].hex(), h["number"]
    sig = bytes.fromhex(block["block_header"]["witness_signature"])
    assert len(sig) == 65
    witness = bytes.fromhex(h["witness_address"])
    assert len(witness) == 21 and witness[0] == 0x41
    return {
        "number": h["number"],
        "timestamp": h["timestamp"],
        "txTrieRoot": "0x" + h["txTrieRoot"],
        "parentHash": "0x" + h["parentHash"],
        "witnessId": h.get("witness_id", 0),
        "witness": "0x" + witness[1:].hex(),
        "version": h.get("version", 0),
        "accountStateRoot": "0x" + h.get("accountStateRoot", ""),
        "r": "0x" + sig[:32].hex(),
        "s": "0x" + sig[32:64].hex(),
        "v": sig[64],
        "key": "0x" + recover(hh, sig).hex(),
        "id": "0x" + block["blockID"],
    }


def first_at_or_after(t):
    now = post("/wallet/getnowblock", {})["block_header"]["raw_data"]
    lo, hi = 1, now["number"]
    while lo < hi:
        mid = (lo + hi) // 2
        if header(mid)["block_header"]["raw_data"]["timestamp"] >= t:
            hi = mid
        else:
            lo = mid + 1
    return lo


def proof_block(blocks, at, producers):
    """A TriggerSmartContract transaction in block `blocks[at]` the verifier can write, its path, and the headers from
    it to where 19 producers of `producers` have built on it."""
    num = blocks[at]["number"]
    block = full_block(num)
    txs = block.get("transactions", [])
    leaves = [sha(tx_bytes(t)) for t in txs]
    root, _, _ = merkle(leaves, 0)
    assert "0x" + root.hex() == blocks[at]["txTrieRoot"], "the transaction tree, results included"
    for index, t in enumerate(txs):
        raw = t["raw_data"]
        if set(raw) - {"ref_block_bytes", "ref_block_hash", "expiration", "contract", "timestamp", "fee_limit"}:
            continue
        if len(raw["contract"]) != 1 or raw["contract"][0]["type"] != "TriggerSmartContract":
            continue
        c = raw["contract"][0]
        value = c["parameter"]["value"]
        if set(value) - {"owner_address", "contract_address", "data"} or not value.get("data"):
            continue
        if c["parameter"]["type_url"] != TYPE_URL.decode() or set(c) - {"type", "parameter", "Permission_id"}:
            continue
        if t.get("ret") != [{"contractRet": "SUCCESS"}] and not (
            len(t.get("ret", [])) == 1 and set(t["ret"][0]) == {"contractRet", "fee"} and t["ret"][0]["contractRet"] == "SUCCESS"
        ):
            continue
        owner, target, data = (bytes.fromhex(value[k]) for k in ("owner_address", "contract_address", "data"))
        permission = c.get("Permission_id", 0)
        if trigger_raw(raw, owner, target, data, permission).hex() != t["raw_data_hex"]:
            continue
        _, path, sides = merkle(leaves, index)
        seen, end = set(), at
        while len(seen) < QUORUM:
            b = blocks[end]
            if producers.get(b["witness"]) == b["key"]:
                seen.add(b["witness"])
            end += 1
        return {
            "block": at,
            "headersEnd": end,
            "owner": "0x" + owner[1:].hex(),
            "target": "0x" + target[1:].hex(),
            "data": "0x" + data.hex(),
            "refBlockBytes": "0x" + raw.get("ref_block_bytes", ""),
            "refBlockHash": "0x" + raw.get("ref_block_hash", ""),
            "expiration": raw.get("expiration", 0),
            "timestamp": raw.get("timestamp", 0),
            "feeLimit": raw.get("fee_limit", 0),
            "permissionId": permission,
            "signatures": ["0x" + s for s in t.get("signature", [])],
            "fee": t["ret"][0].get("fee", 0),
            "leaf": "0x" + leaves[index].hex(),
            "path": ["0x" + p.hex() for p in path],
            "sides": sides,
            "txid": t["txID"],
        }
    raise SystemExit(f"no TriggerSmartContract transaction the verifier can write in block {num}")


def main():
    m = first_at_or_after(BOUNDARY)
    print("maintenance block", m)
    blocks = [checked(header(n)) for n in range(m - BEFORE, m + 3 * ROUND + 1)]
    for i in range(1, len(blocks)):
        assert blocks[i]["parentHash"] == blocks[i - 1]["id"], "linked"
    maint = BEFORE
    assert blocks[maint - 1]["timestamp"] < BOUNDARY <= blocks[maint]["timestamp"]

    def producers(span):
        out = {}
        for b in span:
            assert out.setdefault(b["witness"], b["key"]) == b["key"], "one key per producer within a span"
        return out

    old = producers(blocks[:maint])
    assert blocks[maint - 1]["timestamp"] - blocks[0]["timestamp"] >= (ROUND - 1) * SLOT
    # The learning round: from the block after the maintenance until it spans 27 slots from the block after that. The
    # block right after the maintenance is scheduled two slots behind its time (DposSlot.getTime adds the skipped slots
    # to the slot count, getScheduledWitness never takes them back); from the next one the schedule is slot mod 27.
    first = maint + 1
    vouch_from = first + 2
    while blocks[vouch_from - 1]["timestamp"] < blocks[first + 1]["timestamp"] + (ROUND - 1) * SLOT:
        vouch_from += 1
    # That reading of DposSlot, checked on the chain itself: from the second block on, each producer comes back every 27
    # slots, and the first block's producer is the one the rotation names two slots before its own.
    by_slot = {b["timestamp"] // SLOT: b["witness"] for b in blocks[first + 1 :]}
    repeats = [s for s in by_slot if s + ROUND in by_slot]
    assert repeats and all(by_slot[s + ROUND] == by_slot[s] for s in repeats), "slot modulo 27 from the second block"
    s0 = blocks[first]["timestamp"] // SLOT
    assert by_slot[s0 + ROUND - 2] == blocks[first]["witness"], "the first block is scheduled two slots behind"
    new = producers(blocks[first:vouch_from])
    vouched, end = set(), vouch_from
    while len(vouched) < QUORUM:
        b = blocks[end]
        if old.get(b["witness"]) == b["key"]:
            vouched.add(b["witness"])
        end += 1
    print(f"old list {len(old)}, new list {len(new)}, round {first}..{vouch_from}, vouched by {end - vouch_from} blocks")
    old_proof = proof_block(blocks, 5, old)
    assert old_proof["headersEnd"] <= maint, "the old period's proof stays in its period"
    new_proof = proof_block(blocks, first + 2, new)

    def listed(d):
        return [{"witness": w, "key": d[w]} for w in sorted(d, key=lambda a: int(a, 16))]

    out = {
        "source": API,
        "boundary": BOUNDARY,
        "maintenance": maint,
        "vouchFrom": vouch_from,
        "advanceEnd": end,
        "oldList": listed(old),
        "newList": listed(new),
        "headers": blocks,
        "oldProof": old_proof,
        "newProof": new_proof,
    }
    with open(os.path.join(HERE, "chain.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote chain.json:", len(blocks), "headers, proofs in blocks", blocks[old_proof["block"]]["number"], "and", blocks[new_proof["block"]]["number"])


if __name__ == "__main__":
    main()
