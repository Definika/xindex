//! Ethereum's encodings, read and written byte for byte: the `VaultMessages` payload, the digests the hub proves, the
//! log data the verifiers attest, and the CREATE2 address of an index. Every function here is checked against values
//! Solidity's own encoder produced (`cast abi-encode`).

use alloc::vec;
use alloc::vec::Vec;

use crate::constants::*;
use crate::crypto::Crypto;

const WORD: usize = 32;
/// The payload's head: domain, source chain, kind, destination chain, vault, index, nonce, and the body's offset.
const HEAD: usize = 8 * WORD;

/// What a payload or a body word may fail: not the canonical encoding, or an amount past 64 bits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AbiError {
    BadMessage,
    Overflow,
}

/// One message, decoded: the fields the vault checks, and the body its kind reads.
pub struct Message<'a> {
    pub source_chain_id: u64,
    pub kind: u8,
    pub dest_chain_id: u64,
    pub vault: [u8; 32],
    pub index: [u8; 20],
    /// The sender's message counter: the factory's `messageNonce` for governance, which only rises.
    pub nonce: u64,
    pub body: &'a [u8],
}

fn word(data: &[u8], i: usize) -> Result<&[u8; 32], AbiError> {
    data.get(i * WORD..(i + 1) * WORD)
        .and_then(|w| w.try_into().ok())
        .ok_or(AbiError::BadMessage)
}

/// A 256-bit big-endian word that must fit 64 bits.
pub fn to_u64(w: &[u8; 32]) -> Result<u64, AbiError> {
    if !w[..24].iter().all(|b| *b == 0) {
        return Err(AbiError::Overflow);
    }
    Ok(u64::from_be_bytes(w[24..].try_into().unwrap()))
}

/// A 256-bit big-endian word that must fit 128 bits: an amount on a chain whose coin needs more than 64 bits, as
/// NEAR's yoctoNEAR does.
pub fn to_u128(w: &[u8; 32]) -> Result<u128, AbiError> {
    if !w[..16].iter().all(|b| *b == 0) {
        return Err(AbiError::Overflow);
    }
    Ok(u128::from_be_bytes(w[16..].try_into().unwrap()))
}

/// A word holding an address: its 12 high bytes must be zero, as Solidity's decoder requires.
pub fn to_address(w: &[u8; 32]) -> Result<[u8; 20], AbiError> {
    if !w[..12].iter().all(|b| *b == 0) {
        return Err(AbiError::BadMessage);
    }
    Ok(w[12..].try_into().unwrap())
}

fn to_u8(w: &[u8; 32]) -> Result<u8, AbiError> {
    if !w[..31].iter().all(|b| *b == 0) {
        return Err(AbiError::BadMessage);
    }
    Ok(w[31])
}

/// A number as a 32-byte big-endian word, as `abi.encode(uint256)` writes it.
pub fn u256(x: u64) -> [u8; 32] {
    u256_wide(x as u128)
}

/// A 128-bit number as a 32-byte big-endian word, as `abi.encode(uint256)` writes it.
pub fn u256_wide(x: u128) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[16..].copy_from_slice(&x.to_be_bytes());
    w
}

/// An address as a word, as `abi.encode(address)` writes it.
pub fn address_word(a: &[u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

fn padded(len: usize) -> usize {
    len.div_ceil(WORD) * WORD
}

/// Decodes `abi.encode(DOMAIN, sourceChainId, kind, destChainId, vault, index, nonce, body)`, refusing anything but its
/// canonical encoding: a payload is known by its hash, so one message must have one encoding.
pub fn decode_message(p: &[u8]) -> Result<Message<'_>, AbiError> {
    if p.len() < HEAD + WORD || *word(p, 0)? != DOMAIN {
        return Err(AbiError::BadMessage);
    }
    let source_chain_id = to_u64(word(p, 1)?)?;
    let kind = to_u8(word(p, 2)?)?;
    let dest_chain_id = to_u64(word(p, 3)?)?;
    let vault = *word(p, 4)?;
    let index = to_address(word(p, 5)?)?;
    let nonce = to_u64(word(p, 6)?)?;
    if to_u64(word(p, 7)?)? != HEAD as u64 {
        return Err(AbiError::BadMessage);
    }
    let len = to_u64(word(p, 8)?)? as usize;
    let start = HEAD + WORD;
    if p.len() != start + padded(len) || !p[start + len..].iter().all(|b| *b == 0) {
        return Err(AbiError::BadMessage);
    }
    Ok(Message {
        source_chain_id,
        kind,
        dest_chain_id,
        vault,
        index,
        nonce,
        body: &p[start..start + len],
    })
}

/// A message's id: its payload's hash, the log's second topic.
pub fn message_id<C: Crypto>(c: &C, p: &[u8]) -> [u8; 32] {
    c.keccak256(&[p])
}

/// The index a payload names, read in place so an instruction can derive its accounts from the payload alone. The
/// handler then decodes the whole message, which checks this word is an address.
pub fn index_in(p: &[u8]) -> [u8; 20] {
    p.get(5 * WORD + 12..6 * WORD)
        .and_then(|s| s.try_into().ok())
        .unwrap_or([0u8; 20])
}

/// The `i`-th word of a payload's body, read in place, as `index_in`.
pub fn body_word_in(p: &[u8], i: usize) -> [u8; 32] {
    let at = HEAD + WORD + i * WORD;
    p.get(at..at + WORD)
        .and_then(|s| s.try_into().ok())
        .unwrap_or([0u8; 32])
}

/// The address in the `i`-th word of a payload's body, read in place.
pub fn address_in_body(p: &[u8], i: usize) -> [u8; 20] {
    body_word_in(p, i)[12..].try_into().unwrap()
}

/// The body's `i`-th word, of a body that must be exactly `words` long.
pub fn body_word(body: &[u8], words: usize, i: usize) -> Result<&[u8; 32], AbiError> {
    if body.len() != words * WORD {
        return Err(AbiError::BadMessage);
    }
    word(body, i)
}

/// The log's data: `abi.encode(bytes payload)`, which the verifiers attest by its hash.
pub fn log_data_hash<C: Crypto>(c: &C, payload: &[u8]) -> [u8; 32] {
    let pad = [0u8; WORD];
    c.keccak256(&[
        &u256(WORD as u64),
        &u256(payload.len() as u64),
        payload,
        &pad[..padded(payload.len()) - payload.len()],
    ])
}

/// `keccak256(abi.encode(INDEX_DIGEST_DOMAIN, chainId, vault, index, tokens, balances, paid))`, `vault` the whole
/// 32-byte id the factory registers (for an EVM vault, its address as a word), with the chain's native coin as
/// `address(0)` the only token, listed once the index has been credited.
pub fn index_digest<C: Crypto>(
    c: &C,
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    has: bool,
    balance: u64,
    paid: u64,
) -> [u8; 32] {
    index_digest_wide(
        c,
        chain_id,
        vault,
        index,
        has,
        balance as u128,
        paid as u128,
    )
}

/// `index_digest`, for a chain whose amounts need 128 bits, as NEAR's yoctoNEAR do.
pub fn index_digest_wide<C: Crypto>(
    c: &C,
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    has: bool,
    balance: u128,
    paid: u128,
) -> [u8; 32] {
    let n = has as u64;
    let tokens = 7 * WORD as u64;
    let balances = tokens + WORD as u64 * (1 + n);
    let paids = balances + WORD as u64 * (1 + n);
    let mut parts: Vec<[u8; 32]> = vec![
        INDEX_DIGEST_DOMAIN,
        u256(chain_id),
        *vault,
        address_word(index),
        u256(tokens),
        u256(balances),
        u256(paids),
        u256(n),
    ];
    if has {
        parts.push([0u8; 32]);
    }
    parts.push(u256(n));
    if has {
        parts.push(u256_wide(balance));
    }
    parts.push(u256(n));
    if has {
        parts.push(u256_wide(paid));
    }
    let refs: Vec<&[u8]> = parts.iter().map(|w| w.as_slice()).collect();
    c.keccak256(&refs)
}

/// `keccak256(abi.encode(INTAKE_DIGEST_DOMAIN, chainId, vault, index, intakeId, state, tokens, totals))`, as the hub's
/// `_intakeDigest`.
#[allow(clippy::too_many_arguments)]
pub fn intake_digest<C: Crypto>(
    c: &C,
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    intake_id: &[u8; 32],
    state: u8,
    has: bool,
    total: u64,
) -> [u8; 32] {
    intake_digest_wide(
        c,
        chain_id,
        vault,
        index,
        intake_id,
        state,
        has,
        total as u128,
    )
}

/// `intake_digest`, for a chain whose amounts need 128 bits, as NEAR's yoctoNEAR do.
#[allow(clippy::too_many_arguments)]
pub fn intake_digest_wide<C: Crypto>(
    c: &C,
    chain_id: u64,
    vault: &[u8; 32],
    index: &[u8; 20],
    intake_id: &[u8; 32],
    state: u8,
    has: bool,
    total: u128,
) -> [u8; 32] {
    let n = has as u64;
    let tokens = 8 * WORD as u64;
    let totals = tokens + WORD as u64 * (1 + n);
    let mut parts: Vec<[u8; 32]> = vec![
        INTAKE_DIGEST_DOMAIN,
        u256(chain_id),
        *vault,
        address_word(index),
        *intake_id,
        u256(state as u64),
        u256(tokens),
        u256(totals),
        u256(n),
    ];
    if has {
        parts.push([0u8; 32]);
    }
    parts.push(u256(n));
    if has {
        parts.push(u256_wide(total));
    }
    let refs: Vec<&[u8]> = parts.iter().map(|w| w.as_slice()).collect();
    c.keccak256(&refs)
}

/// The address OpenZeppelin's `Clones.predictDeterministicAddress(implementation, salt, deployer)` gives: the factory's
/// CREATE2 clone of the hub template under `salt`.
pub fn predict_clone<C: Crypto>(
    c: &C,
    implementation: &[u8; 20],
    salt: &[u8; 32],
    deployer: &[u8; 20],
) -> [u8; 20] {
    let init = c.keccak256(&[&CLONE_PREFIX, implementation, &CLONE_SUFFIX]);
    let h = c.keccak256(&[&[0xff], deployer, salt, &init]);
    h[12..].try_into().unwrap()
}

/// An intake id's deadline: its top 64 bits, `(deadline << 192) | nonce`.
pub fn deadline_of(intake_id: &[u8; 32]) -> u64 {
    u64::from_be_bytes(intake_id[..8].try_into().unwrap())
}
