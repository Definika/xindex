//! Messages from Ethereum, one instruction per kind, each naming only the accounts its kind touches. Every one runs
//! the checks of the EVM vault's `deliver`: after a snapshot, no block past it; the canonical encoding, the route, the
//! emitter, the proofs; for a message that moves coins or loosens a rule, both proofs and a checkpoint covering its
//! block (VLT-3); and a used mark created at an address the message id derives, so a message runs at most once. The id,
//! the index and every account address come from the payload itself, which keeps a message within one transaction.

use anchor_lang::prelude::*;

use crate::abi::{self, Message};
use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::instructions::governance;
use crate::state::{Config, IndexState, Intake, Owed, PendingChange, Used};
use crate::vault;
use crate::verify::{self, Log};

/// A message's proofs: the block the relayer claims its log is in, P1's proof, P2's or both, and how many of the
/// remaining accounts after P1's program are P1's own.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Proofs {
    pub block: u64,
    pub proof1: Option<Vec<u8>>,
    pub proof2: Option<Vec<u8>>,
    pub p1_accounts: u8,
}

/// Checks the message and its proofs; returns it decoded, its id, and whether both proofs carried it. The log's
/// emitter the verifiers must attest is the index the message names, or the factory for a governance kind. Only a
/// message on both proofs becomes the last message a successor must prove again: one broken proof system could forge
/// a one-proof freeze, which no honest successor could prove (LG-3).
fn accept<'a, 'info>(
    config: &mut Account<'info, Config>,
    payload: &'a [u8],
    proofs: &Proofs,
    remaining: &[AccountInfo<'info>],
    kinds: &[u8],
) -> Result<(Message<'a>, [u8; 32], bool)> {
    // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
    let snapshot = config.snapshot.block;
    require!(
        snapshot == 0 || proofs.block <= snapshot,
        VaultError::IssuedAfterSnapshot
    );
    let id = abi::message_id(payload);
    let m = abi::decode_message(payload)?;
    require!(kinds.contains(&m.kind), VaultError::UnknownKind);
    check_route(config, &m)?;
    // Any Ethereum contract can emit a message naming itself; a governance kind is the factory's alone.
    require!(
        m.kind < CAP_UPDATE || m.index == config.factory,
        VaultError::WrongEmitter
    );
    let log = Log {
        block: proofs.block,
        emitter: m.index,
        id,
        data_hash: abi::log_data_hash(payload),
    };
    let both = verify::verify(
        config,
        remaining,
        &log,
        &proofs.proof1,
        &proofs.proof2,
        proofs.p1_accounts,
    )?;
    if both {
        config.last_message = id;
    }
    emit!(MessageDelivered {
        id,
        kind: m.kind,
        index: m.index
    });
    Ok((m, id, both))
}

/// The message is Ethereum's, for this chain and this vault.
pub fn check_route(config: &Account<Config>, m: &Message) -> Result<()> {
    require!(
        m.source_chain_id == config.source_chain_id
            && m.dest_chain_id == config.chain_id
            && m.vault == config.key().to_bytes(),
        VaultError::WrongRoute
    );
    Ok(())
}

/// A message that moves coins or loosens a rule: on both proofs, from a block the checkpoint covers (VLT-3).
fn check_loosening(config: &Config, both: bool, block: u64) -> Result<()> {
    require!(both, VaultError::BothProofsRequired);
    vault::check_checkpointed(config, block)
}

/// A body word that must be zero: Stage B's Solana vault holds SOL only, `address(0)` on Ethereum.
pub fn check_native(word: &[u8; 32]) -> Result<()> {
    require!(*word == [0u8; 32], VaultError::NotNative);
    Ok(())
}

// ---------------------------------------------------------------------
// BURN
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverBurn<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(init, payer = payer, space = 8 + Used::INIT_SPACE, seeds = [USED_SEED, abi::message_id(&payload).as_ref()], bump)]
    pub used: Account<'info, Used>,
    #[account(mut, seeds = [INDEX_SEED, abi::index_in(&payload).as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(
        init,
        payer = payer,
        space = 8 + Owed::INIT_SPACE,
        seeds = [OWED_SEED, abi::index_in(&payload).as_ref(), abi::message_id(&payload).as_ref()],
        bump
    )]
    pub owed: Account<'info, Owed>,
    /// CHECK: the recipient the message names, checked against it; it receives lamports only.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,
    #[account(mut, seeds = [TREASURY_SEED], bump = config.treasury_bump)]
    pub treasury: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Anyone, with both proofs: a burn from an index pays its recipient what the speed limit allows now and owes the rest.
pub fn handle_deliver_burn<'info>(
    ctx: Context<'info, DeliverBurn<'info>>,
    payload: Vec<u8>,
    proofs: Proofs,
) -> Result<()> {
    let (m, id, both) = accept(
        &mut ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[BURN],
    )?;
    check_loosening(&ctx.accounts.config, both, proofs.block)?;
    burn(ctx.accounts, ctx.bumps.used, ctx.bumps.owed, &m, id)
}

/// Runs a burn accepted from Ethereum, delivered or recorded.
pub fn burn(
    accounts: &mut DeliverBurn,
    used_bump: u8,
    owed_bump: u8,
    m: &Message,
    id: [u8; 32],
) -> Result<()> {
    let index = m.index;
    check_native(abi::body_word(m.body, 3, 0)?)?;
    let amount = abi::to_u64(abi::body_word(m.body, 3, 1)?)?;
    let recipient = Pubkey::new_from_array(*abi::body_word(m.body, 3, 2)?);
    require!(amount != 0, VaultError::ZeroAmount);
    require!(recipient != Pubkey::default(), VaultError::ZeroAddress);
    require_keys_eq!(
        recipient,
        accounts.recipient.key(),
        VaultError::WrongRecipient
    );
    // The treasury, or any account of this program, would strand the payout (SOL-9).
    require!(
        recipient != accounts.treasury.key() && *accounts.recipient.owner != crate::ID,
        VaultError::WrongRecipient
    );

    accounts.used.bump = used_bump;
    accounts.owed.set_inner(Owed {
        index,
        id,
        to_index: false,
        recipient,
        new_index: [0u8; 20],
        remaining: amount,
        bump: owed_bump,
    });
    emit!(BurnAccepted {
        index,
        id,
        amount,
        recipient
    });
    pay_recipient(
        &mut accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        &accounts.recipient,
        &accounts.treasury,
        &accounts.system_program,
    )
}

/// Pays what the speed limit allows now of `owed`, to its recipient, and leaves the rest owed.
pub fn pay_recipient<'info>(
    config: &mut Account<'info, Config>,
    index_state: &mut Account<'info, IndexState>,
    owed: &mut Account<'info, Owed>,
    recipient: &UncheckedAccount<'info>,
    treasury: &SystemAccount<'info>,
    system_program: &Program<'info, System>,
) -> Result<()> {
    let min_pay = vault::min_payout(&recipient.to_account_info())?;
    let pay = vault::pay_owed(config, index_state, owed, false, min_pay)?;
    if pay == 0 {
        return Ok(());
    }
    config.held -= pay;
    vault::refresh_index(
        index_state,
        config.chain_id,
        &vault::vault_id(&config.key()),
    );
    vault::send(
        &treasury.to_account_info(),
        &recipient.to_account_info(),
        &system_program.to_account_info(),
        config.treasury_bump,
        pay,
    )
}

// ---------------------------------------------------------------------
// INTAKE_SETTLED, INTAKE_FAILED
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverIntake<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(init, payer = payer, space = 8 + Used::INIT_SPACE, seeds = [USED_SEED, abi::message_id(&payload).as_ref()], bump)]
    pub used: Account<'info, Used>,
    #[account(mut, seeds = [INDEX_SEED, abi::index_in(&payload).as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + Intake::INIT_SPACE,
        seeds = [INTAKE_SEED, abi::index_in(&payload).as_ref(), abi::body_word_in(&payload, 0).as_ref()],
        bump
    )]
    pub intake: Account<'info, Intake>,
    pub system_program: Program<'info, System>,
}

/// Anyone, with both proofs: an intake's deposits join the index, or its depositors can take them back.
pub fn handle_deliver_intake<'info>(
    ctx: Context<'info, DeliverIntake<'info>>,
    payload: Vec<u8>,
    proofs: Proofs,
) -> Result<()> {
    let (m, _, both) = accept(
        &mut ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[INTAKE_SETTLED, INTAKE_FAILED],
    )?;
    check_loosening(&ctx.accounts.config, both, proofs.block)?;
    let index = m.index;
    let intake_id = *abi::body_word(m.body, 1, 0)?;

    let accounts = ctx.accounts;
    accounts.used.bump = ctx.bumps.used;
    let intake = &mut accounts.intake;
    match intake.state {
        INTAKE_NONE => {
            intake.index = index;
            intake.intake_id = intake_id;
            intake.bump = ctx.bumps.intake;
        }
        INTAKE_OPEN => {}
        _ => return err!(VaultError::IntakeNotOpen),
    }
    resolve(
        &accounts.config,
        &mut accounts.index_state,
        intake,
        m.kind == INTAKE_SETTLED,
    );
    Ok(())
}

/// Settles an open intake, whose deposits join the index, or fails it, so its depositors can take them back.
pub fn resolve(
    config: &Account<Config>,
    index_state: &mut IndexState,
    intake: &mut Intake,
    settle: bool,
) {
    let vault_id = vault::vault_id(&config.key());
    let chain_id = config.chain_id;
    let (index, intake_id) = (intake.index, intake.intake_id);
    if settle {
        intake.state = INTAKE_SETTLED_STATE;
        if intake.has_native {
            index_state.balance += intake.total;
            index_state.has_native = true;
            vault::refresh_index(index_state, chain_id, &vault_id);
        }
        vault::refresh_intake(intake, chain_id, &vault_id);
        emit!(IntakeSettled { index, intake_id });
    } else {
        intake.state = INTAKE_FAILED_STATE;
        vault::refresh_intake(intake, chain_id, &vault_id);
        emit!(IntakeFailed { index, intake_id });
    }
}

// ---------------------------------------------------------------------
// MIGRATE
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverMigrate<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(init, payer = payer, space = 8 + Used::INIT_SPACE, seeds = [USED_SEED, abi::message_id(&payload).as_ref()], bump)]
    pub used: Account<'info, Used>,
    #[account(mut, seeds = [INDEX_SEED, abi::index_in(&payload).as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    /// Exists only once registered.
    #[account(mut, seeds = [INDEX_SEED, abi::address_in_body(&payload, 0).as_ref()], bump = new_index_state.bump)]
    pub new_index_state: Account<'info, IndexState>,
    #[account(
        init,
        payer = payer,
        space = 8 + Owed::INIT_SPACE,
        seeds = [OWED_SEED, abi::index_in(&payload).as_ref(), abi::message_id(&payload).as_ref()],
        bump
    )]
    pub owed: Account<'info, Owed>,
    pub system_program: Program<'info, System>,
}

/// Anyone, with both proofs: moves coins two index versions share from the old index's balance to the new one's, within
/// the speed limit, as a burn leaves (Stage B spec, section 5.5). The coins never leave the vault.
pub fn handle_deliver_migrate<'info>(
    ctx: Context<'info, DeliverMigrate<'info>>,
    payload: Vec<u8>,
    proofs: Proofs,
) -> Result<()> {
    let (m, id, both) = accept(
        &mut ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[MIGRATE],
    )?;
    check_loosening(&ctx.accounts.config, both, proofs.block)?;
    migrate(ctx.accounts, ctx.bumps.used, ctx.bumps.owed, &m, id)
}

/// Runs a migration accepted from Ethereum, delivered or recorded.
pub fn migrate(
    accounts: &mut DeliverMigrate,
    used_bump: u8,
    owed_bump: u8,
    m: &Message,
    id: [u8; 32],
) -> Result<()> {
    let index = m.index;
    let new_index = abi::to_address(abi::body_word(m.body, 3, 0)?)?;
    require!(new_index != index, VaultError::NotAnIndex);
    check_native(abi::body_word(m.body, 3, 1)?)?;
    let amount = abi::to_u64(abi::body_word(m.body, 3, 2)?)?;
    require!(amount != 0, VaultError::ZeroAmount);

    accounts.used.bump = used_bump;
    accounts.owed.set_inner(Owed {
        index,
        id,
        to_index: true,
        recipient: Pubkey::default(),
        new_index,
        remaining: amount,
        bump: owed_bump,
    });
    emit!(MigrationAccepted {
        index,
        id,
        amount,
        new_index
    });
    let pay = vault::pay_owed(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        false,
        0,
    )?;
    if pay != 0 {
        credit_migration(
            &accounts.config,
            &mut accounts.index_state,
            &mut accounts.new_index_state,
            pay,
        );
    }
    Ok(())
}

/// Moves `pay` into the new index's balance; `held` stays, since the coins stay in the vault.
pub fn credit_migration(
    config: &Account<Config>,
    old: &mut IndexState,
    new: &mut IndexState,
    pay: u64,
) {
    let vault_id = vault::vault_id(&config.key());
    new.balance += pay;
    new.has_native = true;
    vault::refresh_index(old, config.chain_id, &vault_id);
    vault::refresh_index(new, config.chain_id, &vault_id);
}

// ---------------------------------------------------------------------
// Governance: CAP_UPDATE, FREEZE, FREEZER_CHANGE, VERIFIER_ROTATION
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverGovernance<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// Taken if needed: a cut first taken on one proof may come again (A3-02); the handler refuses everything else.
    #[account(init_if_needed, payer = payer, space = 8 + Used::INIT_SPACE, seeds = [USED_SEED, abi::message_id(&payload).as_ref()], bump)]
    pub used: Account<'info, Used>,
    pub system_program: Program<'info, System>,
}

/// Anyone: a governance message from the factory. A freeze, and a cap update raising neither figure, apply at once and
/// may rest on one proof. A raise, a new freezer and new verifiers need both, then wait GOVERNANCE_DELAY here, where
/// the freezer can see them and stop a raise or a rotation, however their proofs were obtained (VLT-2).
pub fn handle_deliver_governance<'info>(
    ctx: Context<'info, DeliverGovernance<'info>>,
    payload: Vec<u8>,
    proofs: Proofs,
) -> Result<()> {
    let (m, _, both) = accept(
        &mut ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[CAP_UPDATE, FREEZE, FREEZER_CHANGE, VERIFIER_ROTATION],
    )?;
    let block = proofs.block;
    let accounts = ctx.accounts;
    // A message runs once. A cut taken on one proof moves no mark (VLT-4), so it stays deliverable on both, which moves
    // the mark past an older raise; until then a replay on one proof only applies it again (A3-02). A freeze is used up
    // at once.
    let used = &mut accounts.used;
    require!(!used.taken || used.open, VaultError::AlreadyDelivered);
    used.bump = ctx.bumps.used;
    used.taken = true;
    used.open = !both && m.kind != FREEZE;
    let config = &mut accounts.config;
    // The factory's nonce only rises: an older message of a kind, delivered late, cannot undo a newer one (SOL-3). Only
    // one on both proofs moves the mark, so a single broken proof system cannot lock the factory out with a forged
    // nonce (VLT-4). A freeze only protects, so any freeze may run.
    if m.kind != FREEZE {
        let last = match m.kind {
            CAP_UPDATE => &mut config.cap_nonce,
            FREEZER_CHANGE => &mut config.freezer_nonce,
            _ => &mut config.rotation_nonce,
        };
        require!(m.nonce > *last, VaultError::StaleGovernance);
        if both {
            *last = m.nonce;
        }
    }
    let now = vault::now()?;
    match m.kind {
        CAP_UPDATE => {
            let (cap, floor) = governance::read_cap(m.body)?;
            if cap <= config.cap && floor <= config.outflow_floor {
                // Newer than a waiting raise, which it replaces.
                config.pending_cap = PendingChange::default();
                governance::set_cap(config, cap, floor);
            } else {
                check_loosening(config, both, block)?;
                governance::queue(&mut config.pending_cap, m.kind, m.body, now);
            }
        }
        FREEZE => {
            let end = abi::freeze_end(m.body, now)?;
            // Nothing could replace the freezer after a snapshot, and nothing may hold the exit off (VLT-5).
            vault::check_no_snapshot(config)?;
            // Only until the factory's own freeze ends: one delivered after it freezes nothing (A3-03).
            if let Some(end) = end {
                freeze_until(config, end, Pubkey::default());
            }
        }
        FREEZER_CHANGE => {
            check_loosening(config, both, block)?;
            abi::body_word(m.body, 1, 0)?;
            governance::queue(&mut config.pending_freezer, m.kind, m.body, now);
        }
        _ => {
            check_loosening(config, both, block)?;
            abi::body_word(m.body, 2, 0)?;
            governance::queue(&mut config.pending_rotation, m.kind, m.body, now);
        }
    }
    Ok(())
}

/// Freezes the vault until `until`: FREEZE_DURATION from now for the freezer, the factory's own freeze's end for its
/// message. A later freeze extends it, and none shortens it. `by` is the freezer, or the default key for the factory's
/// message.
pub fn freeze_until(config: &mut Config, until: i64, by: Pubkey) {
    if until > config.frozen_until {
        config.frozen_until = until;
    }
    emit!(Frozen {
        until: config.frozen_until,
        by
    });
}
