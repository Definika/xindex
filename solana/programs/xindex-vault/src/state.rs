use anchor_lang::prelude::*;

use crate::constants::BUCKETS;

/// The vault: its fixed settings and those governance messages change. Its address is the vault's identity on
/// Ethereum, and the treasury account it signs for holds the coins.
#[account]
#[derive(InitSpace)]
pub struct Config {
    /// Ethereum's chain id, which every message must name.
    pub source_chain_id: u64,
    /// The id the factory's chain registry gives this chain, which every message must name.
    pub chain_id: u64,
    /// The factory on Ethereum, which sends governance messages and deploys every index.
    pub factory: [u8; 20],
    /// The hub template on Ethereum that every index is a clone of.
    pub hub_implementation: [u8; 20],
    /// P1 and P2: two different verifier programs.
    pub p1: Pubkey,
    pub p2: Pubkey,
    /// The guardian's freeze key on this chain.
    pub freezer: Pubkey,
    pub frozen_until: i64,
    /// SOL's quantity cap across all indexes, and its outflow floor.
    pub cap: u64,
    pub outflow_floor: u64,
    /// Every lamport the vault accounts for: settled balances plus the deposits of open and failed intakes.
    pub held: u64,
    /// The factory's nonce of the last cap update, freezer change and rotation delivered: an older one of the same kind,
    /// delivered late, cannot undo a newer one (SOL-3).
    pub cap_nonce: u64,
    pub freezer_nonce: u64,
    pub rotation_nonce: u64,
    /// A raised cap or floor, a new freezer and new verifiers each wait GOVERNANCE_DELAY here, where the freezer can
    /// see them and stop a raise or a rotation, however their proofs were obtained (VLT-2).
    pub pending_cap: PendingChange,
    pub pending_freezer: PendingChange,
    pub pending_rotation: PendingChange,
    pub treasury_bump: u8,
    pub bump: u8,
    /// The owner's emergency multisig on Solana, fixed at initialization: it alone proposes a successor pair, and only
    /// while the vault is stalled.
    pub recovery_proposer: Pubkey,
    /// The last final Ethereum block both P1 and P2 proved. A message that moves coins or loosens a rule runs only from
    /// a block it covers (VLT-3), and a week without a new one is a stall.
    pub checkpoint: Checkpoint,
    /// The checkpoint the snapshot exit took, for good; all zero before it.
    pub snapshot: Checkpoint,
    /// A successor pair under review, all zero when none is.
    pub successor: Successor,
    /// The id of the last message delivered on both proofs, which a successor must prove again (LG-3).
    pub last_message: [u8; 32],
    /// The freezer's vetoes in the current stall; a checkpoint that ends it starts the count again (LG-2).
    pub vetoes: u8,
}

/// A final Ethereum block: its number, its timestamp and its state root.
#[derive(
    AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace, PartialEq, Eq, Debug,
)]
pub struct Checkpoint {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: [u8; 32],
}

/// A successor pair of verifiers under review, and when the review ends.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace)]
pub struct Successor {
    pub p1: Pubkey,
    pub p2: Pubkey,
    pub review_ends: i64,
}

/// A governance change waiting: the hash of its message body and when it may apply, all zero when none waits.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace)]
pub struct PendingChange {
    pub body_hash: [u8; 32],
    pub ready_at: i64,
}

/// One hour's payouts, tagged with the hour so a stale slot reads as empty.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace)]
pub struct Bucket {
    pub hour: u64,
    pub amount: u64,
}

/// An index registered here: its balance, its payouts, its speed limit and the digest Ethereum proves.
#[account]
#[derive(InitSpace)]
pub struct IndexState {
    pub index: [u8; 20],
    /// Whether SOL is among the index's tokens: set by its first credit, as the EVM vault's `_indexTokens`.
    pub has_native: bool,
    pub balance: u64,
    /// Everything paid out of `balance`: to burn recipients, and into other indexes by migration.
    pub paid_total: u64,
    pub outflow: [Bucket; BUCKETS],
    pub digest: [u8; 32],
    pub bump: u8,
}

/// A mint order's or a rebalance delivery's deposits for one index.
#[account]
#[derive(InitSpace)]
pub struct Intake {
    pub index: [u8; 20],
    pub intake_id: [u8; 32],
    pub state: u8,
    pub has_native: bool,
    pub total: u64,
    pub digest: [u8; 32],
    pub bump: u8,
}

/// One depositor's share of an intake.
#[account]
#[derive(InitSpace)]
pub struct DepositRecord {
    pub amount: u64,
    pub bump: u8,
}

/// A burn or a migration accepted from Ethereum and not yet paid in full.
#[account]
#[derive(InitSpace)]
pub struct Owed {
    pub index: [u8; 20],
    pub id: [u8; 32],
    /// A migration is paid into `new_index`'s balance; a burn to `recipient`.
    pub to_index: bool,
    pub recipient: Pubkey,
    pub new_index: [u8; 20],
    pub remaining: u64,
    pub bump: u8,
}

/// A delivered message: its existence at the address its id derives is the mark.
#[account]
#[derive(InitSpace)]
pub struct Used {
    pub bump: u8,
}
