#!/usr/bin/env python3
"""Fetches what a Solana state proof can take from public devnet JSON-RPC, and records what it cannot.

Writes `devnet.json` beside this script: the Alpenglow genesis certificate (`getAgGenesisCert`), every vote account
with its v4 layout read (node, BLS key, stake), the epoch schedule, a finalized block's header fields, and the
probes that show which inputs public RPC does not serve (a block id, a footer, a bank hash, a slot's account writes).

Usage: python3 fetch_devnet.py [rpc_url]   (default https://api.devnet.solana.com)

The v4 vote state layout read here is Agave's `VoteStateFrameV4` (vote/src/vote_state_view/frame_v4.rs at
v4.4.0-beta.0): a u32 version (3 for V4), the node pubkey at 4, the withdrawer at 36, two collectors at 68 and 100, two
u16 commissions at 132 and 134, pending delegator rewards (u64) at 136, then the BLS pubkey as a bincode Option at 144:
a tag byte, then 48 compressed bytes.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://api.devnet.solana.com"
HERE = os.path.dirname(os.path.abspath(__file__))
V4 = 3
BLS_OFFSET = 144


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    for attempt in range(6):
        req = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                out = json.load(r)
            return out.get("result"), out.get("error")
        except urllib.error.HTTPError as e:
            # The public endpoint limits its rate: wait and try again.
            if e.code != 429 or attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))


def vote_account(entry, data):
    version = int.from_bytes(data[:4], "little")
    node = data[4:36]
    bls = None
    if version == V4 and len(data) > BLS_OFFSET + 49 and data[BLS_OFFSET] == 1:
        bls = data[BLS_OFFSET + 1 : BLS_OFFSET + 49].hex()
    return {
        "votePubkey": entry["votePubkey"],
        "nodePubkey": entry["nodePubkey"],
        "nodeFromData": base58(node),
        "activatedStake": entry["activatedStake"],
        "version": version,
        "blsPubkeyCompressed": bls,
        "dataLength": len(data),
    }


ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58(b):
    n = int.from_bytes(b, "big")
    s = ""
    while n:
        n, r = divmod(n, 58)
        s = ALPHABET[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s


def main():
    out = {"rpc": RPC}
    out["version"], _ = rpc("getVersion")
    out["epochInfo"], _ = rpc("getEpochInfo")
    out["epochSchedule"], _ = rpc("getEpochSchedule")
    cert, err = rpc("getAgGenesisCert")
    out["genesisCert"] = cert if cert else {"error": err}
    # Every signed vote payload ends with the cluster's shred version (votor-messages/src/wire.rs).
    nodes, _ = rpc("getClusterNodes")
    versions = sorted({n.get("shredVersion") for n in nodes if n.get("shredVersion") is not None})
    out["shredVersions"] = versions

    va, _ = rpc("getVoteAccounts")
    entries = va["current"] + va["delinquent"]
    infos, _ = rpc("getMultipleAccounts", [[e["votePubkey"] for e in entries], {"encoding": "base64"}])
    out["voteAccounts"] = [vote_account(e, base64.b64decode(i["data"][0])) for e, i in zip(entries, infos["value"])]
    out["epochTotalStakeFromVoteAccounts"] = sum(e["activatedStake"] for e in entries)

    slot, _ = rpc("getSlot", [{"commitment": "finalized"}])
    block, _ = rpc(
        "getBlock",
        [slot, {"transactionDetails": "none", "rewards": False, "maxSupportedTransactionVersion": 1}],
    )
    out["finalizedSlot"] = slot
    out["finalizedBlock"] = block
    # Traffic: transactions and distinct writable accounts in a few recent blocks. A slot's account writes are these
    # plus what the runtime itself writes (sysvars, fees, the incinerator, vote accounts the footer rewards).
    sample = []
    for back in range(1, 40, 6):
        b, _ = rpc(
            "getBlock",
            [slot - back, {"transactionDetails": "accounts", "rewards": False, "maxSupportedTransactionVersion": 1}],
        )
        if not b:
            continue
        writable = {a["pubkey"] for t in b["transactions"] for a in t["transaction"]["accountKeys"] if a.get("writable")}
        sample.append({"slot": slot - back, "transactions": len(b["transactions"]), "writableAccounts": len(writable)})
    out["writeSample"] = sample
    # What a state proof needs and public RPC does not serve: each probe names the method tried and its answer.
    probes = {}
    for method, params in [
        ("getBankHash", [slot]),
        ("getBlockId", [slot]),
        ("getBlockFooter", [slot]),
        ("getAccountsLtHash", [slot]),
        ("getSlotAccountWrites", [slot]),
    ]:
        result, error = rpc(method, params)
        probes[method] = {"result": result, "error": error}
    out["probes"] = probes
    out["blockFields"] = sorted(block.keys()) if block else None

    with open(os.path.join(HERE, "devnet.json"), "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    with_bls = [v for v in out["voteAccounts"] if v["blsPubkeyCompressed"]]
    print(f"{out['version']}: {len(out['voteAccounts'])} vote accounts, {len(with_bls)} with a BLS key")
    print(f"genesis cert slot: {cert['block']['slot'] if cert else None}; finalized slot {slot}")
    print("block fields:", out["blockFields"])
    for m, p in probes.items():
        print(m, "->", p["error"]["message"] if p["error"] else "served")


if __name__ == "__main__":
    main()
