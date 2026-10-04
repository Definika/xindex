//! Checkpoints, stall recovery and the snapshot exit's start (Stage B spec, section 5.6; design 6.9): the twin of the
//! EVM vault's. Anyone advances the checkpoint to a final Ethereum block P1 and P2 both prove. A week without one is a
//! stall: the vault takes no deposit, and the owner's emergency multisig may propose a successor pair, which must prove
//! the last checkpoint, a recent one and the last message, and waits 30 days with at most two vetoes by the freezer.
//! 180 days into a stall, the last checkpoint becomes the snapshot, for good.

use anchor_lang::prelude::*;

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::state::{Checkpoint, Config, Successor};
use crate::vault;
use crate::verify::{self, Calls, Log, PairProofs};

#[derive(Accounts)]
pub struct AdvanceCheckpoint<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// Anyone, before a snapshot exit: records a final Ethereum block both P1 and P2 prove, newer than the last, which is
/// what keeps the vault out of a stall. One recent enough to end a stall also lapses any successor under review and
/// starts the freezer's count again. A stale one, newer but still a stall's, which the pair in force can still prove up
/// to where it broke, only lets what was sent before the break run (VLT-3): the stall goes on, and so do its
/// successor's review and the count (LG-2). The remaining accounts are P1's program and accounts, then P2's.
pub fn handle_advance_checkpoint<'info>(
    ctx: Context<'info, AdvanceCheckpoint<'info>>,
    checkpoint: Checkpoint,
    proofs: PairProofs,
) -> Result<()> {
    let config = &mut ctx.accounts.config;
    vault::check_no_snapshot(config)?;
    let mut calls = Calls::new(ctx.remaining_accounts);
    verify::checkpoint_by_both(&mut calls, (&config.p1, &config.p2), &checkpoint, &proofs)?;
    let now = vault::now()?;
    vault::check_newer(config, &checkpoint, now)?;
    config.checkpoint = checkpoint;
    emit!(CheckpointAdvanced {
        block: checkpoint.block,
        timestamp: checkpoint.timestamp,
        state_root: checkpoint.state_root
    });
    if vault::stalled(config, now) {
        return Ok(());
    }
    // A recent one ends the stall: the pair in force works again.
    config.vetoes = 0;
    if config.successor.review_ends != 0 {
        config.successor = Successor::default();
        emit!(SuccessorLapsed {});
    }
    Ok(())
}

/// The last message the pair in force delivered on both proofs, as the successor proves it again: its payload, the
/// block its log is in, and the successor's proofs of that log.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct LastMessage {
    pub payload: Vec<u8>,
    pub block: u64,
    pub proofs: PairProofs,
}

/// What a successor pair must prove: the checkpoint the pair in force last accepted, a recent one, and the last message
/// delivered on both proofs, if there was one. The remaining accounts are the new P1's program and accounts then the new
/// P2's, for each of the three in that order.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Continuity {
    pub last: PairProofs,
    pub recent: Checkpoint,
    pub recent_proofs: PairProofs,
    pub message: Option<LastMessage>,
}

#[derive(Accounts)]
pub struct ProposeSuccessor<'info> {
    pub proposer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// CHECK: the new P1, a verifier program nobody can upgrade: checked in `check_immutable`.
    pub new_p1: UncheckedAccount<'info>,
    /// CHECK: the new P2, as the new P1.
    pub new_p2: UncheckedAccount<'info>,
    /// CHECK: the new P1's ProgramData account, when the upgradeable loader owns it; checked in `check_immutable`.
    pub new_p1_data: Option<UncheckedAccount<'info>>,
    /// CHECK: the new P2's, as the new P1's.
    pub new_p2_data: Option<UncheckedAccount<'info>>,
}

/// The recovery proposer only, while stalled, before a snapshot exit, with none under review: proposes a successor pair,
/// two different verifier programs nobody can upgrade (SOL-2), which must pass the continuity test.
pub fn handle_propose_successor<'info>(
    ctx: Context<'info, ProposeSuccessor<'info>>,
    continuity: Continuity,
) -> Result<()> {
    let accounts = ctx.accounts;
    let config = &mut accounts.config;
    require_keys_eq!(
        accounts.proposer.key(),
        config.recovery_proposer,
        VaultError::NotRecoveryProposer
    );
    vault::check_no_snapshot(config)?;
    let now = vault::now()?;
    require!(vault::stalled(config, now), VaultError::NotStalled);
    require!(
        config.successor.review_ends == 0,
        VaultError::SuccessorPending
    );
    let (p1, p2) = (accounts.new_p1.key(), accounts.new_p2.key());
    vault::check_immutable(
        &accounts.new_p1.to_account_info(),
        accounts.new_p1_data.as_ref().map(|d| d.as_ref()),
    )?;
    vault::check_immutable(
        &accounts.new_p2.to_account_info(),
        accounts.new_p2_data.as_ref().map(|d| d.as_ref()),
    )?;
    require_keys_neq!(p1, p2, VaultError::VerifiersNotDistinct);

    let mut calls = Calls::new(ctx.remaining_accounts);
    // (a) The last checkpoint the pair in force accepted.
    let last = config.checkpoint;
    verify::checkpoint_by_both(&mut calls, (&p1, &p2), &last, &continuity.last)?;
    // (b) A recent one, which the successor's proof shows descends from it.
    verify::checkpoint_by_both(
        &mut calls,
        (&p1, &p2),
        &continuity.recent,
        &continuity.recent_proofs,
    )?;
    vault::check_recent(config, &continuity.recent, now)?;
    // (c) The last message the pair in force delivered on both proofs, if there was one.
    if config.last_message != [0u8; 32] {
        let message = continuity
            .message
            .as_ref()
            .ok_or(VaultError::Discontinuous)?;
        let id = abi::message_id(&message.payload);
        require!(id == config.last_message, VaultError::Discontinuous);
        let log = Log {
            block: message.block,
            emitter: abi::index_in(&message.payload),
            id,
            data_hash: abi::log_data_hash(&message.payload),
        };
        verify::event_by_both(&mut calls, (&p1, &p2), &log, &message.proofs)?;
    }
    let review_ends = now + RECOVERY_DELAY;
    config.successor = Successor {
        p1,
        p2,
        review_ends,
    };
    emit!(SuccessorProposed {
        p1,
        p2,
        review_ends
    });
    Ok(())
}

#[derive(Accounts)]
pub struct VetoSuccessor<'info> {
    pub freezer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// The freezer only, at most MAX_RECOVERY_VETOES times a stall: drops the successor under review.
pub fn handle_veto_successor(ctx: Context<VetoSuccessor>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    require_keys_eq!(
        ctx.accounts.freezer.key(),
        config.freezer,
        VaultError::NotFreezer
    );
    require!(config.successor.review_ends != 0, VaultError::NoSuccessor);
    require!(
        config.vetoes < MAX_RECOVERY_VETOES,
        VaultError::VetoesExhausted
    );
    config.vetoes += 1;
    config.successor = Successor::default();
    emit!(SuccessorVetoed {
        vetoes: config.vetoes
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AdoptSuccessor<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2, which ends the
/// stall and the freezer's count. The remaining accounts are the successor's P1's program and accounts, then its P2's.
pub fn handle_adopt_successor<'info>(
    ctx: Context<'info, AdoptSuccessor<'info>>,
    checkpoint: Checkpoint,
    proofs: PairProofs,
) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let s = config.successor;
    // A snapshot clears any successor, and a checkpoint that ends the stall lapses it, so a pending one is still in its
    // stall.
    require!(s.review_ends != 0, VaultError::NoSuccessor);
    let now = vault::now()?;
    require!(now >= s.review_ends, VaultError::ReviewNotOver);
    let mut calls = Calls::new(ctx.remaining_accounts);
    verify::checkpoint_by_both(&mut calls, (&s.p1, &s.p2), &checkpoint, &proofs)?;
    vault::check_recent(config, &checkpoint, now)?;
    config.successor = Successor::default();
    config.vetoes = 0;
    config.p1 = s.p1;
    config.p2 = s.p2;
    config.checkpoint = checkpoint;
    emit!(SuccessorAdopted { p1: s.p1, p2: s.p2 });
    emit!(CheckpointAdvanced {
        block: checkpoint.block,
        timestamp: checkpoint.timestamp,
        state_root: checkpoint.state_root
    });
    Ok(())
}

#[derive(Accounts)]
pub struct BeginSnapshot<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// Anyone, SNAPSHOT_EXIT_DELAY after the stall began: takes the last checkpoint as the snapshot for good. From then on
/// no message from a later Ethereum block runs, and holders at it claim directly.
pub fn handle_begin_snapshot(ctx: Context<BeginSnapshot>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    vault::check_no_snapshot(config)?;
    let due = vault::stall_start(config).saturating_add(SNAPSHOT_EXIT_DELAY);
    require!(vault::now()? >= due, VaultError::SnapshotNotDue);
    let last = config.checkpoint;
    // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
    require!(last.state_root != [0u8; 32], VaultError::NoCheckpoint);
    config.snapshot = last;
    emit!(SnapshotBegun {
        block: last.block,
        timestamp: last.timestamp,
        state_root: last.state_root
    });
    if config.successor.review_ends != 0 {
        config.successor = Successor::default();
        emit!(SuccessorLapsed {});
    }
    Ok(())
}
