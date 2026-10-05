"""Builds a production input for the Aptos host (`aptos prove <update|slots> <input.json> <out.json>`) in
`synthetic.json`'s shape, read-only from Aptos Labs' public backups and REST API. DRAFT (2026-10-06): the rebalance
filler (`keeper/chains/aptos.mjs`) runs it; nothing here has run against a vault yet. It reuses `generate.py`'s readers,
which its mainnet fixture checks, and keeps their checks: each epoch-ending ledger info round-trips its BCS and is
signed by a quorum of the set before it; every transaction info of the backup chunk is confirmed by its events' root
and its write set's hash, and the range proof reaches the chunk's ledger info.

    python3 input.py <mainnet|testnet> update <trusted-epoch> <trusted-set> <out.json>
    python3 input.py <mainnet|testnet> slots <trusted-epoch> <trusted-set> <version> <package> <vault-id> <out.json>

`update` crosses from the verifier's latest epoch to the last epoch the backup has ended. `slots` proves the vault's
`attest` at `version` under the ledger info of the backup chunk holding it, crossing from the trusted epoch to that
ledger info's. The backup covers a version two to four hours after it ran: until then `slots` exits asking to wait.
"""

import json
import sys

import aptos_py as a
import generate as gen
from rpc import backup, backup_json, backup_metadata, records

WAIT = 3  # the exit status that means: the backup does not cover it yet


def trusted_set(epoch, expected, names, network):
    _, named = gen.epoch_ending(epoch - 1, names, network)
    nxt = named["ledger_info"]["next_epoch_state"]
    assert nxt["epoch"] == epoch, "the ledger info that ended the epoch before names this epoch"
    assert gen.hx(a.set_hash(nxt["validators"], gen.keccak)) == expected.lower(), "the verifier's trusted set"
    return nxt["validators"], {"epoch": epoch, "validators": gen.hx(a.write_validators(nxt["validators"]))}


def hops(first, last, validators, names, network):
    """The epoch-ending ledger infos of epochs `first` to `last - 1`, each signed by the set before it. Returns them
    and the set of epoch `last`."""
    out = []
    for e in range(first, last):
        raw, s = gen.epoch_ending(e, names, network)
        signed, _ = gen.signed_json(raw, s, validators)
        out.append(signed)
        validators = s["ledger_info"]["next_epoch_state"]["validators"]
    return out, validators


def last_ended(names):
    ends = [int(n.split("_")[-1].split("-")[0]) for n in names if n.startswith("metadata/epoch_ending_")
            and not n.startswith("metadata/epoch_ending_compacted_")]
    return max(ends)


def update(network, epoch, expected):
    names = backup_metadata(network)
    validators, trusted = trusted_set(epoch, expected, names, network)
    last = last_ended(names)
    if last < epoch:
        raise SystemExit(WAIT)
    hs, _ = hops(epoch, last + 1, validators, names, network)
    return {"update": {"trusted": trusted, "hops": hs}}


def chunk_of(version, names, network):
    for n in names:
        if not n.startswith("metadata/transaction_"):
            continue
        first, last = (int(x) for x in n[len("metadata/transaction_"):-len(".meta")].split("-"))
        if first <= version <= last:
            for line in backup(n, network).decode().splitlines():
                b = json.loads(line).get("TransactionBackup")
                if b:
                    for c in backup_json(b["manifest"], network)["chunks"]:
                        if c["first_version"] <= version <= c["last_version"]:
                            return c
    raise SystemExit(WAIT)


def record_fields(record):
    """`abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestamp, slots, values)`."""
    w = lambda i: record[32 * i:32 * (i + 1)]  # noqa: E731

    def array(offset):
        n = int.from_bytes(record[offset:offset + 32], "big")
        return [record[offset + 32 * (1 + i):offset + 32 * (2 + i)] for i in range(n)]

    assert w(0) == gen.ATTEST_DOMAIN
    return (int.from_bytes(w(1), "big"), w(2), int.from_bytes(w(3), "big"),
            array(int.from_bytes(w(4), "big")), array(int.from_bytes(w(5), "big")))


def uleb_bytes(b):
    n, s, i = 0, 0, 0
    while True:
        x = b[i]
        n |= (x & 0x7F) << s
        s += 7
        i += 1
        if x < 0x80:
            assert len(b) == i + n
            return b[i:]


def slots(network, epoch, expected, version, package, vault_id):
    names = backup_metadata(network)
    chunk = chunk_of(version, names, network)
    assert chunk["format"] == "V1"
    r = a.Reader(backup(chunk["proof"], network))
    left, right = r.vec(r.hash), r.vec(r.hash)
    proof_raw = r.d[r.p:]
    final = a.read_signed(r)
    assert r.done()
    li = final["ledger_info"]

    recs = records(backup(chunk["transactions"], network))
    assert len(recs) == chunk["last_version"] - chunk["first_version"] + 1
    parsed = [gen.find_info(rec) for rec in recs]
    leaves = [a.info_hash(info["bcs"]) for info, _ in parsed]
    k = version - chunk["first_version"]
    root, siblings = a.range_to_leaf(a.TXN_ACCUMULATOR, chunk["first_version"], leaves, left, right, version)
    assert root == li["executed_state_id"], "the range proof does not reach the ledger info's root"
    assert a.climb(a.TXN_ACCUMULATOR, leaves[k], version, siblings) == root
    info, events = parsed[k]
    assert info["status"] == 0, "the attest failed"
    assert a.write_info(info, info["event_root_hash"]) == info["bcs"], "the info, written successful"
    tag = a.struct_tag(bytes.fromhex(package[2:]), "vault", "Attested")
    attested = [e for e in events if e["variant"] == 1 and e["type_tag"] == tag]
    assert len(attested) == 1, "exactly one Attested of the package"
    chain_id, vid, timestamp, slot_words, value_words = record_fields(uleb_bytes(attested[0]["data"]))
    assert gen.hx(vid) == vault_id.lower(), "the record names another vault"

    validators, trusted = trusted_set(epoch, expected, names, network)
    hs, final_set = hops(epoch, li["epoch"], validators, names, network)
    ledger_info, _ = gen.signed_json(proof_raw, final, final_set)
    return {
        "slots": {
            "trusted": trusted,
            "hops": hs,
            "ledger_info": ledger_info,
            "transaction": {"version": version, "info": gen.hx(info["bcs"]), "siblings": [gen.hx(s) for s in siblings],
                            "events": [gen.hx(e["bcs"]) for e in events]},
            "chain_id": chain_id,
            "package": package.lower(),
            "vault_id": vault_id.lower(),
            "timestamp": timestamp,
            "slots": [gen.hx(s) for s in slot_words],
            "values": [gen.hx(v) for v in value_words],
        }
    }


if __name__ == "__main__":
    network, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == "update":
        gen.write(args[2], update(network, int(args[0]), args[1]))
    elif cmd == "slots":
        gen.write(args[5], slots(network, int(args[0]), args[1], int(args[2]), args[3], args[4]))
    else:
        raise SystemExit(__doc__)
