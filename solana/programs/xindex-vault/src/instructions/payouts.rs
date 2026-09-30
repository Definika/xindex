use anchor_lang::prelude::*;

use crate::constants::*;
use crate::error::VaultError;
use crate::instructions::messages::{credit_migration, freeze_until};
use crate::state::{Config, IndexState, Owed};
use crate::vault;

#[derive(Accounts)]
#[instruction(index: [u8; 20], id: [u8; 32])]
pub struct Release<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [INDEX_SEED, index.as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(
        mut,
        seeds = [OWED_SEED, index.as_ref(), id.as_ref()],
        bump = owed.bump,
        constraint = !owed.to_index @ VaultError::WrongRecipient
    )]
    pub owed: Account<'info, Owed>,
    /// CHECK: the owed burn's recipient; it receives lamports only.
    #[account(mut, address = owed.recipient @ VaultError::WrongRecipient)]
    pub recipient: UncheckedAccount<'info>,
    #[account(mut, seeds = [TREASURY_SEED], bump = config.treasury_bump)]
    pub treasury: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Anyone, while not frozen: pays what the speed limit now allows of an owed burn.
pub fn handle_release(ctx: Context<Release>, _index: [u8; 20], _id: [u8; 32]) -> Result<()> {
    let accounts = ctx.accounts;
    let min_pay = vault::min_payout(&accounts.recipient.to_account_info())?;
    let pay = vault::pay_owed(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        true,
        min_pay,
    )?;
    let config = &mut accounts.config;
    config.held -= pay;
    vault::refresh_index(
        &mut accounts.index_state,
        config.chain_id,
        &vault::vault_address(&config.key()),
    );
    vault::send(
        &accounts.treasury.to_account_info(),
        &accounts.recipient.to_account_info(),
        &accounts.system_program.to_account_info(),
        config.treasury_bump,
        pay,
    )
}

#[derive(Accounts)]
#[instruction(index: [u8; 20], id: [u8; 32])]
pub struct ReleaseMigration<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [INDEX_SEED, index.as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(
        mut,
        seeds = [OWED_SEED, index.as_ref(), id.as_ref()],
        bump = owed.bump,
        constraint = owed.to_index @ VaultError::WrongRecipient
    )]
    pub owed: Account<'info, Owed>,
    #[account(mut, seeds = [INDEX_SEED, owed.new_index.as_ref()], bump = new_index_state.bump)]
    pub new_index_state: Account<'info, IndexState>,
}

/// Anyone, while not frozen: moves what the speed limit now allows of an owed migration into the new index.
pub fn handle_release_migration(
    ctx: Context<ReleaseMigration>,
    _index: [u8; 20],
    _id: [u8; 32],
) -> Result<()> {
    let accounts = ctx.accounts;
    let pay = vault::pay_owed(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        true,
        0,
    )?;
    credit_migration(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.new_index_state,
        pay,
    );
    Ok(())
}

#[derive(Accounts)]
pub struct Freeze<'info> {
    pub freezer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// The guardian's freeze key only: freezes the vault for FREEZE_DURATION from now.
pub fn handle_freeze(ctx: Context<Freeze>) -> Result<()> {
    require_keys_eq!(
        ctx.accounts.freezer.key(),
        ctx.accounts.config.freezer,
        VaultError::NotFreezer
    );
    freeze_until(
        &mut ctx.accounts.config,
        vault::now()?,
        ctx.accounts.freezer.key(),
    );
    Ok(())
}
