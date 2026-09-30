"""Rebuilds receipts.json: a real mainnet block's header fields and receipt proofs, for EthereumFinalityVerifier's tests.

Run: pip install rlp trie "eth-hash[pycryptodome]"; python generate.py [block] [rpc]. It fetches the block and all its
receipts, rebuilds the receipts trie and checks its root against the header's `receiptsRoot` before writing anything,
so the proofs are the chain's own.
"""
import json
import subprocess
import sys

import rlp
from eth_hash.auto import keccak
from trie import HexaryTrie

RPC = sys.argv[2] if len(sys.argv) > 2 else "https://ethereum-rpc.publicnode.com"


def call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(["curl", "-s", "-m", "60", "-H", "content-type: application/json", "-d", body, RPC],
                         capture_output=True, check=True).stdout
    return json.loads(out)["result"]


def b(x):
    return bytes.fromhex(x[2:]) if x.startswith("0x") else bytes.fromhex(x)


def num(x):
    return int(x, 16)


def encode_receipt(r):
    logs = [[b(l["address"]), [b(t) for t in l["topics"]], b(l["data"])] for l in r["logs"]]
    body = rlp.encode([num(r["status"]), num(r["cumulativeGasUsed"]), b(r["logsBloom"]), logs])
    kind = num(r["type"])
    return body if kind == 0 else bytes([kind]) + body


block_id = sys.argv[1] if len(sys.argv) > 1 else "finalized"
if block_id.isdigit():
    block_id = hex(int(block_id))
block = call("eth_getBlockByNumber", [block_id, False])
receipts = call("eth_getBlockReceipts", [block["number"]])
t = HexaryTrie(db={})
for i, r in enumerate(receipts):
    t[rlp.encode(i)] = encode_receipt(r)
assert t.root_hash == b(block["receiptsRoot"]), "the rebuilt trie must match the header"


def proof(index):
    nodes = t.get_proof(rlp.encode(index))
    # Only nodes referenced by hash are listed: a node shorter than 32 bytes is embedded in its parent.
    return ["0x" + rlp.encode(n).hex() for n in nodes if len(rlp.encode(n)) >= 32]


def pick(predicate):
    return next(i for i, r in enumerate(receipts) if predicate(i, r))


# A successful transaction with at least one log of two or more topics: one early (a one-byte key) and one at index 128
# or later (a two-byte key) if the block has one.
def usable(i, r):
    return num(r["status"]) == 1 and any(len(l["topics"]) >= 2 for l in r["logs"])


cases = []
for predicate in (lambda i, r: i < 0x80 and usable(i, r), lambda i, r: i >= 0x80 and usable(i, r)):
    try:
        i = pick(predicate)
    except StopIteration:
        continue
    r = receipts[i]
    k = next(k for k, l in enumerate(r["logs"]) if len(l["topics"]) >= 2)
    log = r["logs"][k]
    cases.append({"txIndex": i, "logIndex": k, "type": num(r["type"]), "proof": proof(i), "emitter": log["address"],
                  "topic0": log["topics"][0], "topic1": log["topics"][1], "data": log["data"]})
# A legacy (type 0) receipt, which has no type byte, if the block has one.
try:
    i = pick(lambda i, r: num(r["type"]) == 0 and usable(i, r))
    r = receipts[i]
    k = next(k for k, l in enumerate(r["logs"]) if len(l["topics"]) >= 2)
    log = r["logs"][k]
    cases.append({"txIndex": i, "logIndex": k, "type": 0, "proof": proof(i), "emitter": log["address"],
                  "topic0": log["topics"][0], "topic1": log["topics"][1], "data": log["data"]})
except StopIteration:
    pass
# A log with a single topic, which a vault message can never be.
one = next(((i, k) for i, r in enumerate(receipts) if num(r["status"]) == 1
            for k, l in enumerate(r["logs"]) if len(l["topics"]) == 1), None)
failed = [i for i, r in enumerate(receipts) if num(r["status"]) == 0]
out = {
    "number": num(block["number"]),
    "timestamp": num(block["timestamp"]),
    "stateRoot": block["stateRoot"],
    "receiptsRoot": block["receiptsRoot"],
    "transactions": len(receipts),
    "cases": cases,
    "failed": {"txIndex": failed[0], "proof": proof(failed[0])} if failed else None,
    "absent": {"txIndex": len(receipts), "proof": proof(len(receipts))},
    "oneTopic": {"txIndex": one[0], "logIndex": one[1], "proof": proof(one[0])} if one else None,
}
# A made-up receipts trie whose one receipt succeeded with a log from a 19-byte address, which no real block has, for
# the verifier's check of the address's length. Its root is only ever trusted in a test.
bad = HexaryTrie(db={})
bad[rlp.encode(0)] = bytes([2]) + rlp.encode([1, 21000, b"\x00" * 256, [[b"\x11" * 19, [b"\x22" * 32, b"\x33" * 32], b""]]])
out["malformed"] = {"receiptsRoot": "0x" + bad.root_hash.hex(),
                    "proof": ["0x" + rlp.encode(n).hex() for n in bad.get_proof(rlp.encode(0)) if len(rlp.encode(n)) >= 32]}
json.dump(out, open("receipts.json", "w"), indent=1)
print(json.dumps({k: v for k, v in out.items() if k not in ("cases", "failed", "absent")}),
      [(c["txIndex"], c["type"], len(c["proof"])) for c in cases], "failed" if failed else "no failed tx")
