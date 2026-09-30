//! Xindex v4 Stage B: the vault on Solana, holding SOL for every index whose shares live on Ethereum (Stage B spec,
//! section 7). It ports the EVM vault (`src/vault/XindexVault.sol`): coins come in only as deposits to an intake and
//! leave only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over any 24 hours. No owner:
//! the deployer only initializes it, and on mainnet then removes the program's upgrade authority.

pub mod abi;
pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;
pub mod vault;
pub mod verify;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("7HREqSpWGMXWn9VxADLNJU9M4MN11JqgbdtsntUsJsjg");

#[program]
pub mod xindex_vault {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, args: InitArgs) -> Result<()> {
        instructions::setup::handle_initialize(ctx, args)
    }

    pub fn register_index(
        ctx: Context<RegisterIndex>,
        index: [u8; 20],
        salt: [u8; 32],
    ) -> Result<()> {
        instructions::setup::handle_register_index(ctx, index, salt)
    }

    pub fn deposit(
        ctx: Context<Deposit>,
        index: [u8; 20],
        intake_id: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        instructions::deposits::handle_deposit(ctx, index, intake_id, amount)
    }

    pub fn refund(ctx: Context<Refund>, index: [u8; 20], intake_id: [u8; 32]) -> Result<()> {
        instructions::deposits::handle_refund(ctx, index, intake_id)
    }

    pub fn deliver_burn<'info>(
        ctx: Context<'info, DeliverBurn<'info>>,
        payload: Vec<u8>,
        proofs: Proofs,
    ) -> Result<()> {
        instructions::messages::handle_deliver_burn(ctx, payload, proofs)
    }

    pub fn deliver_intake<'info>(
        ctx: Context<'info, DeliverIntake<'info>>,
        payload: Vec<u8>,
        proofs: Proofs,
    ) -> Result<()> {
        instructions::messages::handle_deliver_intake(ctx, payload, proofs)
    }

    pub fn deliver_migrate<'info>(
        ctx: Context<'info, DeliverMigrate<'info>>,
        payload: Vec<u8>,
        proofs: Proofs,
    ) -> Result<()> {
        instructions::messages::handle_deliver_migrate(ctx, payload, proofs)
    }

    pub fn deliver_governance<'info>(
        ctx: Context<'info, DeliverGovernance<'info>>,
        payload: Vec<u8>,
        proofs: Proofs,
    ) -> Result<()> {
        instructions::messages::handle_deliver_governance(ctx, payload, proofs)
    }

    pub fn release(ctx: Context<Release>, index: [u8; 20], id: [u8; 32]) -> Result<()> {
        instructions::payouts::handle_release(ctx, index, id)
    }

    pub fn release_migration(
        ctx: Context<ReleaseMigration>,
        index: [u8; 20],
        id: [u8; 32],
    ) -> Result<()> {
        instructions::payouts::handle_release_migration(ctx, index, id)
    }

    pub fn freeze(ctx: Context<Freeze>) -> Result<()> {
        instructions::payouts::handle_freeze(ctx)
    }

    pub fn apply_change(ctx: Context<ApplyChange>, kind: u8, body: Vec<u8>) -> Result<()> {
        instructions::governance::handle_apply_change(ctx, kind, body)
    }

    pub fn cancel_change(ctx: Context<CancelChange>, kind: u8) -> Result<()> {
        instructions::governance::handle_cancel_change(ctx, kind)
    }
}
