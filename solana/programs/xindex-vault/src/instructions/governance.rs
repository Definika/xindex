//! Governance changes that loosen a rule: a raised cap or floor, a new freezer, new verifiers. Each waits
//! GOVERNANCE_DELAY on the vault after its message arrives, so that even P1 and P2 both broken cannot loosen a rule
//! before the freezer can see it and stop it (VLT-2). Anyone applies a change once it is ready; the freezer may drop a
//! raise or a rotation, never its own replacement.

use anchor_lang::prelude::*;

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::instructions::messages::check_native;
use crate::state::{Config, PendingChange};
use crate::vault;

#[derive(Accounts)]
pub struct ApplyChange<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// CHECK: a rotation's new P1, which must be a program nobody can upgrade; absent for the other kinds.
    pub new_p1: Option<UncheckedAccount<'info>>,
    /// CHECK: a rotation's new P2, as the new P1.
    pub new_p2: Option<UncheckedAccount<'info>>,
    /// CHECK: the new P1's ProgramData account, when the upgradeable loader owns it; checked in `check_immutable`.
    pub new_p1_data: Option<UncheckedAccount<'info>>,
    /// CHECK: the new P2's, as the new P1's.
    pub new_p2_data: Option<UncheckedAccount<'info>>,
}

/// Anyone, from its `ready_at`: applies the waiting change of `kind` whose body `ChangeQueued` announced. A freeze in
/// force holds every change but the freezer's replacement: a freezer that froze again and again must not be able to
/// keep itself in place.
pub fn handle_apply_change(ctx: Context<ApplyChange>, kind: u8, body: Vec<u8>) -> Result<()> {
    let accounts = ctx.accounts;
    let config = &mut accounts.config;
    let now = vault::now()?;
    let waiting = *pending(config, kind)?;
    require!(
        waiting.ready_at != 0 && waiting.body_hash == abi::keccak(&[&body]),
        VaultError::NoPendingChange
    );
    require!(now >= waiting.ready_at, VaultError::ChangeNotReady);
    require!(
        kind == FREEZER_CHANGE || now >= config.frozen_until,
        VaultError::VaultFrozen
    );
    *pending(config, kind)? = PendingChange::default();
    match kind {
        CAP_UPDATE => {
            let (cap, floor) = read_cap(&body)?;
            set_cap(config, cap, floor);
        }
        FREEZER_CHANGE => {
            let freezer = Pubkey::new_from_array(*abi::body_word(&body, 1, 0)?);
            require!(freezer != Pubkey::default(), VaultError::ZeroAddress);
            config.freezer = freezer;
            emit!(FreezerChanged { freezer });
        }
        _ => {
            let p1 = Pubkey::new_from_array(*abi::body_word(&body, 2, 0)?);
            let p2 = Pubkey::new_from_array(*abi::body_word(&body, 2, 1)?);
            check_program(&accounts.new_p1, &accounts.new_p1_data, &p1)?;
            check_program(&accounts.new_p2, &accounts.new_p2_data, &p2)?;
            require_keys_neq!(p1, p2, VaultError::VerifiersNotDistinct);
            config.p1 = p1;
            config.p2 = p2;
            emit!(VerifiersRotated { p1, p2 });
        }
    }
    emit!(ChangeApplied { kind });
    Ok(())
}

#[derive(Accounts)]
pub struct CancelChange<'info> {
    pub freezer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
pub fn handle_cancel_change(ctx: Context<CancelChange>, kind: u8) -> Result<()> {
    let accounts = ctx.accounts;
    let config = &mut accounts.config;
    require!(
        accounts.freezer.key() == config.freezer && kind != FREEZER_CHANGE,
        VaultError::NotFreezer
    );
    let waiting = pending(config, kind)?;
    require!(waiting.ready_at != 0, VaultError::NoPendingChange);
    *waiting = PendingChange::default();
    emit!(ChangeCancelled { kind });
    Ok(())
}

/// Starts `kind`'s wait, replacing whatever older change of its kind was waiting.
pub fn queue(slot: &mut PendingChange, kind: u8, body: &[u8], now: i64) {
    let ready_at = now + GOVERNANCE_DELAY;
    *slot = PendingChange {
        body_hash: abi::keccak(&[body]),
        ready_at,
    };
    emit!(ChangeQueued {
        kind,
        body: body.to_vec(),
        ready_at
    });
}

/// A cap update's body: SOL's id, which must be zero, then its cap and floor.
pub fn read_cap(body: &[u8]) -> Result<(u64, u64)> {
    check_native(abi::body_word(body, 3, 0)?)?;
    let cap = abi::to_u64(abi::body_word(body, 3, 1)?)?;
    let floor = abi::to_u64(abi::body_word(body, 3, 2)?)?;
    Ok((cap, floor))
}

pub fn set_cap(config: &mut Config, cap: u64, floor: u64) {
    config.cap = cap;
    config.outflow_floor = floor;
    emit!(CapSet {
        cap,
        outflow_floor: floor
    });
}

fn pending(config: &mut Config, kind: u8) -> Result<&mut PendingChange> {
    match kind {
        CAP_UPDATE => Ok(&mut config.pending_cap),
        FREEZER_CHANGE => Ok(&mut config.pending_freezer),
        VERIFIER_ROTATION => Ok(&mut config.pending_rotation),
        _ => err!(VaultError::NoPendingChange),
    }
}

fn check_program(
    account: &Option<UncheckedAccount>,
    program_data: &Option<UncheckedAccount>,
    key: &Pubkey,
) -> Result<()> {
    let account = account.as_ref().ok_or(VaultError::NotAContract)?;
    require_keys_eq!(account.key(), *key, VaultError::NotAContract);
    vault::check_immutable(
        &account.to_account_info(),
        program_data.as_ref().map(|d| d.as_ref()),
    )
}
