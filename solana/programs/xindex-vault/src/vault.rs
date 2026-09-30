//! What every instruction shares: the vault's identity in digests, the speed limit, and payouts.

use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::Paid;
use crate::state::{Config, IndexState, Intake, Owed};

/// The vault's address in the digests Ethereum proves: the last 20 bytes of its 32-byte key, the part the hub's
/// `_vaultAddress` keeps (Stage B spec, section 7).
pub fn vault_address(config: &Pubkey) -> [u8; 20] {
    config.to_bytes()[12..].try_into().unwrap()
}

pub fn refresh_index(index: &mut IndexState, chain_id: u64, vault: &[u8; 20]) {
    index.digest = abi::index_digest(
        chain_id,
        vault,
        &index.index,
        index.has_native,
        index.balance,
        index.paid_total,
    );
}

pub fn refresh_intake(intake: &mut Intake, chain_id: u64, vault: &[u8; 20]) {
    intake.digest = abi::intake_digest(
        chain_id,
        vault,
        &intake.index,
        &intake.intake_id,
        intake.state,
        intake.has_native,
        intake.total,
    );
}

pub fn now() -> Result<i64> {
    Ok(Clock::get()?.unix_timestamp)
}

fn hour_of(now: i64) -> u64 {
    (now / HOUR) as u64
}

/// What the index's payouts used of the speed limit over the current hour and the 24 before it.
pub fn recent_outflow(index: &IndexState, now: i64) -> u64 {
    let hour = hour_of(now);
    index
        .outflow
        .iter()
        .filter(|b| b.hour + BUCKETS as u64 > hour)
        .map(|b| b.amount)
        .sum()
}

/// What more the index may pay out now: 4% of its balance before the recent outflow, or the floor if larger.
pub fn available(index: &IndexState, floor: u64, now: i64) -> u64 {
    let recent = recent_outflow(index, now);
    let limit = ((index.balance as u128 + recent as u128) * SPEED_LIMIT_PERCENT / 100) as u64;
    limit.max(floor).saturating_sub(recent)
}

fn record_outflow(index: &mut IndexState, amount: u64, now: i64) {
    let hour = hour_of(now);
    let b = &mut index.outflow[(hour % BUCKETS as u64) as usize];
    b.amount = if b.hour == hour {
        b.amount + amount
    } else {
        amount
    };
    b.hour = hour;
}

pub fn check_not_frozen(config: &Config, now: i64) -> Result<()> {
    require!(now >= config.frozen_until, VaultError::VaultFrozen);
    Ok(())
}

/// Pays what the speed limit, the index's balance and a freeze allow of `owed`, out of `index`. `strict` is set for
/// an explicit release, which fails when it can pay nothing; a message just delivered keeps waiting instead. Returns
/// what it paid: the caller moves it, to the recipient or into the new index.
pub fn pay_owed(
    config: &Config,
    index: &mut IndexState,
    owed: &mut Owed,
    strict: bool,
) -> Result<u64> {
    require!(owed.remaining != 0, VaultError::NothingOwed);
    let now = now()?;
    let pay = if now < config.frozen_until {
        0
    } else {
        owed.remaining
            .min(available(index, config.outflow_floor, now))
            .min(index.balance)
    };
    if pay == 0 {
        require!(!strict, VaultError::NothingPayable);
        return Ok(0);
    }
    owed.remaining -= pay;
    index.balance -= pay;
    index.paid_total += pay;
    record_outflow(index, pay, now);
    emit!(Paid {
        index: index.index,
        id: owed.id,
        amount: pay,
        remaining: owed.remaining
    });
    Ok(pay)
}

/// Sends `amount` lamports from the treasury, which only this program signs for.
pub fn send<'info>(
    treasury: &AccountInfo<'info>,
    to: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    treasury_bump: u8,
    amount: u64,
) -> Result<()> {
    let seeds: &[&[u8]] = &[TREASURY_SEED, &[treasury_bump]];
    transfer(
        CpiContext::new_with_signer(
            system_program.key(),
            Transfer {
                from: treasury.clone(),
                to: to.clone(),
            },
            &[seeds],
        ),
        amount,
    )
}
