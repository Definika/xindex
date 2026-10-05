"""DRAFT, untested (2026-10-06). The production inputs the filler's NEAR adapter (`keeper/chains/near.mjs`) proves a
vault's slots with on Ethereum, built from a NEAR RPC (read-only) with `generate.py`'s checks:

- `update`: the input of `near prove` (the `near` SP1 host) that moves `NearStateVerifier` from the epoch and producer
  set it holds to NEAR's latest final head, and the public values the proof must commit;
- `attest`: the `AttestProof` of one successful `attest` transaction by the vault, under a head the verifier recorded,
  or under a new head, with the `update` input that records it when no recorded head lies above the outcome.

    uv run --with pynacl --with pycryptodome python3 attest_input.py update --rpc URL --epoch 0x.. --producers 0x.. \\
        --out update.json
    uv run --with pynacl --with pycryptodome python3 attest_input.py attest --rpc URL --vault ACCOUNT --chain-id ID \\
        --tx HASH --signer ACCOUNT --slots 0x..,0x.. --values 0x..,0x.. --epoch 0x.. --producers 0x.. \\
        [--head 0xROOT:HEIGHT ...] --out attest.json

`--epoch` and `--producers` are the verifier's `epochId()` and `producersHash()`; `--head` names heads it recorded
(its `Advanced` events). Every block of an update is checked as `generate.py` checks it: each present approval
verifies under its producer's key, the approvals hold more than two thirds of the epoch's stake, and named producers
hash to the header's `next_bp_hash`. The statement (`../statement`) is then run here on the blocks as written, and its
public values written beside them. The outcome is checked to the head as `NearStateVerifier` checks it.

How the update's blocks are chosen. The statement checks each block under the producers of its own epoch, and moves to
the next epoch's producers only on a block that names them; nearcore's light-client blocks always name the next
epoch's. So the input keeps the last block of each epoch, each naming the next epoch's producers, and writes the head
without them: the verifier then stays in the head's epoch, and a later update can still prove a block of it. Its
`namedAt` moves only when an update crosses an epoch, to when the epoch it lands in was named, an epoch at most before.

`attest`'s output holds every integer as a decimal string, since NEAR's nanosecond times exceed what JavaScript's
numbers hold exactly; the `update` input keeps JSON numbers, which the Rust host reads as `u64`.
"""

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

from Crypto.Hash import keccak

from borsh_near import b58_32, block_hash, producers_hash, sha256

# The generator's own encodings and checks, so the two cannot drift. Importing it only sets its RPC URL from argv, which
# nothing here reads.
from generate import (
    ATTEST_DOMAIN,
    attest_record,
    block_json,
    check_block,
    enc58,
    h,
    lite_json,
    outcome_leaf,
    path_json,
    path_root,
    producers_json,
    word,
)
from rpc import call

# How many heights a skipped block can leave around an epoch's first block, at most, before the builder gives up.
SKIPPED = 50
# How long `attest` waits for a final light-client block above the outcome, in seconds.
WAIT = 600


def hex32(s):
    b = bytes.fromhex(s.removeprefix("0x"))
    assert len(b) == 32, s
    return b


def try_call(url, method, params):
    """One request, `None` when the RPC refuses it: a skipped height comes back as an error, never retried."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
        reply = json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError:
        return None
    return reply.get("result")


def lcb_hash(lcb):
    return block_hash(lcb["inner_lite"], lcb["inner_rest_hash"], lcb["prev_block_hash"])


def epoch_anchor(url, epoch, producers):
    """A block of the epoch before `epoch`, from which `next_light_client_block` reaches a block of `epoch`, and
    `epoch`'s ordered producers, checked against the hash the verifier holds."""
    start = call("validators", {"epoch_id": enc58(epoch)}, url)["epoch_start_height"]
    before = None
    for height in range(start - 1, start - SKIPPED, -1):
        r = try_call(url, "block", {"block_id": height})
        if r:
            before = r["header"]
            break
    assert before, f"no block in the {SKIPPED} heights before {start}"
    assert b58_32(before["next_epoch_id"]) == epoch, "the block before the epoch's first names it next"
    first = None
    for height in range(start, start + SKIPPED):
        r = try_call(url, "block", {"block_id": height})
        if r:
            first = r["header"]
            break
    assert first and b58_32(first["epoch_id"]) == epoch, "the epoch's first block"
    ordered = call("EXPERIMENTAL_validators_ordered", [first["hash"]], url)
    assert producers_hash(ordered) == producers, "the epoch's producers are those the verifier holds"
    return before["hash"], ordered


def light_client_blocks(url, known, above, wait):
    """`next_light_client_block` from `known` on, until a block above height `above`, waiting up to `wait` seconds for
    one to be final."""
    blocks = []
    deadline = time.time() + wait
    last = 0
    while True:
        lcb = call("next_light_client_block", {"last_block_hash": known}, url)
        if lcb and lcb.get("inner_lite") and lcb["inner_lite"]["height"] > last:
            blocks.append(lcb)
            last = lcb["inner_lite"]["height"]
            known = enc58(lcb_hash(lcb))
            if last > above:
                return blocks
            continue
        assert time.time() < deadline, f"no final light-client block above {above} within {wait} s"
        time.sleep(5)


def keep_epoch_ends(blocks):
    """The last block of each epoch in `blocks`: the one that names the next epoch's producers to the statement."""
    kept = []
    for b in blocks:
        if kept and kept[-1]["inner_lite"]["epoch_id"] == b["inner_lite"]["epoch_id"]:
            kept[-1] = b
        else:
            kept.append(b)
    return kept


def statement(epoch_in, producers_in, blocks):
    """The statement on the blocks as they will be written: checks each, and returns them as the host reads them and
    the public values `NearStateVerifier.update` will decode."""
    epoch, producers, named_at = epoch_in, producers_in, 0
    producers_out = producers_hash(producers_in)
    written = []
    for i, b in enumerate(blocks):
        lite = b["inner_lite"]
        assert b58_32(lite["epoch_id"]) == epoch, f"block {lite['height']} is in the epoch the statement is at"
        check_block(b, producers)
        out = block_json(b)
        if i == len(blocks) - 1:
            out["next_bps"] = None
        else:
            assert b.get("next_bps"), f"block {lite['height']} names the next epoch's producers"
            assert b58_32(blocks[i + 1]["inner_lite"]["epoch_id"]) == b58_32(lite["next_epoch_id"]), "epochs follow"
            epoch = b58_32(lite["next_epoch_id"])
            producers = b["next_bps"]
            producers_out = producers_hash(producers)
            named_at = int(lite["timestamp_nanosec"])
        written.append(out)
    head = blocks[-1]["inner_lite"]
    public_values = (
        epoch_in
        + producers_hash(producers_in)
        + epoch
        + producers_out
        + word(named_at)
        + word(head["height"])
        + word(int(head["timestamp_nanosec"]))
        + b58_32(head["block_merkle_root"])
    )
    return written, public_values


def build_update(url, epoch, producers, above, wait, path):
    """Writes `near prove`'s input from the verifier's epoch to a final head above `above`, and returns the head and the
    expected public values."""
    known, ordered = epoch_anchor(url, epoch, producers)
    blocks = keep_epoch_ends(light_client_blocks(url, known, above, wait))
    written, public_values = statement(epoch, ordered, blocks)
    with open(path, "w") as f:
        json.dump(
            {
                "source": url,
                "anchor": {"epoch_id": h(epoch), "producers": producers_json(ordered), "producers_hash": h(producers)},
                "blocks": written,
                "public_values": h(public_values),
            },
            f,
            indent=1,
        )
        f.write("\n")
    last = blocks[-1]
    head = {
        "hash": enc58(lcb_hash(last)),
        "block_merkle_root": h(b58_32(last["inner_lite"]["block_merkle_root"])),
        "height": last["inner_lite"]["height"],
    }
    print("update:", len(written), "blocks to", head["height"], file=sys.stderr)
    return head, h(public_values)


def decode_record(value):
    """`attest`'s record, `abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)`, read
    back; `attest_record` then writes it again, so only its exact encoding passes."""
    words = [value[i : i + 32] for i in range(0, len(value), 32)]
    n = int.from_bytes(words[7], "big")
    slots = words[8 : 8 + n]
    values = words[9 + n : 9 + 2 * n]
    return {
        "chain_id": int.from_bytes(words[1], "big"),
        "vault_id": words[2],
        "height": int.from_bytes(words[3], "big"),
        "timestamp": int.from_bytes(words[4], "big"),
        "slots": slots,
        "values": values,
    }


def the_outcome(url, tx, signer, vault):
    """The receipt outcome of `tx` that the vault executed successfully: `attest`'s."""
    status = call("EXPERIMENTAL_tx_status", {"tx_hash": tx, "sender_account_id": signer, "wait_until": "FINAL"}, url)
    found = [
        ro
        for ro in status.get("receipts_outcome", [])
        if ro["outcome"]["executor_id"] == vault
        and isinstance(ro["outcome"]["status"], dict)
        and "SuccessValue" in ro["outcome"]["status"]
    ]
    assert len(found) == 1, f"one successful receipt by {vault} in {tx}, found {len(found)}"
    return found[0]


def light_client_proof(url, receipt_id, vault, head_hash):
    return call(
        "EXPERIMENTAL_light_client_proof",
        {"type": "receipt", "receipt_id": receipt_id, "receiver_id": vault, "light_client_head": head_hash},
        url,
    )


def attest(args):
    url = args.rpc
    account = args.vault.encode()
    vault_id = keccak.new(digest_bits=256, data=account).digest()
    ro = the_outcome(url, args.tx, args.signer, args.vault)
    value = base64.b64decode(ro["outcome"]["status"]["SuccessValue"])
    record = decode_record(value)
    slots = [hex32(s) for s in args.slots.split(",")]
    values = [hex32(v) for v in args.values.split(",")]
    assert record["chain_id"] == args.chain_id and record["vault_id"] == vault_id, "the record names this vault"
    assert record["slots"] == slots and record["values"] == values, "the vault attested the slots and values asked"
    assert value[:32] == ATTEST_DOMAIN
    assert attest_record(args.chain_id, vault_id, record["height"], record["timestamp"], slots, values) == value

    # The block whose outcome root holds the outcome: a proof to the latest final block names it.
    final = call("block", {"finality": "final"}, url)["header"]
    probe = light_client_proof(url, ro["id"], args.vault, final["hash"])
    including = probe["block_header_lite"]["inner_lite"]["height"]

    # A head the verifier recorded above that block, the lowest; or a new one, recorded by an update.
    head, update = None, None
    for root, height in sorted(((hex32(r), int(n)) for r, n in (x.split(":") for x in args.head)), key=lambda x: x[1]):
        if height <= including:
            continue
        r = try_call(url, "block", {"block_id": height})
        if r and b58_32(r["header"]["block_merkle_root"]) == root:
            head = {"hash": r["header"]["hash"], "block_merkle_root": h(root), "height": height}
            break
    if head is None:
        path = args.out.removesuffix(".json") + ".update.json"
        head, public_values = build_update(
            url, hex32(args.epoch), hex32(args.producers), including, args.wait, path
        )
        update = {"input": path, "publicValues": public_values}

    proof = light_client_proof(url, ro["id"], args.vault, head["hash"])
    o = proof["outcome_proof"]["outcome"]
    assert o["executor_id"] == args.vault and base64.b64decode(o["status"]["SuccessValue"]) == value
    receipt_id = b58_32(proof["outcome_proof"]["id"])
    receipt_ids = [b58_32(r) for r in o["receipt_ids"]]
    logs = [log.encode() for log in o["logs"]]
    leaf = outcome_leaf(receipt_id, receipt_ids, o["gas_burnt"], int(o["tokens_burnt"]), account, value, logs)
    lite = proof["block_header_lite"]
    chunk_root = path_root(leaf, proof["outcome_proof"]["proof"])
    assert path_root(sha256(chunk_root), proof["outcome_root_proof"]) == b58_32(lite["inner_lite"]["outcome_root"])
    including_hash = block_hash(lite["inner_lite"], lite["inner_rest_hash"], lite["prev_block_hash"])
    assert path_root(including_hash, proof["block_proof"]) == hex32(head["block_merkle_root"]), "under the head"
    # `NearStateVerifier._proveOutcome`: the run comes before the block whose outcome root holds it.
    assert record["height"] < lite["inner_lite"]["height"]
    assert record["timestamp"] < int(lite["inner_lite"]["timestamp_nanosec"])

    def path_out(items):
        return [{"hash": i["hash"], "left": i["left"]} for i in path_json(items)]

    inner = lite_json(lite["inner_lite"])
    out = {
        "source": url,
        "tx": args.tx,
        "update": update,
        "head": {k: str(v) if isinstance(v, int) else v for k, v in head.items()},
        "record": h(value),
        # `INearStateVerifier.AttestProof`, field by field; integers as decimal strings.
        "attestProof": {
            "head": head["block_merkle_root"],
            "receiptId": h(receipt_id),
            "receiptIds": [h(r) for r in receipt_ids],
            "gasBurnt": str(o["gas_burnt"]),
            "tokensBurnt": str(o["tokens_burnt"]),
            "logs": [h(log) for log in logs],
            "outcomePath": path_out(proof["outcome_proof"]["proof"]),
            "outcomeRootPath": path_out(proof["outcome_root_proof"]),
            "blockHeader": {
                "innerLite": {
                    "height": str(inner["height"]),
                    "epochId": inner["epoch_id"],
                    "nextEpochId": inner["next_epoch_id"],
                    "prevStateRoot": inner["prev_state_root"],
                    "outcomeRoot": inner["outcome_root"],
                    "timestamp": str(inner["timestamp"]),
                    "nextBpHash": inner["next_bp_hash"],
                    "blockMerkleRoot": inner["block_merkle_root"],
                },
                "innerRestHash": h(b58_32(lite["inner_rest_hash"])),
                "prevBlockHash": h(b58_32(lite["prev_block_hash"])),
            },
            "blockPath": path_out(proof["block_proof"]),
            "height": str(record["height"]),
            "timestamp": str(record["timestamp"]),
            "values": [h(v) for v in values],
        },
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("attest: receipt", ro["id"], "in block", lite["inner_lite"]["height"], "under head", head["height"],
          "with an update" if update else "already recorded", file=sys.stderr)


def update(args):
    # To the final head as it stands now: a live chain always has a newer one, so the chain of blocks needs an end.
    final = call("block", {"finality": "final"}, args.rpc)["header"]["height"]
    head, public_values = build_update(args.rpc, hex32(args.epoch), hex32(args.producers), final - 1, WAIT, args.out)
    print(json.dumps({"input": args.out, "publicValues": public_values, "head": {k: str(v) for k, v in head.items()}}))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="mode", required=True)
    for name in ("update", "attest"):
        s = sub.add_parser(name)
        s.add_argument("--rpc", required=True)
        s.add_argument("--epoch", required=True, help="the verifier's epochId()")
        s.add_argument("--producers", required=True, help="the verifier's producersHash()")
        s.add_argument("--out", required=True)
        if name == "attest":
            s.add_argument("--vault", required=True, help="the vault's account id")
            s.add_argument("--chain-id", type=int, required=True)
            s.add_argument("--tx", required=True, help="the attest transaction's hash, base58")
            s.add_argument("--signer", required=True, help="the account that signed it")
            s.add_argument("--slots", required=True, help="the attested slots, comma-separated")
            s.add_argument("--values", required=True, help="their values, comma-separated")
            s.add_argument("--head", action="append", default=[], help="a recorded head, 0xROOT:HEIGHT")
            s.add_argument("--wait", type=int, default=WAIT)
    args = p.parse_args()
    attest(args) if args.mode == "attest" else update(args)


if __name__ == "__main__":
    main()
