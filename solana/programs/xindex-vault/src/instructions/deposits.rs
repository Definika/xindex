use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::{Deposited, Refunded};
use crate::state::{Config, DepositRecord, IndexState, Intake};
use crate::vault;

#[derive(Accounts)]
#[instruction(index: [u8; 20], intake_id: [u8; 32])]
pub struct Deposit<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// Exists only once registered.
    #[account(seeds = [INDEX_SEED, index.as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(
        init_if_needed,
        payer = depositor,
        space = 8 + Intake::INIT_SPACE,
        seeds = [INTAKE_SEED, index.as_ref(), intake_id.as_ref()],
        bump
    )]
    pub intake: Account<'info, Intake>,
    #[account(
        init_if_needed,
        payer = depositor,
        space = 8 + DepositRecord::INIT_SPACE,
        seeds = [DEPOSIT_SEED, index.as_ref(), intake_id.as_ref(), depositor.key().as_ref()],
        bump
    )]
    pub deposit_record: Account<'info, DepositRecord>,
    #[account(mut, seeds = [TREASURY_SEED], bump = config.treasury_bump)]
    pub treasury: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Anyone, while not frozen: deposits `amount` lamports into intake `intake_id` of `index`. The intake's deadline is its
/// id's top 64 bits: nobody can open another's intake with another deadline, and deposits close at it for everyone.
pub fn handle_deposit(
    ctx: Context<Deposit>,
    index: [u8; 20],
    intake_id: [u8; 32],
    amount: u64,
) -> Result<()> {
    let now = vault::now()?;
    vault::check_not_frozen(&ctx.accounts.config, now)?;
    require!(amount != 0, VaultError::ZeroAmount);
    let deadline = abi::deadline_of(&intake_id);
    require!(now as u64 <= deadline, VaultError::IntakeClosed);
    let intake = &mut ctx.accounts.intake;
    match intake.state {
        INTAKE_NONE => {
            require!(
                deadline <= (now + MAX_INTAKE_LIFE) as u64,
                VaultError::IntakeTooLong
            );
            intake.index = index;
            intake.intake_id = intake_id;
            intake.state = INTAKE_OPEN;
            intake.bump = ctx.bumps.intake;
        }
        INTAKE_OPEN => {}
        _ => return err!(VaultError::IntakeClosed),
    }
    let config = &mut ctx.accounts.config;
    let held = config
        .held
        .checked_add(amount)
        .ok_or(VaultError::CapExceeded)?;
    require!(held <= config.cap, VaultError::CapExceeded);
    config.held = held;
    let record = &mut ctx.accounts.deposit_record;
    record.amount += amount;
    record.bump = ctx.bumps.deposit_record;
    intake.total += amount;
    intake.has_native = true;
    vault::refresh_intake(
        intake,
        config.chain_id,
        &vault::vault_address(&config.key()),
    );
    emit!(Deposited {
        index,
        intake_id,
        depositor: ctx.accounts.depositor.key(),
        amount
    });

    transfer(
        CpiContext::new(
            ctx.accounts.system_program.key(),
            Transfer {
                from: ctx.accounts.depositor.to_account_info(),
                to: ctx.accounts.treasury.to_account_info(),
            },
        ),
        amount,
    )
}

#[derive(Accounts)]
#[instruction(index: [u8; 20], intake_id: [u8; 32])]
pub struct Refund<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [INTAKE_SEED, index.as_ref(), intake_id.as_ref()], bump = intake.bump)]
    pub intake: Account<'info, Intake>,
    #[account(
        mut,
        seeds = [DEPOSIT_SEED, index.as_ref(), intake_id.as_ref(), depositor.key().as_ref()],
        bump = deposit_record.bump
    )]
    pub deposit_record: Account<'info, DepositRecord>,
    #[account(mut, seeds = [TREASURY_SEED], bump = config.treasury_bump)]
    pub treasury: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// A depositor of a failed intake, while not frozen: takes its deposit back.
pub fn handle_refund(ctx: Context<Refund>, index: [u8; 20], intake_id: [u8; 32]) -> Result<()> {
    require!(
        ctx.accounts.intake.state == INTAKE_FAILED_STATE,
        VaultError::IntakeNotOpen
    );
    vault::check_not_frozen(&ctx.accounts.config, vault::now()?)?;
    let amount = ctx.accounts.deposit_record.amount;
    require!(amount != 0, VaultError::NothingToRefund);
    ctx.accounts.deposit_record.amount = 0;
    let config = &mut ctx.accounts.config;
    config.held -= amount;
    let intake = &mut ctx.accounts.intake;
    intake.total -= amount;
    vault::refresh_intake(
        intake,
        config.chain_id,
        &vault::vault_address(&config.key()),
    );
    emit!(Refunded {
        index,
        intake_id,
        depositor: ctx.accounts.depositor.key(),
        amount
    });
    vault::send(
        &ctx.accounts.treasury.to_account_info(),
        &ctx.accounts.depositor.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        ctx.accounts.config.treasury_bump,
        amount,
    )
}
