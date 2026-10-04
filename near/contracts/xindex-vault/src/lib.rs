//! Xindex v4 Stage B: the vault on NEAR, holding NEAR for every index whose shares live on Ethereum. The twin of the EVM
//! vault (`src/vault/XindexVault.sol`) and of the Solana vault (`solana/programs/xindex-vault`): coins come in only as
//! deposits to an intake and leave only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over
//! any 24 hours. If Ethereum's formats change unannounced and P1 and P2 stop working, the vault stalls, may adopt a
//! successor pair after a continuity test and 30 days of review, and after 180 days pays each index's holders at its
//! last checkpoint directly (design 6.9). Its state is proven to Ethereum by `attest` (TRON's design, spec 5.7), whose
//! exact output the interfaces doc fixes (`design/2026-10-03-near-stellar-interfaces.md`).
//!
//! What NEAR changes:
//! - P1 and P2 are compiled in, since NEAR's cross-contract calls are asynchronous: each is a light client of Ethereum
//!   kept in the vault's storage under a 32-byte id, the hash of its configuration (`verifier_id`), which is what a
//!   `VERIFIER_ROTATION` and a successor proposal name. Anyone registers a light client and advances it with proofs.
//! - The vault never reads its own balance: NEAR credits plain transfers and gas rebates silently, so `held` is a book.
//!   Whoever adds storage pays for it with the call, and a payout is a transfer whose failure puts its amount back.
//! - Amounts are yoctoNEAR, `u128`; one from Ethereum that does not fit is refused.
//! - No owner and no upgrade: the code has no method that deploys code or adds a key, and the vault runs at a NEP-616
//!   deterministic account (`0s…`) whose code is a global contract fixed by its hash, so no key can ever act for it.

mod crypto;
mod errors;
#[cfg(test)]
mod fixtures;
#[cfg(test)]
mod tests;
pub mod types;

use near_sdk::json_types::{Base64VecU8, U128};
use near_sdk::store::{LookupMap, LookupSet};
use near_sdk::{env, near, AccountId, BorshStorageKey, Gas, NearToken, PanicOnDefault, Promise};
use xindex_core::abi::{self, Message};
use xindex_core::constants::*;
use xindex_core::crypto::Crypto;
use xindex_core::light_client::{self, CheckpointClaim, LogClaim};
use xindex_core::{checkpoint, risc0, snapshot, sp1, speed, state_reader};

pub use crypto::Near;
use errors::{check, fail, Error};
pub use types::*;

/// `keccak256("xindex.v4.vault-attest")`: the domain of `attest`'s record (interfaces doc).
pub const ATTEST_DOMAIN: [u8; 32] =
    xindex_core::hex::h("b0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c");
/// `keccak256("xindex.v4.near-verifier")`: the domain of a light client's id.
pub const VERIFIER_DOMAIN: [u8; 32] =
    xindex_core::hex::h("287b4f180c880466a4db25942c9299de93f8581715aec8f6c50e5ea1c0949dec");
/// The hub's storage layout the vault's slot map follows (`HybridHubStorage`): `intakeDigest` (15), `indexDigest` (14),
/// `_snapshot.stateRoot` (25).
pub const INTAKE_DIGEST_SLOT: u64 = 15;
pub const INDEX_DIGEST_SLOT: u64 = 14;
pub const SNAPSHOT_ROOT_SLOT: u64 = 25;
/// The gas a payout's callback needs to put a failed transfer back.
const CALLBACK_GAS: Gas = Gas::from_tgas(10);

#[derive(BorshStorageKey)]
#[near]
enum Key {
    Verifiers,
    Ranges,
    Indexes,
    Intakes,
    Deposits,
    Owed,
    Used,
    Slots,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Vault {
    source_chain_id: u64,
    chain_id: u64,
    factory: [u8; 20],
    hub_implementation: [u8; 20],
    /// P1's and P2's light clients, by id.
    p1: [u8; 32],
    p2: [u8; 32],
    freezer: AccountId,
    recovery_proposer: AccountId,
    frozen_until: u64,
    cap: u128,
    outflow_floor: u128,
    /// Every yoctoNEAR the vault accounts for: settled balances plus the deposits of open and failed intakes.
    held: u128,
    /// The factory's nonce of the last cap update, freezer change and rotation taken on both proofs (VLT-4, SOL-3).
    cap_nonce: u64,
    freezer_nonce: u64,
    rotation_nonce: u64,
    /// A raised cap or floor, a new freezer and new verifiers each wait GOVERNANCE_DELAY here (VLT-2).
    pending_cap: PendingChange,
    pending_freezer: PendingChange,
    pending_rotation: PendingChange,
    checkpoint: Checkpoint,
    snapshot: Checkpoint,
    successor: Successor,
    /// The last message delivered on both proofs, which a successor must prove again (LG-3).
    last_message: [u8; 32],
    /// The freezer's vetoes in the current stall (LG-2).
    vetoes: u8,
    verifiers: LookupMap<[u8; 32], LightClient>,
    /// The blocks a proof covered, by its light client and its headers root.
    ranges: LookupMap<([u8; 32], [u8; 32]), (u64, u64)>,
    indexes: LookupMap<[u8; 20], IndexState>,
    intakes: LookupMap<([u8; 20], [u8; 32]), Intake>,
    deposits: LookupMap<([u8; 20], [u8; 32], AccountId), u128>,
    owed: LookupMap<([u8; 20], [u8; 32]), Owed>,
    used: LookupSet<[u8; 32]>,
    /// The values `attest` vouches for, by the slot the hub reads them at on an EVM vault.
    slots: LookupMap<[u8; 32], [u8; 32]>,
}

/// A light client's id: `keccak256(abi.encode(VERIFIER_DOMAIN, system, key, anchor, epoch, genesisTime))`, its
/// configuration as first registered.
pub fn verifier_id(c: &VerifierConfig) -> [u8; 32] {
    Near.keccak256(&[
        &VERIFIER_DOMAIN,
        &abi::u256(c.system as u64),
        &c.key.0,
        &c.anchor.0,
        &abi::u256(c.epoch),
        &abi::u256(c.genesis_time),
    ])
}

/// `attest`'s record: `abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)`, the two figures
/// being the height and the time in nanoseconds of the block `attest` ran in.
pub fn attest_record(
    chain_id: u64,
    vault_id: &[u8; 32],
    height: u64,
    timestamp_ns: u64,
    slots: &[[u8; 32]],
    values: &[[u8; 32]],
) -> Vec<u8> {
    let n = slots.len() as u64;
    let mut out = Vec::with_capacity(32 * (9 + 2 * slots.len()));
    out.extend_from_slice(&ATTEST_DOMAIN);
    out.extend_from_slice(&abi::u256(chain_id));
    out.extend_from_slice(vault_id);
    out.extend_from_slice(&abi::u256(height));
    out.extend_from_slice(&abi::u256(timestamp_ns));
    out.extend_from_slice(&abi::u256(7 * 32));
    out.extend_from_slice(&abi::u256(7 * 32 + 32 + 32 * n));
    out.extend_from_slice(&abi::u256(n));
    slots.iter().for_each(|s| out.extend_from_slice(s));
    out.extend_from_slice(&abi::u256(values.len() as u64));
    values.iter().for_each(|v| out.extend_from_slice(v));
    out
}

fn now() -> u64 {
    env::block_timestamp() / 1_000_000_000
}

fn event(name: &str, data: near_sdk::serde_json::Value) {
    env::log_str(&format!(
        "EVENT_JSON:{}",
        near_sdk::serde_json::json!({"standard": "xindex-vault", "version": "1", "event": name, "data": data})
    ));
}

fn abi_err(e: abi::AbiError) -> Error {
    match e {
        abi::AbiError::BadMessage => Error::BadMessage,
        abi::AbiError::Overflow => Error::Overflow,
    }
}

fn snapshot_err(e: snapshot::SnapshotError) -> Error {
    match e {
        snapshot::SnapshotError::BadStateProof => Error::BadStateProof,
        snapshot::SnapshotError::WrongComponent => Error::WrongComponent,
        snapshot::SnapshotError::Overflow => Error::Overflow,
        snapshot::SnapshotError::ZeroAmount => Error::ZeroAmount,
        snapshot::SnapshotError::BadSignature => Error::BadSignature,
    }
}

fn body_word(body: &[u8], words: usize, i: usize) -> [u8; 32] {
    *abi::body_word(body, words, i).unwrap_or_else(|e| fail(abi_err(e)))
}

fn amount(w: &[u8; 32]) -> u128 {
    abi::to_u128(w).unwrap_or_else(|e| fail(abi_err(e)))
}

/// A body word that must be zero: the vault holds NEAR only, `address(0)` on Ethereum.
fn check_native(word: &[u8; 32]) {
    check(*word == [0u8; 32], Error::NotNative);
}

#[near]
impl Vault {
    /// Initializes the vault: the deployment's settings, P1 and P2 registered from their configurations, and its first
    /// week's grace before a stall. At a deterministic account the same state is the account's initial data instead
    /// (`initial_state`), and nothing calls this.
    #[init]
    pub fn new(config: InitConfig) -> Self {
        Self::build(config, now())
    }

    // ---------------------------------------------------------------------
    // Indexes and deposits
    // ---------------------------------------------------------------------

    /// Anyone, paying its storage: records `index` once its address is the factory's CREATE2 clone of the hub template
    /// under `salt`. Only a registered index takes deposits or sends messages that run.
    #[payable]
    pub fn register_index(&mut self, index: Hex20, salt: Hex32) {
        let before = env::storage_usage();
        let salt = salt.0;
        check(
            abi::predict_clone(&Near, &self.hub_implementation, &salt, &self.factory) == index.0,
            Error::NotAnIndex,
        );
        if self.indexes.contains_key(&index.0) {
            self.charge(before, 0);
            return;
        }
        self.indexes.insert(index.0, IndexState::default());
        self.refresh_index(&index.0);
        event(
            "index_registered",
            near_sdk::serde_json::json!({"index": index, "salt": Hex32(salt)}),
        );
        self.charge(before, 0);
    }

    /// Anyone, while neither frozen nor stalled: deposits `amount` yoctoNEAR into intake `intake_id` of `index`, the
    /// call's deposit covering it and the storage it adds; the rest is returned. The intake's deadline is its id's top 64
    /// bits: nobody can open another's intake with another deadline, and deposits close at it for everyone.
    #[payable]
    pub fn deposit(&mut self, index: Hex20, intake_id: Hex32, amount: U128) {
        let before = env::storage_usage();
        let (index, intake_id, amount) = (index.0, intake_id.0, amount.0);
        check(self.indexes.contains_key(&index), Error::NotAnIndex);
        self.check_not_frozen();
        // A stalled vault may never again see the message that would settle or fail an intake.
        check(!self.stalled(), Error::VaultStalled);
        check(amount != 0, Error::ZeroAmount);
        let deadline = abi::deadline_of(&intake_id);
        let now = now();
        check(now <= deadline, Error::IntakeClosed);
        let mut intake = self
            .intakes
            .get(&(index, intake_id))
            .copied()
            .unwrap_or_default();
        match intake.state {
            INTAKE_NONE => {
                check(
                    deadline <= now + MAX_INTAKE_LIFE as u64,
                    Error::IntakeTooLong,
                );
                intake.state = INTAKE_OPEN;
            }
            INTAKE_OPEN => {}
            _ => fail(Error::IntakeClosed),
        }
        let held = self
            .held
            .checked_add(amount)
            .unwrap_or_else(|| fail(Error::CapExceeded));
        check(held <= self.cap, Error::CapExceeded);
        self.held = held;
        let depositor = env::predecessor_account_id();
        let key = (index, intake_id, depositor.clone());
        let mine = self.deposits.get(&key).copied().unwrap_or(0) + amount;
        self.deposits.insert(key, mine);
        intake.total += amount;
        intake.has_native = true;
        self.intakes.insert((index, intake_id), intake);
        self.refresh_intake(&index, &intake_id);
        event(
            "deposited",
            near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id), "depositor": depositor, "amount": U128(amount)}),
        );
        self.charge(before, amount);
    }

    /// A depositor of a failed intake, while not frozen: takes its deposit back.
    pub fn refund(&mut self, index: Hex20, intake_id: Hex32) {
        let (index, intake_id) = (index.0, intake_id.0);
        let mut intake = self
            .intakes
            .get(&(index, intake_id))
            .copied()
            .unwrap_or_else(|| fail(Error::IntakeNotOpen));
        check(intake.state == INTAKE_FAILED_STATE, Error::IntakeNotOpen);
        self.check_not_frozen();
        let depositor = env::predecessor_account_id();
        let key = (index, intake_id, depositor.clone());
        let amount = self.deposits.get(&key).copied().unwrap_or(0);
        check(amount != 0, Error::NothingToRefund);
        self.deposits.insert(key, 0);
        self.held -= amount;
        intake.total -= amount;
        self.intakes.insert((index, intake_id), intake);
        self.refresh_intake(&index, &intake_id);
        event(
            "refunded",
            near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id), "depositor": depositor, "amount": U128(amount)}),
        );
        Promise::new(depositor.clone())
            .transfer(NearToken::from_yoctonear(amount))
            .then(
                Self::ext(env::current_account_id())
                    .with_static_gas(CALLBACK_GAS)
                    .on_refund(Hex20(index), Hex32(intake_id), depositor, U128(amount)),
            )
            .detach();
    }

    // ---------------------------------------------------------------------
    // Messages from Ethereum
    // ---------------------------------------------------------------------

    /// Anyone, paying the storage it adds: runs one `VaultMessage` an index or the factory emitted, on P1's proof, P2's or
    /// both, the log in Ethereum block `block`. After a snapshot, no block past it; then the canonical encoding, the
    /// route, the emitter and the proofs; for a message that moves coins or loosens a rule, both proofs and a checkpoint
    /// covering its block (VLT-3); and a used mark, so a message runs at most once.
    #[payable]
    pub fn deliver(
        &mut self,
        payload: Base64VecU8,
        block: u64,
        proof1: Option<Base64VecU8>,
        proof2: Option<Base64VecU8>,
    ) {
        let before = env::storage_usage();
        let payload = payload.0;
        // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
        check(
            self.snapshot.block == 0 || block <= self.snapshot.block,
            Error::IssuedAfterSnapshot,
        );
        let id = abi::message_id(&Near, &payload);
        let m = abi::decode_message(&payload).unwrap_or_else(|e| fail(abi_err(e)));
        check(
            m.kind != 0 && m.kind <= VERIFIER_ROTATION,
            Error::UnknownKind,
        );
        self.check_route(&m);
        let governance = m.kind >= CAP_UPDATE;
        // Any Ethereum contract can emit a message naming itself; a governance kind is the factory's alone, and an
        // index's kind runs only for a clone of the factory registered here.
        if governance {
            check(m.index == self.factory, Error::WrongEmitter);
        } else {
            check(self.indexes.contains_key(&m.index), Error::NotAnIndex);
        }
        let claim = LogClaim {
            block,
            emitter: m.index,
            topic0: EVENT_TOPIC,
            topic1: id,
            data_hash: abi::log_data_hash(&Near, &payload),
        };
        let p1 = proof1.map(|p| p.0);
        let p2 = proof2.map(|p| p.0);
        check(p1.is_some() || p2.is_some(), Error::NoProof);
        if let Some(p) = &p1 {
            self.verify_event(&self.p1, p, &claim);
        }
        if let Some(p) = &p2 {
            self.verify_event(&self.p2, p, &claim);
        }
        let both = p1.is_some() && p2.is_some();
        let loosening = self.needs_both(&m);
        if loosening {
            check(both, Error::BothProofsRequired);
            // A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
            // snapshot at that checkpoint never pays twice what such a message already paid (VLT-3).
            check(block <= self.checkpoint.block, Error::NotCheckpointed);
        }
        check(!self.used.contains(&id), Error::AlreadyDelivered);
        // A cut taken on one proof moves no mark (VLT-4), so it stays deliverable on both, which moves the mark past an
        // older raise; until then a replay on one proof only applies it again (A3-02). A freeze is used up at once.
        if both || m.kind == FREEZE {
            self.used.insert(id);
        }
        // Only a message on both proofs: one broken proof system could forge a one-proof freeze, which no honest
        // successor could prove again (LG-3).
        if both {
            self.last_message = id;
        }
        event(
            "message_delivered",
            near_sdk::serde_json::json!({"id": Hex32(id), "kind": m.kind, "index": Hex20(m.index)}),
        );
        if governance {
            self.governance_message(&m, loosening, both);
        } else {
            self.index_message(&m, id);
        }
        self.charge(before, 0);
    }

    /// Anyone, while not frozen: pays what the speed limit now allows of an owed burn, claim or migration.
    pub fn release(&mut self, index: Hex20, id: Hex32) {
        self.pay(index.0, id.0, true);
    }

    /// The guardian's freeze key only, before any snapshot exit: freezes the vault for FREEZE_DURATION from now.
    /// Nothing could replace the freezer after a snapshot, so it must not be able to hold the exit off for good (VLT-5).
    pub fn freeze(&mut self) {
        check(
            env::predecessor_account_id() == self.freezer,
            Error::NotFreezer,
        );
        self.check_no_snapshot();
        self.freeze_now(env::predecessor_account_id().to_string());
    }

    /// Anyone, from its ready time: applies the waiting change of `kind` whose body its `change_queued` event announced.
    /// A freeze in force holds every change but the freezer's replacement: a freezer that froze again and again must not
    /// be able to keep itself in place.
    pub fn apply_change(&mut self, kind: u8, body: Base64VecU8) {
        let body = body.0;
        let waiting = *self.pending(kind);
        check(
            waiting.ready_at != 0 && waiting.body_hash.0 == Near.keccak256(&[&body]),
            Error::NoPendingChange,
        );
        check(now() >= waiting.ready_at, Error::ChangeNotReady);
        check(
            kind == FREEZER_CHANGE || now() >= self.frozen_until,
            Error::VaultFrozen,
        );
        *self.pending(kind) = PendingChange::default();
        self.apply(kind, &body);
        event(
            "change_applied",
            near_sdk::serde_json::json!({"kind": kind}),
        );
    }

    /// The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
    pub fn cancel_change(&mut self, kind: u8) {
        check(
            env::predecessor_account_id() == self.freezer && kind != FREEZER_CHANGE,
            Error::NotFreezer,
        );
        let waiting = self.pending(kind);
        check(waiting.ready_at != 0, Error::NoPendingChange);
        *waiting = PendingChange::default();
        event(
            "change_cancelled",
            near_sdk::serde_json::json!({"kind": kind}),
        );
    }

    // ---------------------------------------------------------------------
    // P1 and P2: light clients of Ethereum
    // ---------------------------------------------------------------------

    /// Anyone, paying its storage: registers a light client from its configuration, under its id (`verifier_id`), so a
    /// rotation or a successor proposal can name it. Registering one twice changes nothing.
    #[payable]
    pub fn register_verifier(&mut self, config: VerifierConfig) -> Hex32 {
        let before = env::storage_usage();
        let id = self.add_verifier(&config);
        self.charge(before, 0);
        Hex32(id)
    }

    /// Anyone, paying the storage it adds, until a day after the stored anchor's epoch began (LG-4): advances light
    /// client `id` with a proof of the statement from its stored anchor, and records the blocks it covers.
    #[payable]
    pub fn update_verifier(&mut self, id: Hex32, public_values: Base64VecU8, proof: Base64VecU8) {
        let before = env::storage_usage();
        let mut lc = *self
            .verifiers
            .get(&id.0)
            .unwrap_or_else(|| fail(Error::UnknownVerifier));
        light_client::check_lag(lc.epoch, lc.genesis_time, now() as i64)
            .unwrap_or_else(|e| fail(Error::Verifier(e)));
        let checked = match lc.system {
            SP1 => sp1::verify(&Near, &lc.key.0, &public_values.0, &proof.0),
            _ => risc0::verify(&Near, &lc.key.0, &public_values.0, &proof.0),
        };
        check(checked.is_ok(), Error::InvalidProof);
        let (mut anchor, mut epoch) = (lc.anchor.0, lc.epoch);
        let v = light_client::advance(&mut anchor, &mut epoch, &public_values.0)
            .unwrap_or_else(|e| fail(Error::Verifier(e)));
        lc.anchor = Hex32(anchor);
        lc.epoch = epoch;
        self.verifiers.insert(id.0, lc);
        self.ranges
            .insert((id.0, v.headers_root), (v.first, v.last));
        event(
            "verifier_advanced",
            near_sdk::serde_json::json!({"id": id, "epoch": epoch, "anchor": Hex32(anchor), "headers_root": Hex32(v.headers_root), "first": v.first, "last": v.last}),
        );
        self.charge(before, 0);
    }

    // ---------------------------------------------------------------------
    // Checkpoints, stall recovery and the snapshot exit (design 6.9)
    // ---------------------------------------------------------------------

    /// Anyone, before a snapshot exit: records a final Ethereum block both P1 and P2 prove, newer than the last, which
    /// keeps the vault out of a stall. One recent enough to end a stall also lapses any successor under review and starts
    /// the freezer's count again; a stale one leaves the stall, its successor and its count (LG-2).
    pub fn advance_checkpoint(&mut self, checkpoint: Checkpoint, proofs: PairProofs) {
        self.check_no_snapshot();
        self.checkpoint_by_both(&self.p1.clone(), &self.p2.clone(), &checkpoint, &proofs);
        self.check_newer(&checkpoint);
        self.checkpoint = checkpoint;
        event(
            "checkpoint_advanced",
            near_sdk::serde_json::json!(checkpoint),
        );
        if self.stalled() {
            return;
        }
        // A recent one ends the stall: the pair in force works again.
        self.vetoes = 0;
        if self.successor.review_ends != 0 {
            self.successor = Successor::default();
            event("successor_lapsed", near_sdk::serde_json::json!({}));
        }
    }

    /// The recovery proposer only, while stalled, before a snapshot exit, with none under review: proposes the light
    /// clients `p1` and `p2`, registered here, of two different proof systems, which must prove the last checkpoint, a
    /// recent one and the last message delivered on both proofs.
    pub fn propose_successor(&mut self, p1: Hex32, p2: Hex32, continuity: Continuity) {
        check(
            env::predecessor_account_id() == self.recovery_proposer,
            Error::NotRecoveryProposer,
        );
        self.check_no_snapshot();
        check(self.stalled(), Error::NotStalled);
        check(self.successor.review_ends == 0, Error::SuccessorPending);
        self.check_pair(&p1.0, &p2.0);
        // (a) The last checkpoint the pair in force accepted.
        let last = self.checkpoint;
        self.checkpoint_by_both(&p1.0, &p2.0, &last, &continuity.last);
        // (b) A recent one, which the successor's proof shows descends from it.
        self.checkpoint_by_both(&p1.0, &p2.0, &continuity.recent, &continuity.recent_proofs);
        self.check_recent(&continuity.recent);
        // (c) The last message the pair in force delivered on both proofs, if there was one.
        if self.last_message != [0u8; 32] {
            let message = continuity
                .message
                .as_ref()
                .unwrap_or_else(|| fail(Error::Discontinuous));
            let payload = &message.payload.0;
            let id = abi::message_id(&Near, payload);
            check(id == self.last_message, Error::Discontinuous);
            let claim = LogClaim {
                block: message.block,
                emitter: abi::index_in(payload),
                topic0: EVENT_TOPIC,
                topic1: id,
                data_hash: abi::log_data_hash(&Near, payload),
            };
            self.verify_event(&p1.0, &message.proofs.proof1.0, &claim);
            self.verify_event(&p2.0, &message.proofs.proof2.0, &claim);
        }
        let review_ends = now() + RECOVERY_DELAY as u64;
        self.successor = Successor {
            p1,
            p2,
            review_ends,
        };
        event(
            "successor_proposed",
            near_sdk::serde_json::json!(self.successor),
        );
    }

    /// The freezer only, at most MAX_RECOVERY_VETOES times a stall: drops the successor under review.
    pub fn veto_successor(&mut self) {
        check(
            env::predecessor_account_id() == self.freezer,
            Error::NotFreezer,
        );
        check(self.successor.review_ends != 0, Error::NoSuccessor);
        check(self.vetoes < MAX_RECOVERY_VETOES, Error::VetoesExhausted);
        self.vetoes += 1;
        self.successor = Successor::default();
        event(
            "successor_vetoed",
            near_sdk::serde_json::json!({"vetoes": self.vetoes}),
        );
    }

    /// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2, which ends the
    /// stall and the freezer's count.
    pub fn adopt_successor(&mut self, checkpoint: Checkpoint, proofs: PairProofs) {
        let s = self.successor;
        // A snapshot clears any successor, and a checkpoint that ends the stall lapses it, so a pending one is still in
        // its stall.
        check(s.review_ends != 0, Error::NoSuccessor);
        check(now() >= s.review_ends, Error::ReviewNotOver);
        self.checkpoint_by_both(&s.p1.0, &s.p2.0, &checkpoint, &proofs);
        self.check_recent(&checkpoint);
        self.successor = Successor::default();
        self.vetoes = 0;
        self.p1 = s.p1.0;
        self.p2 = s.p2.0;
        self.checkpoint = checkpoint;
        event(
            "successor_adopted",
            near_sdk::serde_json::json!({"p1": s.p1, "p2": s.p2}),
        );
        event(
            "checkpoint_advanced",
            near_sdk::serde_json::json!(checkpoint),
        );
    }

    /// Anyone, SNAPSHOT_EXIT_DELAY after the stall began: takes the last checkpoint as the snapshot for good. From then
    /// on no message from a later Ethereum block runs, and holders at it claim directly.
    pub fn begin_snapshot(&mut self) {
        self.check_no_snapshot();
        let due =
            checkpoint::stall_start(self.checkpoint.timestamp).saturating_add(SNAPSHOT_EXIT_DELAY);
        check(now() as i64 >= due, Error::SnapshotNotDue);
        let last = self.checkpoint;
        // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
        check(last.state_root.0 != [0u8; 32], Error::NoCheckpoint);
        self.snapshot = last;
        self.slots
            .insert(abi::u256(SNAPSHOT_ROOT_SLOT), last.state_root.0);
        event("snapshot_begun", near_sdk::serde_json::json!(last));
        if self.successor.review_ends != 0 {
            self.successor = Successor::default();
            event("successor_lapsed", near_sdk::serde_json::json!({}));
        }
    }

    /// Anyone after the snapshot, paying the storage it adds: pays `holder`'s share of NEAR in `index` at the snapshot,
    /// read from the hub's storage there, to the account `recipient` names: the recovery address it registered in the
    /// hub for this chain, if any, which a contract holder must register; otherwise the recipient it signed for with its
    /// Ethereum key (EIP-712, the domain's salt this vault's id). Within the speed limit, as any payout: a snapshot of a
    /// forged checkpoint takes no more than a forged burn. Once per holder and index.
    #[payable]
    pub fn claim_snapshot(
        &mut self,
        index: Hex20,
        holder: Hex20,
        component: u64,
        recipient: Hex32,
        signature: Base64VecU8,
        proof: Base64VecU8,
    ) {
        let before = env::storage_usage();
        let (index, holder, recipient) = (index.0, holder.0, recipient.0);
        check(self.indexes.contains_key(&index), Error::NotAnIndex);
        check(recipient != [0u8; 32], Error::ZeroAddress);
        let to = account_of(&recipient);
        check(to != env::current_account_id(), Error::WrongRecipient);
        let root = self.snapshot_root();
        let slots = snapshot::claim_slots(&Near, &holder, component, self.chain_id);
        let values = state_reader::read_slots(&Near, &root, &index, &slots, &proof.0)
            .unwrap_or_else(|_| fail(Error::BadStateProof));
        let (amount, registered) = snapshot::share_wide(&Near, &values, component, self.chain_id)
            .unwrap_or_else(|e| fail(snapshot_err(e)));
        match registered {
            // A holder that registered a recovery address, such as a contract, is paid there and nowhere else.
            Some(key) => check(key == recipient, Error::WrongRecipient),
            None => {
                let digest = snapshot::claim_digest(
                    &Near,
                    &self.vault_id(),
                    self.chain_id,
                    &index,
                    &holder,
                    &recipient,
                );
                snapshot::check_signature(&Near, &digest, &signature.0, &holder)
                    .unwrap_or_else(|e| fail(snapshot_err(e)));
            }
        }
        let id = snapshot::claim_id(&Near, &index, &holder);
        check(!self.owed.contains_key(&(index, id)), Error::AlreadyClaimed);
        self.owed.insert(
            (index, id),
            Owed {
                recipient: Some(to.clone()),
                new_index: [0u8; 20],
                remaining: amount,
            },
        );
        event(
            "snapshot_claimed",
            near_sdk::serde_json::json!({"index": Hex20(index), "holder": Hex20(holder), "recipient": to, "amount": U128(amount), "id": Hex32(id)}),
        );
        self.pay(index, id, false);
        self.charge(before, 0);
    }

    /// Anyone, after the snapshot: settles an intake still open if the hub had sent its settle message by the snapshot,
    /// and otherwise fails it, so its depositors take their coins back. The hub marks an intake settled in the transaction
    /// that sends its settle message (`_settledIntakes`), so its mark at the snapshot says whether that message was sent
    /// by then: nothing sent later will ever run here.
    pub fn resolve_intake(&mut self, index: Hex20, intake_id: Hex32, proof: Base64VecU8) {
        let (index, intake_id) = (index.0, intake_id.0);
        let state = self.intakes.get(&(index, intake_id)).map(|i| i.state);
        check(state == Some(INTAKE_OPEN), Error::IntakeNotOpen);
        let mark = self.read_hub(&index, snapshot::settled_slot(&Near, &intake_id), &proof.0);
        let settled = mark != [0u8; 32];
        event(
            "intake_resolved",
            near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id), "settled": settled}),
        );
        self.resolve(index, intake_id, settled);
    }

    /// Anyone after the snapshot, paying the storage it adds: a burn or migration the index sent before the snapshot and
    /// that never arrived runs on the index's own record of it (`_sentMessages`), once, within the speed limit, as a
    /// delivered one would. Every other kind in flight at the snapshot resolves without one: an intake's through
    /// `resolve_intake`, and governance not at all.
    #[payable]
    pub fn deliver_recorded(&mut self, payload: Base64VecU8, proof: Base64VecU8) {
        let before = env::storage_usage();
        let payload = payload.0;
        let id = abi::message_id(&Near, &payload);
        let m = abi::decode_message(&payload).unwrap_or_else(|e| fail(abi_err(e)));
        check(m.kind == BURN || m.kind == MIGRATE, Error::UnknownKind);
        self.check_route(&m);
        check(self.indexes.contains_key(&m.index), Error::NotAnIndex);
        let mark = self.read_hub(&m.index, snapshot::sent_slot(&Near, &id), &proof.0);
        check(mark != [0u8; 32], Error::NotRecorded);
        check(self.used.insert(id), Error::AlreadyDelivered);
        event(
            "message_delivered",
            near_sdk::serde_json::json!({"id": Hex32(id), "kind": m.kind, "index": Hex20(m.index)}),
        );
        self.index_message(&m, id);
        self.charge(before, 0);
    }

    // ---------------------------------------------------------------------
    // What Ethereum proves of this vault
    // ---------------------------------------------------------------------

    /// Anyone: succeeds only if every slot holds its value, and then returns, as the receipt's value and with nothing
    /// logged, `abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)` (interfaces doc). The
    /// slots are those the hub reads on an EVM vault: an intake's digest, an index's digest, and the snapshot's state
    /// root. A state proof of a successful `attest` is a proof of the vault's state, as on TRON. The height and time are
    /// the block's it ran in: the outcome that carries the record lands in a later block, whose time is not the run's.
    pub fn attest(&self, slots: Vec<Hex32>, values: Vec<Hex32>) {
        check(slots.len() == values.len(), Error::NotAttested);
        for (s, v) in slots.iter().zip(&values) {
            let held = self.slots.get(&s.0).copied().unwrap_or([0u8; 32]);
            check(held == v.0, Error::NotAttested);
        }
        let slots: Vec<[u8; 32]> = slots.iter().map(|s| s.0).collect();
        let values: Vec<[u8; 32]> = values.iter().map(|v| v.0).collect();
        env::value_return(attest_record(
            self.chain_id,
            &self.vault_id(),
            env::block_height(),
            env::block_timestamp(),
            &slots,
            &values,
        ));
    }

    // ---------------------------------------------------------------------
    // Payout callbacks
    // ---------------------------------------------------------------------

    /// The vault itself, after a payout's transfer: if the transfer failed, its amount is owed again, as the EVM vault's
    /// burn to a refusing recipient stays owed.
    #[private]
    pub fn on_payout(&mut self, index: Hex20, id: Hex32, amount: U128) {
        if env::promise_result_checked(0, 0).is_ok() {
            return;
        }
        let (index, id, amount) = (index.0, id.0, amount.0);
        if let Some(owed) = self.owed.get_mut(&(index, id)) {
            owed.remaining += amount;
        }
        if let Some(state) = self.indexes.get_mut(&index) {
            state.balance += amount;
            state.paid_total -= amount;
        }
        self.held += amount;
        self.refresh_index(&index);
        event(
            "payout_returned",
            near_sdk::serde_json::json!({"index": Hex20(index), "id": Hex32(id), "amount": U128(amount)}),
        );
    }

    /// The vault itself, after a refund's transfer: if the transfer failed, the deposit is the depositor's again.
    #[private]
    pub fn on_refund(
        &mut self,
        index: Hex20,
        intake_id: Hex32,
        depositor: AccountId,
        amount: U128,
    ) {
        if env::promise_result_checked(0, 0).is_ok() {
            return;
        }
        let (index, intake_id, amount) = (index.0, intake_id.0, amount.0);
        let key = (index, intake_id, depositor.clone());
        let mine = self.deposits.get(&key).copied().unwrap_or(0) + amount;
        self.deposits.insert(key, mine);
        if let Some(intake) = self.intakes.get_mut(&(index, intake_id)) {
            intake.total += amount;
        }
        self.held += amount;
        self.refresh_intake(&index, &intake_id);
        event(
            "refund_returned",
            near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id), "depositor": depositor, "amount": U128(amount)}),
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    pub fn config(&self) -> ConfigView {
        ConfigView {
            source_chain_id: self.source_chain_id,
            chain_id: self.chain_id,
            vault_id: Hex32(self.vault_id()),
            factory: Hex20(self.factory),
            hub_implementation: Hex20(self.hub_implementation),
            p1: Hex32(self.p1),
            p2: Hex32(self.p2),
            freezer: self.freezer.clone(),
            recovery_proposer: self.recovery_proposer.clone(),
            frozen_until: self.frozen_until,
            cap: U128(self.cap),
            outflow_floor: U128(self.outflow_floor),
            held: U128(self.held),
            nonces: [self.cap_nonce, self.freezer_nonce, self.rotation_nonce],
            pending_cap: self.pending_cap,
            pending_freezer: self.pending_freezer,
            pending_rotation: self.pending_rotation,
            checkpoint: self.checkpoint,
            snapshot: self.snapshot,
            successor: self.successor,
            last_message: Hex32(self.last_message),
            vetoes: self.vetoes,
        }
    }

    pub fn index_state(&self, index: Hex20) -> Option<IndexView> {
        self.indexes.get(&index.0).map(|s| IndexView {
            has_native: s.has_native,
            balance: U128(s.balance),
            paid_total: U128(s.paid_total),
            digest: Hex32(s.digest),
            available: U128(self.available(s)),
        })
    }

    pub fn intake(&self, index: Hex20, intake_id: Hex32) -> Option<IntakeView> {
        self.intakes
            .get(&(index.0, intake_id.0))
            .map(|i| IntakeView {
                state: i.state,
                total: U128(i.total),
                digest: Hex32(i.digest),
            })
    }

    pub fn deposited(&self, index: Hex20, intake_id: Hex32, depositor: AccountId) -> U128 {
        U128(
            self.deposits
                .get(&(index.0, intake_id.0, depositor))
                .copied()
                .unwrap_or(0),
        )
    }

    pub fn owed(&self, index: Hex20, id: Hex32) -> Option<OwedView> {
        self.owed.get(&(index.0, id.0)).map(|o| OwedView {
            recipient: o.recipient.clone(),
            new_index: o.recipient.is_none().then_some(Hex20(o.new_index)),
            remaining: U128(o.remaining),
        })
    }

    pub fn verifier(&self, id: Hex32) -> Option<LightClient> {
        self.verifiers.get(&id.0).copied()
    }

    pub fn range(&self, id: Hex32, headers_root: Hex32) -> Option<(u64, u64)> {
        self.ranges.get(&(id.0, headers_root.0)).copied()
    }

    pub fn used(&self, id: Hex32) -> bool {
        self.used.contains(&id.0)
    }

    pub fn slot(&self, slot: Hex32) -> Hex32 {
        Hex32(self.slots.get(&slot.0).copied().unwrap_or([0u8; 32]))
    }

    pub fn stalled(&self) -> bool {
        checkpoint::stalled(self.checkpoint.timestamp, now() as i64)
    }

    pub fn stall_start(&self) -> u64 {
        checkpoint::stall_start(self.checkpoint.timestamp) as u64
    }
}

impl Vault {
    /// The vault's initial state for `config` at time `now`, checked as `new` checks it. Also what a deterministic
    /// account's initial data holds, so the account's id commits to it.
    pub fn build(config: InitConfig, now: u64) -> Self {
        check(
            config.factory.0 != [0u8; 20] && config.hub_implementation.0 != [0u8; 20],
            Error::ZeroAddress,
        );
        // The twin of `DeployVault`'s checks: the recovery proposer is a multisig, which on NEAR is a contract account,
        // never an implicit account, which one key holds; and it is not the freezer, which vetoes what it proposes. A
        // contract cannot read another account's keys, so that a named account is a multisig with no full-access key is
        // the deployment's to check.
        check(
            !is_implicit(&config.recovery_proposer),
            Error::RecoveryNotMultisig,
        );
        check(config.recovery_proposer != config.freezer, Error::SameRole);
        config.p1.check();
        config.p2.check();
        check(
            config.p1.system != config.p2.system,
            Error::VerifiersNotDistinct,
        );
        let mut v = Self {
            source_chain_id: config.source_chain_id,
            chain_id: config.chain_id,
            factory: config.factory.0,
            hub_implementation: config.hub_implementation.0,
            p1: verifier_id(&config.p1),
            p2: verifier_id(&config.p2),
            freezer: config.freezer,
            recovery_proposer: config.recovery_proposer,
            frozen_until: 0,
            cap: config.native_cap.0,
            outflow_floor: config.native_floor.0,
            held: 0,
            cap_nonce: 0,
            freezer_nonce: 0,
            rotation_nonce: 0,
            pending_cap: PendingChange::default(),
            pending_freezer: PendingChange::default(),
            pending_rotation: PendingChange::default(),
            // Its first week's grace: a stall is a week without a new checkpoint, counted from initialization until the
            // first.
            checkpoint: Checkpoint {
                block: 0,
                timestamp: now,
                state_root: Hex32::default(),
            },
            snapshot: Checkpoint::default(),
            successor: Successor::default(),
            last_message: [0u8; 32],
            vetoes: 0,
            verifiers: LookupMap::new(Key::Verifiers),
            ranges: LookupMap::new(Key::Ranges),
            indexes: LookupMap::new(Key::Indexes),
            intakes: LookupMap::new(Key::Intakes),
            deposits: LookupMap::new(Key::Deposits),
            owed: LookupMap::new(Key::Owed),
            used: LookupSet::new(Key::Used),
            slots: LookupMap::new(Key::Slots),
        };
        v.add_verifier(&config.p1);
        v.add_verifier(&config.p2);
        v
    }

    /// The vault's id in messages and digests: `keccak256(utf8(account_id))` (interfaces doc). Read from the account
    /// itself each time, since a deterministic account's id is derived from its initial state, which so cannot hold it.
    pub fn vault_id(&self) -> [u8; 32] {
        Near.keccak256(&[env::current_account_id().as_bytes()])
    }

    fn add_verifier(&mut self, config: &VerifierConfig) -> [u8; 32] {
        config.check();
        let id = verifier_id(config);
        if !self.verifiers.contains_key(&id) {
            self.verifiers.insert(
                id,
                LightClient {
                    system: config.system,
                    key: config.key,
                    anchor: config.anchor,
                    epoch: config.epoch,
                    genesis_time: config.genesis_time,
                },
            );
            event(
                "verifier_registered",
                near_sdk::serde_json::json!({"id": Hex32(id), "config": config}),
            );
        }
        id
    }

    /// The caller pays, from the call's deposit, `taken` and the storage the call added; the rest goes back to it.
    fn charge(&mut self, before: u64, taken: u128) {
        self.flush();
        let added = env::storage_usage().saturating_sub(before) as u128;
        let cost = added * env::storage_byte_cost().as_yoctonear();
        let attached = env::attached_deposit().as_yoctonear();
        let due = taken
            .checked_add(cost)
            .unwrap_or_else(|| fail(Error::StorageNotPaid));
        check(attached >= due, Error::StorageNotPaid);
        if attached > due {
            Promise::new(env::predecessor_account_id())
                .transfer(NearToken::from_yoctonear(attached - due))
                .detach();
        }
    }

    /// Writes every collection's cached changes now, so `env::storage_usage` counts them.
    fn flush(&mut self) {
        self.verifiers.flush();
        self.ranges.flush();
        self.indexes.flush();
        self.intakes.flush();
        self.deposits.flush();
        self.owed.flush();
        // `used`, a `LookupSet`, writes through.
        self.slots.flush();
    }

    fn check_not_frozen(&self) {
        check(now() >= self.frozen_until, Error::VaultFrozen);
    }

    fn check_no_snapshot(&self) {
        check(
            self.snapshot.state_root.0 == [0u8; 32],
            Error::SnapshotTaken,
        );
    }

    fn snapshot_root(&self) -> [u8; 32] {
        let root = self.snapshot.state_root.0;
        check(root != [0u8; 32], Error::NoSnapshot);
        root
    }

    fn check_newer(&self, c: &Checkpoint) {
        check(
            checkpoint::is_newer(&self.checkpoint.core(), &c.core(), now() as i64),
            Error::NotNewer,
        );
    }

    fn check_recent(&self, c: &Checkpoint) {
        self.check_newer(c);
        check(
            checkpoint::is_recent(&c.core(), now() as i64),
            Error::NotRecent,
        );
    }

    /// The message is Ethereum's, for this chain and this vault.
    fn check_route(&self, m: &Message) {
        check(
            m.source_chain_id == self.source_chain_id
                && m.dest_chain_id == self.chain_id
                && m.vault == self.vault_id(),
            Error::WrongRoute,
        );
    }

    /// Two different registered light clients of two different proof systems: a successor or rotated pair.
    fn check_pair(&self, p1: &[u8; 32], p2: &[u8; 32]) {
        let a = self
            .verifiers
            .get(p1)
            .unwrap_or_else(|| fail(Error::UnknownVerifier));
        let b = self
            .verifiers
            .get(p2)
            .unwrap_or_else(|| fail(Error::UnknownVerifier));
        check(
            p1 != p2 && a.system != b.system,
            Error::VerifiersNotDistinct,
        );
    }

    /// Whether a message needs both proofs and a checkpoint covering its block: everything that moves coins or changes
    /// governance does. Only a freeze, and a cap update that raises neither the cap nor the floor, may rest on one.
    fn needs_both(&self, m: &Message) -> bool {
        let lowers = m.kind == CAP_UPDATE && {
            let (cap, floor) = read_cap(m.body);
            cap <= self.cap && floor <= self.outflow_floor
        };
        checkpoint::needs_both(m.kind, lowers)
    }

    fn recorded(
        &self,
        verifier: &[u8; 32],
        root: &[u8; 32],
    ) -> Result<(u64, u64), light_client::Error> {
        self.ranges
            .get(&(*verifier, *root))
            .copied()
            .ok_or(light_client::Error::UnknownHeaders)
    }

    fn verify_event(&self, verifier: &[u8; 32], proof: &[u8], claim: &LogClaim) {
        light_client::verify_event(&Near, proof, claim, |root| self.recorded(verifier, root))
            .unwrap_or_else(|e| fail(Error::Verifier(e)));
    }

    /// Both light clients of a pair prove checkpoint `c`, as `_agreed` requires: the same block, timestamp and root.
    fn checkpoint_by_both(
        &self,
        p1: &[u8; 32],
        p2: &[u8; 32],
        c: &Checkpoint,
        proofs: &PairProofs,
    ) {
        let claim = CheckpointClaim {
            block: c.block,
            timestamp: c.timestamp,
            state_root: c.state_root.0,
        };
        for (verifier, proof) in [(p1, &proofs.proof1), (p2, &proofs.proof2)] {
            check(
                self.verifiers.contains_key(verifier),
                Error::UnknownVerifier,
            );
            light_client::verify_checkpoint(&Near, &proof.0, &claim, |root| {
                self.recorded(verifier, root)
            })
            .unwrap_or_else(|e| fail(Error::Verifier(e)));
        }
    }

    /// One slot of `index`'s storage in Ethereum's state at the snapshot.
    fn read_hub(&self, index: &[u8; 20], slot: [u8; 32], proof: &[u8]) -> [u8; 32] {
        let root = self.snapshot_root();
        state_reader::read_slots(&Near, &root, index, &[slot], proof)
            .unwrap_or_else(|_| fail(Error::BadStateProof))[0]
    }

    fn index_message(&mut self, m: &Message, id: [u8; 32]) {
        match m.kind {
            BURN => self.burn(m, id),
            INTAKE_SETTLED | INTAKE_FAILED => {
                let intake_id = body_word(m.body, 1, 0);
                let state = self.intakes.get(&(m.index, intake_id)).map(|i| i.state);
                check(
                    state.is_none() || state == Some(INTAKE_OPEN),
                    Error::IntakeNotOpen,
                );
                self.resolve(m.index, intake_id, m.kind == INTAKE_SETTLED);
            }
            _ => self.migrate(m, id),
        }
    }

    /// A burn from an index: pays its recipient what the speed limit allows now, and owes the rest.
    fn burn(&mut self, m: &Message, id: [u8; 32]) {
        check_native(&body_word(m.body, 3, 0));
        let amount = amount(&body_word(m.body, 3, 1));
        let recipient = body_word(m.body, 3, 2);
        check(amount != 0, Error::ZeroAmount);
        check(recipient != [0u8; 32], Error::ZeroAddress);
        let to = account_of(&recipient);
        // The vault itself would strand the payout (SOL-9).
        check(to != env::current_account_id(), Error::WrongRecipient);
        self.owed.insert(
            (m.index, id),
            Owed {
                recipient: Some(to.clone()),
                new_index: [0u8; 20],
                remaining: amount,
            },
        );
        event(
            "burn_accepted",
            near_sdk::serde_json::json!({"index": Hex20(m.index), "id": Hex32(id), "amount": U128(amount), "recipient": to}),
        );
        self.pay(m.index, id, false);
    }

    /// A migration from an index: moves coins two index versions share from the old index's balance into the new one's,
    /// within the speed limit, as a burn leaves (Stage B spec, section 5.5). The coins never leave the vault.
    fn migrate(&mut self, m: &Message, id: [u8; 32]) {
        let new_index =
            abi::to_address(&body_word(m.body, 3, 0)).unwrap_or_else(|e| fail(abi_err(e)));
        check(
            new_index != m.index && self.indexes.contains_key(&new_index),
            Error::NotAnIndex,
        );
        check_native(&body_word(m.body, 3, 1));
        let amount = amount(&body_word(m.body, 3, 2));
        check(amount != 0, Error::ZeroAmount);
        self.owed.insert(
            (m.index, id),
            Owed {
                recipient: None,
                new_index,
                remaining: amount,
            },
        );
        event(
            "migration_accepted",
            near_sdk::serde_json::json!({"index": Hex20(m.index), "id": Hex32(id), "amount": U128(amount), "new_index": Hex20(new_index)}),
        );
        self.pay(m.index, id, false);
    }

    /// Settles an intake, whose deposits join the index, or fails it, so its depositors can take them back.
    fn resolve(&mut self, index: [u8; 20], intake_id: [u8; 32], settle: bool) {
        let mut intake = self
            .intakes
            .get(&(index, intake_id))
            .copied()
            .unwrap_or_default();
        if settle {
            intake.state = INTAKE_SETTLED_STATE;
            if intake.has_native {
                let state = self
                    .indexes
                    .get_mut(&index)
                    .unwrap_or_else(|| fail(Error::NotAnIndex));
                state.balance += intake.total;
                state.has_native = true;
                self.refresh_index(&index);
            }
            event(
                "intake_settled",
                near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id)}),
            );
        } else {
            intake.state = INTAKE_FAILED_STATE;
            event(
                "intake_failed",
                near_sdk::serde_json::json!({"index": Hex20(index), "intake_id": Hex32(intake_id)}),
            );
        }
        self.intakes.insert((index, intake_id), intake);
        self.refresh_intake(&index, &intake_id);
    }

    /// What more `state` may pay out now: 4% of its balance before the recent outflow, or the floor if larger.
    fn available(&self, state: &IndexState) -> u128 {
        let now = now() as i64;
        let recent = speed::recent_wide(state.outflow.iter().copied(), now);
        speed::available_wide(state.balance, recent, self.outflow_floor)
    }

    /// Pays what the speed limit, the index's balance and a freeze allow of owed `(index, id)`. `strict` is set for an
    /// explicit release, which fails when it can pay nothing; a message just accepted keeps waiting instead. A migration
    /// is paid into the new index's balance, so the coins stay in the vault and `held` stays; anything else is a transfer,
    /// whose failure puts the amount back (`on_payout`).
    fn pay(&mut self, index: [u8; 20], id: [u8; 32], strict: bool) {
        let owed = self
            .owed
            .get(&(index, id))
            .cloned()
            .unwrap_or_else(|| fail(Error::NothingOwed));
        check(owed.remaining != 0, Error::NothingOwed);
        let state = self
            .indexes
            .get(&index)
            .cloned()
            .unwrap_or_else(|| fail(Error::NotAnIndex));
        let pay = if now() < self.frozen_until {
            0
        } else {
            owed.remaining
                .min(self.available(&state))
                .min(state.balance)
        };
        if pay == 0 {
            check(!strict, Error::NothingPayable);
            return;
        }
        let now = now() as i64;
        let remaining = owed.remaining - pay;
        self.owed.get_mut(&(index, id)).unwrap().remaining = remaining;
        let s = self.indexes.get_mut(&index).unwrap();
        s.balance -= pay;
        s.paid_total += pay;
        let slot = speed::slot_of(speed::hour_of(now));
        s.outflow[slot] = speed::record_wide(s.outflow[slot], pay, now);
        self.refresh_index(&index);
        event(
            "paid",
            near_sdk::serde_json::json!({"index": Hex20(index), "id": Hex32(id), "amount": U128(pay), "remaining": U128(remaining)}),
        );
        match owed.recipient {
            None => {
                let new = self
                    .indexes
                    .get_mut(&owed.new_index)
                    .unwrap_or_else(|| fail(Error::NotAnIndex));
                new.balance += pay;
                new.has_native = true;
                self.refresh_index(&owed.new_index);
            }
            Some(to) => {
                self.held -= pay;
                Promise::new(to)
                    .transfer(NearToken::from_yoctonear(pay))
                    .then(
                        Self::ext(env::current_account_id())
                            .with_static_gas(CALLBACK_GAS)
                            .on_payout(Hex20(index), Hex32(id), U128(pay)),
                    )
                    .detach();
            }
        }
    }

    /// A freeze, a cap update raising neither figure, a raise, a new freezer or new verifiers from the factory. The
    /// factory's nonce only rises: an older message of a kind, delivered late, cannot undo a newer one (SOL-3). Only one
    /// on both proofs moves the mark, so a single broken proof system cannot lock the factory out with a forged nonce
    /// (VLT-4). A loosening change waits GOVERNANCE_DELAY here, where the freezer can see it and stop a raise or a
    /// rotation, however its proofs were obtained (VLT-2).
    fn governance_message(&mut self, m: &Message, loosening: bool, both: bool) {
        if m.kind == FREEZE {
            check(m.body.is_empty(), Error::BadMessage);
            // Nothing could replace the freezer after a snapshot, and nothing may hold the exit off (VLT-5).
            self.check_no_snapshot();
            self.freeze_now("factory".to_string());
            return;
        }
        let last = match m.kind {
            CAP_UPDATE => &mut self.cap_nonce,
            FREEZER_CHANGE => &mut self.freezer_nonce,
            _ => &mut self.rotation_nonce,
        };
        check(m.nonce > *last, Error::StaleGovernance);
        if both {
            *last = m.nonce;
        }
        // The body's form, checked before it waits.
        match m.kind {
            CAP_UPDATE => {
                read_cap(m.body);
            }
            FREEZER_CHANGE => {
                body_word(m.body, 1, 0);
            }
            _ => {
                body_word(m.body, 2, 0);
            }
        }
        if loosening {
            let ready_at = now() + GOVERNANCE_DELAY as u64;
            *self.pending(m.kind) = PendingChange {
                body_hash: Hex32(Near.keccak256(&[m.body])),
                ready_at,
            };
            event(
                "change_queued",
                near_sdk::serde_json::json!({"kind": m.kind, "body": Base64VecU8(m.body.to_vec()), "ready_at": ready_at}),
            );
        } else {
            // Newer than a waiting raise, which it replaces.
            *self.pending(m.kind) = PendingChange::default();
            self.apply(m.kind, m.body);
        }
    }

    fn apply(&mut self, kind: u8, body: &[u8]) {
        match kind {
            CAP_UPDATE => {
                let (cap, floor) = read_cap(body);
                self.cap = cap;
                self.outflow_floor = floor;
                event(
                    "cap_set",
                    near_sdk::serde_json::json!({"cap": U128(cap), "outflow_floor": U128(floor)}),
                );
            }
            FREEZER_CHANGE => {
                let word = body_word(body, 1, 0);
                check(word != [0u8; 32], Error::ZeroAddress);
                // Only an implicit account, never the recovery proposer, which initialization refuses to be one.
                let freezer = account_of(&word);
                self.freezer = freezer.clone();
                event(
                    "freezer_changed",
                    near_sdk::serde_json::json!({"freezer": freezer}),
                );
            }
            _ => {
                let (p1, p2) = (body_word(body, 2, 0), body_word(body, 2, 1));
                self.check_pair(&p1, &p2);
                self.p1 = p1;
                self.p2 = p2;
                event(
                    "verifiers_rotated",
                    near_sdk::serde_json::json!({"p1": Hex32(p1), "p2": Hex32(p2)}),
                );
            }
        }
    }

    fn pending(&mut self, kind: u8) -> &mut PendingChange {
        match kind {
            CAP_UPDATE => &mut self.pending_cap,
            FREEZER_CHANGE => &mut self.pending_freezer,
            VERIFIER_ROTATION => &mut self.pending_rotation,
            _ => fail(Error::NoPendingChange),
        }
    }

    /// Freezes the vault for FREEZE_DURATION from now; a later freeze extends it, and none shortens it.
    fn freeze_now(&mut self, by: String) {
        let until = now() + FREEZE_DURATION as u64;
        if until > self.frozen_until {
            self.frozen_until = until;
        }
        event(
            "frozen",
            near_sdk::serde_json::json!({"until": self.frozen_until, "by": by}),
        );
    }

    fn refresh_index(&mut self, index: &[u8; 20]) {
        let vault = self.vault_id();
        let state = self
            .indexes
            .get_mut(index)
            .unwrap_or_else(|| fail(Error::NotAnIndex));
        state.digest = abi::index_digest_wide(
            &Near,
            self.chain_id,
            &vault,
            index,
            state.has_native,
            state.balance,
            state.paid_total,
        );
        let digest = state.digest;
        self.slots.insert(index_slot(index), digest);
    }

    fn refresh_intake(&mut self, index: &[u8; 20], intake_id: &[u8; 32]) {
        let vault = self.vault_id();
        let intake = self
            .intakes
            .get_mut(&(*index, *intake_id))
            .unwrap_or_else(|| fail(Error::IntakeNotOpen));
        intake.digest = abi::intake_digest_wide(
            &Near,
            self.chain_id,
            &vault,
            index,
            intake_id,
            intake.state,
            intake.has_native,
            intake.total,
        );
        let digest = intake.digest;
        self.slots.insert(intake_slot(index, intake_id), digest);
    }
}

/// A cap update's body: NEAR's id, which must be zero, then its cap and floor.
fn read_cap(body: &[u8]) -> (u128, u128) {
    check_native(&body_word(body, 3, 0));
    (
        amount(&body_word(body, 3, 1)),
        amount(&body_word(body, 3, 2)),
    )
}

/// Where the hub reads an index's digest on an EVM vault: `keccak256(abi.encode(index, 14))`.
pub fn index_slot(index: &[u8; 20]) -> [u8; 32] {
    snapshot::mapping_slot(
        &Near,
        &abi::address_word(index),
        &abi::u256(INDEX_DIGEST_SLOT),
    )
}

/// Where the hub reads an intake's digest: `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`.
pub fn intake_slot(index: &[u8; 20], intake_id: &[u8; 32]) -> [u8; 32] {
    let inner = snapshot::mapping_slot(
        &Near,
        &abi::address_word(index),
        &abi::u256(INTAKE_DIGEST_SLOT),
    );
    snapshot::mapping_slot(&Near, intake_id, &inner)
}
