#!/usr/bin/env python3
"""Builds the Sui fixtures of test/SuiStateVerifier.t.sol from Sui's public GraphQL endpoint, read-only.

    python3 test/fixtures/sui/generate.py [epoch] [state-checkpoint]
    python3 test/fixtures/sui/generate.py anchor <file>

The first form writes chain.json next to itself: the committee of `epoch` (1268 by default), as the last checkpoint
of the epoch before names it, with that checkpoint's time as the epoch's start; the last checkpoint of `epoch`, its
certificate and the committee it names; and a checkpoint of the epoch after (329,700,002 by default), its certificate,
the Merkle paths of the Clock (0x6) and of the last leaf in its artifacts tree, and the Clock's fields at that
version.

The second form writes the anchor `script/DeployStateVerifier.s.sol` deploys a verifier from: the epoch in progress,
its committee as the last checkpoint of the epoch before names it, and that checkpoint's time, its start.

Needs nothing beyond Python's standard library. Everything is checked here first, independently of the Solidity:
each summary, written from the typed fields the verifier takes, is byte for byte the BCS Sui serves and hashes to the
checkpoint's digest (`blake2b("CheckpointSummary::" ++ bcs)`); each committee lists its keys in ascending order with
a voting power of 10,000 in all, and each key and signature decompresses onto its curve and compresses back to the
bytes Sui gives; the state checkpoint's artifacts tree, rebuilt from every object its transactions wrote, has the
root its summary commits to; and the Clock's fields, written as the verifier writes an object, hash to the digest of
its leaf. The certificates themselves are checked by the Solidity tests, on the EIP-2537 precompiles.
"""
import base64
import hashlib
import json
import os
import sys
import time
import urllib.request

URL = "https://graphql.mainnet.sui.io/graphql"
HERE = os.path.dirname(os.path.abspath(__file__))
CHAIN_ID = 13762264207064992463  # sui:mainnet, design/2026-10-04-four-chains-interfaces.md
EPOCH = 1268
STATE = 329700002
CLOCK = bytes(31) + b"\x06"
TOTAL_VOTING_POWER = 10_000
P = 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB
HALF = (P - 1) // 2
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
# The objects a transaction deletes or wraps are leaves with these digests (sui-types digests.rs).
DELETED, WRAPPED = bytes([99]) * 32, bytes([88]) * 32


def gql(query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json", "User-Agent": "curl/8.0"})
    for attempt in range(5):
        try:
            d = json.load(urllib.request.urlopen(req, timeout=60))
            if "errors" in d:
                raise RuntimeError(d["errors"])
            return d["data"]
        except (OSError, RuntimeError):
            if attempt == 4:
                raise
            time.sleep(2 + attempt * 3)


def b58(s):
    n = 0
    for c in s:
        n = n * 58 + B58.index(c)
    return n.to_bytes(32, "big")


def blake(b):
    return hashlib.blake2b(b, digest_size=32).digest()


def hx(b):
    return "0x" + b.hex()


# ---------------------------------------------------------------------------------------------------------------
# BCS, read and written
# ---------------------------------------------------------------------------------------------------------------


class Reader:
    def __init__(self, b):
        self.b, self.i = b, 0

    def take(self, n):
        v = self.b[self.i:self.i + n]
        assert len(v) == n, "short read"
        self.i += n
        return v

    def u8(self):
        return self.take(1)[0]

    def u64(self):
        return int.from_bytes(self.take(8), "little")

    def uleb(self):
        v, s = 0, 0
        while True:
            x = self.u8()
            v |= (x & 0x7F) << s
            s += 7
            if x < 0x80:
                return v

    def vec(self):
        return self.take(self.uleb())

    def digest(self):
        d = self.vec()
        assert len(d) == 32
        return d


def uleb(n):
    out = b""
    while True:
        if n < 0x80:
            return out + bytes([n])
        out += bytes([n & 0x7F | 0x80])
        n >>= 7


def le64(n):
    return n.to_bytes(8, "little")


def commitments(r):
    out = []
    for _ in range(r.uleb()):
        kind = r.uleb()
        assert kind in (0, 1), "a commitment the verifier does not write"
        out.append({"kind": kind, "digest": r.digest()})
    return out


def parse_summary(b):
    """CheckpointSummary (sui-types messages_checkpoint.rs), with the offsets the verifier splits it at."""
    r = Reader(b)
    s = {"epoch": r.u64(), "sequenceNumber": r.u64(), "networkTotalTransactions": r.u64(), "contentDigest": r.digest()}
    assert r.u8() == 1, "every checkpoint but genesis has a previous one"
    s["previousDigest"] = r.digest()
    s["gas"] = [r.u64() for _ in range(4)]
    s["timestampMs"] = r.u64()
    s["checkpointCommitments"] = commitments(r)
    s["restAt"] = r.i  # verifySlots: everything from the end-of-epoch option on
    if r.u8():
        s["committee"] = []
        for _ in range(r.uleb()):
            k = r.vec()
            assert len(k) == 96
            s["committee"].append((k, r.u64()))
        s["afterCommittee"] = r.i  # update: everything after the next committee
        r.u64()  # the next epoch's protocol version
        commitments(r)
    r.vec()  # version-specific data
    assert r.i == len(b), "the summary ends where its last field does"
    return s


def write_prefix(s):
    """The summary's BCS up to its commitments, written from the typed fields as the verifier writes it."""
    out = le64(s["epoch"]) + le64(s["sequenceNumber"]) + le64(s["networkTotalTransactions"])
    out += b"\x20" + s["contentDigest"] + b"\x01\x20" + s["previousDigest"]
    out += b"".join(le64(g) for g in s["gas"]) + le64(s["timestampMs"])
    out += uleb(len(s["checkpointCommitments"]))
    out += b"".join(bytes([c["kind"]]) + b"\x20" + c["digest"] for c in s["checkpointCommitments"])
    return out


def write_committee(committee):
    return b"\x01" + uleb(len(committee)) + b"".join(b"\x60" + k + le64(p) for k, p in committee)


# ---------------------------------------------------------------------------------------------------------------
# BLS12-381 points: decompressed onto the curve, in EIP-2537's encoding
# ---------------------------------------------------------------------------------------------------------------


def f2_mul(a, b):
    return ((a[0] * b[0] - a[1] * b[1]) % P, (a[0] * b[1] + a[1] * b[0]) % P)


def f2_pow(a, e):
    out = (1, 0)
    while e:
        if e & 1:
            out = f2_mul(out, a)
        a = f2_mul(a, a)
        e >>= 1
    return out


def f2_sqrt(a):
    """A square root in Fp2 for p = 3 mod 4 (Adj and Rodriguez-Henriquez, algorithm 9)."""
    a1 = f2_pow(a, (P - 3) // 4)
    alpha = f2_mul(f2_mul(a1, a1), a)
    x0 = f2_mul(a1, a)
    root = f2_mul((0, 1), x0) if alpha == (P - 1, 0) else f2_mul(f2_pow(((1 + alpha[0]) % P, alpha[1]), (P - 1) // 2), x0)
    assert f2_mul(root, root) == a, "not a square: off the curve"
    return root


def fp(v):
    return v.to_bytes(48, "big").rjust(64, b"\0")


def g1(compressed):
    """A 48-byte compressed G1 point (a min-sig signature) as EIP-2537's 128 bytes."""
    assert len(compressed) == 48 and compressed[0] & 0xC0 == 0x80, "compressed, not the identity"
    x = int.from_bytes(compressed, "big") & ((1 << 381) - 1)
    rhs = (pow(x, 3, P) + 4) % P
    y = pow(rhs, (P + 1) // 4, P)
    assert y * y % P == rhs, "off the curve"
    if (y > HALF) != bool(compressed[0] & 0x20):
        y = P - y
    return fp(x) + fp(y)


def g2_sign(y):
    return y[1] > HALF if y[1] else y[0] > HALF


def g2(compressed):
    """A 96-byte compressed G2 point (a key): x.c1 then x.c0, flags in the top bits, as EIP-2537's 256 bytes."""
    assert len(compressed) == 96 and compressed[0] & 0xC0 == 0x80, "compressed, not the identity"
    x = (int.from_bytes(compressed[48:], "big"), int.from_bytes(compressed[:48], "big") & ((1 << 381) - 1))
    rhs = f2_mul(f2_mul(x, x), x)
    rhs = ((rhs[0] + 4) % P, (rhs[1] + 4) % P)
    y = f2_sqrt(rhs)
    if g2_sign(y) != bool(compressed[0] & 0x20):
        y = ((P - y[0]) % P, (P - y[1]) % P)
    point = fp(x[0]) + fp(x[1]) + fp(y[0]) + fp(y[1])
    assert compress_g2(point) == compressed, "compresses back"
    return point


def compress_g2(point):
    c0, c1, y0, y1 = (int.from_bytes(point[i:i + 64], "big") for i in range(0, 256, 64))
    out = bytearray(c1.to_bytes(48, "big") + c0.to_bytes(48, "big"))
    out[0] |= 0x80 | (0x20 if g2_sign((y0, y1)) else 0)
    return bytes(out)


def committee_json(committee):
    keys = [k for k, _ in committee]
    assert keys == sorted(keys) and len(set(keys)) == len(keys), "ascending, as Committee::new sorts it"
    assert sum(p for _, p in committee) == TOTAL_VOTING_POWER
    return {"keys": hx(b"".join(g2(k) for k in keys)), "compressed": [hx(k) for k in keys],
            "powers": [p for _, p in committee]}


def bitmap(indices, n):
    words = [0] * ((n + 255) // 256)
    for i in indices:
        assert 0 <= i < n
        words[i // 256] |= 1 << (i % 256)
    return [hex(w) for w in words]


# ---------------------------------------------------------------------------------------------------------------
# Checkpoints
# ---------------------------------------------------------------------------------------------------------------

LAST = """query($e: UInt53) { epoch(epochId: $e) { epochId checkpoints(last: 1) { nodes { sequenceNumber } } } }"""
CHECKPOINT = """query($s: UInt53) { checkpoint(sequenceNumber: $s) { sequenceNumber digest artifactsDigest summaryBcs
  validatorSignatures { signature signersMap epoch { epochId } } } }"""


def last_of(epoch):
    return int(gql(LAST, {"e": epoch})["epoch"]["checkpoints"]["nodes"][0]["sequenceNumber"])


def checkpoint(seq):
    c = gql(CHECKPOINT, {"s": seq})["checkpoint"]
    b = base64.b64decode(c["summaryBcs"])
    assert blake(b"CheckpointSummary::" + b) == b58(c["digest"]), "the summary hashes to the checkpoint's digest"
    s = parse_summary(b)
    assert int(c["validatorSignatures"]["epoch"]["epochId"]) == s["epoch"]
    s["bcs"], s["digest"] = b, b58(c["digest"])
    s["signature"] = base64.b64decode(c["validatorSignatures"]["signature"])
    s["signers"] = c["validatorSignatures"]["signersMap"]
    art = [x["digest"] for x in s["checkpointCommitments"] if x["kind"] == 1]
    assert art and art[0] == b58(c["artifactsDigest"])
    s["artifactsDigest"] = art[0]
    return s


def summary_json(s, rest_at):
    assert write_prefix(s) == s["bcs"][:s["restAt"]], "written from its fields, the summary is Sui's"
    return {
        "epoch": s["epoch"], "sequenceNumber": s["sequenceNumber"],
        "networkTotalTransactions": s["networkTotalTransactions"], "contentDigest": hx(s["contentDigest"]),
        "previousDigest": hx(s["previousDigest"]), "gas": [str(g) for g in s["gas"]], "timestampMs": s["timestampMs"],
        "commitmentKinds": [x["kind"] for x in s["checkpointCommitments"]],
        "commitmentDigests": [hx(x["digest"]) for x in s["checkpointCommitments"]],
        "rest": hx(s["bcs"][rest_at:]), "digest": hx(s["digest"]), "bcs": hx(s["bcs"]),
    }


def certificate_json(s, size):
    return {"signature": hx(g1(s["signature"])), "compressed": hx(s["signature"]), "signers": bitmap(s["signers"], size),
            "signerCount": len(s["signers"])}


# ---------------------------------------------------------------------------------------------------------------
# The artifacts tree
# ---------------------------------------------------------------------------------------------------------------

WRITES = """query($s: UInt53, $after: String) { checkpoint(sequenceNumber: $s) { transactions(first: 50, after: $after) {
  pageInfo { hasNextPage endCursor } nodes { effects { lamportVersion objectChanges(first: 50) {
  pageInfo { hasNextPage } nodes { address idDeleted outputState { version digest } } } } } } } }"""
OBJECT = """query($a: SuiAddress!, $v: UInt53) { object(address: $a, version: $v) { digest objectBcs } }"""


def object_states(seq):
    """Every object the checkpoint's transactions wrote, deleted or wrapped, at its last version: `written()` of each
    transaction's effects (sui-types effects_v2.rs), merged in order (messages_checkpoint.rs `CheckpointArtifacts`)."""
    states, after = {}, None
    while True:
        conn = gql(WRITES, {"s": seq, "after": after})["checkpoint"]["transactions"]
        for t in conn["nodes"]:
            e = t["effects"]
            assert not e["objectChanges"]["pageInfo"]["hasNextPage"]
            lamport = int(e["lamportVersion"])
            for ch in e["objectChanges"]["nodes"]:
                oid = bytes.fromhex(ch["address"][2:].rjust(64, "0"))
                out = ch["outputState"]
                v, d = (int(out["version"]), b58(out["digest"])) if out else (lamport, DELETED if ch["idDeleted"] else WRAPPED)
                assert oid not in states or states[oid][0] < v
                states[oid] = (v, d)
        if not conn["pageInfo"]["hasNextPage"]:
            return states
        after = conn["pageInfo"]["endCursor"]


def leaf(oid, version, digest):
    return oid + le64(version) + b"\x20" + digest


def merkle(leaves):
    """fastcrypto merkle.rs: leaves `blake2b(0x00 ++ leaf)`, nodes `blake2b(0x01 ++ left ++ right)`, an odd level
    closed by an empty node of zeros."""
    levels = [[blake(b"\x00" + x) for x in leaves]]
    while len(levels[-1]) > 1:
        level = levels[-1]
        if len(level) % 2:
            level.append(bytes(32))
        levels.append([blake(b"\x01" + level[i] + level[i + 1]) for i in range(0, len(level), 2)])
    return levels


def parse_object(b):
    """`ObjectInner` (sui-types object.rs) of a Move object whose type has no type parameters."""
    r = Reader(b)
    assert r.u8() == 0 and r.u8() == 0, "a Move object of a type MoveObjectType_::Other names"
    o = {"package": r.take(32), "module": r.vec().decode(), "name": r.vec().decode()}
    assert r.uleb() == 0, "no type parameters"
    o["hasPublicTransfer"] = bool(r.u8())
    o["version"] = r.u64()
    o["contents"] = r.vec()
    start = r.i
    assert r.u8() == 2, "the Clock is shared"
    r.u64()
    o["owner"] = b[start:r.i]
    o["previousTransaction"] = r.digest()
    o["storageRebate"] = r.u64()
    assert r.i == len(b)
    return o


def write_object(o):
    """An object's BCS as the verifier writes it, with `Object::`, the name its digest hashes it under."""
    return (b"Object::\x00\x00" + o["package"] + uleb(len(o["module"])) + o["module"].encode() + uleb(len(o["name"]))
            + o["name"].encode() + b"\x00" + bytes([o["hasPublicTransfer"]]) + le64(o["version"])
            + uleb(len(o["contents"])) + o["contents"] + o["owner"] + b"\x20" + o["previousTransaction"]
            + le64(o["storageRebate"]))


def state(seq, size):
    s = checkpoint(seq)
    states = object_states(seq)
    ids = sorted(states)
    levels = merkle([leaf(i, *states[i]) for i in ids])
    assert blake(b"\x01\x20" + levels[-1][0]) == s["artifactsDigest"], "the tree's root is the one committed to"
    def proof(index):
        path, i = [], index
        for level in levels[:-1]:
            path.append(level[i ^ 1])
            i //= 2
        oid = ids[index]
        return {"objectId": hx(oid), "version": states[oid][0], "digest": hx(states[oid][1]), "index": index,
                "path": [hx(x) for x in path]}

    index = ids.index(CLOCK)
    version, digest = states[CLOCK]
    c = gql(OBJECT, {"a": "0x6", "v": version})["object"]
    bcs = base64.b64decode(c["objectBcs"])
    assert b58(c["digest"]) == digest
    o = parse_object(bcs)
    assert blake(write_object(o)) == digest, "written from its fields, the Clock hashes to its leaf's digest"
    return {
        "checkpoint": summary_json(s, s["restAt"]), "certificate": certificate_json(s, size),
        "artifactsDigest": hx(s["artifactsDigest"]), "leafCount": len(ids),
        # The Clock's leaf, and the last one, whose first sibling is the empty node closing an odd level.
        "leaf": proof(index), "lastLeaf": proof(len(ids) - 1),
        "object": {"package": hx(o["package"]), "module": o["module"], "name": o["name"],
                   "hasPublicTransfer": o["hasPublicTransfer"], "version": o["version"], "contents": hx(o["contents"]),
                   "owner": hx(o["owner"]), "previousTransaction": hx(o["previousTransaction"]),
                   "storageRebate": o["storageRebate"]},
    }


def committee_of(epoch):
    """`epoch`'s committee and start, as the last checkpoint of the epoch before names them."""
    s = checkpoint(last_of(epoch - 1))
    assert s["epoch"] == epoch - 1
    return s


def chain(epoch, state_seq):
    named = committee_of(epoch)
    end = checkpoint(last_of(epoch))
    assert end["epoch"] == epoch and "committee" in end
    size = len(named["committee"])
    st = state(state_seq, len(end["committee"]))
    assert st["checkpoint"]["epoch"] == epoch + 1
    return {
        "source": URL, "chainId": str(CHAIN_ID),
        "anchor": dict(committee_json(named["committee"]), epoch=epoch, startMs=named["timestampMs"],
                       namedBy=named["sequenceNumber"]),
        "step": {"checkpoint": summary_json(end, end["afterCommittee"]), "certificate": certificate_json(end, size),
                 "next": committee_json(end["committee"])},
        "state": st,
    }


def anchor(path):
    """The epoch in progress, for a verifier's deployment."""
    epoch = int(gql("{ epoch { epochId } }")["epoch"]["epochId"])
    named = committee_of(epoch)
    d = dict(committee_json(named["committee"]), source=URL, chainId=str(CHAIN_ID), epoch=epoch,
             startMs=named["timestampMs"], namedBy=named["sequenceNumber"], namedByDigest=hx(named["digest"]))
    with open(path, "w") as f:
        json.dump(d, f, indent=1)
        f.write("\n")
    print(f"{path} written: epoch {epoch}, {len(named['committee'])} validators, started at {named['timestampMs']} ms")


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "anchor":
        return anchor(sys.argv[2])
    epoch = int(sys.argv[1]) if len(sys.argv) > 1 else EPOCH
    state_seq = int(sys.argv[2]) if len(sys.argv) > 2 else STATE
    with open(os.path.join(HERE, "chain.json"), "w") as f:
        json.dump(chain(epoch, state_seq), f, indent=1)
        f.write("\n")
    print("chain.json written")


if __name__ == "__main__":
    main()
