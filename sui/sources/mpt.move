/// A Merkle-Patricia walk, as `MerklePatricia.sol` and `crates/xindex-core/src/mpt.rs` walk a block's receipts trie or
/// an account's state and storage: every node is authenticated by its hash from the root down, or embedded in an
/// authenticated parent, so the value found is the one the root commits to; a proof that the key is absent returns
/// none. Nodes lie where they are in the proof's bytes (`Span`s), and the value found is an item of those bytes.
module xindex_vault::mpt;

use sui::hash::keccak256;
use xindex_vault::bytes;
use xindex_vault::rlp::{Self, Item};

/// The proof does not prove the key: a node missing or not the one its parent names, or malformed.
const EBadProof: u64 = 111;

const BRANCH_ITEMS: u64 = 17;
const SHORT_NODE_ITEMS: u64 = 2;
const LEAF_EVEN: u8 = 2;
const LEAF_ODD: u8 = 3;

/// A node's place in the proof's bytes.
public struct Span has copy, drop {
    start: u64,
    len: u64,
}

/// The leaf value stored under the key whose first `key_nibbles` nibbles are `key`'s, if the proof shows one, as an
/// item of `buf`. In a receipts trie, and among a state or storage trie's 64-nibble keys, no key is a prefix of another,
/// so a value is only ever a leaf's. A proof that the key is absent, an empty branch child or a short node whose path
/// parts from the key's, returns none.
public fun get(
    buf: &vector<u8>,
    nodes: &vector<Span>,
    root: &vector<u8>,
    key: &vector<u8>,
    key_nibbles: u64,
): Option<Item> {
    assert!(key_nibbles <= 2 * key.length(), EBadProof);
    let mut expected = *root;
    let mut embedded: Option<Item> = option::none();
    let mut next = 0;
    let mut nibble = 0;
    loop {
        let node = if (embedded.is_some()) {
            embedded.extract()
        } else {
            assert!(next < nodes.length(), EBadProof);
            let s = nodes[next];
            assert!(keccak256(&bytes::slice(buf, s.start, s.len)) == expected, EBadProof);
            next = next + 1;
            rlp::to_item(buf, s.start, s.len)
        };
        let items = rlp::count(buf, &node);
        let child = if (items == BRANCH_ITEMS) {
            assert!(nibble < key_nibbles, EBadProof);
            let child = rlp::at(buf, &node, (nibble_at(key, nibble) as u64));
            nibble = nibble + 1;
            if (rlp::is_empty_string(&child)) return option::none();
            child
        } else if (items == SHORT_NODE_ITEMS) {
            let (length, is_leaf, matches) = match_path(buf, &rlp::at(buf, &node, 0), key, nibble, key_nibbles);
            if (!matches) return option::none();
            nibble = nibble + length;
            if (is_leaf) {
                assert!(nibble == key_nibbles, EBadProof);
                return option::some(rlp::at(buf, &node, 1))
            };
            rlp::at(buf, &node, 1)
        } else {
            abort EBadProof
        };
        // A child is embedded when it is a list, else named by its 32-byte hash.
        if (rlp::is_list(&child)) {
            embedded.fill(child);
        } else {
            expected = rlp::bytes32(buf, &child);
        }
    }
}

/// Decodes a hex-prefix path and compares it with `key` from nibble `offset`: its length in nibbles, whether it ends
/// in a leaf, and whether it matches. The first nibble is a flag: 0 or 1 an extension, 2 or 3 a leaf, odd when the path
/// has an odd number of nibbles, whose first then shares the flag's byte; an even path pads that byte with zero.
fun match_path(buf: &vector<u8>, path: &Item, key: &vector<u8>, offset: u64, key_nibbles: u64): (u64, bool, bool) {
    assert!(!rlp::is_list(path) && rlp::len(path) > 0, EBadProof);
    let at = rlp::start(path);
    let first = buf[at];
    let flag = first >> 4;
    assert!(flag <= LEAF_ODD, EBadProof);
    let is_leaf = flag >= LEAF_EVEN;
    let odd = flag & 1 == 1;
    assert!(odd || first & 0x0f == 0, EBadProof);
    let rest = rlp::len(path) - 1;
    let length = 2 * rest + if (odd) { 1 } else { 0 };
    if (offset + length > key_nibbles) return (length, is_leaf, false);
    let mut i = 0;
    while (i < length) {
        let p = if (odd) {
            if (i == 0) { first & 0x0f } else { nibble_in(buf, at + 1, i - 1) }
        } else {
            nibble_in(buf, at + 1, i)
        };
        if (p != nibble_at(key, offset + i)) return (length, is_leaf, false);
        i = i + 1;
    };
    (length, is_leaf, true)
}

fun nibble_at(v: &vector<u8>, i: u64): u8 {
    nibble_in(v, 0, i)
}

fun nibble_in(v: &vector<u8>, start: u64, i: u64): u8 {
    let b = v[start + i / 2];
    if (i % 2 == 0) { b >> 4 } else { b & 0x0f }
}

/// A receipt's key in its block's trie, `rlp(txIndex)`, and its length in nibbles; none past 65,535.
public fun receipt_key(tx_index: u64): (vector<u8>, u64) {
    if (tx_index == 0) return (vector[0x80], 2);
    if (tx_index < 0x80) return (vector[(tx_index as u8)], 2);
    if (tx_index < 0x100) return (vector[0x81, (tx_index as u8)], 4);
    assert!(tx_index < 0x10000, EBadProof);
    (vector[0x82, ((tx_index >> 8) as u8), ((tx_index & 0xff) as u8)], 6)
}

/// One node list at `at` of `buf`: `count (u8) ++ (length (u32, little-endian) ++ node) * count`, and where it ends.
public fun read_nodes(buf: &vector<u8>, at: u64): (vector<Span>, u64) {
    assert!(at < buf.length(), EBadProof);
    let count = buf[at] as u64;
    let mut at = at + 1;
    let mut nodes = vector[];
    let mut i = 0;
    while (i < count) {
        assert!(at <= buf.length() && 4 <= buf.length() - at, EBadProof);
        let len = bytes::le_at(buf, at, 4);
        at = at + 4;
        assert!(len <= buf.length() - at, EBadProof);
        nodes.push_back(Span { start: at, len });
        at = at + len;
        i = i + 1;
    };
    (nodes, at)
}

#[test_only]
public fun test_match_path(encoded: vector<u8>, key: vector<u8>, offset: u64, key_nibbles: u64): (u64, bool, bool) {
    // The path as an RLP string of `encoded`.
    let mut buf = vector[(0x80 + encoded.length() as u8)];
    buf.append(encoded);
    let item = rlp::to_item(&buf, 0, buf.length());
    match_path(&buf, &item, &key, offset, key_nibbles)
}
