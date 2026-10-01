//! P1 and P2: the vault calls each verifier program's `verify_event`, which must succeed for the log to count.
//!
//! The verifier interface, the Solana form of `IEthereumEventVerifier`: instruction data is
//! `[VERIFY_EVENT] ++ block (u64, little-endian) ++ emitter (20) ++ topic0 (32) ++ topic1 (32) ++ keccak256(data) (32)
//! ++ proof`, and the accounts are the verifier's own. It succeeds only if the proof shows that log in a final Ethereum
//! block. The log's data travels by its hash, so a message crosses a transaction once, not three times.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};
use anchor_lang::solana_program::program::invoke;

use crate::constants::EVENT_TOPIC;
use crate::error::VaultError;
use crate::state::Config;

pub const VERIFY_EVENT: u8 = 0;

/// The log a message arrives in, as the relayer claims it; the verifiers attest it.
pub struct Log {
    pub block: u64,
    pub emitter: [u8; 20],
    pub id: [u8; 32],
    pub data_hash: [u8; 32],
}

fn call<'info>(
    program: &AccountInfo<'info>,
    accounts: &[AccountInfo<'info>],
    log: &Log,
    proof: &[u8],
) -> Result<()> {
    require!(program.executable, VaultError::WrongVerifier);
    let mut data = Vec::with_capacity(1 + 8 + 20 + 3 * 32 + proof.len());
    data.push(VERIFY_EVENT);
    data.extend_from_slice(&log.block.to_le_bytes());
    data.extend_from_slice(&log.emitter);
    data.extend_from_slice(&EVENT_TOPIC);
    data.extend_from_slice(&log.id);
    data.extend_from_slice(&log.data_hash);
    data.extend_from_slice(proof);
    let metas = accounts
        .iter()
        .map(|a| AccountMeta {
            pubkey: a.key(),
            is_signer: a.is_signer,
            is_writable: false,
        })
        .collect();
    let mut infos = accounts.to_vec();
    infos.push(program.clone());
    invoke(
        &Instruction {
            program_id: program.key(),
            accounts: metas,
            data,
        },
        &infos,
    )?;
    Ok(())
}

/// Runs P1, P2 or both on `log`. The remaining accounts are P1's program and its `p1_accounts` accounts, when
/// `proof1` is given, then P2's program and every account after it, when `proof2` is. Returns whether both proved it.
pub fn verify<'info>(
    config: &Config,
    remaining: &[AccountInfo<'info>],
    log: &Log,
    proof1: &Option<Vec<u8>>,
    proof2: &Option<Vec<u8>>,
    p1_accounts: u8,
) -> Result<bool> {
    let mut rest = remaining;
    if let Some(proof) = proof1 {
        let (program, tail) = rest.split_first().ok_or(VaultError::WrongVerifier)?;
        require_keys_eq!(program.key(), config.p1, VaultError::WrongVerifier);
        let n = p1_accounts as usize;
        require!(tail.len() >= n, VaultError::WrongVerifier);
        call(program, &tail[..n], log, proof)?;
        rest = &tail[n..];
    }
    if let Some(proof) = proof2 {
        let (program, tail) = rest.split_first().ok_or(VaultError::WrongVerifier)?;
        require_keys_eq!(program.key(), config.p2, VaultError::WrongVerifier);
        call(program, tail, log, proof)?;
    }
    require!(proof1.is_some() || proof2.is_some(), VaultError::NoProof);
    Ok(proof1.is_some() && proof2.is_some())
}
