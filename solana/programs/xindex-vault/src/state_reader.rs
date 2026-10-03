//! Reads an Ethereum account's storage under a trusted state root, from the proofs `eth_getProof` returns: the twin of
//! `EthereumStateReader.sol`. The vault uses it only for its snapshot exit, under the state root of the last checkpoint
//! its verifiers accepted. Every node is authenticated by its hash from the root down, or embedded in an authenticated
//! parent (`ethereum_verifier::mpt`), so a value read is the one the root commits to, and a slot the proof shows
//! absent reads zero.
//!
//! A proof is `accountProof` then one storage proof per slot, in the slots' order, each a node list: `count (u8) ++
//! (length (u32, little-endian) ++ node) * count`, and nothing after. It travels inline, or in a loader buffer when it
//! is too long for a transaction (`staged`).

use anchor_lang::prelude::*;
use anchor_lang::solana_program::bpf_loader_upgradeable;
use ethereum_verifier::{mpt, rlp};

use crate::abi::keccak;
use crate::error::VaultError;

/// A loader buffer's data starts after its metadata: the state tag and the authority option.
const BUFFER_METADATA: usize = 37;
const BUFFER_TAG: [u8; 4] = [1, 0, 0, 0];
/// An account's RLP is the list (nonce, balance, storageRoot, codeHash).
const STORAGE_ROOT: usize = 2;
const KEY_NIBBLES: usize = 64;

/// The values of `slots` of `account`, read under `state_root` from `proof`. An account the root shows absent has no
/// storage: every slot reads zero.
pub fn read_slots(
    state_root: &[u8; 32],
    account: &[u8; 20],
    slots: &[[u8; 32]],
    proof: &[u8],
) -> Result<Vec<[u8; 32]>> {
    let mut at = 0;
    let account_proof = nodes(proof, &mut at)?;
    let mut storage_proofs = Vec::with_capacity(slots.len());
    for _ in slots {
        storage_proofs.push(nodes(proof, &mut at)?);
    }
    require!(at == proof.len(), VaultError::BadStateProof);
    let mut values = vec![[0u8; 32]; slots.len()];
    let Some(storage_root) = storage_root(state_root, account, &account_proof)? else {
        return Ok(values);
    };
    for (i, slot) in slots.iter().enumerate() {
        values[i] = slot_at(&storage_root, slot, &storage_proofs[i])?;
    }
    Ok(values)
}

/// The storage root of `account`, proven from `state_root`; none if the proof shows the account absent.
fn storage_root(
    state_root: &[u8; 32],
    account: &[u8; 20],
    proof: &[&[u8]],
) -> Result<Option<[u8; 32]>> {
    let Some(leaf) = mpt::get(state_root, &keccak(&[account]), KEY_NIBBLES, proof).map_err(bad)?
    else {
        return Ok(None);
    };
    // The leaf's value is a string holding the account's RLP.
    let account = rlp::to_item(leaf.bytes().map_err(bad)?).map_err(bad)?;
    let root = account
        .at(STORAGE_ROOT)
        .and_then(|r| r.bytes32())
        .map_err(bad)?;
    Ok(Some(root))
}

/// The value of `slot`, proven from an account's storage root; zero for a slot the proof shows absent.
fn slot_at(root: &[u8; 32], slot: &[u8; 32], proof: &[&[u8]]) -> Result<[u8; 32]> {
    let Some(leaf) = mpt::get(root, &keccak(&[slot]), KEY_NIBBLES, proof).map_err(bad)? else {
        return Ok([0u8; 32]);
    };
    // A slot's value is its RLP-encoded big-endian integer, inside the leaf's value string.
    let value = rlp::to_item(leaf.bytes().map_err(bad)?).map_err(bad)?;
    let bytes = value.bytes().map_err(bad)?;
    require!(bytes.len() <= 32, VaultError::BadStateProof);
    let mut word = [0u8; 32];
    word[32 - bytes.len()..].copy_from_slice(bytes);
    Ok(word)
}

/// Any error of the proof's RLP or of its walk: the proof does not prove the storage.
fn bad<E>(_: E) -> anchor_lang::error::Error {
    error!(VaultError::BadStateProof)
}

/// One node list at `*at`, which it moves past.
fn nodes<'a>(proof: &'a [u8], at: &mut usize) -> Result<Vec<&'a [u8]>> {
    let count = *proof.get(*at).ok_or(VaultError::BadStateProof)? as usize;
    *at += 1;
    let mut list = Vec::with_capacity(count);
    for _ in 0..count {
        let len = proof
            .get(*at..*at + 4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
            .ok_or(VaultError::BadStateProof)?;
        *at += 4;
        let end = at.checked_add(len).ok_or(VaultError::BadStateProof)?;
        list.push(proof.get(*at..end).ok_or(VaultError::BadStateProof)?);
        *at = end;
    }
    Ok(list)
}

/// Runs `read` on the proof: `inline` when it is given, else the one staged in `buffer`, a loader buffer holding its
/// length (u32) then its bytes. What the buffer holds is no more trusted than instruction data, since every node is
/// checked against the root, so whose buffer it is does not matter.
pub fn staged<T>(
    inline: &[u8],
    buffer: Option<&AccountInfo>,
    read: impl FnOnce(&[u8]) -> Result<T>,
) -> Result<T> {
    if !inline.is_empty() {
        return read(inline);
    }
    let buffer = buffer.ok_or(VaultError::BadStateProof)?;
    require_keys_eq!(
        *buffer.owner,
        bpf_loader_upgradeable::id(),
        VaultError::BadStateProof
    );
    let data = buffer.try_borrow_data()?;
    require!(
        data.len() >= BUFFER_METADATA + 4 && data[..4] == BUFFER_TAG,
        VaultError::BadStateProof
    );
    let len = u32::from_le_bytes(
        data[BUFFER_METADATA..BUFFER_METADATA + 4]
            .try_into()
            .unwrap(),
    ) as usize;
    let start = BUFFER_METADATA + 4;
    let proof = data
        .get(start..start + len)
        .ok_or(VaultError::BadStateProof)?;
    read(proof)
}
