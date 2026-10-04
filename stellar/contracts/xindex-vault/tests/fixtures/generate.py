#!/usr/bin/env python3
"""Builds hub.json: a real HybridHub index's storage, proven by `eth_getProof`, for the Stellar vault's snapshot exit.

The Stellar copy of `solana/programs/xindex-vault/tests/fixtures/generate.py`, parametrized for Stellar: the chain is
registered under Stellar testnet's registry id (`design/2026-10-03-near-stellar-interfaces.md`) with the tests' vault
contract id, and the vault's coin is XLM in stroops. It runs the repository's own contracts on a local anvil with
Sepolia's chain id: the HybridIndexFactory and its three HybridHub parts, an index of WETH and XLM, and an order that
mints through the timelocks. Then it gives two holders shares, has one register a recovery key on Stellar, books a
claim of XLM, sends a burn to a Stellar account, migrates into a second version, and leaves a second order unsettled.
Every slot the vault reads is proven from the last block's state root, as the vault reads it at its snapshot, and one
holder signs its claim (EIP-712) with its Ethereum key.

Needs foundry (forge, cast, anvil) and the Solidity libraries in `lib/`. From the repository root:

    python3 stellar/contracts/xindex-vault/tests/fixtures/generate.py

The state verifier is the repository's `MockStateVerifier`, which on a chain without cheatcodes reports the value its
proof claims: the settlement it proves is the deposit the Stellar tests make into the same intake.
"""

import json
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), *[".."] * 5))
OUT = os.path.join(os.path.dirname(__file__), "hub.json")
RPC = "http://127.0.0.1:8577"
CHAIN = 11_155_111  # Sepolia's id, which the vault's messages name as their source
# Stellar testnet's registry id: the first 8 bytes of keccak256("stellar:testnet").
XLM_CHAIN = 17_667_989_177_921_016_935
# The tests' vault contract id, where they deploy the vault: keccak256("xindex stellar vault (tests)").
XLM_VAULT = "0x1fe52b378c4f36f86bb4aa3eafe30f9045c01bcc23182cd8ea8d01d43515728a"
START = 1_800_000_000
# anvil's first accounts: the deployer (owner, guardian, creator and minter), holder A (signs) and holder B (a recovery
# key).
KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9ad8a4ed574dc",
]
ETH_SUPPLY = 120_000_000 * 10**18
XLM_SUPPLY = 50_000_000_000 * 10**7  # XLM's, in stroops
K = 25 * 10**26  # 0.3 WETH and 125 XLM per whole share
LISTING_DELAY = 2 * 24 * 3600
MINT_LOCK = 24 * 3600
INTAKE_DIGEST_DOMAIN = "0x73bc63cbb2438f9ca78af51ef010ac754ee98b02f528cf72c876da9a84dd01f9"
HUB_SHARES = "0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00"


def data(out):
    """A JSON answer, unwrapped from the `{"schema_version", "success", "data"}` envelope newer tools add."""
    value = json.loads(out[out.index("{"):])
    return value["data"] if "schema_version" in value else value


def run(*args, cwd=ROOT):
    done = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"{' '.join(args)}\n{done.stderr}")
    return done.stdout.strip()


def cast(*args):
    return run("cast", *args, "--rpc-url", RPC) if args[0] in ("call", "send", "rpc", "block", "proof", "nonce",
                                                                 "storage") else run("cast", *args)


def address_of(key):
    return run("cast", "wallet", "address", "--private-key", key)


def send(key, to, sig, *args):
    cast("send", "--private-key", key, to, sig, *args)


def call(to, sig, *args, sender=None):
    extra = ["--from", sender] if sender else []
    return cast("call", *extra, to, sig, *args)


def warp(seconds):
    cast("rpc", "evm_increaseTime", hex(seconds))
    cast("rpc", "evm_mine")


def now():
    return int(data(cast("block", "latest", "--json"))["timestamp"], 16)


def create(contract, *args):
    out = run("forge", "create", contract, "--rpc-url", RPC, "--private-key", KEYS[0], "--broadcast", "--json",
              *(["--constructor-args", *args] if args else []))
    return data(out)["deployedTo"]


def keccak(hexdata):
    return run("cast", "keccak", hexdata)


def abi_encode(types, *values):
    return run("cast", "abi-encode", f"f({types})", *[str(v) for v in values])


def word(x):
    return "0x" + format(x, "064x")


def mapping(key_type, key, slot_word):
    return keccak(abi_encode(f"{key_type},bytes32", key, slot_word))


def nodes(proof):
    out = bytes([len(proof)])
    for n in proof:
        b = bytes.fromhex(n[2:])
        out += len(b).to_bytes(4, "little") + b
    return out


def prove(hub, block, slots):
    """The vault's proof of `slots`: the account proof, then each slot's proof, each a node list."""
    p = data(cast("proof", hub, *slots, "--block", str(block)))
    encoded = nodes(p["accountProof"])
    values = []
    for slot, sp in zip(slots, p["storageProof"]):
        assert int(sp["key"], 16) == int(slot, 16)
        encoded += nodes(sp["proof"])
        values.append(word(int(sp["value"], 16)))
    return {"slots": slots, "values": values, "proof": "0x" + encoded.hex()}


def claim_slots(holder, component, xlm_token):
    h = holder.lower()
    components = int(keccak(word(0)), 16)
    return [
        mapping("address", h, HUB_SHARES),
        word(components + component),
        keccak(abi_encode("address,bytes32", xlm_token, mapping("address", h, word(11)))),
        keccak(abi_encode("uint256,bytes32", XLM_CHAIN, mapping("address", h, word(59)))),
        word(0),
    ]


def claim_digest(index, holder, recipient):
    # The domain's chainId is Ethereum's, where the holder's wallet is; the vault's id is the salt (B1-06).
    domain = keccak(abi_encode("bytes32,bytes32,bytes32,uint256,bytes32",
                               keccak("0x" + b"EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)"
                                      .hex()),
                               keccak("0x" + b"Xindex vault".hex()), keccak("0x31"), CHAIN, XLM_VAULT))
    claim = keccak(abi_encode("bytes32,address,address,bytes32",
                              keccak("0x" + b"SnapshotClaim(address index,address holder,bytes32 recipient)".hex()),
                              index, holder, recipient))
    return keccak("0x1901" + domain[2:] + claim[2:])


def main():
    anvil = subprocess.Popen(["anvil", "--port", "8577", "--chain-id", str(CHAIN), "--timestamp", str(START),
                              "--code-size-limit", "50000", "--silent"])
    try:
        time.sleep(2)
        build(*[address_of(k) for k in KEYS])
    finally:
        anvil.terminate()


def build(deployer, holder_a, holder_b):
    for holder in (holder_a, holder_b):
        cast("send", "--private-key", KEYS[0], holder, "--value", "1ether")
    # The extension, the module and the template, each built for the factory deployed after them.
    nonce = int(cast("nonce", deployer))
    factory_at = run("cast", "compute-address", deployer, "--nonce", str(nonce + 3)).split()[-1]
    extension = create("src/hybrid/HybridHubExtension.sol:HybridHubExtension", factory_at)
    module = create("src/hybrid/HybridHubModule.sol:HybridHubModule", factory_at, extension)
    template = create("src/HybridHub.sol:HybridHub", factory_at, module)
    factory = create("src/HybridIndexFactory.sol:HybridIndexFactory", deployer, deployer, template)
    assert factory.lower() == factory_at.lower()
    verifier = create("test/mocks/MockStateVerifier.sol:MockStateVerifier")
    weth = create("test/mocks/MockERC20.sol:MockERC20", "Wrapped Ether", "WETH", "18")

    send(KEYS[0], factory, "proposeChain(uint256,bytes32,address)", str(XLM_CHAIN), XLM_VAULT, verifier)
    send(KEYS[0], factory, "proposeListing(address,uint256)", weth, str(ETH_SUPPLY))
    warp(LISTING_DELAY + 1)
    send(KEYS[0], factory, "executeChain(uint256)", str(XLM_CHAIN))
    send(KEYS[0], factory, "executeListing(address)", weth)
    send(KEYS[0], factory, "proposeVaultListing(uint256,bytes32,uint256)", str(XLM_CHAIN), word(0), str(XLM_SUPPLY))
    xlm = call(factory, "vaultTokenId(uint256,bytes32)(address)", str(XLM_CHAIN), word(0))
    warp(LISTING_DELAY + 1)
    send(KEYS[0], factory, "executeListing(address)", xlm)

    tokens = f"[{weth},{xlm}]"
    hub = call(factory, "createIndex(string,string,address[],uint256)(address)", "Fixture", "FIX", tokens, str(K),
               sender=deployer)
    send(KEYS[0], factory, "createIndex(string,string,address[],uint256)", "Fixture", "FIX", tokens, str(K))
    salt = call(factory, "indexSalt(address)(bytes32)", hub)

    def order(shares):
        weth_in, xlm_in = [int(x.split()[0]) for x in
                           call(hub, "previewOrder(uint256)(uint256[])", str(shares)).strip("[]").split(", ")]
        send(KEYS[0], weth, "mint(address,uint256)", deployer, str(weth_in))
        send(KEYS[0], weth, "approve(address,uint256)", hub, str(weth_in))
        deadline = now() + 3600
        out = call(hub, "openOrder(uint256,uint256)(uint256,uint256)", str(shares), str(deadline), sender=deployer)
        order_id, intake = [int(x.split()[0]) for x in out.splitlines()]
        send(KEYS[0], hub, "openOrder(uint256,uint256)", str(shares), str(deadline))
        return order_id, intake, deadline, xlm_in

    # The seed: ten shares, settled on the state verifier's word that the XLM intake holds what it needs.
    order_id, intake, deadline, xlm_in = order(10 * 10**18)
    warp(3601)
    digest = keccak(abi_encode("bytes32,uint256,bytes32,address,uint256,uint8,address[],uint256[]",
                               INTAKE_DIGEST_DOMAIN, XLM_CHAIN, XLM_VAULT, hub, intake, 1,
                               "[0x0000000000000000000000000000000000000000]", f"[{xlm_in}]"))
    proof = abi_encode("uint256,bool,bytes32", deadline + 1, "true", digest)
    send(KEYS[0], hub, "settleOrder(uint256,(bytes,address[],uint256[])[])", str(order_id),
         f"[({proof},[0x0000000000000000000000000000000000000000],[{xlm_in}])]")
    warp(MINT_LOCK + 1)
    send(KEYS[0], hub, "claimOrder(uint256)", str(order_id))

    # Holder A: four shares, and a claim of XLM; holder B: three shares and a recovery key on Stellar.
    recipient_a = keccak("0x" + b"recipient A".hex())
    recipient_b = keccak("0x" + b"recipient B".hex())
    burn_recipient = keccak("0x" + b"burn recipient".hex())
    send(KEYS[0], hub, "transfer(address,uint256)", holder_a, str(4 * 10**18))
    send(KEYS[0], hub, "transfer(address,uint256)", holder_b, str(3 * 10**18))
    send(KEYS[2], hub, "setRecoveryAddress(uint256,bytes32)", str(XLM_CHAIN), recipient_b)
    send(KEYS[0], hub, "redeem(uint256,address,bytes32[],uint256)", str(10**18), holder_a, f"[{word(0)}]", "0")
    # A burn to a Stellar account, marked sent: its message is the one in this transaction's logs.
    receipt = data(run("cast", "send", "--private-key", KEYS[0], hub, "redeem(uint256,address,bytes32[],uint256)",
                             str(10**18), deployer, f"[{burn_recipient}]", "0", "--rpc-url", RPC, "--json"))
    topic = keccak("0x" + b"VaultMessage(bytes32,bytes)".hex())
    log = next(entry for entry in receipt["logs"] if entry["topics"][0] == topic)
    burn_id = log["topics"][1]
    burn_payload = "0x" + run("cast", "abi-decode", "--input", "f(bytes)", log["data"])[2:]
    assert keccak(burn_payload) == burn_id
    # The same burn under a nonce the index never used: a message it never sent, whose mark the state proves absent.
    nonce_at = 2 + 6 * 64  # the nonce is the payload's seventh word
    unsent_payload = burn_payload[:nonce_at] + format(10**6, "064x") + burn_payload[nonce_at + 64:]
    unsent_id = keccak(unsent_payload)

    # A second version of the index, which its creator seeds by migrating its last share: a MIGRATE of XLM, marked sent.
    v2 = call(factory, "createIndex(string,string,address[],uint256)(address)", "Fixture 2", "FIX2", tokens, str(K),
              sender=deployer)
    send(KEYS[0], factory, "createIndex(string,string,address[],uint256)", "Fixture 2", "FIX2", tokens, str(K))
    v2_salt = call(factory, "indexSalt(address)(bytes32)", v2)
    receipt = data(run("cast", "send", "--private-key", KEYS[0], hub,
                       "migrate(address,uint256,uint256,address,bytes32[])", v2, str(10**18), str(10**18), deployer,
                       f"[{word(0)}]", "--rpc-url", RPC, "--json"))
    log = next(entry for entry in receipt["logs"] if entry["topics"][0] == topic)
    migrate_id = log["topics"][1]
    migrate_payload = "0x" + run("cast", "abi-decode", "--input", "f(bytes)", log["data"])[2:]

    # A second order, never settled: its intake is open at the snapshot.
    _, open_intake, open_deadline, open_xlm = order(10**18)

    # Storage past the components array's end, filled as if a component: XLM at a far larger unit count, as storage a
    # holder may be able to fill (VLT-1).
    past = 7
    cast("rpc", "anvil_setStorageAt", hub, word(int(keccak(word(0)), 16) + past),
         word((10**12 << 160) | int(xlm, 16)))
    cast("rpc", "evm_mine")

    block = data(cast("block", "latest", "--json"))
    number = int(block["number"], 16)
    fixture = {
        "source_chain_id": CHAIN,
        "chain_id": XLM_CHAIN,
        "vault": XLM_VAULT,
        "factory": factory,
        "hub_implementation": template,
        "index": hub,
        "salt": salt,
        "xlm_token": xlm,
        "block": number,
        "timestamp": int(block["timestamp"], 16),
        "state_root": block["stateRoot"],
        "settled_intake": {"id": word(intake), "deadline": deadline, "amount": xlm_in,
                           "proof": prove(hub, number, [mapping("uint256", intake, word(60))])},
        "open_intake": {"id": word(open_intake), "deadline": open_deadline, "amount": open_xlm,
                        "proof": prove(hub, number, [mapping("uint256", open_intake, word(60))])},
        "burn": {"payload": burn_payload, "id": burn_id, "recipient": burn_recipient,
                 "proof": prove(hub, number, [mapping("bytes32", burn_id, word(62))])},
        "migrate": {"payload": migrate_payload, "id": migrate_id, "new_index": v2, "new_salt": v2_salt,
                    "proof": prove(hub, number, [mapping("bytes32", migrate_id, word(62))])},
        "unsent_burn": {"payload": unsent_payload, "id": unsent_id,
                        "proof": prove(hub, number, [mapping("bytes32", unsent_id, word(62))])},
        # An account the state does not hold: its storage reads zero.
        "absent_account": {"address": "0x000000000000000000000000000000000000dEaD",
                           "proof": prove("0x000000000000000000000000000000000000dEaD", number, [word(0)])},
        "holder_a": {"address": holder_a, "recipient": recipient_a,
                     "digest": claim_digest(hub, holder_a, recipient_a),
                     "signature": run("cast", "wallet", "sign", "--no-hash", "--private-key", KEYS[1],
                                      claim_digest(hub, holder_a, recipient_a)),
                     "claims": [prove(hub, number, claim_slots(holder_a, c, xlm)) for c in range(3)],
                     "past_the_end": prove(hub, number, claim_slots(holder_a, past, xlm))},
        "holder_b": {"address": holder_b, "recipient": recipient_b,
                     "claims": [prove(hub, number, claim_slots(holder_b, c, xlm)) for c in range(3)]},
    }
    with open(OUT, "w") as f:
        json.dump(fixture, f, indent=1)
        f.write("\n")
    print(f"wrote {OUT}: block {number}, state root {block['stateRoot']}")


if __name__ == "__main__":
    sys.exit(main())
