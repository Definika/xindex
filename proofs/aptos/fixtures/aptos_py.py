"""Aptos's encodings, written from aptos-core (aptos-node v1.49.2) for the fixture generator: an implementation separate
from the Rust statement, so the two check each other.

- BCS: little-endian integers, ULEB128 lengths, `Option` as a 0/1 tag, an enum as its ULEB128 variant index.
- Hashing (`aptos-crypto`'s `CryptoHasher`): `sha3_256(seed ++ bcs(value))`, the seed `sha3_256(b"APTOS::" ++ name)`,
  `name` the type's serde name (`LedgerInfo`, `TransactionInfo`, `ContractEvent`, ...). A ledger info is signed over
  `seed ++ bcs(ledger_info)` with BLS12-381 min-pk and the `..._POP_` tag.
- The accumulators (`aptos-types`' `proof`): an internal node is `sha3_256(seed ++ left ++ right)` under
  `TransactionAccumulator` or `EventAccumulator`, an empty subtree the literal `ACCUMULATOR_PLACEHOLDER_HASH`.
"""

import hashlib

PLACEHOLDER = b"ACCUMULATOR_PLACEHOLDER_HASH".ljust(32, b"\x00")


def sha3(*parts):
    h = hashlib.sha3_256()
    for p in parts:
        h.update(p)
    return h.digest()


def seed(name):
    return sha3(b"APTOS::" + name.encode())


LEDGER_INFO = seed("LedgerInfo")
TRANSACTION_INFO = seed("TransactionInfo")
CONTRACT_EVENT = seed("ContractEvent")
TRANSACTION = seed("Transaction")
WRITE_SET = seed("WriteSet")
TXN_ACCUMULATOR = seed("TransactionAccumulator")
EVENT_ACCUMULATOR = seed("EventAccumulator")


# ---------------------------------------------------------------------------
# BCS
# ---------------------------------------------------------------------------


def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def u64(n):
    return n.to_bytes(8, "little")


def u32(n):
    return n.to_bytes(4, "little")


def bytes_(b):
    return uleb(len(b)) + bytes(b)


def option(x, f=lambda v: v):
    return b"\x00" if x is None else b"\x01" + f(x)


class Reader:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def take(self, n):
        assert self.p + n <= len(self.d), "short"
        out = self.d[self.p:self.p + n]
        self.p += n
        return out

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return int.from_bytes(self.take(2), "little")

    def u32(self):
        return int.from_bytes(self.take(4), "little")

    def u64(self):
        return int.from_bytes(self.take(8), "little")

    def uleb(self):
        n, shift = 0, 0
        while True:
            b = self.u8()
            n |= (b & 0x7F) << shift
            if not b & 0x80:
                return n
            shift += 7
            assert shift < 64, "uleb"

    def bytes(self):
        return self.take(self.uleb())

    def hash(self):
        return self.take(32)

    def option(self, f):
        tag = self.u8()
        assert tag in (0, 1), "option tag"
        return f() if tag else None

    def vec(self, f):
        return [f() for _ in range(self.uleb())]

    def done(self):
        return self.p == len(self.d)


# ---------------------------------------------------------------------------
# ledger infos (`types/src/ledger_info.rs`, `block_info.rs`, `validator_verifier.rs`, `aggregate_signature.rs`)
# ---------------------------------------------------------------------------


def read_validators(r):
    return r.vec(lambda: {"address": r.hash(), "public_key": r.bytes(), "voting_power": r.u64()})


def write_validators(vals):
    out = uleb(len(vals))
    for v in vals:
        assert len(v["address"]) == 32 and len(v["public_key"]) == 48
        out += v["address"] + bytes_(v["public_key"]) + u64(v["voting_power"])
    return out


def read_ledger_info(r):
    li = {
        "epoch": r.u64(),
        "round": r.u64(),
        "id": r.hash(),
        "executed_state_id": r.hash(),
        "version": r.u64(),
        "timestamp_usecs": r.u64(),
    }
    li["next_epoch_state"] = r.option(lambda: {"epoch": r.u64(), "validators": read_validators(r)})
    li["consensus_data_hash"] = r.hash()
    return li


def write_ledger_info(li):
    nxt = li["next_epoch_state"]
    return (
        u64(li["epoch"]) + u64(li["round"]) + li["id"] + li["executed_state_id"] + u64(li["version"])
        + u64(li["timestamp_usecs"])
        + option(nxt, lambda s: u64(s["epoch"]) + write_validators(s["validators"]))
        + li["consensus_data_hash"]
    )


def read_signed(r):
    """`LedgerInfoWithSignatures::V0`: the ledger info, the signers' `BitVec` and the aggregate signature."""
    assert r.u8() == 0, "LedgerInfoWithSignatures::V0"
    li = read_ledger_info(r)
    bitmask = r.bytes()
    sig = r.option(r.bytes)
    assert sig is None or len(sig) == 96
    return {"ledger_info": li, "bitmask": bitmask, "signature": sig}


def write_signed(s):
    return b"\x00" + write_ledger_info(s["ledger_info"]) + bytes_(s["bitmask"]) + option(s["signature"], bytes_)


def signing_message(li):
    return LEDGER_INFO + write_ledger_info(li)


def set_hash(validators, keccak):
    """The verifier's name for a validator set: keccak256 of its BCS, `ValidatorVerifier`'s."""
    return keccak(write_validators(validators))


def signers(bitmask, n):
    """Aptos's `BitVec`: bit `i` is `0x80 >> (i % 8)` of byte `i / 8`; exactly `ceil(n / 8)` bytes, no bit past `n`."""
    assert len(bitmask) == (n + 7) // 8, "bitmask length"
    out = [i for i in range(len(bitmask) * 8) if bitmask[i // 8] & (0x80 >> (i % 8))]
    assert all(i < n for i in out), "bit past the set"
    return out


def quorum(validators, idx):
    """`ValidatorVerifier`: the signers' power must reach `total * 2 / 3 + 1`."""
    total = sum(v["voting_power"] for v in validators)
    power = sum(validators[i]["voting_power"] for i in idx)
    return power, total, power >= total * 2 // 3 + 1


# ---------------------------------------------------------------------------
# transaction infos and events (`types/src/transaction/mod.rs`, `contract_event.rs`)
# ---------------------------------------------------------------------------


def read_status(r):
    tag = r.uleb()
    if tag in (0, 1):  # Success, OutOfGas
        return tag
    if tag == 2:  # MoveAbort { location, code, info }
        read_location(r)
        r.u64()
        r.option(lambda: (r.bytes(), r.bytes()))
        return tag
    if tag == 3:  # ExecutionFailure { location, function, code_offset }
        read_location(r)
        r.u16()
        r.u16()
        return tag
    if tag == 4:  # MiscellaneousError(Option<StatusCode>), a StatusCode is a u64
        r.option(r.u64)
        return tag
    raise AssertionError("status")


def read_location(r):
    tag = r.uleb()
    if tag == 0:  # AbortLocation::Module(ModuleId { address, name })
        r.hash()
        r.bytes()
    else:
        assert tag == 1, "location"  # Script


def read_info(r):
    """`TransactionInfo` V0 or V1, with its BCS."""
    start = r.p
    variant = r.uleb()
    assert variant in (0, 1), "TransactionInfo variant"
    info = {"variant": variant, "gas_used": r.u64()}
    sstart = r.p
    info["status"] = read_status(r)
    info["status_bcs"] = r.d[sstart:r.p]
    info["transaction_hash"] = r.hash()
    info["event_root_hash"] = r.hash()
    info["state_change_hash"] = r.hash()
    info["state_checkpoint_hash"] = r.option(r.hash)
    if variant == 1:
        info["hot_state_checkpoint_hash"] = r.option(r.hash)
    info["auxiliary_info_hash"] = r.option(r.hash)
    if variant == 1:
        info["position_state_checkpoint_hash"] = r.option(r.hash)
        info["placeholders"] = [r.option(r.hash) for _ in range(7)]
    info["bcs"] = r.d[start:r.p]
    return info


def write_info(info, event_root):
    """A successful `TransactionInfo`, as the statement writes it: the status is `Success` and the event root is the
    events' own."""
    out = uleb(info["variant"]) + u64(info["gas_used"]) + b"\x00" + info["transaction_hash"] + event_root
    out += info["state_change_hash"] + option(info["state_checkpoint_hash"])
    if info["variant"] == 1:
        out += option(info["hot_state_checkpoint_hash"])
    out += option(info["auxiliary_info_hash"])
    if info["variant"] == 1:
        out += option(info["position_state_checkpoint_hash"])
        out += b"".join(option(p) for p in info["placeholders"])
    return out


def info_hash(info_bcs):
    return sha3(TRANSACTION_INFO, info_bcs)


def read_type_tag(r):
    tag = r.uleb()
    if tag in (0, 1, 2, 3, 4, 5, 8, 9, 10):
        return
    if tag == 6:  # Vector
        read_type_tag(r)
        return
    if tag == 7:  # Struct { address, module, name, type_args }
        r.hash()
        r.bytes()
        r.bytes()
        r.vec(lambda: read_type_tag(r))
        return
    raise AssertionError("type tag %d" % tag)


def read_event(r):
    """A `ContractEvent`'s BCS, its variant, and the span of its type tag and data."""
    start = r.p
    variant = r.uleb()
    assert variant in (0, 1), "ContractEvent variant"
    if variant == 0:  # V1 { key: EventKey { creation_number, account_address }, sequence_number, type_tag, data }
        r.u64()
        r.hash()
        r.u64()
    tstart = r.p
    read_type_tag(r)
    type_tag = r.d[tstart:r.p]
    data = r.bytes()
    return {"variant": variant, "type_tag": type_tag, "data": data, "bcs": r.d[start:r.p]}


def struct_tag(address, module, name):
    """A `TypeTag::Struct` with no type arguments."""
    return b"\x07" + address + bytes_(module.encode()) + bytes_(name.encode()) + b"\x00"


def event_v2(type_tag, data):
    return b"\x01" + type_tag + bytes_(data)


def event_hash(event_bcs):
    return sha3(CONTRACT_EVENT, event_bcs)


# ---------------------------------------------------------------------------
# accumulators (`types/src/proof/`, `accumulator`)
# ---------------------------------------------------------------------------


def node(seed_, left, right):
    return sha3(seed_, left, right)


def accumulator_root(seed_, leaves):
    """`InMemoryAccumulator::from_leaves(..).root_hash()`: an empty subtree is the placeholder, one leaf is the root."""
    if not leaves:
        return PLACEHOLDER
    level = list(leaves)
    while len(level) > 1:
        if len(level) % 2:
            level.append(PLACEHOLDER)
        level = [node(seed_, level[i], level[i + 1]) for i in range(0, len(level), 2)]
    return level[0]


def climb(seed_, leaf, index, siblings):
    """`AccumulatorProof::verify`'s fold: siblings from the bottom level up."""
    h = leaf
    for s in siblings:
        h = node(seed_, h, s) if index % 2 == 0 else node(seed_, s, h)
        index //= 2
    return h


def range_to_leaf(seed_, first, leaves, left, right, target):
    """`AccumulatorRangeProof::verify` over `leaves` from index `first`, and the single-leaf proof of index `target`
    read off the same reduction: the root and the target's siblings, bottom up."""
    left, right = list(left), list(right)
    hashes, pos, t = list(leaves), first, target
    assert first <= target < first + len(leaves)
    siblings = []
    while len(hashes) > 1 or left or right:
        if pos % 2:
            hashes = [left.pop(0)] + hashes
            pos -= 1
        if len(hashes) % 2:
            hashes = hashes + [right.pop(0)]
        siblings.append(hashes[(t ^ 1) - pos])
        hashes = [node(seed_, hashes[i], hashes[i + 1]) for i in range(0, len(hashes), 2)]
        pos //= 2
        t //= 2
    return hashes[0], siblings
