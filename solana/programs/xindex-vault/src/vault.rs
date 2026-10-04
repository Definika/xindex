//! What every instruction shares: the vault's identity in digests, the speed limit, and payouts. The speed limit's
//! arithmetic and the checkpoint rules are every chain's (`xindex_core::speed`, `xindex_core::checkpoint`).

use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};
use xindex_core::{checkpoint, speed};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::Paid;
use crate::state::{Checkpoint, Config, IndexState, Intake, Owed};

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

/// What the index's payouts used of the speed limit over the current hour and the 24 before it.
pub fn recent_outflow(index: &IndexState, now: i64) -> u64 {
    speed::recent(index.outflow.iter().map(|b| (b.hour, b.amount)), now)
}

/// What more the index may pay out now: 4% of its balance before the recent outflow, or the floor if larger.
pub fn available(index: &IndexState, floor: u64, now: i64) -> u64 {
    speed::available(index.balance, recent_outflow(index, now), floor)
}

fn record_outflow(index: &mut IndexState, amount: u64, now: i64) {
    let b = &mut index.outflow[speed::slot_of(speed::hour_of(now))];
    (b.hour, b.amount) = speed::record((b.hour, b.amount), amount, now);
}

pub fn check_not_frozen(config: &Config, now: i64) -> Result<()> {
    require!(now >= config.frozen_until, VaultError::VaultFrozen);
    Ok(())
}

/// When the vault stalls: STALL_PERIOD after its last checkpoint's time, or after initialization until the first.
pub fn stall_start(config: &Config) -> i64 {
    checkpoint::stall_start(config.checkpoint.timestamp)
}

/// A week without a new checkpoint: P1 and P2 may have stopped working.
pub fn stalled(config: &Config, now: i64) -> bool {
    checkpoint::stalled(config.checkpoint.timestamp, now)
}

fn core_checkpoint(c: &Checkpoint) -> checkpoint::Checkpoint {
    checkpoint::Checkpoint {
        block: c.block,
        timestamp: c.timestamp,
        state_root: c.state_root,
    }
}

/// A checkpoint after the last, in blocks and in time, not in the future, and with a state to read.
pub fn check_newer(config: &Config, c: &Checkpoint, now: i64) -> Result<()> {
    require!(
        checkpoint::is_newer(
            &core_checkpoint(&config.checkpoint),
            &core_checkpoint(c),
            now
        ),
        VaultError::NotNewer
    );
    Ok(())
}

/// A newer checkpoint within STALL_PERIOD of now: one that would not leave the vault stalled.
pub fn check_recent(config: &Config, c: &Checkpoint, now: i64) -> Result<()> {
    check_newer(config, c, now)?;
    require!(
        checkpoint::is_recent(&core_checkpoint(c), now),
        VaultError::NotRecent
    );
    Ok(())
}

pub fn check_no_snapshot(config: &Config) -> Result<()> {
    require!(
        config.snapshot.state_root == [0u8; 32],
        VaultError::SnapshotTaken
    );
    Ok(())
}

/// The snapshot's state root, which every read of the hub's storage is under.
pub fn snapshot_root(config: &Config) -> Result<[u8; 32]> {
    let root = config.snapshot.state_root;
    require!(root != [0u8; 32], VaultError::NoSnapshot);
    Ok(root)
}

/// A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so the snapshot
/// at that checkpoint never pays a holder whose burn it paid too (VLT-3).
pub fn check_checkpointed(config: &Config, block: u64) -> Result<()> {
    require!(
        block <= config.checkpoint.block,
        VaultError::NotCheckpointed
    );
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

/// The least a payout to `recipient` may be: what leaves it rent-exempt for its data. The runtime refuses a transfer
/// that leaves an empty account below rent (SOL-5), or one already below it still below with more (B1-07); so a smaller
/// payout waits instead of failing the delivery.
pub fn min_payout(recipient: &AccountInfo) -> Result<u64> {
    Ok(Rent::get()?
        .minimum_balance(recipient.data_len())
        .saturating_sub(recipient.lamports()))
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
