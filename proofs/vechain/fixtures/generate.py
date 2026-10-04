"""Writes the VeChain statement's fixtures, reading VeChainThor's public REST API only (`rpc.py`):

    python3 generate.py mainnet   [mainnet.json]     real mainnet data, every piece checked against its own root
    python3 generate.py synthetic [synthetic.json]   the full claims on a SYNTHETIC chain signed with test keys
    python3 generate.py anchor <out.json> [mainnet|testnet]   the verifier's first table, from the latest finalized block

Everything is computed here by a Python implementation separate from the Rust statement (`vechain_py.py`,
`secp256k1.py`, `keccak.py`), so each checks the other.

**mainnet.json** (real). No vault and no `VeChainStakerAttester` exist on VeChain yet, so no real `attest` call does
either. It holds what can be real: the headers from a block of round `k - 1` to past the end of round `k + 1`, where
`k * 180` is the block mainnet's API calls finalized, each re-encoded to its own bytes, its signer recovered and its id
recomputed; the Staker's tables in force in rounds `k - 1`, `k` and `k + 1`, read at those rounds' blocks through the
Staker's own views; whether round `k` is justified and round `k + 1` committed under them, as thor's `bft` package
counts; and a real successful call, one clause and no value, standing in for `attest`, with its transaction and
receipt proven under its block's roots.

**synthetic.json** (SYNTHETIC: every key is a test key, every block made up). The two claims end to end, update and
slots, with the attester's and the vault's calls the statement writes, and the public values the program commits and
`test/VeChainStateVerifier.t.sol` uses.
"""

import json
import sys

import secp256k1 as ec
import vechain_py as v
from keccak import keccak
from rpc import MAINNET, TESTNET, get, inspect

EPOCH = 180
STAKER = "0x00000000000000000000000000005374616b6572"
UPDATE = keccak(b"xindex.v4.vechain.update")
SLOTS = keccak(b"xindex.v4.vechain.slots")
VAULT_ATTEST = keccak(b"attest(bytes32[],bytes32[])")[:4]
STAKER_ATTEST = keccak(b"attest(bytes32)")[:4]
NO_OUTPUTS = bytes.fromhex("c3c2c0c0")


def hx(b):
    return "0x" + bytes(b).hex()


def sel(sig):
    return "0x" + keccak(sig.encode())[:4].hex()


def word(n):
    return n.to_bytes(32, "big")


def addr_word(a):
    return bytes(12) + a


# ---------------------------------------------------------------------------
# tables and VIP-220's counting, as thor's `bft` package counts
# ---------------------------------------------------------------------------


def table_hash(total, validators):
    """`VeChainStakerAttester.currentTable`: keccak over the total weight, then over each validator and weight in order."""
    h = keccak(word(total))
    for a, w in validators:
        h = keccak(h + addr_word(a) + word(w))
    return h


def fetch_table(node, revision):
    """The Staker's total weight and active validators with their weights, at block `revision`'s state."""
    call = lambda data: {"to": STAKER, "value": "0x0", "data": data}  # noqa: E731
    out = inspect(node, [call(sel("totalStake()"))], revision)[0]
    assert not out["reverted"]
    total = int(out["data"][66:130], 16)
    order = []
    cur = inspect(node, [call(sel("firstActive()"))], revision)[0]["data"][-40:]
    while int(cur, 16):
        order.append(cur)
        cur = inspect(node, [call(sel("next(address)") + cur.rjust(64, "0"))], revision)[0]["data"][-40:]
    outs = inspect(node, [call(sel("getValidation(address)") + c.rjust(64, "0")) for c in order], revision)
    vals = []
    for c, o in zip(order, outs):
        assert not o["reverted"]
        vals.append((bytes.fromhex(c), int(o["data"][2:][128:192], 16)))
    assert sum(w for _, w in vals) == total, "the active validators' weights sum to the total"
    return total, vals


def quorum(table, signers):
    """More than two thirds of the table's total, `Σ > total * 2 / 3` in whole VET: `3Σ > 2·total` in wei."""
    total, vals = table
    by = dict(vals)
    return 3 * sum(by.get(s, 0) for s in set(signers)) > 2 * total


def committed(table, round_headers):
    """COM voters: signers whose every block in the round voted COM (thor's `justifier.AddBlock`)."""
    against = {s for s, com in round_headers if not com}
    return quorum(table, [s for s, _ in round_headers if s not in against])


def table_json(table):
    total, vals = table
    return {"totalWeight": hx(word(total)), "validators": [[hx(a), hx(word(w))] for a, w in vals],
            "hash": hx(table_hash(total, vals))}


# ---------------------------------------------------------------------------
# JSON in the statement's input form
# ---------------------------------------------------------------------------


def header_json(h):
    return {
        "parentID": hx(h["parentID"]), "timestamp": h["timestamp"], "gasLimit": h["gasLimit"],
        "beneficiary": hx(h["beneficiary"]), "gasUsed": h["gasUsed"], "totalScore": h["totalScore"],
        "txsRoot": hx(h["txsRoot"]), "txsFeatures": h["txsFeatures"], "stateRoot": hx(h["stateRoot"]),
        "receiptsRoot": hx(h["receiptsRoot"]), "alpha": hx(h["alpha"]), "com": h["com"],
        "baseFee": hx(word(h["baseFee"])), "signature": hx(h["signature"]),
    }


def features_of(reserved):
    items = v.dec(reserved)
    assert len(items) <= 1, "consensus refuses unused reserved fields"
    return v.uint(items[0]) if items else 0


def tx_json(t):
    j = {
        "chainTag": t["chainTag"], "blockRef": hex(t["blockRef"]), "expiration": t["expiration"], "gas": t["gas"],
        "dependsOn": hx(t["dependsOn"]) if t["dependsOn"] is not None else None, "nonce": hex(t["nonce"]),
        "features": features_of(t["reserved"]), "signature": hx(t["signature"]),
    }
    if t["type"] == v.LEGACY:
        j["gasPriceCoef"] = t["gasPriceCoef"]
    else:
        j["maxPriorityFeePerGas"] = hx(word(t["maxPriorityFeePerGas"]))
        j["maxFeePerGas"] = hx(word(t["maxFeePerGas"]))
    return j


def call_json(block_index, tx_index, t, receipt, tx_proof, receipt_proof):
    return {
        "block": block_index, "index": tx_index, "transaction": tx_json(t),
        "receipt": {"gasUsed": receipt["gasUsed"], "gasPayer": hx(receipt["gasPayer"]),
                    "paid": hx(word(receipt["paid"])), "reward": hx(word(receipt["reward"]))},
        "transactionProof": [hx(n) for n in tx_proof], "receiptProof": [hx(n) for n in receipt_proof],
    }


def abi_slots_values(slots, values):
    n = len(slots)
    return (word(64) + word(64 + 32 + 32 * n) + word(n) + b"".join(slots) + word(len(values)) + b"".join(values))


# ---------------------------------------------------------------------------
# mainnet: real data
# ---------------------------------------------------------------------------


def fetch_header(node, n):
    blk = get(node, "/blocks/%d" % n)
    h = v.decode_header(v.h(get(node, "/blocks/%s?raw=true" % blk["id"])["raw"]))
    signer = ec.recover(v.signing_hash(h), h["signature"][:65])
    assert hx(signer) == blk["signer"].lower(), "the signature recovers to the API's signer"
    assert hx(v.block_id(h, signer)) == blk["id"], "the id recomputes"
    assert v.number(h) == n and h["com"] == blk["com"]
    return h, signer, blk


def standin(node, lo, hi):
    """A real successful call in blocks `lo..hi`: one clause to a contract, no value, not reverted. One that logged
    nothing, as `attest` logs nothing, is preferred."""
    found = None
    for n in range(hi, lo - 1, -1):
        blk = get(node, "/blocks/%d?expanded=true" % n)
        for i, t in enumerate(blk["transactions"]):
            if len(t["clauses"]) != 1 or t["reverted"]:
                continue
            c = t["clauses"][0]
            if c["to"] is None or int(c["value"], 16) != 0 or len(c["data"]) <= 10:
                continue
            quiet = not t["outputs"][0]["events"] and not t["outputs"][0]["transfers"]
            if quiet:
                return n, i, blk
            found = found or (n, i, blk)
    assert found, "no successful one-clause call in the window"
    return found


def mainnet(out):
    node = MAINNET
    genesis = get(node, "/blocks/0")["id"]
    fin = get(node, "/blocks/finalized")
    k = fin["number"] // EPOCH
    assert fin["number"] == k * EPOCH, "VIP-220 finalizes checkpoints"
    r = k + 1
    best = get(node, "/blocks/best")["number"]
    end = r * EPOCH + EPOCH - 1 + 12
    assert best >= end, "round k + 1 must be complete, and a few blocks after it"

    y, tx_index, yblk = standin(node, k * EPOCH - 60, k * EPOCH)
    print("stand-in call in block", y, "index", tx_index, file=sys.stderr)
    headers, signers, ids = [], [], []
    for n in range(y, end + 1):
        h, s, blk = fetch_header(node, n)
        if headers:
            assert h["parentID"] == ids[-1], "each header is its successor's parent"
        headers.append(h)
        signers.append(s)
        ids.append(v.h(blk["id"]))

    # The stand-in's transaction and receipt, written from their fields, under its block's roots.
    txs = yblk["transactions"]
    raws = [v.h(get(node, "/transactions/%s?raw=true" % t["id"])["raw"]) for t in txs]
    receipts = [
        v.encode_receipt(t["type"], t["gasUsed"], v.h(t["gasPayer"]), int(t["paid"], 16), int(t["reward"], 16),
                         t["reverted"], v.encode_outputs(t["outputs"]))
        for t in txs
    ]
    troot, tproof = v.trie(raws)
    rroot, rproof = v.trie(receipts)
    assert troot == headers[0]["txsRoot"] and rroot == headers[0]["receiptsRoot"]
    t = v.decode_tx(raws[tx_index])
    meta = txs[tx_index]
    clause = t["clauses"][0]
    outputs = v.encode_outputs(meta["outputs"])
    receipt = {"gasUsed": meta["gasUsed"], "gasPayer": v.h(meta["gasPayer"]), "paid": int(meta["paid"], 16),
               "reward": int(meta["reward"], 16)}

    # The tables in force in rounds k - 1, k and k + 1: each at a block of its round, after its first block's
    # housekeeping.
    trusted = fetch_table(node, yblk["id"])
    tk = fetch_table(node, hx(ids[k * EPOCH - y]))
    tr = fetch_table(node, hx(ids[r * EPOCH - y]))
    numbered = list(zip(range(y, end + 1), signers, [h["com"] for h in headers]))
    round_k = [(s, c) for n, s, c in numbered if n // EPOCH == k]
    round_r = [(s, c) for n, s, c in numbered if n // EPOCH == r]
    assert len(round_k) == EPOCH and len(round_r) == EPOCH
    expect = {
        "justified": quorum(tk, [s for s, _ in round_k]),
        "committed": committed(tr, round_r),
        "vouchedAfterK": quorum(trusted, signers[k * EPOCH - y + 1:]),
        "vouchedAfterR": quorum(trusted, signers[r * EPOCH - y + 1:]),
        "comVoters": sum(1 for s in set(s for s, _ in round_r) if all(c for s2, c in round_r if s2 == s)),
        "signersK": len({s for s, _ in round_k}),
    }
    assert expect["justified"] and expect["committed"], "the API finalized checkpoint k: thor counted as we do"
    f = {
        "network": "mainnet",
        "note": "REAL mainnet data, read from %s; no attest call exists on VeChain yet, so `standin` is a real "
                "successful one-clause call in its place" % node,
        "chain": genesis,
        "finalized": fin["number"],
        "justifiedRound": k,
        "committedRound": r,
        "first": y,
        "headers": [header_json(h) for h in headers],
        "signers": [hx(s) for s in signers],
        "ids": [hx(i) for i in ids],
        "tables": {"trusted": table_json(trusted), "justified": table_json(tk), "committed": table_json(tr)},
        "standin": {
            "call": call_json(0, tx_index, t, receipt, tproof(tx_index), rproof(tx_index)),
            "to": hx(clause["to"]), "data": hx(clause["data"]), "outputs": hx(outputs),
            "quiet": outputs == NO_OUTPUTS,
        },
        "expect": expect,
    }
    write(out, f)


# ---------------------------------------------------------------------------
# synthetic: the claims end to end, on a chain made up here
# ---------------------------------------------------------------------------

SYNTHETIC_ROUND = 144_450  # rounds of mainnet's height: block 26,001,000 starts the justified round
VALIDATORS = 101
BASE_FEE = 10**13


def _weights(salt):
    """Deterministic weights from 25M to about 600M VET, as mainnet's spread."""
    out = []
    for i in range(VALIDATORS):
        x = int.from_bytes(keccak(salt + bytes([i])), "big")
        out.append((25_000_000 + x % 575_000_000) * 10**18)
    return out


class Chain:
    def __init__(self, start_parent, start_time):
        self.parent = start_parent
        self.time = start_time
        self.headers, self.signers, self.ids = [], [], []
        self.block_txs = []

    def add(self, key, com, txs):
        """A block signed by `key`, with `txs` as (raw transaction, raw receipt) pairs."""
        traws = [t for t, _ in txs]
        rraws = [r for _, r in txs]
        troot = v.trie(traws)[0] if traws else v.EMPTY_ROOT
        rroot = v.trie(rraws)[0] if rraws else v.EMPTY_ROOT
        signer = ec.address(key)
        h = {
            "parentID": self.parent, "timestamp": self.time, "gasLimit": 40_000_000, "beneficiary": signer,
            "gasUsed": 21_000 * len(txs), "totalScore": 28_000_000_000 + 10_000 * len(self.headers),
            "txsRoot": troot, "txsFeatures": 1, "stateRoot": keccak(b"synthetic state" + self.parent),
            "receiptsRoot": rroot, "alpha": v.blake2b(b"synthetic beta", self.parent), "com": com,
            "baseFee": BASE_FEE, "signature": b"",
        }
        h["signature"] = ec.sign(key, v.signing_hash(h)) + bytes(81)
        assert ec.recover(v.signing_hash(h), h["signature"][:65]) == signer
        bid = v.block_id(h, signer)
        self.headers.append(h)
        self.signers.append(signer)
        self.ids.append(bid)
        self.block_txs.append(txs)
        self.parent = bid
        self.time += 10
        return len(self.headers) - 1


def _tx(kind, chain_tag, to, data, nonce, features):
    t = {"type": kind, "chainTag": chain_tag, "blockRef": 0x018CF3A800000000 + nonce, "expiration": 720,
         "clauses": [{"to": to, "value": 0, "data": data}], "gas": 1_000_000,
         "dependsOn": None, "nonce": 0x5EED0000 + nonce, "reserved": v.enc([features] if features else [])}
    if kind == v.LEGACY:
        t["gasPriceCoef"] = 128
    else:
        t["maxPriorityFeePerGas"] = 10**12
        t["maxFeePerGas"] = 2 * 10**13
    # A transaction's own signature is consensus's to check, not the statement's: test bytes stand in.
    t["signature"] = keccak(b"synthetic tx signature %d" % nonce) * 2 + b"\x01"
    if features & 1:
        t["signature"] += keccak(b"synthetic delegator signature %d" % nonce) * 2 + b"\x00"
    return t


def _receipt(kind, payer, outputs):
    r = {"gasUsed": 734_632, "gasPayer": payer, "paid": 7_346_320_000_000_000_000, "reward": 2_203_896_000_000_000_000}
    return r, v.encode_receipt(kind, r["gasUsed"], r["gasPayer"], r["paid"], r["reward"], False, outputs)


def synthetic(out):
    chain_id = v.h("0x00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a")
    tag = chain_id[31]
    attester = keccak(b"synthetic VeChainStakerAttester")[12:]
    vault = keccak(b"synthetic XindexVault")[12:]
    keys = [ec.test_key(b"validator %d" % i) for i in range(VALIDATORS)]
    addrs = [ec.address(d) for d in keys]
    base = list(zip(addrs, _weights(b"base")))
    trusted = (sum(w for _, w in base), base)
    t_k = trusted
    # Round r's table: three validators renewed with new weights at its first block.
    changed = list(base)
    for i, w in zip((3, 40, 77), (612_000_000, 31_000_000, 250_000_000)):
        changed[i] = (changed[i][0], w * 10**18)
    t_r = (sum(w for _, w in changed), changed)

    a = SYNTHETIC_ROUND - 1
    k, r = a + 1, a + 2
    start = a * EPOCH + 175
    trusted_number = start - 30
    trusted_id = trusted_number.to_bytes(4, "big") + keccak(b"synthetic trusted block")[4:]
    parent = (start - 1).to_bytes(4, "big") + keccak(b"synthetic parent")[4:]
    c = Chain(parent, 1_791_000_000)

    # Signers: every validator in turn, in an order of their own, so each round sees all of them.
    order = sorted(range(VALIDATORS), key=lambda i: keccak(b"order" + addrs[i]))
    slots = [keccak(b"synthetic intake digest slot"), (25).to_bytes(32, "big")]
    values = [keccak(b"synthetic intake digest"), bytes(32)]
    payer = keccak(b"synthetic gas payer")[12:]
    filler_to = keccak(b"synthetic token")[12:]
    filler = lambda n: (  # noqa: E731
        v.encode_tx(_tx(v.LEGACY, tag, filler_to, bytes.fromhex("a9059cbb") + bytes(64), n, 0)),
        _receipt(v.LEGACY, payer, v.enc([[[[filler_to, [keccak(b"Transfer(address,address,uint256)")], word(1)]], []]]))[1],
    )
    marks = {}
    end = r * EPOCH + EPOCH - 1 + 6
    for n in range(start, end + 1):
        key_index = order[(n - start) % VALIDATORS]
        txs = []
        if n == start:
            # The vault's attest, between two other transactions, in a dynamic-fee, fee-delegated transaction.
            t = _tx(v.DYNAMIC_FEE, tag, vault, VAULT_ATTEST + abi_slots_values(slots, values), 1, 1)
            rc, rraw = _receipt(v.DYNAMIC_FEE, payer, NO_OUTPUTS)
            txs = [filler(100), (v.encode_tx(t), rraw), filler(101)]
            marks["slots"] = (t, rc, 1)
        elif n == k * EPOCH + 1:
            t = _tx(v.LEGACY, tag, attester, STAKER_ATTEST + table_hash(*t_k), 2, 0)
            rc, rraw = _receipt(v.LEGACY, payer, NO_OUTPUTS)
            txs = [(v.encode_tx(t), rraw)]
            marks["justified"] = (t, rc, 0)
        elif n == r * EPOCH + 2:
            t = _tx(v.DYNAMIC_FEE, tag, attester, STAKER_ATTEST + table_hash(*t_r), 3, 0)
            rc, rraw = _receipt(v.DYNAMIC_FEE, payer, NO_OUTPUTS)
            txs = [filler(102), (v.encode_tx(t), rraw)]
            marks["committed"] = (t, rc, 1)
        # Two validators vote COM in round r but not in one of their blocks: thor counts them as not voting COM.
        com = not (n // EPOCH == r and (n - start) % VALIDATORS in (5, 6) and n < r * EPOCH + 101)
        idx = c.add(keys[key_index], com, txs)
        if n == start:
            marks["slotsBlock"] = idx
        elif n == k * EPOCH + 1:
            marks["justifiedBlock"] = idx
        elif n == r * EPOCH + 2:
            marks["committedBlock"] = idx

    def call_of(name):
        t, rc, ti = marks[name]
        bi = marks[name + "Block"]
        txs = c.block_txs[bi]
        _, tproof = v.trie([x for x, _ in txs])
        _, rproof = v.trie([y for _, y in txs])
        return call_json(bi, ti, t, rc, tproof(ti), rproof(ti))

    # The claims, as the statement must find them.
    numbered = list(zip(range(start, end + 1), c.signers, [h["com"] for h in c.headers]))
    round_k = [(s, cm) for n, s, cm in numbered if n // EPOCH == k]
    round_r = [(s, cm) for n, s, cm in numbered if n // EPOCH == r]
    jb, cb = marks["justifiedBlock"], marks["committedBlock"]
    assert quorum(trusted, c.signers[jb + 1:]) and quorum(trusted, c.signers[cb + 1:])
    assert quorum(t_k, [s for s, _ in round_k]) and committed(t_r, round_r)
    against = {s for s, cm in round_r if not cm}
    assert len(against) == 2
    th = table_hash(*trusted)
    update_values = (UPDATE + chain_id + addr_word(attester) + trusted_id + th + c.ids[jb] + table_hash(*t_k)
                     + word(c.headers[jb]["timestamp"]))
    y = c.headers[0]
    slots_values = (SLOTS + chain_id + addr_word(attester) + trusted_id + th + word(start) + word(y["timestamp"])
                    + addr_word(vault) + keccak(abi_slots_values(slots, values)))
    f = {
        "network": "synthetic",
        "note": "SYNTHETIC: test keys, made-up blocks and transactions, mainnet's chain id; the claims end to end",
        "chain": hx(chain_id),
        "attester": hx(attester),
        "trusted": {"id": hx(trusted_id), "number": trusted_number, "time": c.headers[0]["timestamp"] - 300,
                    "table": table_json(trusted)},
        "headers": [header_json(h) for h in c.headers],
        "signers": [hx(s) for s in c.signers],
        "ids": [hx(i) for i in c.ids],
        "update": {"attested": {"table": table_json(t_k), "call": call_of("justified")}},
        "slots": {
            "vault": hx(vault), "slots": [hx(s) for s in slots], "values": [hx(x) for x in values],
            "call": call_of("slots"),
            "justified": {"table": table_json(t_k), "call": call_of("justified")},
            "committed": {"table": table_json(t_r), "call": call_of("committed")},
        },
        "public_values": {"update": hx(update_values), "slots": hx(slots_values)},
    }
    write(out, f)


# ---------------------------------------------------------------------------
# anchor: the verifier's first table
# ---------------------------------------------------------------------------


def anchor(out, network="mainnet"):
    node = {"mainnet": MAINNET, "testnet": TESTNET}[network]
    genesis = get(node, "/blocks/0")["id"]
    fin = get(node, "/blocks/finalized")
    h, signer, blk = fetch_header(node, fin["number"])
    table = fetch_table(node, fin["id"])
    f = {
        "network": network,
        "note": "The verifier's first table: the Staker's at block `id`, a finalized checkpoint, read through its own "
                "views at that block. Check it again during the chain's listing delay. Deploy the vault and the "
                "attester before choosing it: the verifier proves only blocks after this one.",
        "chainId": genesis,
        "id": fin["id"],
        "number": fin["number"],
        "time": fin["timestamp"],
        "table": table_json(table)["hash"],
        "totalWeight": hx(word(table[0])),
        "validators": [[hx(a), hx(word(w))] for a, w in table[1]],
    }
    write(out, f)


def write(out, f):
    with open(out, "w") as fh:
        json.dump(f, fh, indent=1)
        fh.write("\n")
    print("wrote", out, file=sys.stderr)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "mainnet":
        mainnet(sys.argv[2] if len(sys.argv) > 2 else "mainnet.json")
    elif cmd == "synthetic":
        synthetic(sys.argv[2] if len(sys.argv) > 2 else "synthetic.json")
    elif cmd == "anchor" and len(sys.argv) > 2:
        anchor(sys.argv[2], *(sys.argv[3:4]))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
