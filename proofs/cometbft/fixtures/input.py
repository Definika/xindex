"""Builds a production input for the CometBFT host (`cometbft prove <update|slots> <input.json> <out.json>`) in
`injective.json`'s shape, read-only: hops from a header `CometBftStateVerifier` already trusts to a recent height H and
H+1, and ICS-23 proofs of the vault's `slots` at H. The rebalance filler (`keeper/chains/injective.mjs`) calls it with
the vault's intake digest slot; an update proves the same hops and ignores the slots. DRAFT (2026-10-06), adapted from
`generate.py`, whose checks it keeps, without the fixture's own choices of slots and span.

    uv run --with pynacl --with pycryptodome python3 input.py <vault> <trusted_height> <out.json> <slot> [<slot> ...]

The trusted header must be one the verifier trusts (`trusted(latestHash()).height`); the public sentry serves state
proofs only for the last hundred or so blocks, so H is taken three blocks behind the head and its proofs fetched first.
"""

import base64
import json
import sys

from cometbft_py import (
    abi_slots_values,
    commitment_proof,
    evm_value,
    existence_root,
    header_hash,
    keccak,
    more_than_two_thirds,
    parse_time,
    prove_slot,
    signed_power,
    validators_hash,
    word,
)
from rpc import COMET, EVM, comet, evm

CHAIN_ID = "injective-1"
EVM_CHAIN_ID = 1776
UPDATE = keccak(b"xindex.v4.cometbft.update")
STATE = keccak(b"xindex.v4.cometbft.slots")


def c(endpoint, **params):
    return comet(endpoint, params, COMET)


def e(method, *params):
    return evm(method, list(params), EVM)


def validators(height):
    out = c("validators", height=height, per_page=100)
    assert int(out["total"]) == len(out["validators"]), "more validators than one page"
    return out["validators"]


def signed_header(height):
    return c("commit", height=height)["signed_header"]


def seconds(h):
    return parse_time(h["time"]) // 10**9


def build(vault_hex, trusted_height, slot_words):
    head = int(c("status")["sync_info"]["latest_block_height"])
    h = head - 3
    vault = bytes.fromhex(vault_hex[2:].lower())

    proofs = []
    for s in slot_words:
        key = b"\x02" + vault + s
        q = c("abci_query", path='"/store/evm/key"', data="0x" + key.hex(), height=h, prove="true")["response"]
        assert q["code"] == 0 and int(q["height"]) == h, q
        ops = q["proofOps"]["ops"]
        assert [o["type"] for o in ops] == ["ics23:iavl", "ics23:simple"], ops
        raw = base64.b64decode(q["value"]) if q.get("value") else b""
        proofs.append((s, key, raw, base64.b64decode(ops[0]["data"]), base64.b64decode(ops[1]["data"])))
    store_proof = proofs[0][4]
    assert all(p[4] == store_proof for p in proofs), "one multistore proof for every slot of one height"

    trusted = signed_header(trusted_height)["header"]
    trusted_next = validators(trusted_height + 1)
    sh_h, vals_h, next_h = signed_header(h), validators(h), validators(h + 1)
    sh_h1, vals_h1, next_h1 = signed_header(h + 1), validators(h + 1), validators(h + 2)

    assert trusted["chain_id"] == CHAIN_ID
    trusted_hash = header_hash(trusted)
    assert validators_hash(trusted_next) == bytes.fromhex(trusted["next_validators_hash"])
    hh = sh_h["header"]
    assert hh["chain_id"] == CHAIN_ID and int(hh["height"]) > trusted_height + 1
    assert parse_time(hh["time"]) > parse_time(trusted["time"])
    assert validators_hash(vals_h) == bytes.fromhex(hh["validators_hash"])
    assert validators_hash(next_h) == bytes.fromhex(hh["next_validators_hash"])
    own = signed_power(sh_h, vals_h)
    overlap = signed_power(sh_h, trusted_next)
    assert more_than_two_thirds(*own) and more_than_two_thirds(*overlap), (own, overlap)
    h1 = sh_h1["header"]
    assert int(h1["height"]) == h + 1 and h1["validators_hash"] == hh["next_validators_hash"]
    assert validators_hash(vals_h1) == bytes.fromhex(h1["validators_hash"])
    assert validators_hash(next_h1) == bytes.fromhex(h1["next_validators_hash"])
    assert more_than_two_thirds(*signed_power(sh_h1, vals_h1))
    assert bytes.fromhex(h1["last_block_id"]["hash"]) == header_hash(hh)
    block = e("eth_getBlockByNumber", hex(h), False)
    assert int(block["number"], 16) == h and int(block["timestamp"], 16) == seconds(hh), block

    kind, sp = commitment_proof(store_proof)
    assert kind == "exist" and sp["key"] == b"evm"
    assert existence_root(sp) == bytes.fromhex(h1["app_hash"]), "the multistore proof is not under H+1's app hash"
    evm_root = sp["value"]
    slots, values, kinds = [], [], []
    for s, key, raw, proof, _ in proofs:
        got = prove_slot(proof, key, evm_root)
        assert got == raw and len(got) in (0, 32)
        value = evm_value(got) if got else bytes(32)
        onchain = bytes.fromhex(e("eth_getStorageAt", "0x" + vault.hex(), "0x" + s.hex(), hex(h))[2:])
        assert value == onchain, (s.hex(), value.hex(), onchain.hex())
        slots.append(s)
        values.append(value)
        kinds.append(commitment_proof(proof)[0])

    chain_hash = keccak(CHAIN_ID.encode())
    t = (word(int(trusted["height"])), trusted_hash, word(seconds(trusted)))
    update = UPDATE + chain_hash + b"".join(t) + word(h + 1) + header_hash(h1) + word(seconds(h1))
    state = (
        STATE + chain_hash + b"".join(t) + word(h) + word(seconds(hh)) + vault.rjust(32, b"\x00")
        + keccak(abi_slots_values(slots, values))
    )
    return {
        "note": "Injective mainnet, read-only, for the rebalance filler: written by input.py, every link checked.",
        "chain_id": CHAIN_ID,
        "evm_chain_id": EVM_CHAIN_ID,
        "trusted": {
            "height": int(trusted["height"]),
            "hash": "0x" + trusted_hash.hex(),
            "time": seconds(trusted),
            "header": trusted,
            "next_validators": trusted_next,
        },
        "hops": [
            {"signed_header": sh_h, "validators": vals_h, "next_validators": next_h},
            {"signed_header": sh_h1, "validators": vals_h1, "next_validators": next_h1},
        ],
        "state": {
            "height": h,
            "time": seconds(hh),
            "header": hh,
            "app_hash": "0x" + h1["app_hash"].lower(),
            "evm_root": "0x" + evm_root.hex(),
            "vault": "0x" + vault.hex(),
            "store_proof": "0x" + store_proof.hex(),
            "slots": [
                {"slot": "0x" + s.hex(), "proof": "0x" + p[3].hex(), "value": "0x" + v.hex(), "kind": k}
                for s, p, v, k in zip(slots, proofs, values, kinds)
            ],
        },
        "head": {"height": h + 1, "hash": "0x" + header_hash(h1).hex(), "time": seconds(h1)},
        "public_values": {"update": "0x" + update.hex(), "slots": "0x" + state.hex()},
        "values": ["0x" + v.hex() for v in values],
    }


if __name__ == "__main__":
    vault_hex, trusted_height, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    slot_words = [bytes.fromhex(s[2:].rjust(64, "0")) for s in sys.argv[4:]]
    assert slot_words, "at least one slot"
    with open(out_path, "w") as f:
        json.dump(build(vault_hex, trusted_height, slot_words), f, indent=1)
        f.write("\n")
    print("wrote", out_path)
