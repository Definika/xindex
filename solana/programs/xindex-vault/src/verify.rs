//! P1 and P2: the vault calls each verifier program's `verify_event` or `verify_checkpoint`, which must succeed for the
//! log or the checkpoint to count.
//!
//! The verifier interface, the Solana form of `IEthereumEventVerifier`. Instruction data is, by its first byte:
//! - `0`, verify_event: `block (u64, little-endian) ++ emitter (20) ++ topic0 (32) ++ topic1 (32) ++ keccak256(data)
//!   (32) ++ proof`. It succeeds only if the proof shows that log in a final Ethereum block. The log's data travels by
//!   its hash, so a message crosses a transaction once, not three times.
//! - `4`, verify_checkpoint: `block (u64) ++ timestamp (u64) ++ stateRoot (32) ++ proof`. It succeeds only if the proof
//!   shows that final Ethereum block, with that timestamp and state root.
//!
//! The accounts are the verifier's own. In the vault's remaining accounts each call takes the verifier's program, then
//! as many of its accounts as the caller says.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};
use anchor_lang::solana_program::program::invoke;

use crate::constants::EVENT_TOPIC;
use crate::error::VaultError;
use crate::state::{Checkpoint, Config};

pub const VERIFY_EVENT: u8 = 0;
pub const VERIFY_CHECKPOINT: u8 = 4;

/// The log a message arrives in, as the relayer claims it; the verifiers attest it.
pub struct Log {
    pub block: u64,
    pub emitter: [u8; 20],
    pub id: [u8; 32],
    pub data_hash: [u8; 32],
}

/// One claim proven by both verifiers of a pair: P1's proof and P2's, and how many accounts of its own each takes after
/// its program in the remaining accounts. An empty proof is the verifier's to read from its own accounts.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Default)]
pub struct PairProofs {
    pub proof1: Vec<u8>,
    pub proof2: Vec<u8>,
    pub accounts1: u8,
    pub accounts2: u8,
}

/// The remaining accounts, read call by call: each call takes a verifier's program, then its own accounts.
pub struct Calls<'a, 'info> {
    rest: &'a [AccountInfo<'info>],
}

impl<'a, 'info> Calls<'a, 'info> {
    pub fn new(remaining: &'a [AccountInfo<'info>]) -> Self {
        Self { rest: remaining }
    }

    /// The next call's program, which must be `expected`, and its `n` accounts; with `n` none, every account left.
    fn next(
        &mut self,
        expected: &Pubkey,
        n: Option<usize>,
    ) -> Result<(&'a AccountInfo<'info>, &'a [AccountInfo<'info>])> {
        let (program, tail) = self.rest.split_first().ok_or(VaultError::WrongVerifier)?;
        require_keys_eq!(program.key(), *expected, VaultError::WrongVerifier);
        let n = n.unwrap_or(tail.len());
        require!(tail.len() >= n, VaultError::WrongVerifier);
        self.rest = &tail[n..];
        Ok((program, &tail[..n]))
    }

    /// The accounts no call has taken.
    pub fn left(&self) -> &'a [AccountInfo<'info>] {
        self.rest
    }
}

fn call<'info>(
    program: &AccountInfo<'info>,
    accounts: &[AccountInfo<'info>],
    data: Vec<u8>,
) -> Result<()> {
    require!(program.executable, VaultError::WrongVerifier);
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

fn event_data(log: &Log, proof: &[u8]) -> Vec<u8> {
    let mut data = Vec::with_capacity(1 + 8 + 20 + 3 * 32 + proof.len());
    data.push(VERIFY_EVENT);
    data.extend_from_slice(&log.block.to_le_bytes());
    data.extend_from_slice(&log.emitter);
    data.extend_from_slice(&EVENT_TOPIC);
    data.extend_from_slice(&log.id);
    data.extend_from_slice(&log.data_hash);
    data.extend_from_slice(proof);
    data
}

fn checkpoint_data(c: &Checkpoint, proof: &[u8]) -> Vec<u8> {
    let mut data = Vec::with_capacity(1 + 8 + 8 + 32 + proof.len());
    data.push(VERIFY_CHECKPOINT);
    data.extend_from_slice(&c.block.to_le_bytes());
    data.extend_from_slice(&c.timestamp.to_le_bytes());
    data.extend_from_slice(&c.state_root);
    data.extend_from_slice(proof);
    data
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
    let mut calls = Calls::new(remaining);
    if let Some(proof) = proof1 {
        let (program, accounts) = calls.next(&config.p1, Some(p1_accounts as usize))?;
        call(program, accounts, event_data(log, proof))?;
    }
    if let Some(proof) = proof2 {
        let (program, accounts) = calls.next(&config.p2, None)?;
        call(program, accounts, event_data(log, proof))?;
    }
    require!(proof1.is_some() || proof2.is_some(), VaultError::NoProof);
    Ok(proof1.is_some() && proof2.is_some())
}

/// Both verifiers `pair` prove checkpoint `c`, as `_agreed` requires: the same block, timestamp and state root.
pub fn checkpoint_by_both<'info>(
    calls: &mut Calls<'_, 'info>,
    pair: (&Pubkey, &Pubkey),
    c: &Checkpoint,
    proofs: &PairProofs,
) -> Result<()> {
    let (program, accounts) = calls.next(pair.0, Some(proofs.accounts1 as usize))?;
    call(program, accounts, checkpoint_data(c, &proofs.proof1))?;
    let (program, accounts) = calls.next(pair.1, Some(proofs.accounts2 as usize))?;
    call(program, accounts, checkpoint_data(c, &proofs.proof2))
}

/// Both verifiers `pair` prove `log`.
pub fn event_by_both<'info>(
    calls: &mut Calls<'_, 'info>,
    pair: (&Pubkey, &Pubkey),
    log: &Log,
    proofs: &PairProofs,
) -> Result<()> {
    let (program, accounts) = calls.next(pair.0, Some(proofs.accounts1 as usize))?;
    call(program, accounts, event_data(log, &proofs.proof1))?;
    let (program, accounts) = calls.next(pair.1, Some(proofs.accounts2 as usize))?;
    call(program, accounts, event_data(log, &proofs.proof2))
}
