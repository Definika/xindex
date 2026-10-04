//! Xindex v4 Stage B: the vault on Solana, holding SOL for every index whose shares live on Ethereum (Stage B spec,
//! section 7). It ports the EVM vault (`src/vault/XindexVault.sol`): coins come in only as deposits to an intake and
//! leave only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over any 24 hours. If Ethereum's
//! formats change unannounced and P1 and P2 stop working, the vault stalls, may adopt a successor pair after a
//! continuity test and 30 days of review, and after 180 days pays each index's holders at its last checkpoint directly
//! (design 6.9). No owner: the deployer only initializes it, and on mainnet then removes the program's upgrade
//! authority.

pub mod abi;
pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod snapshot;
pub mod state;
pub mod state_reader;
pub mod vault;
pub mod verify;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;
pub use verify::PairProofs;

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

    pub fn advance_checkpoint<'info>(
        ctx: Context<'info, AdvanceCheckpoint<'info>>,
        checkpoint: Checkpoint,
        proofs: PairProofs,
    ) -> Result<()> {
        instructions::recovery::handle_advance_checkpoint(ctx, checkpoint, proofs)
    }

    pub fn propose_successor<'info>(
        ctx: Context<'info, ProposeSuccessor<'info>>,
        continuity: Continuity,
    ) -> Result<()> {
        instructions::recovery::handle_propose_successor(ctx, continuity)
    }

    pub fn veto_successor(ctx: Context<VetoSuccessor>) -> Result<()> {
        instructions::recovery::handle_veto_successor(ctx)
    }

    pub fn adopt_successor<'info>(
        ctx: Context<'info, AdoptSuccessor<'info>>,
        checkpoint: Checkpoint,
        proofs: PairProofs,
    ) -> Result<()> {
        instructions::recovery::handle_adopt_successor(ctx, checkpoint, proofs)
    }

    pub fn begin_snapshot(ctx: Context<BeginSnapshot>) -> Result<()> {
        instructions::recovery::handle_begin_snapshot(ctx)
    }

    pub fn claim_snapshot<'info>(
        ctx: Context<'info, ClaimSnapshot<'info>>,
        index: [u8; 20],
        holder: [u8; 20],
        component: u64,
        signature: Vec<u8>,
        proof: Vec<u8>,
    ) -> Result<()> {
        instructions::exit::handle_claim_snapshot(ctx, index, holder, component, signature, proof)
    }

    pub fn resolve_intake<'info>(
        ctx: Context<'info, ResolveIntake<'info>>,
        index: [u8; 20],
        intake_id: [u8; 32],
        proof: Vec<u8>,
    ) -> Result<()> {
        instructions::exit::handle_resolve_intake(ctx, index, intake_id, proof)
    }

    pub fn deliver_recorded_burn<'info>(
        ctx: Context<'info, DeliverBurn<'info>>,
        payload: Vec<u8>,
        proof: Vec<u8>,
    ) -> Result<()> {
        instructions::exit::handle_deliver_recorded_burn(ctx, payload, proof)
    }

    pub fn deliver_recorded_migrate<'info>(
        ctx: Context<'info, DeliverMigrate<'info>>,
        payload: Vec<u8>,
        proof: Vec<u8>,
    ) -> Result<()> {
        instructions::exit::handle_deliver_recorded_migrate(ctx, payload, proof)
    }
}
