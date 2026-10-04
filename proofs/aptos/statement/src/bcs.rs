//! Aptos's encodings and hashes, written from aptos-core (aptos-node v1.49.2) and checked on mainnet's own data
//! (`fixtures/mainnet.json`): the statement writes every preimage it hashes from typed fields and parses none.
//!
//! - BCS: little-endian integers, ULEB128 lengths, `Option` as a 0/1 tag, an enum as its ULEB128 variant index.
//! - `CryptoHasher`: `sha3_256(seed ++ bcs(value))`, the seed `sha3_256("APTOS::" ++ name)`, `name` the type's serde
//!   name. A ledger info is signed over `seed ++ bcs(ledger_info)` (`aptos_crypto::signing_message`).
//! - The accumulators: an internal node `sha3_256(seed ++ left ++ right)` under `TransactionAccumulator` or
//!   `EventAccumulator`, an empty subtree the literal `ACCUMULATOR_PLACEHOLDER_HASH`, zero-padded.

use alloc::vec::Vec;
use tiny_keccak::{Hasher, Keccak, Sha3};

use crate::{BlockInfo, EpochState, LedgerInfo, TransactionInfo, Validator, Word};

/// `ACCUMULATOR_PLACEHOLDER_HASH`: the string's bytes, zero-padded to 32.
pub const PLACEHOLDER: Word = *b"ACCUMULATOR_PLACEHOLDER_HASH\0\0\0\0";

pub fn sha3(parts: &[&[u8]]) -> Word {
    let mut h = Sha3::v256();
    for p in parts {
        h.update(p);
    }
    let mut out = [0u8; 32];
    h.finalize(&mut out);
    out
}

pub fn keccak(parts: &[&[u8]]) -> Word {
    let mut h = Keccak::v256();
    for p in parts {
        h.update(p);
    }
    let mut out = [0u8; 32];
    h.finalize(&mut out);
    out
}

/// A `CryptoHasher`'s seed: `sha3_256("APTOS::" ++ name)`.
pub fn seed(name: &str) -> Word {
    sha3(&[b"APTOS::", name.as_bytes()])
}

pub fn uleb(out: &mut Vec<u8>, mut n: u64) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// A byte string: its ULEB128 length, then its bytes.
pub fn bytes(out: &mut Vec<u8>, b: &[u8]) {
    uleb(out, b.len() as u64);
    out.extend_from_slice(b);
}

fn option(out: &mut Vec<u8>, w: &Option<Word>) {
    match w {
        None => out.push(0),
        Some(w) => {
            out.push(1);
            out.extend_from_slice(w);
        }
    }
}

/// `ValidatorVerifier`'s BCS: its `validator_infos`, each `ValidatorConsensusInfo { address, public_key, voting_power }`.
pub fn validators(vals: &[Validator]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + vals.len() * 90);
    uleb(&mut out, vals.len() as u64);
    for v in vals {
        out.extend_from_slice(&v.address);
        bytes(&mut out, &v.public_key);
        out.extend_from_slice(&v.voting_power.to_le_bytes());
    }
    out
}

fn epoch_state(out: &mut Vec<u8>, s: &EpochState) {
    out.extend_from_slice(&s.epoch.to_le_bytes());
    out.extend_from_slice(&validators(&s.validators));
}

fn block_info(out: &mut Vec<u8>, b: &BlockInfo) {
    out.extend_from_slice(&b.epoch.to_le_bytes());
    out.extend_from_slice(&b.round.to_le_bytes());
    out.extend_from_slice(&b.id);
    out.extend_from_slice(&b.executed_state_id);
    out.extend_from_slice(&b.version.to_le_bytes());
    out.extend_from_slice(&b.timestamp_usecs.to_le_bytes());
    match &b.next_epoch_state {
        None => out.push(0),
        Some(s) => {
            out.push(1);
            epoch_state(out, s);
        }
    }
}

/// `LedgerInfo { commit_info, consensus_data_hash }`'s BCS.
pub fn ledger_info(li: &LedgerInfo) -> Vec<u8> {
    let mut out = Vec::with_capacity(160);
    block_info(&mut out, &li.commit_info);
    out.extend_from_slice(&li.consensus_data_hash);
    out
}

/// What the validators sign: `LedgerInfo`'s seed, then its BCS.
pub fn signing_message(li: &LedgerInfo) -> Vec<u8> {
    let mut out = seed("LedgerInfo").to_vec();
    out.extend_from_slice(&ledger_info(li));
    out
}

/// A successful `TransactionInfo`'s BCS, written with the status `ExecutionStatus::Success` (variant 0) and the event
/// root given, which the statement computes from the events.
pub fn transaction_info(info: &TransactionInfo, event_root: &Word) -> Vec<u8> {
    let mut out = Vec::with_capacity(200);
    let common = |out: &mut Vec<u8>,
                  variant: u8,
                  gas_used: &u64,
                  transaction_hash: &Word,
                  state_change_hash: &Word| {
        out.push(variant);
        out.extend_from_slice(&gas_used.to_le_bytes());
        out.push(0); // ExecutionStatus::Success
        out.extend_from_slice(transaction_hash);
        out.extend_from_slice(event_root);
        out.extend_from_slice(state_change_hash);
    };
    match info {
        TransactionInfo::V0 {
            gas_used,
            transaction_hash,
            state_change_hash,
            state_checkpoint_hash,
            auxiliary_info_hash,
        } => {
            common(&mut out, 0, gas_used, transaction_hash, state_change_hash);
            option(&mut out, state_checkpoint_hash);
            option(&mut out, auxiliary_info_hash);
        }
        TransactionInfo::V1 {
            gas_used,
            transaction_hash,
            state_change_hash,
            state_checkpoint_hash,
            hot_state_checkpoint_hash,
            auxiliary_info_hash,
            position_state_checkpoint_hash,
            placeholders,
        } => {
            common(&mut out, 1, gas_used, transaction_hash, state_change_hash);
            option(&mut out, state_checkpoint_hash);
            option(&mut out, hot_state_checkpoint_hash);
            option(&mut out, auxiliary_info_hash);
            option(&mut out, position_state_checkpoint_hash);
            for p in placeholders {
                option(&mut out, p);
            }
        }
    }
    out
}

/// `TypeTag::Struct(StructTag { address, module, name, type_args: [] })`'s BCS.
pub fn struct_tag(address: &Word, module: &str, name: &str) -> Vec<u8> {
    let mut out = alloc::vec![7u8];
    out.extend_from_slice(address);
    bytes(&mut out, module.as_bytes());
    bytes(&mut out, name.as_bytes());
    out.push(0);
    out
}

/// A module event, `ContractEvent::V2(ContractEventV2 { type_tag, event_data })`'s BCS.
pub fn module_event(type_tag: &[u8], data: &[u8]) -> Vec<u8> {
    let mut out = alloc::vec![1u8];
    out.extend_from_slice(type_tag);
    bytes(&mut out, data);
    out
}

/// Where a `ContractEvent`'s type tag starts: after the variant for a module event (V2), and after the variant, the
/// `EventKey` (`creation_number`, `account_address`) and the sequence number for a handle event (V1).
pub fn type_tag_at(event: &[u8]) -> Option<usize> {
    match event.first() {
        Some(0) => Some(1 + 8 + 32 + 8),
        Some(1) => Some(1),
        _ => None,
    }
}

/// An accumulator's internal node.
pub fn node(seed: &Word, left: &Word, right: &Word) -> Word {
    sha3(&[seed, left, right])
}

/// `InMemoryAccumulator::from_leaves(leaves).root_hash()`: levels padded on the right with the placeholder, which
/// stands for a whole empty subtree; one leaf is its own root, none the placeholder.
pub fn accumulator_root(seed: &Word, leaves: &[Word]) -> Word {
    if leaves.is_empty() {
        return PLACEHOLDER;
    }
    let mut level = leaves.to_vec();
    while level.len() > 1 {
        if level.len() % 2 == 1 {
            level.push(PLACEHOLDER);
        }
        level = level
            .as_chunks::<2>()
            .0
            .iter()
            .map(|[left, right]| node(seed, left, right))
            .collect();
    }
    level[0]
}

/// `AccumulatorProof::verify`'s fold: the root above the leaf at `index`, its siblings from the bottom level up.
pub fn climb(seed: &Word, leaf: &Word, mut index: u64, siblings: &[Word]) -> Word {
    let mut hash = *leaf;
    for sibling in siblings {
        // The node is a left child when its index is even.
        hash = if index & 1 == 0 {
            node(seed, &hash, sibling)
        } else {
            node(seed, sibling, &hash)
        };
        index /= 2;
    }
    hash
}

pub fn word_u64(n: u64) -> Word {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&n.to_be_bytes());
    w
}

fn words(out: &mut Vec<u8>, list: &[Word]) {
    out.extend_from_slice(&word_u64(list.len() as u64));
    for w in list {
        out.extend_from_slice(w);
    }
}

/// `abi.encode(bytes32[] slots, bytes32[] values)`.
pub fn abi_slots_values(slots: &[Word], values: &[Word]) -> Vec<u8> {
    let mut out = Vec::with_capacity(128 + 32 * (slots.len() + values.len()));
    out.extend_from_slice(&word_u64(64));
    out.extend_from_slice(&word_u64(64 + 32 + 32 * slots.len() as u64));
    words(&mut out, slots);
    words(&mut out, values);
    out
}

/// The vault's record, `abi.encode(ATTEST_DOMAIN, uint256 chainId, bytes32 vaultId, uint256 timestamp, bytes32[] slots,
/// bytes32[] values)` (`design/2026-10-04-four-chains-interfaces.md`).
pub fn record(
    chain_id: u64,
    vault_id: &Word,
    timestamp: u64,
    slots: &[Word],
    values: &[Word],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(256 + 32 * (slots.len() + values.len()));
    out.extend_from_slice(&crate::ATTEST_DOMAIN);
    out.extend_from_slice(&word_u64(chain_id));
    out.extend_from_slice(vault_id);
    out.extend_from_slice(&word_u64(timestamp));
    out.extend_from_slice(&word_u64(6 * 32));
    out.extend_from_slice(&word_u64(6 * 32 + 32 + 32 * slots.len() as u64));
    words(&mut out, slots);
    words(&mut out, values);
    out
}
