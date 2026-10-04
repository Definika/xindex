//! Ethereum's encodings, read and written byte for byte: the `VaultMessages` payload, the digests the hub proves, the
//! log data the verifiers attest, and the CREATE2 address of an index. Every chain's vault shares them
//! (`xindex_core::abi`, checked there against Solidity's own encoder); here they run over Solana's syscalls, with the
//! core's refusals as this vault's errors.

use anchor_lang::prelude::*;
use ethereum_verifier::Solana;
use xindex_core::abi::{self as core, AbiError};
use xindex_core::crypto::Crypto;

pub use xindex_core::abi::{address_in_body, body_word_in, deadline_of, index_in, Message};

use crate::error::VaultError;

fn err(e: AbiError) -> anchor_lang::error::Error {
    match e {
        AbiError::BadMessage => error!(VaultError::BadMessage),
        AbiError::Overflow => error!(VaultError::Overflow),
    }
}

pub fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    Solana.keccak256(parts)
}

/// A 256-bit big-endian word that must fit 64 bits.
pub fn to_u64(w: &[u8; 32]) -> Result<u64> {
    core::to_u64(w).map_err(err)
}

/// A word holding an address: its 12 high bytes must be zero, as Solidity's decoder requires.
pub fn to_address(w: &[u8; 32]) -> Result<[u8; 20]> {
    core::to_address(w).map_err(err)
}

/// Decodes a `VaultMessages` payload, refusing anything but its canonical encoding.
pub fn decode_message(p: &[u8]) -> Result<Message<'_>> {
    core::decode_message(p).map_err(err)
}

/// A message's id: its payload's hash, the log's second topic.
pub fn message_id(p: &[u8]) -> [u8; 32] {
    core::message_id(&Solana, p)
}

/// The end of the freeze a `FREEZE` with this body sets: the factory's own freeze's end, never more than
/// FREEZE_DURATION from now; none if that freeze is over (A3-03). The body must be one word (B4-04).
pub fn freeze_end(body: &[u8], now: i64) -> Result<Option<i64>> {
    core::freeze_end(body, now).map_err(err)
}

/// The body's `i`-th word, of a body that must be exactly `words` long.
pub fn body_word(body: &[u8], words: usize, i: usize) -> Result<&[u8; 32]> {
    core::body_word(body, words, i).map_err(err)
}

/// The log's data: `abi.encode(bytes payload)`, which the verifiers attest by its hash.
pub fn log_data_hash(payload: &[u8]) -> [u8; 32] {
    core::log_data_hash(&Solana, payload)
}

/// `keccak256(abi.encode(INDEX_DIGEST_DOMAIN, chainId, vault, index, tokens, balances, paid))`, SOL as `address(0)`.
pub fn index_digest(
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    has: bool,
    balance: u64,
    paid: u64,
) -> [u8; 32] {
    core::index_digest(&Solana, chain_id, vault, index, has, balance, paid)
}

/// `keccak256(abi.encode(INTAKE_DIGEST_DOMAIN, chainId, vault, index, intakeId, state, tokens, totals))`, as the hub's
/// `_intakeDigest`.
pub fn intake_digest(
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    intake_id: &[u8; 32],
    state: u8,
    has: bool,
    total: u64,
) -> [u8; 32] {
    core::intake_digest(
        &Solana, chain_id, vault, index, intake_id, state, has, total,
    )
}

/// The address OpenZeppelin's `Clones.predictDeterministicAddress(implementation, salt, deployer)` gives.
pub fn predict_clone(implementation: &[u8; 20], salt: &[u8; 32], deployer: &[u8; 20]) -> [u8; 20] {
    core::predict_clone(&Solana, implementation, salt, deployer)
}
