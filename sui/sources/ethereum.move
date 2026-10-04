/// A vault message's log, shown in a block a P1 or P2 proof covered: the block's leaf at its place in the headers tree
/// the proof recorded, then the receipt under the block's receipts root, which must have succeeded, and the log in it.
/// As `FinalityVerifier.verifyEvent` checks it on an EVM chain, and `crates/xindex-core/src/event.rs` on the other
/// vault chains, whose proof format this reads byte for byte. A checkpoint is the same block's leaf alone.
module xindex_vault::ethereum;

use sui::hash::keccak256;
use xindex_vault::bytes;
use xindex_vault::mpt::{Self, Span};
use xindex_vault::rlp::{Self, Item};

/// The proof's bytes are not an event or checkpoint proof: short, or with bytes after it.
const EBadEventProof: u64 = 121;
/// The block lies outside the range its headers root covered.
const ENotInRange: u64 = 122;
/// The block's leaf is not at its place under the headers root.
const EBadHeaderPath: u64 = 123;
/// The receipts trie holds no receipt at the transaction's index.
const ENoReceipt: u64 = 124;
/// The receipt is malformed.
const EBadReceiptProof: u64 = 125;
/// The transaction failed.
const EFailedTransaction: u64 = 126;
/// The receipt holds no such log, or the log has fewer than two topics.
const ENoLog: u64 = 127;

/// A receipt's fields: (status, cumulativeGasUsed, logsBloom, logs).
const STATUS: u64 = 0;
const LOGS: u64 = 3;

/// A block covered by a proof: its leaf's fields, and the leaf's path to the headers root that proof recorded.
public struct Header has copy, drop {
    headers_root: vector<u8>,
    number: u64,
    timestamp: u64,
    state_root: vector<u8>,
    receipts_root: vector<u8>,
    path: vector<vector<u8>>,
}

/// A log: its emitter, its first two topics, and where its data lies in the proof.
public struct Log has copy, drop {
    emitter: vector<u8>,
    topic0: vector<u8>,
    topic1: vector<u8>,
    data: Item,
}

public fun headers_root(h: &Header): vector<u8> { h.headers_root }

public fun number(h: &Header): u64 { h.number }

public fun timestamp(h: &Header): u64 { h.timestamp }

public fun state_root(h: &Header): vector<u8> { h.state_root }

public fun receipts_root(h: &Header): vector<u8> { h.receipts_root }

public fun emitter(l: &Log): vector<u8> { l.emitter }

public fun topic0(l: &Log): vector<u8> { l.topic0 }

public fun topic1(l: &Log): vector<u8> { l.topic1 }

public fun data(l: &Log): Item { l.data }

/// Reads `headersRoot (32) ++ number (u64) ++ timestamp (u64) ++ stateRoot (32) ++ receiptsRoot (32) ++ path count
/// (u8) ++ path` at `at`, integers little-endian, and where it ends.
fun read_header(proof: &vector<u8>, at: u64): (Header, u64) {
    assert!(at <= proof.length() && 113 <= proof.length() - at, EBadEventProof);
    let headers_root = bytes::slice(proof, at, 32);
    let number = bytes::le_at(proof, at + 32, 8);
    let timestamp = bytes::le_at(proof, at + 40, 8);
    let state_root = bytes::slice(proof, at + 48, 32);
    let receipts_root = bytes::slice(proof, at + 80, 32);
    let depth = proof[at + 112] as u64;
    let mut at = at + 113;
    assert!(32 * depth <= proof.length() - at, EBadEventProof);
    let mut path = vector[];
    let mut i = 0;
    while (i < depth) {
        path.push_back(bytes::slice(proof, at, 32));
        at = at + 32;
        i = i + 1;
    };
    (Header { headers_root, number, timestamp, state_root, receipts_root, path }, at)
}

/// A checkpoint proof: an event proof's header part alone, which must be the whole of `proof`.
public fun parse_header(proof: &vector<u8>): Header {
    let (h, end) = read_header(proof, 0);
    assert!(end == proof.length(), EBadEventProof);
    h
}

/// An event proof: the header, then `node count (u8) ++ each node's length (u32) and bytes ++ txIndex (u32) ++ logIndex
/// (u32)`, which must be the whole of `proof`. A node's length is a u32 because a receipt has no size limit of its own:
/// a leaf past 64 KB is valid on Ethereum (LG-1).
public fun parse_event(proof: &vector<u8>): (Header, vector<Span>, u64, u64) {
    let (h, at) = read_header(proof, 0);
    assert!(at < proof.length(), EBadEventProof);
    let (nodes, at) = mpt::read_nodes(proof, at);
    assert!(at <= proof.length() && proof.length() - at == 8, EBadEventProof);
    let tx_index = bytes::le_at(proof, at, 4);
    let log_index = bytes::le_at(proof, at + 4, 4);
    (h, nodes, tx_index, log_index)
}

/// The header's leaf lies at its place in the tree a proof recorded over blocks `first` to `last`: `number - first`,
/// at a depth of `ceil(log2(last - first + 1))`, a zero standing in for an odd layer's missing sibling. The leaf is
/// `keccak256(abi.encode(uint256 number, uint256 timestamp, stateRoot, receiptsRoot))`.
public fun check_header(h: &Header, first: u64, last: u64) {
    assert!(h.number >= first && h.number <= last, ENotInRange);
    let size = ((last - first) as u128) + 1;
    let mut depth: u8 = 0;
    while ((1u128 << depth) < size) depth = depth + 1;
    assert!(h.path.length() == (depth as u64), EBadHeaderPath);
    let mut leaf = bytes::word64(h.number);
    leaf.append(bytes::word64(h.timestamp));
    leaf.append(h.state_root);
    leaf.append(h.receipts_root);
    let mut node = keccak256(&leaf);
    let index = h.number - first;
    let mut i: u8 = 0;
    while (i < depth) {
        let sibling = h.path[(i as u64)];
        let right = (index >> i) & 1 == 1;
        let mut pair = if (right) { sibling } else { node };
        pair.append(if (right) { node } else { sibling });
        node = keccak256(&pair);
        i = i + 1;
    };
    assert!(node == h.headers_root, EBadHeaderPath);
}

/// The `log_index`-th log of the receipt of transaction `tx_index`, which must have succeeded, proven under the
/// receipts root by `nodes` of `proof`. The log must carry at least two topics.
public fun log(
    proof: &vector<u8>,
    receipts_root: &vector<u8>,
    nodes: &vector<Span>,
    tx_index: u64,
    log_index: u64,
): Log {
    assert!(tx_index < 0x10000, ENoReceipt);
    let (key, nibbles) = mpt::receipt_key(tx_index);
    let value = mpt::get(proof, nodes, receipts_root, &key, nibbles);
    assert!(value.is_some(), ENoReceipt);
    let value = value.destroy_some();
    // A receipt is the list (status, cumulativeGasUsed, logsBloom, logs), after its type byte if it has one: a typed
    // receipt's first byte is its type, below every RLP list's prefix.
    assert!(!rlp::is_list(&value) && rlp::len(&value) > 0, EBadReceiptProof);
    let (start, len) = (rlp::start(&value), rlp::len(&value));
    let receipt = if (proof[start] < 0xc0) {
        rlp::to_item(proof, start + 1, len - 1)
    } else {
        rlp::to_item(proof, start, len)
    };
    assert!(rlp::uint(proof, &rlp::at(proof, &receipt, STATUS)) == 1, EFailedTransaction);
    let logs = rlp::at(proof, &receipt, LOGS);
    assert!(log_index < rlp::count(proof, &logs), ENoLog);
    let log = rlp::at(proof, &logs, log_index);
    let emitter = rlp::at(proof, &log, 0);
    assert!(!rlp::is_list(&emitter) && rlp::len(&emitter) == 20, EBadReceiptProof);
    let topics = rlp::at(proof, &log, 1);
    assert!(rlp::count(proof, &topics) >= 2, ENoLog);
    let data = rlp::at(proof, &log, 2);
    assert!(!rlp::is_list(&data), EBadReceiptProof);
    Log {
        emitter: rlp::bytes(proof, &emitter),
        topic0: rlp::bytes32(proof, &rlp::at(proof, &topics, 0)),
        topic1: rlp::bytes32(proof, &rlp::at(proof, &topics, 1)),
        data,
    }
}
