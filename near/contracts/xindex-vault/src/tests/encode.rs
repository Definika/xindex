//! What Ethereum writes, as the vault reads it: messages, their logs and receipts, a block alone under a headers root,
//! and message bodies. Pure functions over the core's native hashing, shared by the unit tests and, through `#[path]`,
//! the sandbox tests.

use xindex_core::abi::{address_word, u256, u256_wide};
use xindex_core::constants::*;
use xindex_core::crypto::Crypto;
use xindex_core::native::Native;

pub fn keccak_native(parts: &[&[u8]]) -> [u8; 32] {
    Native.keccak256(parts)
}

/// `VaultMessages.encode`: a message of `kind` from `emitter` on chain `source` with `body`, to vault `vault` on chain
/// `dest`.
pub fn message(
    source: u64,
    kind: u8,
    emitter: &[u8; 20],
    body: &[u8],
    nonce: u64,
    dest: u64,
    vault: &[u8; 32],
) -> Vec<u8> {
    let pad = (32 - body.len() % 32) % 32;
    [
        &DOMAIN[..],
        &u256(source),
        &u256(kind as u64),
        &u256(dest),
        vault,
        &address_word(emitter),
        &u256(nonce),
        &u256(8 * 32),
        &u256(body.len() as u64),
        body,
        &vec![0u8; pad],
    ]
    .concat()
}

pub fn rlp_bytes(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    [rlp_len(0x80, b.len()), b.to_vec()].concat()
}

pub fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let body = items.concat();
    [rlp_len(0xc0, body.len()), body].concat()
}

fn rlp_len(base: u8, len: usize) -> Vec<u8> {
    if len < 56 {
        return vec![base + len as u8];
    }
    let bytes: Vec<u8> = len
        .to_be_bytes()
        .iter()
        .copied()
        .skip_while(|b| *b == 0)
        .collect();
    [vec![base + 55 + bytes.len() as u8], bytes].concat()
}

/// `abi.encode(bytes payload)`, a `VaultMessage` log's data.
pub fn log_data(payload: &[u8]) -> Vec<u8> {
    let pad = (32 - payload.len() % 32) % 32;
    [
        &u256(32)[..],
        &u256(payload.len() as u64),
        payload,
        &vec![0u8; pad],
    ]
    .concat()
}

/// A successful legacy receipt with one log, `emitter`'s `VaultMessage(id, payload)`.
pub fn receipt(emitter: &[u8; 20], id: &[u8; 32], payload: &[u8]) -> Vec<u8> {
    let log = rlp_list(&[
        rlp_bytes(emitter),
        rlp_list(&[rlp_bytes(&EVENT_TOPIC), rlp_bytes(id)]),
        rlp_bytes(&log_data(payload)),
    ]);
    rlp_list(&[
        rlp_bytes(&[1]),
        rlp_bytes(&[0x52, 0x08]),
        rlp_bytes(&[0u8; 256]),
        rlp_list(&[log]),
    ])
}

/// The receipts trie of a block whose one transaction made `receipt`: a leaf at key `rlp(0)`, nibbles 8 and 0.
pub fn receipt_leaf(receipt: &[u8]) -> Vec<u8> {
    rlp_list(&[rlp_bytes(&[0x20, 0x80]), rlp_bytes(receipt)])
}

/// A block alone under its headers root: the header part of every proof, `headersRoot ++ number ++ timestamp ++
/// stateRoot ++ receiptsRoot ++ 0 (path)`, and its headers root.
pub fn header(
    number: u64,
    timestamp: u64,
    state_root: &[u8; 32],
    receipts_root: &[u8; 32],
) -> (Vec<u8>, [u8; 32]) {
    let root = keccak_native(&[&u256(number), &u256(timestamp), state_root, receipts_root]);
    let proof = [
        &root[..],
        &number.to_le_bytes(),
        &timestamp.to_le_bytes(),
        state_root,
        receipts_root,
        &[0u8],
    ]
    .concat();
    (proof, root)
}

/// A proof of `payload`'s log by `emitter` in block `number` at `timestamp`, the log's receipt alone in the block's
/// receipts trie, the block alone under the returned headers root.
pub fn event_proof(
    emitter: &[u8; 20],
    payload: &[u8],
    number: u64,
    timestamp: u64,
) -> (Vec<u8>, [u8; 32]) {
    let id = keccak_native(&[payload]);
    let leaf = receipt_leaf(&receipt(emitter, &id, payload));
    let (head, root) = header(number, timestamp, &[7u8; 32], &keccak_native(&[&leaf]));
    let proof = [
        head,
        vec![1u8],
        (leaf.len() as u32).to_le_bytes().to_vec(),
        leaf,
        0u32.to_le_bytes().to_vec(),
        0u32.to_le_bytes().to_vec(),
    ]
    .concat();
    (proof, root)
}

/// A real block under a five-block headers root, second in it, as the core's light-client tests take it: the header
/// part of a proof, the headers root and the range a proof over the five recorded.
pub fn five_blocks(
    number: u64,
    timestamp: u64,
    state: &[u8; 32],
    receipts: &[u8; 32],
) -> (Vec<u8>, [u8; 32], (u64, u64)) {
    let leaf =
        |n: u64, s: &[u8; 32], r: &[u8; 32]| keccak_native(&[&u256(n), &u256(timestamp), s, r]);
    let first = number - 1;
    let mut layer: Vec<[u8; 32]> = (0..5)
        .map(|i| {
            if i == 1 {
                leaf(number, state, receipts)
            } else {
                leaf(first + i, &[i as u8; 32], &[i as u8; 32])
            }
        })
        .collect();
    let (mut path, mut i) = (Vec::new(), 1usize);
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            layer.push([0u8; 32]);
        }
        path.push(layer[i ^ 1]);
        layer = layer
            .chunks(2)
            .map(|p| keccak_native(&[&p[0], &p[1]]))
            .collect();
        i /= 2;
    }
    let root = layer[0];
    let mut head = [
        &root[..],
        &number.to_le_bytes(),
        &timestamp.to_le_bytes(),
        state,
        receipts,
    ]
    .concat();
    head.push(path.len() as u8);
    path.iter().for_each(|p| head.extend_from_slice(p));
    (head, root, (first, first + 4))
}

/// The receipt part of an event proof: the trie nodes from the root to the receipt, then the transaction's and the
/// log's index.
pub fn receipt_part(nodes: &[Vec<u8>], tx: u64, log: u64) -> Vec<u8> {
    let mut out = vec![nodes.len() as u8];
    for n in nodes {
        out.extend_from_slice(&(n.len() as u32).to_le_bytes());
        out.extend_from_slice(n);
    }
    out.extend_from_slice(&(tx as u32).to_le_bytes());
    out.extend_from_slice(&(log as u32).to_le_bytes());
    out
}

/// An intake id: its deadline in the top 64 bits, then a nonce.
pub fn intake_id(deadline: u64, nonce: u64) -> [u8; 32] {
    let mut id = [0u8; 32];
    id[..8].copy_from_slice(&deadline.to_be_bytes());
    id[24..].copy_from_slice(&nonce.to_be_bytes());
    id
}

/// A burn body: NEAR, `amount` yocto, to the 32-byte `recipient`.
pub fn burn_body(amount: u128, recipient: &[u8; 32]) -> Vec<u8> {
    [&[0u8; 32][..], &u256_wide(amount), recipient].concat()
}

pub fn cap_body(cap: u128, floor: u128) -> Vec<u8> {
    [&[0u8; 32][..], &u256_wide(cap), &u256_wide(floor)].concat()
}

/// A FREEZE body: `abi.encode(until)`, when the factory's own freeze of this chain ends (A3-03).
pub fn freeze_body(until: u64) -> Vec<u8> {
    u256(until).to_vec()
}
