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
    pub treasury_bump: u8,
    pub bump: u8,
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
