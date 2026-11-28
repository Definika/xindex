// SPDX-License-Identifier: BUSL-1.1
//! The configuration's roles: the owner, handed on in two steps, and the guardian, changed behind `GUARDIAN_DELAY`.

use anchor_lang::prelude::*;

use crate::{constants::*, error::XindexError, events::*, program::Xindex, state::Config};

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ XindexError::NotUpgradeAuthority)]
    pub program: Program<'info, Xindex>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ XindexError::NotUpgradeAuthority)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

/// Sets the owner, the guardian and the two stablecoins once. Only the program's upgrade authority may, so nobody
/// claims the configuration between the deployment and its first instruction.
pub fn handle_initialize(
    ctx: Context<Initialize>,
    owner: Pubkey,
    guardian: Pubkey,
    usdc: Pubkey,
    usdt: Pubkey,
) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.owner = owner;
    config.pending_owner = Pubkey::default();
    config.guardian = guardian;
    config.pending_guardian = Pubkey::default();
    config.pending_guardian_eta = 0;
    config.platform_recipient = Pubkey::default();
    config.platform_fee_bps = 0;
    config.platform_streaming_bps = 0;
    config.referral_share_bps = 0;
    config.mint_paused_all = false;
    config.usdc = usdc;
    config.usdt = usdt;
    config.bump = ctx.bumps.config;
    emit!(OwnershipTransferred {
        previous: Pubkey::default(),
        owner
    });
    emit!(GuardianChanged {
        previous: Pubkey::default(),
        guardian
    });
    Ok(())
}

#[derive(Accounts)]
pub struct OwnerOnly<'info> {
    pub owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
}

/// Offers the owner's role to `pending_owner`, which takes it with `accept_ownership`. The default key withdraws an
/// offer.
pub fn handle_transfer_ownership(ctx: Context<OwnerOnly>, pending_owner: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pending_owner = pending_owner;
    emit!(OwnershipTransferStarted {
        owner: config.owner,
        pending_owner
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptOwnership<'info> {
    pub pending_owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = pending_owner @ XindexError::NotPendingOwner)]
    pub config: Account<'info, Config>,
}

pub fn handle_accept_ownership(ctx: Context<AcceptOwnership>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let previous = config.owner;
    config.owner = config.pending_owner;
    config.pending_owner = Pubkey::default();
    emit!(OwnershipTransferred {
        previous,
        owner: config.owner
    });
    Ok(())
}

/// Proposes `guardian`, executable from `GUARDIAN_DELAY` for `PROPOSAL_WINDOW`. The default key removes the role.
pub fn handle_propose_guardian(ctx: Context<OwnerOnly>, guardian: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let eta = Clock::get()?.unix_timestamp + GUARDIAN_DELAY;
    config.pending_guardian = guardian;
    config.pending_guardian_eta = eta;
    emit!(GuardianChangeProposed { guardian, eta });
    Ok(())
}

#[derive(Accounts)]
pub struct ExecuteGuardian<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// Anyone executes a guardian change within its window.
pub fn handle_execute_guardian(ctx: Context<ExecuteGuardian>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let eta = config.pending_guardian_eta;
    require!(eta != 0, XindexError::NothingPending);
    let now = Clock::get()?.unix_timestamp;
    require!(now >= eta, XindexError::TooEarly);
    require!(now <= eta + PROPOSAL_WINDOW, XindexError::ProposalExpired);
    let previous = config.guardian;
    config.guardian = config.pending_guardian;
    config.pending_guardian = Pubkey::default();
    config.pending_guardian_eta = 0;
    emit!(GuardianChanged {
        previous,
        guardian: config.guardian
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CancelGuardian<'info> {
    pub signer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// The owner cancels a guardian change; the guardian cancels only one that would remove the role, so it cannot block
/// its own replacement.
pub fn handle_cancel_guardian(ctx: Context<CancelGuardian>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    require!(
        config.pending_guardian_eta != 0,
        XindexError::NothingPending
    );
    let signer = ctx.accounts.signer.key();
    let removal = config.pending_guardian == Pubkey::default();
    require!(
        signer == config.owner
            || (removal && signer == config.guardian && signer != Pubkey::default()),
        XindexError::NotOwnerOrGuardian
    );
    let guardian = config.pending_guardian;
    config.pending_guardian = Pubkey::default();
    config.pending_guardian_eta = 0;
    emit!(GuardianChangeCancelled { guardian });
    Ok(())
}
