//! Messages from Ethereum, one instruction per kind, each naming only the accounts its kind touches. Every one runs
//! the checks of the EVM vault's `deliver`: the canonical encoding, the route, the emitter, the proofs, and a used
//! mark created at an address the message id derives, so a message runs at most once. The id, the index and every
//! account address come from the payload itself, which keeps a message within one transaction.

use anchor_lang::prelude::*;

use crate::abi::{self, Message};
use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::state::{Config, IndexState, Intake, Owed, Used};
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
/// emitter the verifiers must attest is the index the message names, or the factory for a governance kind.
fn accept<'a, 'info>(
    config: &Account<'info, Config>,
    payload: &'a [u8],
    proofs: &Proofs,
    remaining: &[AccountInfo<'info>],
    kinds: &[u8],
) -> Result<(Message<'a>, [u8; 32], bool)> {
    let id = abi::message_id(payload);
    let m = abi::decode_message(payload)?;
    require!(kinds.contains(&m.kind), VaultError::UnknownKind);
    require!(
        m.source_chain_id == config.source_chain_id
            && m.dest_chain_id == config.chain_id
            && m.vault == config.key().to_bytes(),
        VaultError::WrongRoute
    );
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
    emit!(MessageDelivered {
        id,
        kind: m.kind,
        index: m.index
    });
    Ok((m, id, both))
}

/// A body word that must be zero: Stage B's Solana vault holds SOL only, `address(0)` on Ethereum.
fn check_native(word: &[u8; 32]) -> Result<()> {
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
        &ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[BURN],
    )?;
    require!(both, VaultError::BothProofsRequired);
    let index = m.index;
    check_native(abi::body_word(m.body, 3, 0)?)?;
    let amount = abi::to_u64(abi::body_word(m.body, 3, 1)?)?;
    let recipient = Pubkey::new_from_array(*abi::body_word(m.body, 3, 2)?);
    require!(amount != 0, VaultError::ZeroAmount);
    require!(recipient != Pubkey::default(), VaultError::ZeroAddress);
    require_keys_eq!(
        recipient,
        ctx.accounts.recipient.key(),
        VaultError::WrongRecipient
    );

    let accounts = ctx.accounts;
    accounts.used.bump = ctx.bumps.used;
    accounts.owed.set_inner(Owed {
        index,
        id,
        to_index: false,
        recipient,
        new_index: [0u8; 20],
        remaining: amount,
        bump: ctx.bumps.owed,
    });
    emit!(BurnAccepted {
        index,
        id,
        amount,
        recipient
    });
    let pay = vault::pay_owed(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        false,
    )?;
    if pay == 0 {
        return Ok(());
    }
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

// ---------------------------------------------------------------------
// INTAKE_SETTLED, INTAKE_FAILED
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverIntake<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
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
        &ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[INTAKE_SETTLED, INTAKE_FAILED],
    )?;
    require!(both, VaultError::BothProofsRequired);
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
    let vault_address = vault::vault_address(&accounts.config.key());
    let chain_id = accounts.config.chain_id;
    if m.kind == INTAKE_SETTLED {
        intake.state = INTAKE_SETTLED_STATE;
        if intake.has_native {
            let state = &mut accounts.index_state;
            state.balance += intake.total;
            state.has_native = true;
            vault::refresh_index(state, chain_id, &vault_address);
        }
        vault::refresh_intake(intake, chain_id, &vault_address);
        emit!(IntakeSettled { index, intake_id });
    } else {
        intake.state = INTAKE_FAILED_STATE;
        vault::refresh_intake(intake, chain_id, &vault_address);
        emit!(IntakeFailed { index, intake_id });
    }
    Ok(())
}

// ---------------------------------------------------------------------
// MIGRATE
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct DeliverMigrate<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
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
        &ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[MIGRATE],
    )?;
    require!(both, VaultError::BothProofsRequired);
    let index = m.index;
    let new_index = abi::to_address(abi::body_word(m.body, 3, 0)?)?;
    require!(new_index != index, VaultError::NotAnIndex);
    check_native(abi::body_word(m.body, 3, 1)?)?;
    let amount = abi::to_u64(abi::body_word(m.body, 3, 2)?)?;
    require!(amount != 0, VaultError::ZeroAmount);

    let accounts = ctx.accounts;
    accounts.used.bump = ctx.bumps.used;
    accounts.owed.set_inner(Owed {
        index,
        id,
        to_index: true,
        recipient: Pubkey::default(),
        new_index,
        remaining: amount,
        bump: ctx.bumps.owed,
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
    let vault_address = vault::vault_address(&config.key());
    new.balance += pay;
    new.has_native = true;
    vault::refresh_index(old, config.chain_id, &vault_address);
    vault::refresh_index(new, config.chain_id, &vault_address);
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
    #[account(init, payer = payer, space = 8 + Used::INIT_SPACE, seeds = [USED_SEED, abi::message_id(&payload).as_ref()], bump)]
    pub used: Account<'info, Used>,
    /// CHECK: a rotation's new P1, which must be a program; absent for the other kinds.
    pub new_p1: Option<UncheckedAccount<'info>>,
    /// CHECK: a rotation's new P2, as the new P1.
    pub new_p2: Option<UncheckedAccount<'info>>,
    pub system_program: Program<'info, System>,
}

/// Anyone: a governance message from the factory. A freeze, or a cap update raising neither figure, may rest on one
/// proof; everything else needs both.
pub fn handle_deliver_governance<'info>(
    ctx: Context<'info, DeliverGovernance<'info>>,
    payload: Vec<u8>,
    proofs: Proofs,
) -> Result<()> {
    let (m, _, both) = accept(
        &ctx.accounts.config,
        &payload,
        &proofs,
        ctx.remaining_accounts,
        &[CAP_UPDATE, FREEZE, FREEZER_CHANGE, VERIFIER_ROTATION],
    )?;
    let accounts = ctx.accounts;
    accounts.used.bump = ctx.bumps.used;
    let config = &mut accounts.config;
    match m.kind {
        CAP_UPDATE => {
            check_native(abi::body_word(m.body, 3, 0)?)?;
            let cap = abi::to_u64(abi::body_word(m.body, 3, 1)?)?;
            let floor = abi::to_u64(abi::body_word(m.body, 3, 2)?)?;
            require!(
                both || (cap <= config.cap && floor <= config.outflow_floor),
                VaultError::BothProofsRequired
            );
            config.cap = cap;
            config.outflow_floor = floor;
            emit!(CapSet {
                cap,
                outflow_floor: floor
            });
        }
        FREEZE => {
            require!(m.body.is_empty(), VaultError::BadMessage);
            freeze_until(config, vault::now()?, Pubkey::default());
        }
        FREEZER_CHANGE => {
            require!(both, VaultError::BothProofsRequired);
            let freezer = Pubkey::new_from_array(*abi::body_word(m.body, 1, 0)?);
            require!(freezer != Pubkey::default(), VaultError::ZeroAddress);
            config.freezer = freezer;
            emit!(FreezerChanged { freezer });
        }
        _ => {
            require!(both, VaultError::BothProofsRequired);
            let p1 = Pubkey::new_from_array(*abi::body_word(m.body, 2, 0)?);
            let p2 = Pubkey::new_from_array(*abi::body_word(m.body, 2, 1)?);
            check_program(&accounts.new_p1, &p1)?;
            check_program(&accounts.new_p2, &p2)?;
            require_keys_neq!(p1, p2, VaultError::VerifiersNotDistinct);
            config.p1 = p1;
            config.p2 = p2;
            emit!(VerifiersRotated { p1, p2 });
        }
    }
    Ok(())
}

fn check_program(account: &Option<UncheckedAccount>, key: &Pubkey) -> Result<()> {
    let account = account.as_ref().ok_or(VaultError::NotAContract)?;
    require!(
        account.key() == *key && account.executable,
        VaultError::NotAContract
    );
    Ok(())
}

/// Freezes the vault for FREEZE_DURATION from now; a later freeze extends it, and none shortens it. `by` is the freezer,
/// or the default key for the factory's message.
pub fn freeze_until(config: &mut Config, now: i64, by: Pubkey) {
    let until = now + FREEZE_DURATION;
    if until > config.frozen_until {
        config.frozen_until = until;
    }
    emit!(Frozen {
        until: config.frozen_until,
        by
    });
}
