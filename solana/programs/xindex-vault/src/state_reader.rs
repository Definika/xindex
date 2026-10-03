//! Reads an Ethereum account's storage under a trusted state root, from the proofs `eth_getProof` returns: the twin of
//! `EthereumStateReader.sol`, as every chain's vault reads it (`xindex_core::state_reader`), over Solana's syscalls. The
//! vault uses it only for its snapshot exit, under the state root of the last checkpoint its verifiers accepted. Every
//! node is authenticated by its hash from the root down, or embedded in an authenticated parent, so a value read is the
//! one the root commits to, and a slot the proof shows absent reads zero.
//!
//! A proof is `accountProof` then one storage proof per slot, in the slots' order, each a node list: `count (u8) ++
//! (length (u32, little-endian) ++ node) * count`, and nothing after. It travels inline, or in a loader buffer when it
//! is too long for a transaction (`staged`).

use anchor_lang::prelude::*;
use anchor_lang::solana_program::bpf_loader_upgradeable;
use ethereum_verifier::Solana;

use crate::error::VaultError;

/// A loader buffer's data starts after its metadata: the state tag and the authority option.
const BUFFER_METADATA: usize = 37;
const BUFFER_TAG: [u8; 4] = [1, 0, 0, 0];

/// The values of `slots` of `account`, read under `state_root` from `proof`. An account the root shows absent has no
/// storage: every slot reads zero.
pub fn read_slots(
    state_root: &[u8; 32],
    account: &[u8; 20],
    slots: &[[u8; 32]],
    proof: &[u8],
) -> Result<Vec<[u8; 32]>> {
    xindex_core::state_reader::read_slots(&Solana, state_root, account, slots, proof)
        .map_err(|_| error!(VaultError::BadStateProof))
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
