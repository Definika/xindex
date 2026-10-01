#!/usr/bin/env python3
"""Builds the BNB Chain fixtures of test/BnbStateVerifier.t.sol from a public RPC, read-only.

    python3 test/fixtures/bnb/generate.py [rpc-url]
    python3 test/fixtures/bnb/generate.py <rpc-url> anchor <file>

The second form writes the anchor `script/DeployStateVerifier.s.sol` deploys a verifier from: the newest epoch block
at or below the chain's finalized block, its validator set's uncompressed keys, each checked on the curve, and the
header's RLP, checked against its hash. The deploy refuses an anchor more than an hour old.

With a BNB Chain mainnet RPC (the default) it writes chain.json; with a BNB testnet one (chain id 97) it writes
testnet.json, which the same tests run on, as the testnet deployment's verifier will follow that chain.

Needs py_ecc and pycryptodome. It writes the file next to itself: four consecutive epoch blocks (BNB Chain rotates
part of its validator set at every one), the votes that finalized the last three, the votes on either side of the
block from which the third epoch's set signs, and a block at the head with the vote that finalized it and
`eth_getProof` there for WBNB's slot 0. Public nodes serve proofs only at the head, so the file is rebuilt, not
edited.

Every vote is checked here with py_ecc against the validator set the switch rule assigns it, before anything is
written, so a fixture that reaches the Solidity tests is already known to verify.
"""
import json
import os
import sys
import time
import urllib.request

from Crypto.Hash import keccak as _keccak
from py_ecc.bls import G2ProofOfPossession as bls
from py_ecc.bls.point_compression import decompress_G1, decompress_G2
from py_ecc.optimized_bls12_381 import normalize

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://bsc-rpc.publicnode.com"
HERE = os.path.dirname(os.path.abspath(__file__))
EPOCH = 1000  # since Maxwell
# Each chain's WBNB, which stores its name, "Wrapped BNB", in slot 0 on both, and the file its fixture goes to.
CHAINS = {
    56: ("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", "chain.json"),
    97: ("0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd", "testnet.json"),
}
UNUSED_SLOT = "0x" + "ab" * 32  # WBNB stores nothing there
ABSENT = "0x" + "00" * 14 + "58696e646578"  # "Xindex": an address nothing was ever sent to
FIELDS = [
    "parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot", "receiptsRoot", "logsBloom", "difficulty",
    "number", "gasLimit", "gasUsed", "timestamp", "extraData", "mixHash", "nonce", "baseFeePerGas",
    "withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash",
]
INTS = {"difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas", "blobGasUsed", "excessBlobGas"}


def keccak(b):
    k = _keccak.new(digest_bits=256)
    k.update(b)
    return k.digest()


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "curl/8.0"})
    for attempt in range(6):
        try:
            reply = json.load(urllib.request.urlopen(req, timeout=30))
            if "error" in reply:
                raise RuntimeError(reply["error"])
            return reply["result"]
        except Exception:
            if attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))


def rpc_batch(calls):
    """One JSON-RPC batch, answered in order; None if any call failed."""
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "curl/8.0"})
    replies = sorted(json.load(urllib.request.urlopen(req, timeout=30)), key=lambda r: r["id"])
    if any("error" in r for r in replies):
        print("batch error:", [r.get("error") for r in replies])
        return None
    return [r["result"] for r in replies]


# --- RLP -------------------------------------------------------------------------------------------------------------

def _len(n, offset):
    if n < 56:
        return bytes([offset + n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(b)]) + b


def enc_bytes(b):
    return b if len(b) == 1 and b[0] < 0x80 else _len(len(b), 0x80) + b


def enc_int(i):
    return b"\x80" if i == 0 else enc_bytes(i.to_bytes((i.bit_length() + 7) // 8, "big"))


def enc_list(items):
    payload = b"".join(items)
    return _len(len(payload), 0xC0) + payload


def dec(b, i=0):
    p = b[i]
    if p < 0x80:
        return b[i:i + 1], i + 1
    if p <= 0xB7:
        n = p - 0x80
        return b[i + 1:i + 1 + n], i + 1 + n
    if p <= 0xBF:
        m = p - 0xB7
        n = int.from_bytes(b[i + 1:i + 1 + m], "big")
        return b[i + 1 + m:i + 1 + m + n], i + 1 + m + n
    if p <= 0xF7:
        n, s = p - 0xC0, i + 1
    else:
        m = p - 0xF7
        n, s = int.from_bytes(b[i + 1:i + 1 + m], "big"), i + 1 + m
    out, j = [], s
    while j < s + n:
        v, j = dec(b, j)
        out.append(v)
    return out, s + n


# --- chain data ------------------------------------------------------------------------------------------------------

_blocks = {}


def block(n):
    """Block n; a block not produced yet is waited for, as a vote on a block near the head arrives a few blocks on."""
    for _ in range(60):
        if n not in _blocks:
            b = rpc("eth_getBlockByNumber", [hex(n), False])
            if b is None:
                time.sleep(1)
                continue
            _blocks[n] = b
        return _blocks[n]
    raise RuntimeError(f"block {n} did not appear")


def header_rlp(n):
    b = block(n)
    items = []
    for f in FIELDS:
        v = b[f]
        items.append(enc_int(int(v, 16)) if f in INTS else enc_bytes(bytes.fromhex(v[2:])))
    rlp = enc_list(items)
    assert "0x" + keccak(rlp).hex() == b["hash"], f"header {n} does not hash to its block hash"
    return rlp


def extra(n):
    return bytes.fromhex(block(n)["extraData"][2:])


def validators(n):
    """The (address, compressed BLS key) entries of epoch block n, and its turn length."""
    assert n % EPOCH == 0
    ex = extra(n)
    count = ex[32]
    entries = [(ex[33 + 68 * i:53 + 68 * i], ex[53 + 68 * i:33 + 68 * (i + 1)]) for i in range(count)]
    assert [a for a, _ in entries] == sorted(a for a, _ in entries), "entries are in ascending address order"
    return entries, ex[33 + 68 * count]


def attestation(n):
    ex = extra(n)
    att = ex[33 + 68 * ex[32] + 1:-65] if n % EPOCH == 0 else ex[32:-65]
    if not att:
        return None
    a, _ = dec(att)
    vd = a[2]
    return {
        "bitset": int.from_bytes(a[0], "big"), "sig": a[1],
        "sn": int.from_bytes(vd[0], "big"), "sh": vd[1], "tn": int.from_bytes(vd[2], "big"), "th": vd[3],
    }


def vote_hash(sn, sh, tn, th):
    return keccak(enc_list([enc_int(sn), enc_bytes(sh), enc_int(tn), enc_bytes(th)]))


def _fq(v):
    return int(getattr(v, "n", v)).to_bytes(48, "big").rjust(64, b"\0")


def g1(compressed):
    x, y = normalize(decompress_G1(int.from_bytes(compressed, "big")))
    return _fq(x) + _fq(y)


def g2(compressed):
    x, y = normalize(decompress_G2((int.from_bytes(compressed[:48], "big"), int.from_bytes(compressed[48:], "big"))))
    return _fq(x.coeffs[0]) + _fq(x.coeffs[1]) + _fq(y.coeffs[0]) + _fq(y.coeffs[1])


def finality_vote(b, entries):
    """The attestation, carried by a later header, whose source is block b and target its child; checked here against
    `entries`, the set the switch rule says signs that target."""
    for h in range(b + 2, b + 8):
        a = attestation(h)
        if a and a["sn"] == b and a["tn"] == b + 1:
            assert "0x" + a["sh"].hex() == block(b)["hash"]
            keys = [k for i, (_, k) in enumerate(entries) if a["bitset"] >> i & 1]
            assert a["bitset"] >> len(entries) == 0 and 3 * len(keys) >= 2 * len(entries), "a quorum"
            assert bls.FastAggregateVerify(keys, vote_hash(b, a["sh"], b + 1, a["th"]), a["sig"]), f"vote on {b}"
            return {"targetHash": "0x" + a["th"].hex(), "bitset": hex(a["bitset"]), "signature": "0x" + g2(a["sig"]).hex()}
    raise RuntimeError(f"no attestation finalizes block {b} through its child")


def header(n):
    return {"number": n, "time": int(block(n)["timestamp"], 16), "hash": block(n)["hash"],
            "rlp": "0x" + header_rlp(n).hex()}


def keys(entries):
    return ["0x" + g1(k).hex() for _, k in entries]


def check_len(entries, turn_length):
    """Blocks after an epoch block before the snapshot takes its set: the old set's length and turn length."""
    return (len(entries) // 2 + 1) * turn_length - 1


# --- fixtures --------------------------------------------------------------------------------------------------------

def chain(WBNB):
    """Four consecutive epoch blocks, the votes that finalized the last three, the votes on either side of the third's
    switch, and a block at the head with its vote and a storage proof there."""
    # Taken first, at the head itself: public nodes refuse proofs even a few blocks back.
    # At "latest": public nodes serve proofs only at their head, and a numbered request often lands on a node a block
    # behind. The block is then found by its state root, which the proof's root node hashes to, and both proofs must
    # come from it.
    for _ in range(10):
        got = rpc_batch([
            ("eth_getProof", [WBNB, ["0x0", UNUSED_SLOT], "latest"]),
            ("eth_getProof", [ABSENT, [], "latest"]),
            ("eth_blockNumber", []),
        ])
        if got is None:
            continue
        proof, absent, near = got
        root = "0x" + keccak(bytes.fromhex(proof["accountProof"][0][2:])).hex()
        if "0x" + keccak(bytes.fromhex(absent["accountProof"][0][2:])).hex() != root:
            print("the two proofs came from different blocks; retrying")
            continue
        near = int(near, 16)
        b = next((n for n in range(near - 8, near + 4) if block(n)["stateRoot"] == root), None)
        if b is not None:
            value = proof["storageProof"][0]["value"]
            break
        print("no block near the head has the proofs' state root; retrying")
    else:
        raise RuntimeError("no consistent proof at the head")
    assert int(proof["storageProof"][0]["value"], 16) == int(value, 16)
    assert int(proof["storageProof"][1]["value"], 16) == 0, "the unused slot is empty"
    assert absent["nonce"] == "0x0" and int(absent["balance"], 16) == 0 and absent["codeHash"] in (
        "0x" + "00" * 32, "0x" + keccak(b"").hex()), "the absent account does not exist"
    top = b // EPOCH * EPOCH
    epochs = [top - 3 * EPOCH, top - 2 * EPOCH, top - EPOCH, top]
    sets = {e: validators(e) for e in epochs}

    def first_target(i):  # the first vote target epochs[i]'s set signs
        entries, tl = sets[epochs[i - 1]]
        return epochs[i] + check_len(entries, tl) + 1

    out = []
    for i, e in enumerate(epochs):
        entries, tl = sets[e]
        d = dict(header(e), turnLength=tl, count=len(entries), keys=keys(entries))
        if i > 0:
            d["vote"] = finality_vote(e, sets[epochs[i - 1]][0])  # its child is signed by the set it replaces
            d["firstTarget"] = first_target(i)
        out.append(d)
    switch = first_target(2)
    signer = 3 if b + 1 >= first_target(3) else 2
    print(f"epochs {epochs}; epoch {epochs[2]}'s set signs from {switch}; block {b} is signed by epoch {epochs[signer]}")
    return {
        "epochLength": EPOCH,
        "epochs": out,
        "switch": {
            "epoch": epochs[2],
            "firstTarget": switch,
            "before": dict(header(switch - 2), vote=finality_vote(switch - 2, sets[epochs[1]][0])),
            "after": dict(header(switch - 1), vote=finality_vote(switch - 1, sets[epochs[2]][0])),
        },
        "state": {
            "epoch": epochs[signer],
            "block": dict(header(b), stateRoot=block(b)["stateRoot"], vote=finality_vote(b, sets[epochs[signer]][0])),
            "account": WBNB,
            "slot": "0x" + "00" * 32,
            "value": "0x" + int(value, 16).to_bytes(32, "big").hex(),
            "accountProof": proof["accountProof"],
            "storageProof": proof["storageProof"][0]["proof"],
            "unusedSlot": UNUSED_SLOT,
            "unusedSlotProof": proof["storageProof"][1]["proof"],
            "absentAccount": ABSENT,
            "absentAccountProof": absent["accountProof"],
        },
    }


def anchor(path):
    """The newest final epoch block and its set, for a verifier's deployment."""
    chain_id = int(rpc("eth_chainId", []), 16)
    final = int(rpc("eth_getBlockByNumber", ["finalized", False])["number"], 16)
    e = final // EPOCH * EPOCH
    entries, tl = validators(e)
    d = dict(header(e), chainId=chain_id, source=RPC, finalized=final, turnLength=tl, count=len(entries),
             keys=keys(entries))
    with open(path, "w") as f:
        json.dump(d, f, indent=1)
        f.write("\n")
    print(f"{path} written: epoch {e} of chain {chain_id}, {len(entries)} validators, hash {d['hash']}")


def main():
    if len(sys.argv) > 3 and sys.argv[2] == "anchor":
        return anchor(sys.argv[3])
    wbnb, name = CHAINS[int(rpc("eth_chainId", []), 16)]
    fixture = chain(wbnb)
    json.dump(fixture, open(os.path.join(HERE, name), "w"), indent=1)
    print(name, "written")


if __name__ == "__main__":
    main()
