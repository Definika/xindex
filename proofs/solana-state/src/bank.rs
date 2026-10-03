//! A bank's hash, and what a slot's writes must add up to.
//!
//! `Bank::hash_internal_state` (`runtime/src/bank.rs`, Agave v4.4.0-beta.0 and v4.3.0 alike):
//! `sha256(sha256(parent_bank_hash ++ signature_count (u64 LE) ++ last_blockhash) ++ accounts_lt_hash (2,048 bytes))`,
//! hashed once more with the hard-fork count (u64 LE) when a hard fork lies in `(parent_slot, slot]`
//! (`HardForks::get_hash_data`, solana-hard-forks 3.2.0). The whole lattice hash is absorbed, not its checksum, so a
//! bank hash opens to exactly one lattice hash.

use crate::lthash::{account_lt_hash, Account, LtHash};
use sha2::{Digest, Sha256};

/// What a bank hash commits to.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct BankHashPreimage {
    pub parent_bank_hash: [u8; 32],
    pub signature_count: u64,
    pub last_blockhash: [u8; 32],
    pub accounts_lt_hash: LtHash,
    /// Hard forks in `(parent_slot, slot]`, zero almost always.
    pub hard_forks: u64,
}

impl BankHashPreimage {
    pub fn hash(&self) -> [u8; 32] {
        let inner: [u8; 32] = Sha256::new()
            .chain_update(self.parent_bank_hash)
            .chain_update(self.signature_count.to_le_bytes())
            .chain_update(self.last_blockhash)
            .finalize()
            .into();
        let mut hash: [u8; 32] = Sha256::new()
            .chain_update(inner)
            .chain_update(self.accounts_lt_hash.to_bytes())
            .finalize()
            .into();
        if self.hard_forks > 0 {
            hash = Sha256::new()
                .chain_update(hash)
                .chain_update(self.hard_forks.to_le_bytes())
                .finalize()
                .into();
        }
        hash
    }
}

/// One account the slot wrote: its address, its state before (none if it did not exist) and after (none if
/// deleted). A zero-lamport state and a missing one hash alike, to the identity.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Write {
    pub pubkey: [u8; 32],
    pub old: Option<Account>,
    pub new: Option<Account>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DeltaError {
    /// An address listed twice: each account has one state before the slot and one after.
    Duplicate([u8; 32]),
    /// The parent's lattice hash with these writes is not the slot's.
    Mismatch,
    /// The parent preimage does not open the slot's parent bank hash.
    WrongParent,
}

/// The slot's lattice hash from its parent's and every account it wrote: the parent's, each old state mixed out and
/// each new one mixed in. The caller compares it with the lattice hash the slot's bank hash opens to; if they agree,
/// LtHash's collision resistance makes `writes` the slot's writes, and each new state the account's state after it.
pub fn apply_writes(parent: &LtHash, writes: &[Write]) -> Result<LtHash, DeltaError> {
    let mut seen: Vec<[u8; 32]> = writes.iter().map(|w| w.pubkey).collect();
    seen.sort_unstable();
    if let Some(d) = seen.windows(2).find(|p| p[0] == p[1]) {
        return Err(DeltaError::Duplicate(d[0]));
    }
    let mut out = parent.clone();
    for w in writes {
        if let Some(old) = &w.old {
            out.mix_out(&account_lt_hash(old, &w.pubkey));
        }
        if let Some(new) = &w.new {
            out.mix_in(&account_lt_hash(new, &w.pubkey));
        }
    }
    Ok(out)
}

/// The statement's core: `slot` opens a finalized bank hash, `parent` opens the parent bank hash `slot` names, and
/// the parent's lattice hash with `writes` is the slot's. Returns the state `pubkey` was written to, if it was.
pub fn written_state<'a>(
    slot: &BankHashPreimage,
    parent: &BankHashPreimage,
    writes: &'a [Write],
    pubkey: &[u8; 32],
) -> Result<Option<&'a Account>, DeltaError> {
    if parent.hash() != slot.parent_bank_hash {
        return Err(DeltaError::WrongParent);
    }
    if apply_writes(&parent.accounts_lt_hash, writes)? != slot.accounts_lt_hash {
        return Err(DeltaError::Mismatch);
    }
    Ok(writes
        .iter()
        .find(|w| w.pubkey == *pubkey)
        .and_then(|w| w.new.as_ref()))
}
