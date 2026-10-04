#!/usr/bin/env python3
"""Pins, on real Aptos mainnet transactions, how a ledger commits to a module event such as the vault's `Attested`, for
the Ethereum side's `AptosStateVerifier`:

- an event's BCS is `ContractEvent::V2` (variant 1): `TypeTag::Struct` (variant 7), the struct tag (address, module and
  name as ULEB128-prefixed strings, no type arguments), then the event's data as a ULEB128-prefixed byte string;
- its hash is `sha3_256(sha3_256("APTOS::ContractEvent") ++ bcs)`;
- the transaction info's `event_root_hash` is the in-memory accumulator over those hashes: each internal node
  `sha3_256(sha3_256("APTOS::EventAccumulator") ++ left ++ right)`, a missing right sibling the placeholder
  `"ACCUMULATOR_PLACEHOLDER_HASH" ++ 0x00000000`.

`--fetch` reads three transactions from a public fullnode, read-only (their BCS and JSON), and writes
`mainnet-events.json`: each transaction's events as BCS, found in the transaction's own BCS, and its event root. Without
it, the script checks that file offline. From the repository root:

    python3 aptos/tests/fixtures/events.py --fetch
    python3 aptos/tests/fixtures/events.py
"""

import hashlib
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "mainnet-events.json")
NODE = "https://fullnode.mainnet.aptoslabs.com/v1"
# One, two and three events: a lone fee statement, and accumulators with and without a placeholder.
VERSIONS = [7481082438, 7481082436, 7481082440]


def sha3(b):
    return hashlib.sha3_256(b).digest()


def uleb(n):
    out = b""
    while True:
        x = n & 0x7F
        n >>= 7
        if n:
            out += bytes([x | 0x80])
        else:
            return out + bytes([x])


def read_uleb(b, i):
    n = shift = 0
    while True:
        x = b[i]
        i += 1
        n |= (x & 0x7F) << shift
        shift += 7
        if x < 0x80:
            return n, i


def type_tag(type_str):
    """`TypeTag::Struct` of a non-generic `address::module::Name`."""
    addr, module, name = type_str.split("::")
    a = bytes.fromhex(addr[2:].rjust(64, "0"))
    return bytes([7]) + a + uleb(len(module)) + module.encode() + uleb(len(name)) + name.encode() + uleb(0)


def event_hash(bcs):
    return sha3(sha3(b"APTOS::ContractEvent") + bcs)


def accumulator_root(leaves):
    salt = sha3(b"APTOS::EventAccumulator")
    placeholder = b"ACCUMULATOR_PLACEHOLDER_HASH" + bytes(4)
    if not leaves:
        return placeholder
    layer = list(leaves)
    while len(layer) > 1:
        if len(layer) % 2:
            layer.append(placeholder)
        layer = [sha3(salt + layer[i] + layer[i + 1]) for i in range(0, len(layer), 2)]
    return layer[0]


def get(url, bcs):
    request = urllib.request.Request(url, headers={"Accept": "application/x-bcs" if bcs else "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def fetch():
    out = []
    for v in VERSIONS:
        raw = get(f"{NODE}/transactions/by_version/{v}", True)
        tx = json.loads(get(f"{NODE}/transactions/by_version/{v}", False))
        events, at = [], 0
        for e in tx["events"]:
            tag = type_tag(e["type"])
            start = raw.find(b"\x01" + tag, at)
            assert start >= 0, f"{v}: {e['type']} is not in the transaction's BCS as ContractEvent::V2"
            n, data_at = read_uleb(raw, start + 1 + len(tag))
            at = data_at + n
            events.append({"type": e["type"], "bcs": "0x" + raw[start:at].hex()})
        out.append({"version": v, "hash": tx["hash"], "event_root_hash": tx["event_root_hash"], "events": events})
    with open(OUT, "w") as f:
        json.dump({"source": NODE, "transactions": out}, f, indent=1)
        f.write("\n")
    print(f"wrote {OUT}")


def check():
    ok = True
    for tx in json.load(open(OUT))["transactions"]:
        hashes = []
        for e in tx["events"]:
            bcs = bytes.fromhex(e["bcs"][2:])
            tag = type_tag(e["type"])
            assert bcs[0] == 1 and bcs[1:1 + len(tag)] == tag, e["type"]
            n, data_at = read_uleb(bcs, 1 + len(tag))
            assert data_at + n == len(bcs)
            hashes.append(event_hash(bcs))
        match = accumulator_root(hashes) == bytes.fromhex(tx["event_root_hash"][2:])
        ok &= match
        print(f"{tx['version']}: {len(hashes)} events, event root {'matches' if match else 'DIFFERS'}")
    return ok


if __name__ == "__main__":
    if "--fetch" in sys.argv:
        fetch()
    sys.exit(0 if check() else 1)
