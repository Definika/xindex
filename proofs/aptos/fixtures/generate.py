"""Writes the Aptos statement's fixtures, reading Aptos's public data only (`rpc.py`):

    python3 generate.py mainnet   [mainnet.json]     real mainnet data, every piece checked against what commits to it
    python3 generate.py synthetic [synthetic.json]   the full claims on a SYNTHETIC chain signed with test keys
    python3 generate.py anchor <out.json> [mainnet|testnet]   the verifier's first set, the epoch in force

Everything is computed here by a Python implementation separate from the Rust statement (`aptos_py.py`, `bls_py.py`,
`keccak.py`), so each checks the other. The one thing this does not do is verify a BLS signature: the Rust statement
verifies mainnet's own aggregates natively (`statement/tests/statement.rs`), which no wrong implementation of the hash
to G2, the signing message or the aggregation could.

**mainnet.json** (real). No vault exists on Aptos yet, so no real `attest` does either. It holds what can be real:
- from Aptos Labs' public backup, the epoch-ending ledger infos of two epochs, each with its signatures, and the set
  the one before them named, which the verifier would trust;
- from the latest transaction backup, a chunk's accumulator range proof and the ledger info it is proven under, signed
  by the set those two hops reach; every transaction info of the chunk, read from its records and each confirmed by its
  events' root and its write set's hash; the range proof checked against the ledger info's root; and from it the
  single-leaf path of one successful transaction with a module event besides `FeeStatement`, which stands in for
  `Attested`, with all its events;
- the signers of each ledger info and their share of the voting power, as `ValidatorVerifier` counts it, and each
  signer's uncompressed point;
- the trusted set checked against the chain's own `0x1::stake::ValidatorSet` at a version of its epoch, and the stand-in
  transaction against the REST API's.

**synthetic.json** (SYNTHETIC: every key is a test key, every ledger info made up). The two claims end to end, update
and slots, with the vault's `Attested` event the statement writes, and the public values the program must commit,
which `test/AptosStateVerifier.t.sol` uses.
"""

import json
import os
import sys

import aptos_py as a
import bls_py as bls
from keccak import keccak
from rpc import MAINNET, TESTNET, backup, backup_json, backup_metadata, records, rest

HERE = os.path.dirname(os.path.abspath(__file__))
UPDATE = keccak(b"xindex.v4.aptos.update")
SLOTS = keccak(b"xindex.v4.aptos.slots")
ATTEST_DOMAIN = keccak(b"xindex.v4.vault-attest")
CHAIN_ID = {"mainnet": 549304973309166888, "testnet": 10134113455198361380}
FEE_STATEMENT = a.struct_tag(bytes(31) + b"\x01", "transaction_fee", "FeeStatement")


def hx(b):
    return "0x" + bytes(b).hex()


def word(n):
    return n.to_bytes(32, "big")


def check_caip2():
    for name, cid in (("aptos:1", CHAIN_ID["mainnet"]), ("aptos:2", CHAIN_ID["testnet"])):
        assert int.from_bytes(keccak(name.encode())[:8], "big") == cid, name


# ---------------------------------------------------------------------------
# the backup
# ---------------------------------------------------------------------------


def epoch_ending(epoch, names, network="mainnet"):
    """The ledger info that ended `epoch`, as `LedgerInfoWithSignatures` BCS, from the backup's epoch-ending files."""
    single = "metadata/epoch_ending_%d-%d.meta" % (epoch, epoch)
    candidates = [single] if single in names else [
        n for n in names if n.startswith("metadata/epoch_ending_compacted_")
        and int(n.split("_")[-1].split("-")[0]) <= epoch <= int(n.split("-")[-1].split(".")[0])
    ]
    for meta in candidates:
        for line in backup(meta, network).decode().splitlines():
            b = json.loads(line).get("EpochEndingBackup")
            if not b or not b["first_epoch"] <= epoch <= b["last_epoch"]:
                continue
            for chunk in backup_json(b["manifest"], network)["chunks"]:
                if chunk["first_epoch"] <= epoch <= chunk["last_epoch"]:
                    raw = records(backup(chunk["ledger_infos"], network))[epoch - chunk["first_epoch"]]
                    s = a.read_signed(a.Reader(raw))
                    assert s["ledger_info"]["epoch"] == epoch and s["ledger_info"]["next_epoch_state"]
                    assert a.write_signed(s) == raw, "BCS round trip"
                    return raw, s
    raise SystemExit("no epoch-ending ledger info for epoch %d in the backup" % epoch)


def find_info(rec):
    """The `TransactionInfo` in a backup record `(Transaction, PersistedAuxiliaryInfo, TransactionInfo, events,
    WriteSet)`: the one offset where an info parses, followed by events whose accumulator is its event root and a
    write set whose hash is its state change hash. Each is a SHA3-256 commitment, so no other offset passes both."""
    found = []
    for o in range(1, len(rec) - 120):
        # A variant (0 or 1), a gas count below 2^32, a status variant below 5.
        if rec[o] > 1 or rec[o + 5] or rec[o + 6] or rec[o + 7] or rec[o + 8] or rec[o + 9] > 4:
            continue
        try:
            r = a.Reader(rec, o)
            info = a.read_info(r)
            events = r.vec(lambda: a.read_event(r))
        except (AssertionError, IndexError):
            continue
        if a.accumulator_root(a.EVENT_ACCUMULATOR, [a.event_hash(e["bcs"]) for e in events]) != info["event_root_hash"]:
            continue
        if a.sha3(a.WRITE_SET, rec[r.p:]) != info["state_change_hash"]:
            continue
        found.append((info, events))
    assert len(found) == 1, "%d infos in a record" % len(found)
    return found[0]


def latest_transactions(names):
    metas = [n for n in names if n.startswith("metadata/transaction_")]
    best = max(metas, key=lambda n: int(n.split("_")[-1].split("-")[0]))
    return backup_json(json.loads(backup(best))["TransactionBackup"]["manifest"])


def points(signed, validators):
    idx = a.signers(signed["bitmask"], len(validators))
    return [hx(bls.decompress_g1(validators[i]["public_key"])) for i in idx], idx


def signed_json(raw, s, validators):
    pts, idx = points(s, validators)
    power, total, ok = a.quorum(validators, idx)
    assert ok, "no quorum"
    return {"signed": hx(raw), "points": pts}, {"signers": len(idx), "of": len(validators), "power": power,
                                                 "total": total}


def chain_set(node, version):
    """`ValidatorVerifier::from(&ValidatorSet)` for the on-chain `0x1::stake::ValidatorSet` at `version`: the active
    and pending-inactive validators, ordered by `validator_index`, each with its consensus key and voting power."""
    d = rest(node, "/accounts/0x1/resource/0x1::stake::ValidatorSet?ledger_version=%d" % version)["data"]
    vals = []
    for v in d["active_validators"] + d["pending_inactive"]:
        vals.append((int(v["config"]["validator_index"]), {
            "address": bytes.fromhex(v["addr"][2:].rjust(64, "0")),
            "public_key": bytes.fromhex(v["config"]["consensus_pubkey"][2:]),
            "voting_power": int(v["voting_power"]),
        }))
    vals.sort(key=lambda x: x[0])
    assert [i for i, _ in vals] == list(range(len(vals)))
    return [v for _, v in vals]


def configuration(node, version=None):
    q = "" if version is None else "?ledger_version=%d" % version
    d = rest(node, "/accounts/0x1/resource/0x1::reconfiguration::Configuration" + q)["data"]
    return int(d["epoch"]), int(d["last_reconfiguration_time"])


# ---------------------------------------------------------------------------
# mainnet.json
# ---------------------------------------------------------------------------


def mainnet(out):
    names = backup_metadata()
    manifest = latest_transactions(names)
    chunk = min(manifest["chunks"], key=lambda c: c["last_version"] - c["first_version"])
    assert chunk["format"] == "V1"
    r = a.Reader(backup(chunk["proof"]))
    left, right = r.vec(r.hash), r.vec(r.hash)
    proof_raw = r.d[r.p:]
    final = a.read_signed(r)
    assert r.done()
    li = final["ledger_info"]
    epoch = li["epoch"]
    print("chunk %d-%d under a ledger info of epoch %d at version %d" % (
        chunk["first_version"], chunk["last_version"], epoch, li["version"]))

    # Every transaction info of the chunk, each confirmed by its events and write set, then the range proof.
    recs = records(backup(chunk["transactions"]))
    assert len(recs) == chunk["last_version"] - chunk["first_version"] + 1
    parsed = [find_info(rec) for rec in recs]
    leaves = [a.info_hash(info["bcs"]) for info, _ in parsed]
    root, _ = a.range_to_leaf(a.TXN_ACCUMULATOR, chunk["first_version"], leaves, left, right, chunk["first_version"])
    assert root == li["executed_state_id"], "the range proof does not reach the ledger info's root"
    print("range proof of %d infos verified" % len(leaves))

    # The stand-in: a successful transaction with two module events, one of them FeeStatement, the other the smallest.
    def fits(p):
        info, events = p
        return (info["status"] == 0 and len(events) == 2 and all(e["variant"] == 1 for e in events)
                and events[1]["type_tag"] == FEE_STATEMENT and events[0]["type_tag"] != FEE_STATEMENT)

    k = min((i for i, p in enumerate(parsed) if fits(p)), key=lambda i: len(parsed[i][1][0]["bcs"]))
    info, events = parsed[k]
    version = chunk["first_version"] + k
    root2, siblings = a.range_to_leaf(a.TXN_ACCUMULATOR, chunk["first_version"], leaves, left, right, version)
    assert root2 == root and a.climb(a.TXN_ACCUMULATOR, leaves[k], version, siblings) == root
    assert a.write_info(info, info["event_root_hash"]) == info["bcs"], "the info, written successful"
    js = rest(MAINNET, "/transactions/by_version/%d" % version)
    assert js["success"] and js["hash"] == hx(info["transaction_hash"])
    assert js["event_root_hash"] == hx(info["event_root_hash"]) and js["accumulator_root_hash"]
    assert info["bcs"] in rest(MAINNET, "/transactions/by_version/%d" % version, bcs=True)
    print("stand-in: version %d, %s" % (version, js["events"][0]["type"]))

    # The sets: the trusted one, named when epoch - 3 ended, and the two hops.
    trusted_epoch = epoch - 2
    _, named = epoch_ending(trusted_epoch - 1, names)
    trusted = named["ledger_info"]["next_epoch_state"]
    assert trusted["epoch"] == trusted_epoch
    hop_raw = [epoch_ending(e, names) for e in (trusted_epoch, trusted_epoch + 1)]
    sets = [trusted["validators"], hop_raw[0][1]["ledger_info"]["next_epoch_state"]["validators"],
            hop_raw[1][1]["ledger_info"]["next_epoch_state"]["validators"]]
    assert hop_raw[1][1]["ledger_info"]["next_epoch_state"]["epoch"] == epoch

    # The trusted set as the chain holds it, after the version whose ledger info named it.
    start = named["ledger_info"]["version"]
    assert chain_set(MAINNET, start) == trusted["validators"], "the trusted set is not the chain's"
    assert configuration(MAINNET, start) == (trusted_epoch, named["ledger_info"]["timestamp_usecs"])

    hops, quorums = [], []
    for (raw, s), vals in zip(hop_raw, sets[:2]):
        j, q = signed_json(raw, s, vals)
        hops.append(j)
        quorums.append(q)
    final_json, q = signed_json(proof_raw, final, sets[2])
    quorums.append(q)

    trusted_json = {"epoch": trusted_epoch, "validators": hx(a.write_validators(trusted["validators"]))}
    new_set = hop_raw[1][1]["ledger_info"]["next_epoch_state"]
    time = hop_raw[1][1]["ledger_info"]["timestamp_usecs"]
    update_values = UPDATE + word(trusted_epoch) + a.set_hash(trusted["validators"], keccak) + word(epoch) \
        + a.set_hash(new_set["validators"], keccak) + word(time)
    stand_in = events[0]
    doc = {
        "network": "mainnet",
        "note": "Real mainnet data from Aptos Labs' public backup (gs://%s) and REST API. No vault exists on Aptos yet: "
                "the module event of `event.transaction`, `event.type_tag` with `event.data`, stands in for the "
                "vault's `Attested`." % "aptos-mainnet-backup-usce1",
        "update": {"trusted": trusted_json, "hops": hops},
        "event": {
            "trusted": trusted_json,
            "hops": hops,
            "ledger_info": final_json,
            "transaction": {
                "version": version,
                "info": hx(info["bcs"]),
                "siblings": [hx(s) for s in siblings],
                "events": [hx(e["bcs"]) for e in events],
            },
            "type_tag": hx(stand_in["type_tag"]),
            "data": hx(stand_in["data"]),
            "type": js["events"][0]["type"],
        },
        "public_values": {"update": hx(update_values)},
        "checks": {
            "trusted_set": hx(a.set_hash(trusted["validators"], keccak)),
            "trusted_time": named["ledger_info"]["timestamp_usecs"],
            "set": hx(a.set_hash(new_set["validators"], keccak)),
            "time": time,
            "quorums": quorums,
            "chunk": [chunk["first_version"], chunk["last_version"]],
            "ledger_version": li["version"],
            "root": hx(root),
        },
    }
    write(out, doc)


# ---------------------------------------------------------------------------
# synthetic.json
# ---------------------------------------------------------------------------


def synthetic_set(epoch, keys, powers):
    vals = []
    for k, p in zip(keys, powers):
        compressed, _ = bls.public_key(bls.test_key(k))
        vals.append({"address": keccak(b"validator" + k.to_bytes(4, "big")), "public_key": compressed,
                     "voting_power": p})
    return {"epoch": epoch, "validators": vals, "keys": keys}


def synthetic_sign(li, s, signer_idx):
    """`LedgerInfoWithSignatures` BCS signed by validators `signer_idx` of set `s`, and their points."""
    n = len(s["validators"])
    bitmask = bytearray((n + 7) // 8)
    for i in signer_idx:
        bitmask[i // 8] |= 0x80 >> (i % 8)
    secret = sum(bls.test_key(s["keys"][i]) for i in signer_idx) % bls.R
    sig = bls.sign(secret, a.signing_message(li))
    signed = {"ledger_info": li, "bitmask": bytes(bitmask), "signature": sig}
    power, total, ok = a.quorum(s["validators"], sorted(signer_idx))
    assert ok
    pts = [hx(bls.public_key(bls.test_key(s["keys"][i]))[1]) for i in sorted(signer_idx)]
    return {"signed": hx(a.write_signed(signed)), "points": pts}


def quorum_signers(vals):
    """The fewest validators, largest first, whose power passes two thirds: a quorum with room to spare for none."""
    order = sorted(range(len(vals)), key=lambda i: -vals[i]["voting_power"])
    total = sum(v["voting_power"] for v in vals)
    picked, power = [], 0
    for i in order:
        picked.append(i)
        power += vals[i]["voting_power"]
        if 3 * power > 2 * total:
            return sorted(picked)
    raise AssertionError


def synthetic(out):
    # 25 validators with a spread like mainnet's (octas of APT staked, rounded): a few large, a long tail.
    powers = [(3_000_000 - 110_000 * i) * 10 ** 8 for i in range(25)]
    trusted_epoch = 17_600
    trusted_time = 1_791_200_000_000_000  # microseconds: 2026-10-05T09:33:20Z, when the set was named
    s0 = synthetic_set(trusted_epoch, list(range(1, 26)), powers)
    s1 = synthetic_set(trusted_epoch + 1, list(range(2, 27)), powers[1:] + [powers[0]])  # one leaves, one joins
    s2 = synthetic_set(trusted_epoch + 2, list(range(2, 27)), [p + 10 ** 12 for p in powers])  # powers move

    def li(epoch, rnd, version, ts, root, nxt):
        return {"epoch": epoch, "round": rnd, "id": keccak(b"block" + version.to_bytes(8, "big")),
                "executed_state_id": root, "version": version, "timestamp_usecs": ts,
                "next_epoch_state": None if nxt is None else {"epoch": nxt["epoch"], "validators": nxt["validators"]},
                "consensus_data_hash": keccak(b"consensus" + version.to_bytes(8, "big"))}

    hop0 = li(trusted_epoch, 3_901, 7_500_000_000, trusted_time + 7_200_000_000, keccak(b"root0"), s1)
    hop1 = li(trusted_epoch + 1, 3_877, 7_501_000_000, trusted_time + 14_400_000_000, keccak(b"root1"), s2)
    hops = [synthetic_sign(hop0, s0, quorum_signers(s0["validators"])),
            synthetic_sign(hop1, s1, list(range(25)))]

    # The vault's `attest` at a mainnet-sized version: its info under a made-up accumulator of 33 levels.
    chain_id = CHAIN_ID["mainnet"]
    package = keccak(b"SYNTHETIC xindex_vault package")
    vault_id = keccak(b"SYNTHETIC vault object")
    timestamp = trusted_time + 15_000_123_456
    slots = [keccak(b"intake slot"), word(25)]
    values = [keccak(b"intake digest"), bytes(32)]
    record = ATTEST_DOMAIN + word(chain_id) + vault_id + word(timestamp) + word(6 * 32) \
        + word(6 * 32 + 32 + 32 * len(slots)) + word(len(slots)) + b"".join(slots) + word(len(values)) + b"".join(values)
    attested = a.event_v2(a.struct_tag(package, "vault", "Attested"), a.bytes_(record))
    fee = a.event_v2(FEE_STATEMENT, bytes(range(40)))
    events = [attested, fee]
    event_root = a.accumulator_root(a.EVENT_ACCUMULATOR, [a.event_hash(e) for e in events])
    info = {"variant": 0, "gas_used": 27, "transaction_hash": keccak(b"attest transaction"),
            "state_change_hash": keccak(b"attest write set"), "state_checkpoint_hash": None,
            "auxiliary_info_hash": keccak(b"auxiliary info")}
    info_bcs = a.write_info(info, event_root)
    version = 7_501_234_567
    siblings = [keccak(b"sibling" + bytes([i])) for i in range(33)]
    root = a.climb(a.TXN_ACCUMULATOR, a.info_hash(info_bcs), version, siblings)
    final = synthetic_sign(li(trusted_epoch + 2, 41, version + 9, timestamp + 300_000, root, None), s2,
                           quorum_signers(s2["validators"]))

    trusted_json = {"epoch": trusted_epoch, "validators": hx(a.write_validators(s0["validators"]))}
    trusted_set = a.set_hash(s0["validators"], keccak)
    update_values = UPDATE + word(trusted_epoch) + trusted_set + word(trusted_epoch + 2) \
        + a.set_hash(s2["validators"], keccak) + word(hop1["timestamp_usecs"])
    slots_hash = keccak(word(64) + word(64 + 32 + 32 * len(slots)) + word(len(slots)) + b"".join(slots)
                        + word(len(values)) + b"".join(values))
    slots_values = SLOTS + word(chain_id) + word(trusted_epoch) + trusted_set + package + vault_id + word(version) \
        + word(timestamp) + slots_hash
    doc = {
        "network": "SYNTHETIC",
        "note": "SYNTHETIC: every key is a test key (bls_py.test_key) and every ledger info is made up. Both claims end "
                "to end, with the public values the program must commit.",
        "verifier": {"chain_id": chain_id, "package": hx(package), "vault_id": hx(vault_id),
                     "trusted_epoch": trusted_epoch, "trusted_set": hx(trusted_set), "trusted_time": trusted_time,
                     "new_epoch": trusted_epoch + 2, "new_set": hx(a.set_hash(s2["validators"], keccak)),
                     "new_time": hop1["timestamp_usecs"]},
        "update": {"trusted": trusted_json, "hops": hops},
        "slots": {
            "trusted": trusted_json,
            "hops": hops,
            "ledger_info": final,
            "transaction": {"version": version, "info": hx(info_bcs), "siblings": [hx(x) for x in siblings],
                            "events": [hx(e) for e in events]},
            "chain_id": chain_id,
            "package": hx(package),
            "vault_id": hx(vault_id),
            "timestamp": timestamp,
            "slots": [hx(x) for x in slots],
            "values": [hx(x) for x in values],
        },
        "public_values": {"update": hx(update_values), "slots": hx(slots_values)},
    }
    write(out, doc)


# ---------------------------------------------------------------------------
# anchor
# ---------------------------------------------------------------------------


def anchor(out, network):
    """The epoch in force: its number, its validators' hash and when the ledger info that named it was signed, read
    from the chain's own `Configuration` and `ValidatorSet`, and checked against the backup's epoch-ending ledger info,
    whose next set must be exactly this one."""
    node = MAINNET if network == "mainnet" else TESTNET
    head = rest(node, "/")
    version = int(head["ledger_version"])
    epoch, named = configuration(node, version)
    vals = chain_set(node, version)
    doc = {
        "network": network,
        "note": "The verifier's first set: the validators of epoch `epoch`, in force at version `version`, named by the "
                "ledger info that ended the epoch before, signed at `time` (microseconds). Check it again during the "
                "chain's listing delay. The verifier must be advanced within MAX_LAG of `time`.",
        "chainId": str(CHAIN_ID[network]),
        "epoch": epoch,
        "set": hx(a.set_hash(vals, keccak)),
        "time": named,
        "version": version,
        "validators": [[hx(v["address"]), hx(v["public_key"]), str(v["voting_power"])] for v in vals],
    }
    _, s = epoch_ending(epoch - 1, backup_metadata(network), network)
    nxt = s["ledger_info"]["next_epoch_state"]
    assert nxt["epoch"] == epoch and nxt["validators"] == vals, "the backup's set is not the chain's"
    assert s["ledger_info"]["timestamp_usecs"] == named
    doc["named_by_version"] = s["ledger_info"]["version"]
    write(out, doc)


def write(path, doc):
    with open(path, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print("wrote", path)


if __name__ == "__main__":
    check_caip2()
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "mainnet":
        mainnet(sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "mainnet.json"))
    elif mode == "synthetic":
        synthetic(sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "synthetic.json"))
    elif mode == "anchor" and len(sys.argv) > 2:
        anchor(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "mainnet")
    else:
        raise SystemExit(__doc__)
