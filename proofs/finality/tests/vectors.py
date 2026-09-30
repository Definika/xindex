"""Independent test vectors for xindex-finality, from the consensus specs' own SSZ library (remerkleable) and py_ecc.

Run: pip install remerkleable py_ecc; python vectors.py. It prints the constants `vectors.rs` pins. Nothing here shares
code with the Rust being tested.
"""
from remerkleable.basic import uint64, boolean
from remerkleable.byte_arrays import Bytes32, Bytes48, Bytes4
from remerkleable.complex import Container, List
from py_ecc.bls import G2ProofOfPossession as bls


class Validator(Container):
    pubkey: Bytes48
    withdrawal_credentials: Bytes32
    effective_balance: uint64
    slashed: boolean
    activation_eligibility_epoch: uint64
    activation_epoch: uint64
    exit_epoch: uint64
    withdrawable_epoch: uint64


class Checkpoint(Container):
    epoch: uint64
    root: Bytes32


class AttestationData(Container):
    slot: uint64
    index: uint64
    beacon_block_root: Bytes32
    source: Checkpoint
    target: Checkpoint


class BeaconBlockHeader(Container):
    slot: uint64
    proposer_index: uint64
    parent_root: Bytes32
    state_root: Bytes32
    body_root: Bytes32


class ForkData(Container):
    current_version: Bytes4
    genesis_validators_root: Bytes32


class SigningData(Container):
    object_root: Bytes32
    domain: Bytes32


FAR = 2**64 - 1
GVR = bytes.fromhex("4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95")

keys = [bls.SkToPk(sk) for sk in (1, 2, 3)]
validators = [
    Validator(pubkey=keys[0], withdrawal_credentials=b"\x01" + b"\x00" * 11 + b"\x11" * 20,
              effective_balance=32_000_000_000, slashed=False, activation_eligibility_epoch=0,
              activation_epoch=0, exit_epoch=FAR, withdrawable_epoch=FAR),
    Validator(pubkey=keys[1], withdrawal_credentials=b"\x02" + b"\x00" * 11 + b"\x22" * 20,
              effective_balance=2_048_000_000_000, slashed=True, activation_eligibility_epoch=5,
              activation_epoch=9, exit_epoch=400_000, withdrawable_epoch=400_256),
    Validator(pubkey=keys[2], withdrawal_credentials=b"\x00" * 32,
              effective_balance=31_000_000_000, slashed=False, activation_eligibility_epoch=FAR,
              activation_epoch=FAR, exit_epoch=FAR, withdrawable_epoch=FAR),
]
Registry = List[Validator, 2**40]

data = AttestationData(slot=13_164_577, index=0, beacon_block_root=b"\xaa" * 32,
                       source=Checkpoint(epoch=411_392, root=b"\xbb" * 32),
                       target=Checkpoint(epoch=411_393, root=b"\xcc" * 32))
header = BeaconBlockHeader(slot=13_164_544, proposer_index=123_456, parent_root=b"\x01" * 32,
                           state_root=b"\x02" * 32, body_root=b"\x03" * 32)
fork_data_root = ForkData(current_version=bytes([6, 0, 0, 0]), genesis_validators_root=GVR).hash_tree_root()
domain = bytes([1, 0, 0, 0]) + bytes(fork_data_root)[:28]
signing_root = SigningData(object_root=data.hash_tree_root(), domain=domain).hash_tree_root()
signature = bls.Aggregate([bls.Sign(sk, bytes(signing_root)) for sk in (1, 2, 3)])

print("validator[1]", validators[1].hash_tree_root().hex())
print("registry    ", Registry(*validators).hash_tree_root().hex())
print("data        ", data.hash_tree_root().hex())
print("header      ", header.hash_tree_root().hex())
print("domain      ", domain.hex())
print("signing     ", bytes(signing_root).hex())
print("keys        ", [k.hex() for k in keys])
print("signature   ", signature.hex())
assert bls.FastAggregateVerify(keys, bytes(signing_root), signature)
