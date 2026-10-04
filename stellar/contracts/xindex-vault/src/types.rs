//! The vault's storage and arguments, as Soroban values.
//!
//! Where each lives:
//! - `Config`, in the contract's instance storage, small and read by every call;
//! - per index, intake, deposit, owed payout, delivered message and attested slot, a persistent entry under its
//!   `DataKey`.
//!
//! Nothing is ever temporary storage. Every persistent entry is extended to the network's maximum TTL when written, and
//! anyone can extend one further or restore one archived: a transaction that reads an archived entry restores it
//! (protocol 23's automatic restore) or fails, and never reads it as missing. So a used mark cannot lapse into a second
//! delivery, and nothing a holder needs is lost to archival.

use soroban_sdk::{contracttype, Address, Bytes, BytesN, Vec};

/// A final Ethereum block: its number, its timestamp and its state root.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Checkpoint {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: BytesN<32>,
}

/// A verifier contract and the hash of the Wasm it ran when the vault took it, which it must still run whenever the
/// vault calls it: the twin of Solana's check that a verifier can no longer be upgraded (SOL-2). A contract whose code
/// changes, by its own `update_current_contract_wasm` or behind an executable reference, is refused, and the vault
/// stalls until a successor is adopted.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Verifier {
    pub address: Address,
    pub code: BytesN<32>,
}

/// A successor pair under review, and when the review ends.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Successor {
    pub p1: Verifier,
    pub p2: Verifier,
    pub review_ends: u64,
}

/// A governance change waiting: the hash of its message body and when it may apply; `ready_at` zero when none waits.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingChange {
    pub body_hash: BytesN<32>,
    pub ready_at: u64,
}

/// The vault: its fixed settings and those governance messages change.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    /// Ethereum's chain id, which every message must name.
    pub source_chain_id: u64,
    /// The id the factory's chain registry gives Stellar, which every message must name.
    pub chain_id: u64,
    /// The factory on Ethereum, which sends governance messages and deploys every index.
    pub factory: BytesN<20>,
    /// The hub template on Ethereum that every index is a clone of.
    pub hub_implementation: BytesN<20>,
    /// The native asset's contract, through which XLM moves: computed, never given.
    pub xlm: Address,
    /// P1 and P2: two different verifier contracts, their code pinned.
    pub p1: Verifier,
    pub p2: Verifier,
    /// The guardian's freeze address on Stellar.
    pub freezer: Address,
    pub frozen_until: u64,
    /// XLM's quantity cap across all indexes, and its outflow floor, in stroops.
    pub cap: u64,
    pub outflow_floor: u64,
    /// Every stroop the vault accounts for: settled balances plus the deposits of open and failed intakes. The vault
    /// keeps this book and never reads its own balance.
    pub held: u64,
    /// The factory's nonce of the last cap update, freezer change and rotation taken on both proofs (VLT-4).
    pub cap_nonce: u64,
    pub freezer_nonce: u64,
    pub rotation_nonce: u64,
    /// A raised cap or floor, a new freezer and new verifiers each wait GOVERNANCE_DELAY here (VLT-2).
    pub pending_cap: PendingChange,
    pub pending_freezer: PendingChange,
    pub pending_rotation: PendingChange,
    /// The owner's emergency multisig on Stellar, fixed at deployment: a contract, never a plain account.
    pub recovery_proposer: Address,
    /// The last final Ethereum block both P1 and P2 proved (VLT-3); a week without a new one is a stall.
    pub checkpoint: Checkpoint,
    /// The checkpoint the snapshot exit took, for good; zero before it.
    pub snapshot: Checkpoint,
    /// The id of the last message delivered on both proofs, which a successor must prove again (LG-3).
    pub last_message: BytesN<32>,
    /// The freezer's vetoes in the current stall; a checkpoint that ends it starts the count again (LG-2).
    pub vetoes: u32,
}

/// What the deployer passes the constructor.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InitArgs {
    pub source_chain_id: u64,
    pub chain_id: u64,
    pub factory: BytesN<20>,
    pub hub_implementation: BytesN<20>,
    pub freezer: Address,
    pub recovery_proposer: Address,
    pub native_cap: u64,
    pub native_floor: u64,
}

/// One hour's payouts, tagged with the hour so a stale slot reads as empty.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Bucket {
    pub hour: u64,
    pub amount: u64,
}

/// An index registered here: its balance, its payouts and its speed limit. Its digest is in the slot map.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IndexState {
    /// Whether XLM is among the index's tokens: set by its first credit, as the EVM vault's `_indexTokens`.
    pub has_native: bool,
    pub balance: u64,
    /// Everything paid out of `balance`: to burn recipients, and into other indexes by migration.
    pub paid_total: u64,
    pub outflow: Vec<Bucket>,
}

/// A mint order's or a rebalance delivery's deposits for one index. Its digest is in the slot map.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Intake {
    pub state: u32,
    pub has_native: bool,
    pub total: u64,
}

/// A burn, a migration or a snapshot claim accepted and not yet paid in full.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Owed {
    /// A migration is paid into `new_index`'s balance; a burn or a claim to the account `recipient`.
    pub to_index: bool,
    pub recipient: BytesN<32>,
    pub new_index: BytesN<20>,
    pub remaining: u64,
}

/// What a successor pair must prove (Stage B spec, section 5.6): the checkpoint the pair in force last accepted and a
/// recent one; the last message delivered on both proofs comes beside it. Each proof is the new P1's, then the new
/// P2's.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Continuity {
    pub last1: Bytes,
    pub last2: Bytes,
    pub recent: Checkpoint,
    pub recent1: Bytes,
    pub recent2: Bytes,
}

/// The last message delivered on both proofs, as the successor proves it again: its payload, the block of its log, and
/// the new P1's and P2's proofs of that log.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LastMessage {
    pub payload: Bytes,
    pub block: u64,
    pub proof1: Bytes,
    pub proof2: Bytes,
}

#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    Config,
    /// The successor pair under review, in instance storage beside the config.
    Successor,
    Index(BytesN<20>),
    Intake(BytesN<20>, BytesN<32>),
    Deposit(BytesN<20>, BytesN<32>, Address),
    Used(BytesN<32>),
    Owed(BytesN<20>, BytesN<32>),
    /// The value the hub reads at an EVM vault's storage slot: an intake's digest, an index's digest, or the
    /// snapshot's state root, under the key the hub computes (`design/2026-10-03-near-stellar-interfaces.md`).
    Slot(BytesN<32>),
}
