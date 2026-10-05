#!/usr/bin/env python3
"""Builds what `SuiStateVerifier` takes in production, read-only from Sui's GraphQL: an `update` to the next epoch's
committee, and the `AttestProof` of one `vault::attest`. DRAFT (2026-10-06): the rebalance filler (`keeper/chains/
sui.mjs`) runs it; nothing here has run against mainnet yet.

    python3 sui/proof.py <graphql-url> update <epoch> <out.json>
    python3 sui/proof.py <graphql-url> attest <checkpoint> <attestation-object-id> <out.json>

`update` takes the epoch the verifier is in and writes its committee, the epoch's last checkpoint with its certificate,
and the committee that checkpoint names, as `NextCommittee` (each key's source in the committee in force, or NEW_KEY
and the key itself). `attest` writes the committee of the checkpoint's epoch, the checkpoint and its certificate, and
the `Attestation` object's fields, its record's time and values, and its leaf and path in the checkpoint's artifacts
tree.

It reuses `test/fixtures/sui/generate.py`'s helpers and keeps their checks: each summary, written from the typed fields
the verifier takes, is the BCS Sui serves and hashes to the checkpoint's digest; each key and signature decompresses
onto its curve and compresses back; the artifacts tree rebuilt from every object the checkpoint wrote has the root its
summary commits to; and the attestation, written as the verifier writes it, hashes to its leaf's digest.
"""
import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "test", "fixtures", "sui"))
import generate as g  # noqa: E402

NEW_KEY = 0xFFFF
IMMUTABLE = 3
WORD = 32


def update(epoch):
    named = g.committee_of(epoch)
    current = named["committee"]
    end = g.checkpoint(g.last_of(epoch))
    assert end["epoch"] == epoch and "committee" in end, "the epoch's last checkpoint names the next committee"
    keys = [k for k, _ in current]
    nxt = end["committee"]
    sources = b"".join((keys.index(k) if k in keys else NEW_KEY).to_bytes(2, "big") for k, _ in nxt)
    new_keys = b"".join(g.g2(k) for k, _ in nxt if k not in keys)
    g.committee_json(nxt)  # ascending, and the full voting power
    return {
        "epoch": epoch,
        "current": g.committee_json(current),
        "checkpoint": g.summary_json(end, end["afterCommittee"]),
        "certificate": g.certificate_json(end, len(current)),
        "next": {"sources": g.hx(sources), "newKeys": g.hx(new_keys), "powers": [p for _, p in nxt]},
    }


def parse_attestation(b):
    """`ObjectInner` of an immutable Move object of a type without type parameters, its owner `Owner::Immutable`."""
    r = g.Reader(b)
    assert r.u8() == 0 and r.u8() == 0, "a Move object of a type MoveObjectType_::Other names"
    o = {"package": r.take(32), "module": r.vec().decode(), "name": r.vec().decode()}
    assert r.uleb() == 0, "no type parameters"
    o["hasPublicTransfer"] = bool(r.u8())
    o["version"] = r.u64()
    o["contents"] = r.vec()
    assert r.u8() == IMMUTABLE, "an attestation is frozen"
    o["owner"] = bytes([IMMUTABLE])
    o["previousTransaction"] = r.digest()
    o["storageRebate"] = r.u64()
    assert r.i == len(b)
    return o


def record_fields(record):
    """`abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, timestampMs, slots, values)`: the time, the slots, the values."""
    word = lambda i: int.from_bytes(record[i * WORD:(i + 1) * WORD], "big")  # noqa: E731

    def array(offset):
        n = int.from_bytes(record[offset:offset + WORD], "big")
        return [record[offset + WORD * (1 + i):offset + WORD * (2 + i)] for i in range(n)]

    return word(3), array(word(4)), array(word(5))


def attest(seq, object_id):
    s = g.checkpoint(seq)
    committee = g.committee_of(s["epoch"])["committee"]
    states = g.object_states(seq)
    ids = sorted(states)
    levels = g.merkle([g.leaf(i, *states[i]) for i in ids])
    assert g.blake(b"\x01\x20" + levels[-1][0]) == s["artifactsDigest"], "the tree's root is the one committed to"
    oid = bytes.fromhex(object_id[2:].rjust(64, "0"))
    index = ids.index(oid)
    path, i = [], index
    for level in levels[:-1]:
        path.append(level[i ^ 1])
        i //= 2
    version, digest = states[oid]
    obj = g.gql(g.OBJECT, {"a": g.hx(oid), "v": version})["object"]
    assert g.b58(obj["digest"]) == digest
    o = parse_attestation(base64.b64decode(obj["objectBcs"]))
    assert (o["module"], o["name"], o["hasPublicTransfer"]) == ("vault", "Attestation", False)
    assert g.blake(g.write_object(o)) == digest, "written from its fields, the attestation hashes to its leaf's digest"
    contents = o["contents"]
    assert contents[:32] == oid, "an object's contents start with its id"
    r = g.Reader(contents[32:])
    record = r.vec()
    assert r.i == len(contents) - 32
    time_ms, slots, values = record_fields(record)
    assert time_ms <= s["timestampMs"], "the record is dated by the checkpoint's commit"
    return {
        "package": g.hx(o["package"]),
        "committee": g.committee_json(committee),
        "checkpoint": g.summary_json(s, s["restAt"]),
        "certificate": g.certificate_json(s, len(committee)),
        "objectId": g.hx(oid),
        "version": o["version"],
        "previousTransaction": g.hx(o["previousTransaction"]),
        "storageRebate": o["storageRebate"],
        "timestampMs": time_ms,
        "slots": [g.hx(x) for x in slots],
        "values": [g.hx(x) for x in values],
        "leafIndex": index,
        "path": [g.hx(x) for x in path],
    }


def main():
    g.URL = sys.argv[1]
    command, args = sys.argv[2], sys.argv[3:]
    if command == "update":
        out = update(int(args[0]))
    elif command == "attest":
        out = attest(int(args[0]), args[1])
    else:
        raise SystemExit(f"unknown command {command}")
    with open(args[-1], "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
