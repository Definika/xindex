"""VeChainThor's encodings, written from vechain/thor for the fixture generator: an implementation separate from the Rust
statement, so the two check each other.

- RLP, as go-ethereum's `rlp` writes it.
- blake2b-256 (`thor.Blake2b`), the hash of every header, trie node and block id.
- A header (`block/header.go`): its RLP body is `[parentID, timestamp, gasLimit, beneficiary, gasUsed, totalScore,
  txsRootFeatures, stateRoot, receiptsRoot, signature, extension]`; its signing hash is blake2b of the RLP list of the
  same fields without the signature, the extension `[alpha, com, baseFee]` included once a base fee is set; its id is
  `number (4 bytes) ++ blake2b(signingHash ++ signer)[4:]`, its number its parent's plus one.
- The transactions and receipts tries (`trie.DeriveRoot`): an Ethereum Merkle-Patricia trie keyed by `rlp(index)`,
  hashed with blake2b, the root always hashed.
"""

import hashlib

from keccak import keccak  # noqa: F401  (re-exported for the generator)


def blake2b(*parts):
    h = hashlib.blake2b(digest_size=32)
    for p in parts:
        h.update(p)
    return h.digest()


# ---------------------------------------------------------------------------
# RLP
# ---------------------------------------------------------------------------


def _length(n, offset):
    if n < 56:
        return bytes([offset + n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(b)]) + b


def enc(x):
    """RLP: bytes are a string, a list a list, an int its minimal big-endian bytes (zero is empty)."""
    if isinstance(x, list):
        body = b"".join(enc(i) for i in x)
        return _length(len(body), 0xC0) + body
    if isinstance(x, bool):
        return b"\x01" if x else b"\x80"
    if isinstance(x, int):
        assert x >= 0
        x = x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
    if len(x) == 1 and x[0] < 0x80:
        return bytes(x)
    return _length(len(x), 0x80) + bytes(x)


def raw(b):
    """An already-encoded item, written as given."""
    return _Raw(b)


class _Raw(bytes):
    pass


def enc_raw_aware(x):
    if isinstance(x, _Raw):
        return bytes(x)
    if isinstance(x, list):
        body = b"".join(enc_raw_aware(i) for i in x)
        return _length(len(body), 0xC0) + body
    return enc(x)


def dec(b):
    """Decodes one RLP item spanning all of `b`: bytes, or a list of items."""
    item, rest = _dec(b)
    assert rest == b"", "trailing bytes"
    return item


def _dec(b):
    p = b[0]
    if p < 0x80:
        return b[:1], b[1:]
    if p < 0xB8:
        n = p - 0x80
        return b[1:1 + n], b[1 + n:]
    if p < 0xC0:
        ll = p - 0xB7
        n = int.from_bytes(b[1:1 + ll], "big")
        return b[1 + ll:1 + ll + n], b[1 + ll + n:]
    if p < 0xF8:
        n = p - 0xC0
        body, rest = b[1:1 + n], b[1 + n:]
    else:
        ll = p - 0xF7
        n = int.from_bytes(b[1:1 + ll], "big")
        body, rest = b[1 + ll:1 + ll + n], b[1 + ll + n:]
    items = []
    while body:
        i, body = _dec(body)
        items.append(i)
    return items, rest


def dec_raw_items(b):
    """The raw encodings of a list's items."""
    p = b[0]
    assert p >= 0xC0
    if p < 0xF8:
        body = b[1:1 + p - 0xC0]
    else:
        ll = p - 0xF7
        n = int.from_bytes(b[1:1 + ll], "big")
        body = b[1 + ll:1 + ll + n]
    out = []
    while body:
        _, rest = _dec(body)
        out.append(body[:len(body) - len(rest)])
        body = rest
    return out


def uint(b):
    return int.from_bytes(b, "big")


# ---------------------------------------------------------------------------
# headers
# ---------------------------------------------------------------------------

HEADER_FIELDS = [
    "parentID", "timestamp", "gasLimit", "beneficiary", "gasUsed", "totalScore", "txsRoot", "txsFeatures", "stateRoot",
    "receiptsRoot", "signature", "alpha", "com", "baseFee",
]


def decode_header(raw_header):
    """A header's fields from its RLP (`/blocks/{id}?raw=true`)."""
    items = dec(raw_header)
    assert len(items) == 11, len(items)
    trf = items[6]
    if isinstance(trf, list):
        txs_root, features = trf[0], uint(trf[1])
    else:
        txs_root, features = trf, 0
    ext = items[10]
    assert isinstance(ext, list) and len(ext) == 3, "a header after Galactica carries alpha, COM and the base fee"
    h = {
        "parentID": items[0],
        "timestamp": uint(items[1]),
        "gasLimit": uint(items[2]),
        "beneficiary": items[3],
        "gasUsed": uint(items[4]),
        "totalScore": uint(items[5]),
        "txsRoot": txs_root,
        "txsFeatures": features,
        "stateRoot": items[7],
        "receiptsRoot": items[8],
        "signature": items[9],
        "alpha": ext[0],
        "com": ext[1] == b"\x01",
        "baseFee": uint(ext[2]),
    }
    assert ext[1] in (b"", b"\x01")
    assert encode_header(h) == raw_header, "the header must re-encode to its own bytes"
    return h


def _trf(h):
    return h["txsRoot"] if h["txsFeatures"] == 0 else [h["txsRoot"], h["txsFeatures"]]


def _signing_fields(h):
    return [
        h["parentID"], h["timestamp"], h["gasLimit"], h["beneficiary"], h["gasUsed"], h["totalScore"], _trf(h),
        h["stateRoot"], h["receiptsRoot"],
    ]


def encode_header(h):
    ext = [h["alpha"], h["com"], h["baseFee"]]
    return enc(_signing_fields(h) + [h["signature"], ext])


def signing_hash(h):
    return blake2b(enc(_signing_fields(h) + [[h["alpha"], h["com"], h["baseFee"]]]))


def number(h):
    return uint(h["parentID"][:4]) + 1


def block_id(h, signer):
    return number(h).to_bytes(4, "big") + blake2b(signing_hash(h), signer)[4:]


# ---------------------------------------------------------------------------
# tries
# ---------------------------------------------------------------------------


def index_key(i):
    return enc(i)


def _nibbles(b):
    out = []
    for x in b:
        out += [x >> 4, x & 15]
    return out


def _compact(nibs, leaf):
    flag = 2 if leaf else 0
    if len(nibs) % 2:
        first = bytes([((flag + 1) << 4) | nibs[0]])
        nibs = nibs[1:]
    else:
        first = bytes([flag << 4])
    return first + bytes((nibs[i] << 4) | nibs[i + 1] for i in range(0, len(nibs), 2))


def _build(items):
    """A node over `items`, a list of (nibbles, value) sharing the path so far: ('leaf', path, value),
    ('ext', path, child) or ('branch', [17 children])."""
    if not items:
        return None
    if len(items) == 1:
        return ("leaf", items[0][0], items[0][1])
    common = 0
    first = items[0][0]
    while all(len(k) > common and k[common] == first[common] for k, _ in items):
        common += 1
    if common:
        return ("ext", first[:common], _build([(k[common:], v) for k, v in items]))
    children = [None] * 17
    for n in range(16):
        sub = [(k[1:], v) for k, v in items if k and k[0] == n]
        children[n] = _build(sub)
    assert all(k for k, _ in items), "no key is a prefix of another"
    return ("branch", children)


def _encode_node(node):
    """The node's consensus encoding, its children referenced by hash or embedded when shorter than 32 bytes."""
    kind = node[0]
    if kind == "leaf":
        return enc_raw_aware([_compact(node[1], True), node[2]])
    if kind == "ext":
        return enc_raw_aware([_compact(node[1], False), _ref(node[2])])
    return enc_raw_aware([_ref(c) if c is not None else b"" for c in node[1][:16]] + [b""])


def _ref(node):
    e = _encode_node(node)
    return raw(e) if len(e) < 32 else blake2b(e)


def trie(values):
    """The root of `trie.DeriveRoot` over `values` (index i under `rlp(i)`), and a function giving index i's proof: the
    hashed nodes from the root to its leaf, in order."""
    items = [(_nibbles(index_key(i)), v) for i, v in enumerate(values)]
    root = _build(items)
    root_hash = blake2b(_encode_node(root))

    def proof(i):
        key = _nibbles(index_key(i))
        out = []
        node, hashed = root, True
        while True:
            e = _encode_node(node)
            if hashed:
                out.append(e)
            kind = node[0]
            if kind == "leaf":
                assert node[1] == key
                return out
            if kind == "ext":
                assert key[:len(node[1])] == node[1]
                key = key[len(node[1]):]
                node = node[2]
            else:
                node = node[1][key[0]]
                key = key[1:]
            hashed = len(_encode_node(node)) >= 32

    return root_hash, proof


EMPTY_ROOT = blake2b(enc(b""))


# ---------------------------------------------------------------------------
# transactions and receipts
# ---------------------------------------------------------------------------

LEGACY = 0x00
DYNAMIC_FEE = 0x51


def decode_tx(raw_tx):
    """A transaction's fields from its consensus encoding (`/transactions/{id}?raw=true`)."""
    if raw_tx[0] >= 0xC0:
        kind, body = LEGACY, raw_tx
    else:
        kind, body = raw_tx[0], raw_tx[1:]
        assert kind == DYNAMIC_FEE
    items = dec(body)
    raws = dec_raw_items(body)
    t = {"type": kind, "chainTag": uint(items[0]), "blockRef": uint(items[1]), "expiration": uint(items[2])}
    t["clauses"] = [{"to": c[0], "value": uint(c[1]), "data": c[2]} for c in items[3]]
    if kind == LEGACY:
        assert len(items) == 10
        t["gasPriceCoef"] = uint(items[4])
        rest = items[5:]
        rest_raw = raws[5:]
    else:
        assert len(items) == 11
        t["maxPriorityFeePerGas"] = uint(items[4])
        t["maxFeePerGas"] = uint(items[5])
        rest = items[6:]
        rest_raw = raws[6:]
    t["gas"] = uint(rest[0])
    t["dependsOn"] = rest[1] if rest[1] != b"" else None
    t["nonce"] = uint(rest[2])
    t["reserved"] = rest_raw[3]
    t["signature"] = rest[4]
    assert encode_tx(t) == raw_tx, "the transaction must re-encode to its own bytes"
    return t


def encode_tx(t):
    clauses = [[c["to"], c["value"], c["data"]] for c in t["clauses"]]
    head = [t["chainTag"], t["blockRef"], t["expiration"], clauses]
    if t["type"] == LEGACY:
        fees = [t["gasPriceCoef"]]
    else:
        fees = [t["maxPriorityFeePerGas"], t["maxFeePerGas"]]
    depends = t["dependsOn"] if t["dependsOn"] is not None else b""
    body = enc_raw_aware(head + fees + [t["gas"], depends, t["nonce"], raw(t["reserved"]), t["signature"]])
    return body if t["type"] == LEGACY else bytes([t["type"]]) + body


def encode_outputs(outputs):
    """A receipt's outputs, from the API's JSON: per clause, its events `[address, topics, data]` and its transfers
    `[sender, recipient, amount]`."""
    return enc([
        [
            [[h(e["address"]), [h(x) for x in e["topics"]], h(e["data"])] for e in o["events"]],
            [[h(x["sender"]), h(x["recipient"]), int(x["amount"], 16)] for x in o["transfers"]],
        ]
        for o in outputs
    ])


def encode_receipt(kind, gas_used, gas_payer, paid, reward, reverted, outputs_rlp):
    body = enc_raw_aware([gas_used, gas_payer, paid, reward, reverted, raw(outputs_rlp)])
    return body if kind == LEGACY else bytes([kind]) + body


def h(s):
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)
