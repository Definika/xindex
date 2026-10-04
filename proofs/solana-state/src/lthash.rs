//! The accounts lattice hash (SIMD-0215), as Agave computes it.
//!
//! - `LtHash` is 1,024 `u16`s, added and subtracted element-wise with wrapping (`lattice-hash/src/lt_hash.rs`).
//! - An account's is the 2,048-byte BLAKE3 XOF of `lamports (u64 LE) ++ data ++ executable (u8) ++ owner ++ pubkey`, read
//!   as little-endian `u16`s; a zero-lamport account's is the identity (`AccountsDb::lt_hash_account`,
//!   `accounts-db/src/accounts_db.rs`).
//! - A bank's is its parent's, with each account it wrote mixed out at its old state and in at its new one
//!   (`AccountsLtHashAsyncProgress::process`, `runtime/src/bank/accounts_lt_hash.rs`).

/// A lattice hash: 1,024 `u16` elements.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct LtHash(pub [u16; LtHash::ELEMENTS]);

impl LtHash {
    pub const ELEMENTS: usize = 1024;
    pub const BYTES: usize = 2 * Self::ELEMENTS;

    pub const fn identity() -> Self {
        Self([0; Self::ELEMENTS])
    }

    /// The hash of everything `hasher` has absorbed: its XOF's first 2,048 bytes, as little-endian `u16`s.
    pub fn with(hasher: &blake3::Hasher) -> Self {
        let mut bytes = [0u8; Self::BYTES];
        hasher.finalize_xof().fill(&mut bytes);
        Self::from_bytes(&bytes)
    }

    pub fn from_bytes(bytes: &[u8; Self::BYTES]) -> Self {
        let mut out = Self::identity();
        for (i, e) in out.0.iter_mut().enumerate() {
            *e = u16::from_le_bytes([bytes[2 * i], bytes[2 * i + 1]]);
        }
        out
    }

    /// The little-endian bytes the bank hash absorbs.
    pub fn to_bytes(&self) -> [u8; Self::BYTES] {
        let mut out = [0u8; Self::BYTES];
        for (i, e) in self.0.iter().enumerate() {
            out[2 * i..2 * i + 2].copy_from_slice(&e.to_le_bytes());
        }
        out
    }

    pub fn mix_in(&mut self, other: &Self) {
        for (a, b) in self.0.iter_mut().zip(other.0.iter()) {
            *a = a.wrapping_add(*b);
        }
    }

    pub fn mix_out(&mut self, other: &Self) {
        for (a, b) in self.0.iter_mut().zip(other.0.iter()) {
            *a = a.wrapping_sub(*b);
        }
    }

    /// BLAKE3 of the 2,048 bytes: what Agave logs and stores in a snapshot.
    pub fn checksum(&self) -> [u8; 32] {
        *blake3::hash(&self.to_bytes()).as_bytes()
    }
}

/// An account's state, as the lattice hash reads it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Account {
    pub lamports: u64,
    pub data: Vec<u8>,
    pub owner: [u8; 32],
    pub executable: bool,
}

/// `AccountsDb::lt_hash_account`: the identity for a zero-lamport account, else the hash of its fields and address.
pub fn account_lt_hash(account: &Account, pubkey: &[u8; 32]) -> LtHash {
    if account.lamports == 0 {
        return LtHash::identity();
    }
    let mut hasher = blake3::Hasher::new();
    hasher.update(&account.lamports.to_le_bytes());
    hasher.update(&account.data);
    hasher.update(&[u8::from(account.executable)]);
    hasher.update(&account.owner);
    hasher.update(pubkey);
    LtHash::with(&hasher)
}
