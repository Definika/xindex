//! Ethereum's encodings, read and written byte for byte: the `VaultMessages` payload, the digests the hub proves, the
//! log data the verifiers attest, and the CREATE2 address of an index. Every function here is checked against values
//! Solidity's own encoder produced (`cast abi-encode`).

use anchor_lang::prelude::*;
use solana_keccak_hasher::hashv;

use crate::constants::*;
use crate::error::VaultError;

const WORD: usize = 32;
/// The payload's head: domain, source chain, kind, destination chain, vault, index, nonce, and the body's offset.
const HEAD: usize = 8 * WORD;

pub fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    hashv(parts).to_bytes()
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

fn word(data: &[u8], i: usize) -> Result<&[u8; 32]> {
    data.get(i * WORD..(i + 1) * WORD)
        .and_then(|w| w.try_into().ok())
        .ok_or_else(|| error!(VaultError::BadMessage))
}

/// A 256-bit big-endian word that must fit 64 bits.
pub fn to_u64(w: &[u8; 32]) -> Result<u64> {
    require!(w[..24].iter().all(|b| *b == 0), VaultError::Overflow);
    Ok(u64::from_be_bytes(w[24..].try_into().unwrap()))
}

/// A word holding an address: its 12 high bytes must be zero, as Solidity's decoder requires.
pub fn to_address(w: &[u8; 32]) -> Result<[u8; 20]> {
    require!(w[..12].iter().all(|b| *b == 0), VaultError::BadMessage);
    Ok(w[12..].try_into().unwrap())
}

fn to_u8(w: &[u8; 32]) -> Result<u8> {
    require!(w[..31].iter().all(|b| *b == 0), VaultError::BadMessage);
    Ok(w[31])
}

fn u256(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

fn address_word(a: &[u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

fn padded(len: usize) -> usize {
    len.div_ceil(WORD) * WORD
}

/// Decodes `abi.encode(DOMAIN, sourceChainId, kind, destChainId, vault, index, nonce, body)`, refusing anything but its
/// canonical encoding: a payload is known by its hash, so one message must have one encoding.
pub fn decode_message(p: &[u8]) -> Result<Message<'_>> {
    require!(p.len() >= HEAD + WORD, VaultError::BadMessage);
    require!(*word(p, 0)? == DOMAIN, VaultError::BadMessage);
    let source_chain_id = to_u64(word(p, 1)?)?;
    let kind = to_u8(word(p, 2)?)?;
    let dest_chain_id = to_u64(word(p, 3)?)?;
    let vault = *word(p, 4)?;
    let index = to_address(word(p, 5)?)?;
    let nonce = to_u64(word(p, 6)?)?;
    require!(to_u64(word(p, 7)?)? == HEAD as u64, VaultError::BadMessage);
    let len = to_u64(word(p, 8)?)? as usize;
    let start = HEAD + WORD;
    require!(p.len() == start + padded(len), VaultError::BadMessage);
    require!(
        p[start + len..].iter().all(|b| *b == 0),
        VaultError::BadMessage
    );
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
pub fn message_id(p: &[u8]) -> [u8; 32] {
    keccak(&[p])
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
pub fn body_word(body: &[u8], words: usize, i: usize) -> Result<&[u8; 32]> {
    require!(body.len() == words * WORD, VaultError::BadMessage);
    word(body, i)
}

/// The log's data: `abi.encode(bytes payload)`, which the verifiers attest by its hash.
pub fn log_data_hash(payload: &[u8]) -> [u8; 32] {
    let pad = [0u8; WORD];
    keccak(&[
        &u256(WORD as u64),
        &u256(payload.len() as u64),
        payload,
        &pad[..padded(payload.len()) - payload.len()],
    ])
}

/// `keccak256(abi.encode(INDEX_DIGEST_DOMAIN, chainId, vault, index, tokens, balances, paid))`, with SOL as
/// `address(0)` the only token, listed once the index has been credited.
pub fn index_digest(
    chain_id: u64,
    vault: &[u8; 20],
    index: &[u8; 20],
    has: bool,
    balance: u64,
    paid: u64,
) -> [u8; 32] {
    let n = has as u64;
    let tokens = 7 * WORD as u64;
    let balances = tokens + WORD as u64 * (1 + n);
    let paids = balances + WORD as u64 * (1 + n);
    let mut parts: Vec<[u8; 32]> = vec![
        INDEX_DIGEST_DOMAIN,
        u256(chain_id),
        address_word(vault),
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
        parts.push(u256(balance));
    }
    parts.push(u256(n));
    if has {
        parts.push(u256(paid));
    }
    let refs: Vec<&[u8]> = parts.iter().map(|w| w.as_slice()).collect();
    keccak(&refs)
}

/// `keccak256(abi.encode(INTAKE_DIGEST_DOMAIN, chainId, vault, index, intakeId, state, tokens, totals))`, as the hub's
/// `_intakeDigest`.
pub fn intake_digest(
    chain_id: u64,
    vault: &[u8; 20],
    index: &[u8; 20],
    intake_id: &[u8; 32],
    state: u8,
    has: bool,
    total: u64,
) -> [u8; 32] {
    let n = has as u64;
    let tokens = 8 * WORD as u64;
    let totals = tokens + WORD as u64 * (1 + n);
    let mut parts: Vec<[u8; 32]> = vec![
        INTAKE_DIGEST_DOMAIN,
        u256(chain_id),
        address_word(vault),
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
        parts.push(u256(total));
    }
    let refs: Vec<&[u8]> = parts.iter().map(|w| w.as_slice()).collect();
    keccak(&refs)
}

/// The address OpenZeppelin's `Clones.predictDeterministicAddress(implementation, salt, deployer)` gives: the factory's
/// CREATE2 clone of the hub template under `salt`.
pub fn predict_clone(implementation: &[u8; 20], salt: &[u8; 32], deployer: &[u8; 20]) -> [u8; 20] {
    let init = keccak(&[&CLONE_PREFIX, implementation, &CLONE_SUFFIX]);
    let h = keccak(&[&[0xff], deployer, salt, &init]);
    h[12..].try_into().unwrap()
}

/// An intake id's deadline: its top 64 bits, `(deadline << 192) | nonce`.
pub fn deadline_of(intake_id: &[u8; 32]) -> u64 {
    u64::from_be_bytes(intake_id[..8].try_into().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        let s = s.trim_start_matches("0x");
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn h32(s: &str) -> [u8; 32] {
        hex(s).try_into().unwrap()
    }

    fn h20(s: &str) -> [u8; 20] {
        hex(s).try_into().unwrap()
    }

    const VAULT: &str = "1111111111111111111111111111111111111111";
    const INDEX: &str = "2222222222222222222222222222222222222222";

    #[test]
    fn the_constants_are_their_hashes() {
        assert_eq!(keccak(&[b"xindex.v4.vault-message"]), DOMAIN);
        assert_eq!(keccak(&[b"VaultMessage(bytes32,bytes)"]), EVENT_TOPIC);
        assert_eq!(
            keccak(&[b"xindex.v4.vault.index-digest"]),
            INDEX_DIGEST_DOMAIN
        );
        assert_eq!(
            keccak(&[b"xindex.v4.vault.intake-digest"]),
            INTAKE_DIGEST_DOMAIN
        );
    }

    /// Against `cast abi-encode` of the same arguments, then `cast keccak`.
    #[test]
    fn digests_match_solidity() {
        let (v, i) = (h20(VAULT), h20(INDEX));
        assert_eq!(
            index_digest(900, &v, &i, true, 5000, 70),
            h32("28f9869e4f8936341babb928cb7b6888fba387b81c11825a1781134c8ee69a4a")
        );
        assert_eq!(
            index_digest(900, &v, &i, false, 0, 0),
            h32("38135e9824ef7b5dd023173ff6c58dc1a539c4e73da45a2f981d3590a02569d2")
        );
        let id = h32("0000000066000000000000000000000000000000000000000000000000000007");
        assert_eq!(
            intake_digest(900, &v, &i, &id, 1, true, 1_400_000_000),
            h32("0afe82d8eca28b59179df3c684949af67c44cf3ab186628d6c07690fd1e13cce")
        );
        assert_eq!(
            intake_digest(900, &v, &i, &id, 2, false, 0),
            h32("6a4afe70fb1fde2003ca24af9451d14d8657374390fae92bad4e6a8ae513653d")
        );
    }

    /// Against `cast compute-address` over the EIP-1167 creation code.
    #[test]
    fn the_clone_address_is_create2s() {
        let got = predict_clone(
            &h20("3333333333333333333333333333333333333333"),
            &h32("5555555555555555555555555555555555555555555555555555555555555555"),
            &h20("4444444444444444444444444444444444444444"),
        );
        assert_eq!(got, h20("c93ae4f4ad09ddf3f73bb4591134b372268e1138"));
    }

    const BURN_PAYLOAD: &str = "bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a00000000000000000000000000000000000000000000000000000000000aa36a7000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003849999999999999999999999999999999999999999999999999999999999999999000000000000000000000000222222222222222222222222222222222222222200000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000053724e007777777777777777777777777777777777777777777777777777777777777777";

    #[test]
    fn a_burn_decodes() {
        let p = hex(BURN_PAYLOAD);
        let m = decode_message(&p).unwrap();
        assert_eq!(m.source_chain_id, 11_155_111);
        assert_eq!(m.kind, BURN);
        assert_eq!(m.dest_chain_id, 900);
        assert_eq!(m.vault, [0x99; 32]);
        assert_eq!(m.index, h20(INDEX));
        assert_eq!(
            to_u64(body_word(m.body, 3, 1).unwrap()).unwrap(),
            1_400_000_000
        );
        assert_eq!(*body_word(m.body, 3, 2).unwrap(), [0x77; 32]);
        assert_eq!(
            message_id(&p),
            h32("d96d23eda6686b98ba93d99e2b34ca449fb421958b59a98ec94043eba68b3aac")
        );
        assert_eq!(index_in(&p), h20(INDEX));
        assert_eq!(body_word_in(&p, 2), [0x77; 32]);
        assert_eq!(address_in_body(&p, 2), [0x77; 20]);
        assert_eq!(
            index_in(&p[..100]),
            [0u8; 20],
            "a short payload names no index"
        );
        assert_eq!(body_word_in(&p[..300], 0), [0u8; 32]);
        assert_eq!(
            log_data_hash(&p),
            h32("b8d83ce716606d07066b4090f8ecf185878a751d0c2cdee3238b1cece2b39591")
        );
    }

    #[test]
    fn only_the_canonical_encoding_decodes() {
        let p = hex(BURN_PAYLOAD);
        let mut longer = p.clone();
        longer.extend_from_slice(&[0u8; 32]);
        assert!(decode_message(&longer).is_err(), "trailing bytes");
        assert!(decode_message(&p[..p.len() - 1]).is_err(), "truncated");
        let mut domain = p.clone();
        domain[0] ^= 1;
        assert!(decode_message(&domain).is_err(), "another domain");
        let mut kind = p.clone();
        kind[2 * 32 + 30] = 1;
        assert!(decode_message(&kind).is_err(), "a kind above 255");
        let mut index = p.clone();
        index[5 * 32] = 1;
        assert!(decode_message(&index).is_err(), "an index above 160 bits");
        let mut offset = p.clone();
        offset[7 * 32 + 31] = 0x20;
        assert!(decode_message(&offset).is_err(), "a body elsewhere");
        let mut chain = p.clone();
        chain[32] = 1;
        assert!(decode_message(&chain).is_err(), "a chain id above 64 bits");
        assert!(
            body_word(decode_message(&p).unwrap().body, 2, 0).is_err(),
            "a body of the wrong length"
        );
    }

    #[test]
    fn an_intake_id_carries_its_deadline() {
        let id = h32("0000000066000000000000000000000000000000000000000000000000000007");
        assert_eq!(deadline_of(&id), 0x66000000);
    }
}
