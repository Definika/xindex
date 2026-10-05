#!/usr/bin/env python3
"""Builds what `TronStateVerifier` takes in production, read-only from TronGrid: a `CallProof` of one `attest`
transaction, an `advance` to a later producer list, and the producers of a recorded list. DRAFT (2026-10-06): the
rebalance filler (`keeper/chains/tron.mjs`) runs it; nothing here has run against mainnet yet.

    python3 tron/proof.py <api> producers <start-ms> <end-ms> <out.json>
    python3 tron/proof.py <api> advance <current.json> <list-end-ms> <target-ms> <out.json>
    python3 tron/proof.py <api> call <txid> <producers.json> <start-ms> <end-ms> <out.json>

`producers` learns a period's list from its own blocks two ways, as `advance` learns one (the round from two blocks
after the maintenance block) and as the deployment's anchor does (three rounds after it), so the caller keeps the one
whose hash the verifier recorded. `advance` builds the arguments of `advance` for the period holding `target-ms`, the
first on the grid of `list-end-ms` at or after it, vouched for by `current.json`'s producers. `call` builds the proof of
transaction `txid`, which must be a top-level TriggerSmartContract the verifier can write, under the list `producers.json`
names, whose period is [start-ms, end-ms).

It reuses `test/fixtures/tron/generate.py`'s helpers, whose header, transaction and tree encodings are checked against
mainnet there, and keeps their checks: every header hashes to its block id and recovers to a key, every block names its
parent, the block's transaction tree rebuilt from all its transactions matches its header, and the transaction written
from its fields is the one the block holds.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "test", "fixtures", "tron"))
_argv, sys.argv = sys.argv, sys.argv[:2]  # generate.py reads its API from argv[1] when imported
import generate as g  # noqa: E402

sys.argv = _argv

NOT_LISTED = 255
INTERVAL = 6 * 3600 * 1000


def linked(blocks):
    for i in range(1, len(blocks)):
        assert blocks[i]["parentHash"] == blocks[i - 1]["id"], f"block {blocks[i]['number']} names another parent"


def blocks_from(first, count):
    out = [g.checked(g.header(n)) for n in range(first, first + count)]
    linked(out)
    return out


def extend(blocks, count):
    more = blocks_from(blocks[-1]["number"] + 1, count)
    assert more[0]["parentHash"] == blocks[-1]["id"], "linked"
    blocks.extend(more)


def maintenance(start):
    """The period's first block, and a check that the block before it is in the period before."""
    m = g.first_at_or_after(start)
    assert g.header(m - 1)["block_header"]["raw_data"]["timestamp"] < start
    return m


def keys(span):
    out = {}
    for b in span:
        assert out.setdefault(b["witness"], b["key"]) == b["key"], "one key per producer within a span"
    return out


def round_of(blocks):
    """The learning round as `advance` takes it, with the maintenance block at 0: from block 2 until it spans 27 slots.
    Returns (learnFrom, vouchFrom); `blocks` grows as needed."""
    learn_from = 2
    vouch_from = learn_from + 1
    while True:
        while vouch_from > len(blocks):
            extend(blocks, g.ROUND)
        if blocks[vouch_from - 1]["timestamp"] >= blocks[learn_from]["timestamp"] + (g.ROUND - 1) * g.SLOT:
            return learn_from, vouch_from
        vouch_from += 1


def header_struct(b, producer):
    return {
        "timestamp": b["timestamp"],
        "txTrieRoot": b["txTrieRoot"],
        "parentHash": b["parentHash"],
        "number": b["number"],
        "witnessId": b["witnessId"],
        "witness": b["witness"],
        "version": b["version"],
        "accountStateRoot": b["accountStateRoot"],
        "extra": b["extra"],
        "r": b["r"],
        "s": b["s"],
        "v": b["v"],
        "producer": producer,
    }


def index_of(listed):
    return {p["witness"]: (i, p["key"]) for i, p in enumerate(listed)}


def producers(start, end):
    m = maintenance(start)
    blocks = blocks_from(m, 3 * g.ROUND + 1)
    learn_from, vouch_from = round_of(blocks)
    assert blocks[0]["timestamp"] >= start and all(b["timestamp"] < end for b in blocks), "the blocks lie in the period"
    return {
        "start": start,
        "end": end,
        "round": g.listed(keys(blocks[learn_from:vouch_from])),
        "rounds": g.listed(keys(blocks[1:])),
    }


def advance(current, list_end, target):
    assert target >= list_end, "the target lies before the latest list's end"
    start = list_end + (target - list_end) // INTERVAL * INTERVAL
    end = start + INTERVAL
    m = maintenance(start)
    blocks = blocks_from(m, g.ROUND + 8)
    learn_from, vouch_from = round_of(blocks)
    assert blocks[0]["timestamp"] >= start and all(b["timestamp"] < end for b in blocks[learn_from:vouch_from])
    nxt = g.listed(keys(blocks[learn_from:vouch_from]))
    assert g.QUORUM <= len(nxt) <= g.ROUND, f"a round of {len(nxt)} producers"
    old = index_of(current)
    vouched, at = set(), vouch_from
    while len(vouched) < g.QUORUM:
        while at >= len(blocks):
            extend(blocks, g.ROUND)
        b = blocks[at]
        if old.get(b["witness"], (None, None))[1] == b["key"]:
            vouched.add(b["witness"])
        at += 1
    new = index_of(nxt)
    headers = []
    for i, b in enumerate(blocks[:at]):
        if learn_from <= i < vouch_from:
            producer = new[b["witness"]][0]
        elif i >= vouch_from and old.get(b["witness"], (None, None))[1] == b["key"]:
            producer = old[b["witness"]][0]
        else:
            producer = NOT_LISTED
        headers.append(header_struct(b, producer))
    return {
        "start": start,
        "end": end,
        "nextList": nxt,
        "headers": headers,
        "learnFrom": learn_from,
        "vouchFrom": vouch_from,
    }


def call(txid, listed, start, end):
    info = g.post("/walletsolidity/gettransactioninfobyid", {"value": txid})
    assert info.get("blockNumber"), f"{txid} is not solidified yet"
    num = info["blockNumber"]
    first = g.checked(g.header(num))
    assert start <= first["timestamp"] < end, "the block lies outside the list's period"
    block = g.full_block(num)
    txs = block.get("transactions", [])
    at = next((i for i, t in enumerate(txs) if t["txID"] == txid), None)
    assert at is not None, f"{txid} is not in block {num}"
    leaves = [g.sha(g.tx_bytes(t)) for t in txs]
    root, path, sides = g.merkle(leaves, at)
    assert "0x" + root.hex() == first["txTrieRoot"], "the transaction tree, results included"

    t = txs[at]
    raw = t["raw_data"]
    assert not set(raw) - {"ref_block_bytes", "ref_block_hash", "expiration", "contract", "timestamp", "fee_limit"}, raw
    assert len(raw["contract"]) == 1 and raw["contract"][0]["type"] == "TriggerSmartContract"
    c = raw["contract"][0]
    assert not set(c) - {"type", "parameter", "Permission_id"}, c
    assert c["parameter"]["type_url"] == g.TYPE_URL.decode()
    value = c["parameter"]["value"]
    assert not set(value) - {"owner_address", "contract_address", "data"}, "a call with value or a token"
    ret = t.get("ret", [])
    assert len(ret) == 1 and ret[0].get("contractRet") == "SUCCESS" and not set(ret[0]) - {"contractRet", "fee"}, ret
    owner, target, data = (bytes.fromhex(value[k]) for k in ("owner_address", "contract_address", "data"))
    permission = c.get("Permission_id", 0)
    assert g.trigger_raw(raw, owner, target, data, permission).hex() == t["raw_data_hex"], "the verifier cannot write it"

    listed_at = index_of(listed)
    blocks, seen, headers = [first], set(), []
    i = 0
    while len(seen) < g.QUORUM:
        while i >= len(blocks):
            extend(blocks, g.QUORUM)
        b = blocks[i]
        assert b["timestamp"] < end, "the period ended before 19 of its producers built on the block: attest again"
        producer = NOT_LISTED
        if listed_at.get(b["witness"], (None, None))[1] == b["key"]:
            producer = listed_at[b["witness"]][0]
            seen.add(b["witness"])
        headers.append(header_struct(b, producer))
        i += 1
    return {
        "blockNumber": num,
        "timestamp": first["timestamp"],
        "target": "0x" + target[1:].hex(),
        "data": "0x" + data.hex(),
        "producers": listed,
        "transaction": {
            "owner": "0x" + owner[1:].hex(),
            "refBlockBytes": "0x" + raw.get("ref_block_bytes", ""),
            "refBlockHash": "0x" + raw.get("ref_block_hash", ""),
            "expiration": raw.get("expiration", 0),
            "timestamp": raw.get("timestamp", 0),
            "feeLimit": raw.get("fee_limit", 0),
            "permissionId": permission,
            "signatures": ["0x" + s for s in t.get("signature", [])],
            "fee": ret[0].get("fee", 0),
        },
        "path": ["0x" + p.hex() for p in path],
        "sides": sides,
        "headers": headers,
    }


def write(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=1)
        f.write("\n")


def main():
    command, args = sys.argv[2], sys.argv[3:]
    if command == "producers":
        write(args[2], producers(int(args[0]), int(args[1])))
    elif command == "advance":
        with open(args[0]) as f:
            current = json.load(f)
        write(args[3], advance(current, int(args[1]), int(args[2])))
    elif command == "call":
        with open(args[1]) as f:
            listed = json.load(f)
        write(args[4], call(args[0], listed, int(args[2]), int(args[3])))
    else:
        raise SystemExit(f"unknown command {command}")


if __name__ == "__main__":
    main()
