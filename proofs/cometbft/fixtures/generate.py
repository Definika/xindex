"""Builds `injective.json`, the CometBFT state verifier's fixture, from Injective mainnet's public endpoints (read-only),
checking every link with `cometbft_py`, an implementation separate from the Rust statement and the Solidity verifier.

    uv run --with pynacl --with pycryptodome python3 generate.py [span] [contract] [comet-url] [evm-url]

- the trusted header T, `span` blocks back (3,000 by default, about half an hour), and its next validator set;
- a skipping hop to H, every validator set of H and H+1 checked against the headers, H's commit signed by more than two
  thirds of T's next set and of H's own set, and an adjacent hop to H+1, signed by more than two thirds of its set;
- block H's header, under H+1's `last_block_id`, whose time the EVM gave block H;
- ICS-23 proofs of two storage slots of `contract`, one present and one absent, in the `evm` store under
  `0x02 ++ address ++ slot` at height H, checked to H+1's `app_hash` and against `eth_getStorageAt` at block H;
- the public values the statement must commit for the update to H+1 and for the slots.

Injective's public sentry keeps state proofs for about the last 100 blocks, so the generator takes H three blocks behind
the head and fetches its proofs first; Polkachu's archive (`https://injective-rpc.polkachu.com`) keeps about 8 hours.
"""

import base64
import json
import sys

from cometbft_py import (
    abi_slots_values,
    evm_value,
    existence,
    commitment_proof,
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

SPAN = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
CONTRACT = (sys.argv[2] if len(sys.argv) > 2 else "0x263c63c1d8901c14520474110ce88cfadae0cfe9").lower()
COMET_URL = sys.argv[3] if len(sys.argv) > 3 else COMET
EVM_URL = sys.argv[4] if len(sys.argv) > 4 else EVM
CHAIN_ID = "injective-1"
EVM_CHAIN_ID = 1776
# A slot the contract holds (an `Ownable` owner) and one it never wrote: the snapshot root's slot, `bytes32(25)`, which
# every evidence proof reads as zero.
SLOTS = [0, 25]
UPDATE = keccak(b"xindex.v4.cometbft.update")
STATE = keccak(b"xindex.v4.cometbft.slots")


def c(endpoint, **params):
    return comet(endpoint, params, COMET_URL)


def e(method, *params):
    return evm(method, list(params), EVM_URL)


def validators(height):
    out = c("validators", height=height, per_page=100)
    assert int(out["total"]) == len(out["validators"]), "more validators than one page"
    return out["validators"]


def signed_header(height):
    out = c("commit", height=height)
    assert out["canonical"], "the commit of %d is not canonical yet" % height
    return out["signed_header"]


def seconds(h):
    return parse_time(h["time"])[0]


def main():
    head = int(c("status")["sync_info"]["latest_block_height"])
    h = head - 3
    vault = bytes.fromhex(CONTRACT[2:])

    # The state first: the sentry keeps proofs only for the last hundred or so blocks.
    proofs = []
    for s in SLOTS:
        key = b"\x02" + vault + word(s)
        q = c("abci_query", path='"/store/evm/key"', data="0x" + key.hex(), height=h, prove="true")["response"]
        assert q["code"] == 0 and int(q["height"]) == h, q
        ops = q["proofOps"]["ops"]
        assert [o["type"] for o in ops] == ["ics23:iavl", "ics23:simple"], ops
        assert base64.b64decode(ops[0]["key"]) == key and base64.b64decode(ops[1]["key"]) == b"evm"
        raw = base64.b64decode(q["value"]) if q.get("value") else b""
        proofs.append((s, key, raw, base64.b64decode(ops[0]["data"]), base64.b64decode(ops[1]["data"])))
    store_proof = proofs[0][4]
    assert all(p[4] == store_proof for p in proofs), "one multistore proof for every slot of one height"

    trusted_height = h - SPAN
    trusted = signed_header(trusted_height)["header"]
    trusted_next = validators(trusted_height + 1)
    sh_h, vals_h, next_h = signed_header(h), validators(h), validators(h + 1)
    sh_h1, vals_h1, next_h1 = signed_header(h + 1), validators(h + 1), validators(h + 2)

    # The trusted header and its next set.
    assert trusted["chain_id"] == CHAIN_ID
    trusted_hash = header_hash(trusted)
    assert validators_hash(trusted_next) == bytes.fromhex(trusted["next_validators_hash"])
    # Hop 1, skipping: H's sets, H's commit, more than two thirds of T's next set and of H's own.
    hh = sh_h["header"]
    assert hh["chain_id"] == CHAIN_ID and int(hh["height"]) > trusted_height + 1
    assert seconds(hh) >= seconds(trusted) and parse_time(hh["time"]) > parse_time(trusted["time"])
    assert validators_hash(vals_h) == bytes.fromhex(hh["validators_hash"])
    assert validators_hash(next_h) == bytes.fromhex(hh["next_validators_hash"])
    own = signed_power(sh_h, vals_h)
    overlap = signed_power(sh_h, trusted_next)
    assert more_than_two_thirds(*own) and more_than_two_thirds(*overlap), (own, overlap)
    changed = hh["validators_hash"] != trusted["next_validators_hash"]
    # Hop 2, adjacent: H+1's set is H's next, and more than two thirds of it signed.
    h1 = sh_h1["header"]
    assert int(h1["height"]) == h + 1 and h1["validators_hash"] == hh["next_validators_hash"]
    assert validators_hash(vals_h1) == bytes.fromhex(h1["validators_hash"])
    assert validators_hash(next_h1) == bytes.fromhex(h1["next_validators_hash"])
    own1 = signed_power(sh_h1, vals_h1)
    assert more_than_two_thirds(*own1), own1
    # Block H is H+1's parent, and the EVM dates block H by its header's time, in seconds.
    assert bytes.fromhex(h1["last_block_id"]["hash"]) == header_hash(hh)
    block = e("eth_getBlockByNumber", hex(h), False)
    assert int(block["number"], 16) == h and int(block["timestamp"], 16) == seconds(hh), block
    assert int(e("eth_chainId"), 16) == EVM_CHAIN_ID

    # The state: the multistore proof opens `evm` to its root under H+1's app hash, and each slot's proof opens its key
    # under that root, its value what the EVM reads at block H.
    kind, sp = commitment_proof(store_proof)
    assert kind == "exist" and sp["key"] == b"evm"
    assert existence_root(sp) == bytes.fromhex(h1["app_hash"]), "the multistore proof is not under H+1's app hash"
    evm_root = sp["value"]
    slots, values, kinds = [], [], []
    for s, key, raw, proof, _ in proofs:
        got = prove_slot(proof, key, evm_root)
        assert got == raw, "the proof's value is the query's"
        value = evm_value(got) if got else bytes(32)
        assert len(got) in (0, 32), "a stored value of %d bytes" % len(got)
        onchain = bytes.fromhex(e("eth_getStorageAt", "0x" + vault.hex(), "0x" + word(s).hex(), hex(h))[2:])
        assert value == onchain, (s, value.hex(), onchain.hex())
        slots.append(word(s))
        values.append(value)
        kinds.append(commitment_proof(proof)[0])
    assert kinds == ["exist", "nonexist"] and values[0] != bytes(32), (kinds, values)

    chain_hash = keccak(CHAIN_ID.encode())
    t = (word(int(trusted["height"])), trusted_hash, word(seconds(trusted)))
    update = UPDATE + chain_hash + b"".join(t) + word(h + 1) + header_hash(h1) + word(seconds(h1))
    state = (
        STATE
        + chain_hash
        + b"".join(t)
        + word(h)
        + word(seconds(hh))
        + vault.rjust(32, b"\x00")
        + keccak(abi_slots_values(slots, values))
    )

    out = {
        "note": "Injective mainnet, read-only from %s and %s: written by generate.py, every link checked." % (
            COMET_URL,
            EVM_URL,
        ),
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
        "checks": {
            "skip_blocks": h - int(trusted["height"]),
            "set_changed_between": changed,
            "hop1_own_power": list(own),
            "hop1_trusted_power": list(overlap),
            "hop2_own_power": list(own1),
        },
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
    }
    with open("injective.json", "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print(
        "trusted %d, H %d (%d blocks, set changed: %s), hop 1: %d/%d of H's set and %d/%d of T's, %d slots"
        % (int(trusted["height"]), h, h - int(trusted["height"]), changed, *own, *overlap, len(slots))
    )


if __name__ == "__main__":
    main()
