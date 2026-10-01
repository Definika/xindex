//! What every instruction shares: the vault's identity in digests, the speed limit, and payouts.

use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::Paid;
use crate::state::{Config, IndexState, Intake, Owed};

/// The vault's id in the digests Ethereum proves: its whole 32-byte key, as the factory's registry holds it.
pub fn vault_id(config: &Pubkey) -> [u8; 32] {
    config.to_bytes()
}

pub fn refresh_index(index: &mut IndexState, chain_id: u64, vault: &[u8; 32]) {
    index.digest = abi::index_digest(
        chain_id,
        vault,
        &index.index,
        index.has_native,
        index.balance,
        index.paid_total,
    );
}

pub fn refresh_intake(intake: &mut Intake, chain_id: u64, vault: &[u8; 32]) {
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
    min_pay: u64,
) -> Result<u64> {
    require!(owed.remaining != 0, VaultError::NothingOwed);
    let now = now()?;
    let mut pay = if now < config.frozen_until {
        0
    } else {
        owed.remaining
            .min(available(index, config.outflow_floor, now))
            .min(index.balance)
    };
    // A payout the recipient could not hold, below rent to an empty account, waits instead of failing (SOL-5).
    if pay < min_pay {
        pay = 0;
    }
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

/// The least a payout to `recipient` may be: an account holding nothing must be left rent-exempt, or the transfer fails.
pub fn min_payout(recipient: &AccountInfo) -> Result<u64> {
    Ok(if recipient.lamports() == 0 {
        Rent::get()?.minimum_balance(0)
    } else {
        0
    })
}

/// A verifier must be a program nobody can change: an upgradeable one only with its upgrade authority removed, whose
/// ProgramData account `program_data` shows it. Otherwise whoever holds that authority could rewrite P1 or P2 at once,
/// past the 30-day rotation (SOL-2).
pub fn check_immutable(program: &AccountInfo, program_data: Option<&AccountInfo>) -> Result<()> {
    require!(program.executable, VaultError::NotAContract);
    let loader = anchor_lang::solana_program::bpf_loader_upgradeable::id();
    if *program.owner != loader {
        // The older loaders cannot upgrade a program at all.
        require!(
            *program.owner == BPF_LOADER || *program.owner == BPF_LOADER_DEPRECATED,
            VaultError::NotAContract
        );
        return Ok(());
    }
    let data = program_data.ok_or(VaultError::VerifierUpgradeable)?;
    let expected = Pubkey::find_program_address(&[program.key.as_ref()], &loader).0;
    require_keys_eq!(*data.key, expected, VaultError::VerifierUpgradeable);
    require_keys_eq!(*data.owner, loader, VaultError::VerifierUpgradeable);
    let bytes = data.try_borrow_data()?;
    // UpgradeableLoaderState::ProgramData: tag 3 (u32), slot (u64), then Option<Pubkey>: 0 is None.
    require!(
        bytes.len() >= 13 && bytes[..4] == [3, 0, 0, 0] && bytes[12] == 0,
        VaultError::VerifierUpgradeable
    );
    Ok(())
}

const BPF_LOADER: Pubkey = Pubkey::from_str_const("BPFLoader2111111111111111111111111111111111");
const BPF_LOADER_DEPRECATED: Pubkey =
    Pubkey::from_str_const("BPFLoader1111111111111111111111111111111111");

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
