//! Reads an Ethereum account's storage under a trusted state root, from the proofs `eth_getProof` returns: the twin of
//! `EthereumStateReader.sol`. A vault uses it only for its snapshot exit, under the state root of the last checkpoint
//! its verifiers accepted. Every node is authenticated by its hash from the root down, or embedded in an authenticated
//! parent (`mpt`), so a value read is the one the root commits to, and a slot the proof shows absent reads zero.
//!
//! A proof is `accountProof` then one storage proof per slot, in the slots' order, each a node list: `count (u8) ++
//! (length (u32, little-endian) ++ node) * count`, and nothing after.

use alloc::vec;
use alloc::vec::Vec;

use crate::crypto::Crypto;
use crate::{mpt, rlp};

/// The proof does not prove the storage: malformed, under another root, or with bytes after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BadStateProof;

/// An account's RLP is the list (nonce, balance, storageRoot, codeHash).
const STORAGE_ROOT: usize = 2;
const KEY_NIBBLES: usize = 64;

/// The values of `slots` of `account`, read under `state_root` from `proof`. An account the root shows absent has no
/// storage: every slot reads zero.
pub fn read_slots<C: Crypto>(
    c: &C,
    state_root: &[u8; 32],
    account: &[u8; 20],
    slots: &[[u8; 32]],
    proof: &[u8],
) -> Result<Vec<[u8; 32]>, BadStateProof> {
    let mut at = 0;
    let account_proof = nodes(proof, &mut at)?;
    let mut storage_proofs = Vec::with_capacity(slots.len());
    for _ in slots {
        storage_proofs.push(nodes(proof, &mut at)?);
    }
    if at != proof.len() {
        return Err(BadStateProof);
    }
    let mut values = vec![[0u8; 32]; slots.len()];
    let Some(storage_root) = storage_root(c, state_root, account, &account_proof)? else {
        return Ok(values);
    };
    for (i, slot) in slots.iter().enumerate() {
        values[i] = slot_at(c, &storage_root, slot, &storage_proofs[i])?;
    }
    Ok(values)
}

/// The storage root of `account`, proven from `state_root`; none if the proof shows the account absent.
fn storage_root<C: Crypto>(
    c: &C,
    state_root: &[u8; 32],
    account: &[u8; 20],
    proof: &[&[u8]],
) -> Result<Option<[u8; 32]>, BadStateProof> {
    let Some(leaf) =
        mpt::get(c, state_root, &c.keccak256(&[account]), KEY_NIBBLES, proof).map_err(bad)?
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
fn slot_at<C: Crypto>(
    c: &C,
    root: &[u8; 32],
    slot: &[u8; 32],
    proof: &[&[u8]],
) -> Result<[u8; 32], BadStateProof> {
    let Some(leaf) = mpt::get(c, root, &c.keccak256(&[slot]), KEY_NIBBLES, proof).map_err(bad)?
    else {
        return Ok([0u8; 32]);
    };
    // A slot's value is its RLP-encoded big-endian integer, inside the leaf's value string.
    let value = rlp::to_item(leaf.bytes().map_err(bad)?).map_err(bad)?;
    let bytes = value.bytes().map_err(bad)?;
    if bytes.len() > 32 {
        return Err(BadStateProof);
    }
    let mut word = [0u8; 32];
    word[32 - bytes.len()..].copy_from_slice(bytes);
    Ok(word)
}

/// Any error of the proof's RLP or of its walk: the proof does not prove the storage.
fn bad<E>(_: E) -> BadStateProof {
    BadStateProof
}

/// One node list at `*at`, which it moves past.
fn nodes<'a>(proof: &'a [u8], at: &mut usize) -> Result<Vec<&'a [u8]>, BadStateProof> {
    let count = *proof.get(*at).ok_or(BadStateProof)? as usize;
    *at += 1;
    let mut list = Vec::with_capacity(count);
    for _ in 0..count {
        let len = proof
            .get(*at..*at + 4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
            .ok_or(BadStateProof)?;
        *at += 4;
        let end = at.checked_add(len).ok_or(BadStateProof)?;
        list.push(proof.get(*at..end).ok_or(BadStateProof)?);
        *at = end;
    }
    Ok(list)
}
