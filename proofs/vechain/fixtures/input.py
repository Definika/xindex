"""Builds a production input for the VeChain host (`vechain prove <update|slots> <input.json> <out.json>`) in
`synthetic.json`'s shape, read-only from a public node, from calls already sent on chain. DRAFT (2026-10-06): the
rebalance filler (`keeper/chains/vechain.mjs`) runs it; nothing here has run against mainnet yet. It reuses
`generate.py`'s encodings and counting, which its mainnet fixture checks, and keeps its checks: every header re-encoded
to its own bytes, its signer recovered and its id recomputed, each the parent of the next; each call's transaction and
receipt under its block's roots; each table read through the Staker's own views and hashed as the attester hashes it.

    python3 input.py <node> update <attester> <trusted-id> <trusted-table> <call-txid> <out.json>
    python3 input.py <node> slots <attester> <trusted-id> <trusted-table> <vault> <vault-txid> <k-txid> <r-txid> \
        <slot,slot,...> <value,value,...> <out.json>

`update`: `call-txid` is a successful `attest(table)` of the attester, vouched for by the blocks after it, signed by
more than two thirds of the trusted table's weight. `slots`: `vault-txid` is the vault's `attest(slots, values)`, at or
before round k's checkpoint; `k-txid` and `r-txid` the attester's calls in rounds k and r > k; round k must be
justified and round r committed, every block of r in the chain. The trusted table is the verifier's (`trusted(id)`),
read again here at its block and checked against the hash given.
"""

import json
import sys

import generate as gen
import vechain_py as v
from rpc import get

EPOCH = gen.EPOCH
MORE = 30  # headers fetched at a time past the minimum, while the vouching is short


def call_of(node, txid, first, to, data):
    """The call's block number and its `call_json`, block index relative to `first`. It must be one clause, no value,
    to `to` with `data`, not reverted, and log nothing."""
    receipt = get(node, "/transactions/%s/receipt" % txid)
    assert receipt and not receipt["reverted"], "%s reverted or is unknown" % txid
    n = receipt["meta"]["blockNumber"]
    blk = get(node, "/blocks/%d?expanded=true" % n)
    txs = blk["transactions"]
    i = next(j for j, t in enumerate(txs) if t["id"] == txid)
    raws = [v.h(get(node, "/transactions/%s?raw=true" % t["id"])["raw"]) for t in txs]
    receipts = [
        v.encode_receipt(t["type"], t["gasUsed"], v.h(t["gasPayer"]), int(t["paid"], 16), int(t["reward"], 16),
                         t["reverted"], v.encode_outputs(t["outputs"]))
        for t in txs
    ]
    troot, tproof = v.trie(raws)
    rroot, rproof = v.trie(receipts)
    h, _, _ = gen.fetch_header(node, n)
    assert troot == h["txsRoot"] and rroot == h["receiptsRoot"], "the block's roots"
    t = v.decode_tx(raws[i])
    assert len(t["clauses"]) == 1, "one clause"
    clause = t["clauses"][0]
    assert clause["to"] == to and clause["value"] == 0 and clause["data"] == data, "the call expected"
    meta = txs[i]
    assert v.encode_outputs(meta["outputs"]) == gen.NO_OUTPUTS, "a view logs nothing"
    r = {"gasUsed": meta["gasUsed"], "gasPayer": v.h(meta["gasPayer"]), "paid": int(meta["paid"], 16),
         "reward": int(meta["reward"], 16)}
    return n, gen.call_json(n - first, i, t, r, tproof(i), rproof(i))


def headers_from(node, first, last):
    headers, signers, ids = [], [], []
    for n in range(first, last + 1):
        h, s, blk = gen.fetch_header(node, n)
        if headers:
            assert h["parentID"] == ids[-1], "each header is its successor's parent"
        headers.append(h)
        signers.append(s)
        ids.append(v.h(blk["id"]))
    return headers, signers, ids


def extend(node, chain):
    headers, signers, ids = chain
    more = headers_from(node, v.number(headers[-1]) + 1, v.number(headers[-1]) + MORE)
    assert more[0][0]["parentID"] == ids[-1], "linked"
    for a, b in zip(chain, more):
        a.extend(b)


def vouch(node, chain, trusted, first, at):
    """Fetches headers until the signers after block `at` hold more than two thirds of the trusted weight."""
    while not gen.quorum(trusted, chain[1][at - first + 1:]):
        best = get(node, "/blocks/best")["number"]
        assert v.number(chain[0][-1]) + MORE <= best, "the blocks after the call do not vouch for it yet: wait"
        extend(node, chain)


def common(node, attester, trusted_id, trusted_table, chain):
    trusted = gen.fetch_table(node, trusted_id)
    assert gen.table_hash(*trusted) == v.h(trusted_table), "the verifier's trusted table, read again at its block"
    headers, signers, ids = chain
    return trusted, {
        "chain": get(node, "/blocks/0")["id"],
        "attester": attester.lower(),
        "trusted": {"id": trusted_id.lower(), "table": gen.table_json(trusted)},
        "headers": [gen.header_json(h) for h in headers],
        "signers": [gen.hx(s) for s in signers],
        "ids": [gen.hx(i) for i in ids],
    }


def attested(node, attester, txid, first):
    """The attester's call `txid` and the table it attests, read at its block."""
    receipt = get(node, "/transactions/%s/receipt" % txid)
    n = receipt["meta"]["blockNumber"]
    table = gen.fetch_table(node, receipt["meta"]["blockID"])
    data = gen.STAKER_ATTEST + gen.table_hash(*table)
    at, call = call_of(node, txid, first, v.h(attester), data)
    assert at == n
    return n, table, {"table": gen.table_json(table), "call": call}


def update(node, attester, trusted_id, trusted_table, txid):
    n = get(node, "/transactions/%s/receipt" % txid)["meta"]["blockNumber"]
    assert n > int(trusted_id[2:10], 16), "the call is after the trusted block"
    chain = headers_from(node, n, n + EPOCH // 2)
    vouch(node, chain, gen.fetch_table(node, trusted_id), n, n)
    _, f = common(node, attester, trusted_id, trusted_table, chain)
    _, _, a = attested(node, attester, txid, n)
    f["update"] = {"attested": a}
    return f


def slots(node, attester, trusted_id, trusted_table, vault, vault_txid, k_txid, r_txid, slot_words, value_words):
    y = get(node, "/transactions/%s/receipt" % vault_txid)["meta"]["blockNumber"]
    nk = get(node, "/transactions/%s/receipt" % k_txid)["meta"]["blockNumber"]
    nr = get(node, "/transactions/%s/receipt" % r_txid)["meta"]["blockNumber"]
    k, r = nk // EPOCH, nr // EPOCH
    assert y > int(trusted_id[2:10], 16), "the vault's call is after the trusted block"
    assert k < r and y <= k * EPOCH, "the vault's call at or before round k's checkpoint, then rounds k and r"
    end = r * EPOCH + EPOCH - 1
    assert get(node, "/blocks/best")["number"] >= end, "round r is not over yet: wait"
    chain = headers_from(node, y, end)
    trusted = gen.fetch_table(node, trusted_id)
    vouch(node, chain, trusted, y, nk)
    vouch(node, chain, trusted, y, nr)
    trusted, f = common(node, attester, trusted_id, trusted_table, chain)

    data = gen.VAULT_ATTEST + gen.abi_slots_values(slot_words, value_words)
    _, call = call_of(node, vault_txid, y, v.h(vault), data)
    _, tk, justified = attested(node, attester, k_txid, y)
    _, tr, committed = attested(node, attester, r_txid, y)
    numbered = list(zip(range(y, y + len(chain[0])), chain[1], [h["com"] for h in chain[0]]))
    assert gen.quorum(tk, [s for n, s, _ in numbered if n // EPOCH == k]), "round k is not justified"
    assert gen.committed(tr, [(s, c) for n, s, c in numbered if n // EPOCH == r]), "round r is not committed"
    f["slots"] = {
        "vault": vault.lower(),
        "slots": [gen.hx(s) for s in slot_words],
        "values": [gen.hx(x) for x in value_words],
        "call": call,
        "justified": justified,
        "committed": committed,
    }
    return f


def words(arg):
    return [v.h(w) for w in arg.split(",")]


if __name__ == "__main__":
    node, cmd = sys.argv[1], sys.argv[2]
    a = sys.argv[3:]
    if cmd == "update":
        gen.write(a[4], update(node, a[0], a[1], a[2], a[3]))
    elif cmd == "slots":
        gen.write(a[9], slots(node, a[0], a[1], a[2], a[3], a[4], a[5], a[6], words(a[7]), words(a[8])))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
