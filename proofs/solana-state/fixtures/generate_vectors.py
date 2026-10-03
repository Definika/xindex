#!/usr/bin/env python3
"""Writes `vectors.json`: test vectors the Rust prototype checks itself against, from sources independent of it.

- `ltHash`: Agave's own lattice-hash vectors, read out of its source (`lattice-hash/src/lt_hash.rs`, test
  `test_hello_world`): the LtHash and checksum of BLAKE3 over each input the test names ("hello" and "world!").
- `bankHash`: a bank hash computed here with Python's hashlib, as `Bank::hash_internal_state` composes it, over chosen
  inputs (the lattice hash bytes taken from Agave's "hello" vector), with and without a hard fork.
- `blockId`: a double Merkle root computed here, as `Blockstore::build_double_merkle_tree` and the shred Merkle tree
  build it, over three chosen FEC roots and a parent.

Usage: python3 generate_vectors.py <agave source dir>   (Agave v4.3.0 or v4.4.0-beta.0; their vectors agree)
"""

import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def lt_hash_vectors(agave):
    src = open(os.path.join(agave, "lattice-hash/src/lt_hash.rs")).read()
    out = {}
    for word in ("hello", "world"):
        m = re.search(r"let expected_%s_lt_hash = LtHash\(\[(.*?)\]\);" % word, src, re.S)
        values = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{4})", m.group(1))]
        assert len(values) == 1024, (word, len(values))
        m = re.search(r"let expected_%s_checksum = Checksum\(\[(.*?)\]\);" % word, src, re.S)
        checksum = [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", m.group(1))]
        assert len(checksum) == 32, (word, len(checksum))
        m = re.search(r'\("([^"]*)", expected_%s_lt_hash, expected_%s_checksum\)' % (word, word), src)
        out[word] = {"input": m.group(1), "ltHash": values, "checksum": bytes(checksum).hex()}
    return out


def sha256(*parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def bank_hash(parent, signature_count, last_blockhash, lt_hash_bytes, hard_forks):
    h = sha256(sha256(parent, signature_count.to_bytes(8, "little"), last_blockhash), lt_hash_bytes)
    if hard_forks:
        h = sha256(h, hard_forks.to_bytes(8, "little"))
    return h


NODE = b"\x01SOLANA_MERKLE_SHREDS_NODE"


def join(a, b):
    return sha256(NODE, a[:20], b[:20])


def merkle_root(leaves):
    layer = list(leaves)
    while len(layer) > 1:
        layer = [join(layer[i], layer[i + 1] if i + 1 < len(layer) else layer[i]) for i in range(0, len(layer), 2)]
    return layer[0]


def main():
    agave = sys.argv[1]
    lt = lt_hash_vectors(agave)
    lt_bytes = b"".join(v.to_bytes(2, "little") for v in lt["hello"]["ltHash"])
    parent = bytes(range(32))
    blockhash = bytes(range(32, 64))
    banks = []
    for hard_forks in (0, 2):
        banks.append(
            {
                "parentBankHash": parent.hex(),
                "signatureCount": 1234,
                "lastBlockhash": blockhash.hex(),
                "ltHash": "hello",
                "hardForks": hard_forks,
                "bankHash": bank_hash(parent, 1234, blockhash, lt_bytes, hard_forks).hex(),
            }
        )
    fec = [sha256(bytes([i])) for i in range(3)]
    parent_block_id = sha256(b"parent")
    parent_leaf = sha256((7).to_bytes(8, "little"), parent_block_id, (3).to_bytes(4, "little"))
    block = {
        "fecRoots": [f.hex() for f in fec],
        "parentSlot": 7,
        "parentBlockId": parent_block_id.hex(),
        "blockId": merkle_root(fec + [parent_leaf]).hex(),
    }
    out = {"source": os.path.basename(os.path.normpath(agave)), "ltHash": lt, "bankHash": banks, "blockId": block}
    with open(os.path.join(HERE, "vectors.json"), "w") as f:
        json.dump(out, f, indent=1)
    print("wrote vectors.json:", [b["bankHash"][:16] for b in banks], block["blockId"][:16])


if __name__ == "__main__":
    main()
