//! What the vault reads of an index at its snapshot exit, and the holder's signature it checks there: the twin of
//! `VaultSnapshot.sol`, as every chain's vault without a 20-byte address reads it (`xindex_core::snapshot`), over
//! Solana's syscalls. Solana's differences: the chain is named by the id the factory's registry gives it, where the EVM
//! vault uses `block.chainid`; a recovery address is a whole 32-byte key, so only zero counts as none; and the signed
//! claim names a 32-byte recipient, under a domain whose salt is the vault's 32-byte id.

use anchor_lang::prelude::*;
use ethereum_verifier::Solana;
use xindex_core::snapshot::{self as core, SnapshotError};

use crate::error::VaultError;

pub use xindex_core::snapshot::CLAIM_SLOTS;

fn err(e: SnapshotError) -> anchor_lang::error::Error {
    match e {
        SnapshotError::BadStateProof => error!(VaultError::BadStateProof),
        SnapshotError::WrongComponent => error!(VaultError::WrongComponent),
        SnapshotError::Overflow => error!(VaultError::Overflow),
        SnapshotError::ZeroAmount => error!(VaultError::ZeroAmount),
        SnapshotError::BadSignature => error!(VaultError::BadSignature),
    }
}

/// This chain's coin as the factory names it on Ethereum: `vaultTokenId(chainId, bytes32(0))`.
pub fn vault_token(chain_id: u64) -> [u8; 20] {
    core::vault_token(&Solana, chain_id)
}

/// The slots of the hub's storage `holder`'s claim reads (`CLAIM_SLOTS`).
pub fn claim_slots(holder: &[u8; 20], component: u64, chain_id: u64) -> [[u8; 32]; CLAIM_SLOTS] {
    core::claim_slots(&Solana, holder, component, chain_id)
}

/// The slot of `_settledIntakes[intakeId]`.
pub fn settled_slot(intake_id: &[u8; 32]) -> [u8; 32] {
    core::settled_slot(&Solana, intake_id)
}

/// The slot of `_sentMessages[id]`.
pub fn sent_slot(id: &[u8; 32]) -> [u8; 32] {
    core::sent_slot(&Solana, id)
}

/// The holder's share from the values its claim read, and its recovery key if it registered one (VLT-1).
pub fn share(values: &[[u8; 32]], component: u64, chain_id: u64) -> Result<(u64, Option<Pubkey>)> {
    let (amount, recovery) = core::share(&Solana, values, component, chain_id).map_err(err)?;
    Ok((amount, recovery.map(Pubkey::new_from_array)))
}

/// The id of `holder`'s claim on `index`: its owed account's seed, so a holder claims once.
pub fn claim_id(index: &[u8; 20], holder: &[u8; 20]) -> [u8; 32] {
    core::claim_id(&Solana, index, holder)
}

/// The EIP-712 digest `holder` signs to have the vault `vault_id` on chain `chain_id` pay its share of `index` to
/// `recipient`.
pub fn claim_digest(
    vault_id: &[u8; 32],
    chain_id: u64,
    index: &[u8; 20],
    holder: &[u8; 20],
    recipient: &Pubkey,
) -> [u8; 32] {
    core::claim_digest(
        &Solana,
        vault_id,
        chain_id,
        index,
        holder,
        &recipient.to_bytes(),
    )
}

/// `signature` is `holder`'s over `digest`, as OpenZeppelin's `ECDSA.tryRecover` accepts one.
pub fn check_signature(digest: &[u8; 32], signature: &[u8], holder: &[u8; 20]) -> Result<()> {
    core::check_signature(&Solana, digest, signature, holder).map_err(err)
}
