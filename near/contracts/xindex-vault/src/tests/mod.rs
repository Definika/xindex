//! The vault's rules in near-sdk's mocked runtime, which runs nearcore's own host functions, so the clock can move a
//! year in a test. Messages arrive in real Ethereum receipts: a legacy receipt carrying the `VaultMessage` log, alone in
//! its block's receipts trie, the block alone under a headers root P1 and P2 recorded, as `FinalityVerifier.verifyEvent`
//! would take it. The snapshot exit reads a real hub's storage (`tests/fixtures/hub.json`, which `generate.py` captures
//! from the repository's own contracts on anvil, with this vault's id and NEAR's registry id).

pub mod encode;
mod exit;
mod governance;
mod messages;
mod recovery;
mod setup;

use std::panic::{catch_unwind, AssertUnwindSafe};

use near_sdk::json_types::{Base64VecU8, U128, U64};
use near_sdk::test_utils::VMContextBuilder;
use near_sdk::{testing_env, AccountId, Gas, NearToken};
use xindex_core::abi::{address_word, u256, u256_wide};
use xindex_core::constants::*;

pub use crate::fixtures::{hex, risc0_receipt, sp1_fixture};
pub use crate::*;
pub use encode::*;

pub const VAULT: &str = "vault.test.near";
pub const SEPOLIA: u64 = 11_155_111;
pub const NEAR_TESTNET: u64 = 4_078_699_518_750_379_172;
pub const ONE: u128 = 1_000_000_000_000_000_000_000_000;
pub const SEPOLIA_GENESIS: u64 = 1_655_733_600;
pub const FREEZER: &str = "freezer.test.near";
pub const RECOVERY: &str = "recovery.test.near";
pub const RELAYER: &str = "relayer.test.near";
pub const ALICE: &str = "alice.test.near";

pub fn json() -> near_sdk::serde_json::Value {
    near_sdk::serde_json::from_str(&crate::fixtures::repo_file(
        "near/contracts/xindex-vault/tests/fixtures/hub.json",
    ))
    .unwrap()
}

pub fn h20(v: &near_sdk::serde_json::Value) -> [u8; 20] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

pub fn h32(v: &near_sdk::serde_json::Value) -> [u8; 32] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

pub fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    Near.keccak256(parts)
}

/// Runs `f`, which must fail with `XindexVault: <expected>`. The mocked runtime does not roll a failed call back, so
/// every test fails a call only where it fails before changing anything, or as its last.
pub fn fails<R>(expected: &str, f: impl FnOnce() -> R) {
    host_fails(&format!("XindexVault: {expected}"), f)
}

/// Runs `f`, which must fail with a message containing `expected`: the vault's, or a host function's.
pub fn host_fails<R>(expected: &str, f: impl FnOnce() -> R) {
    let err = catch_unwind(AssertUnwindSafe(f))
        .err()
        .unwrap_or_else(|| panic!("expected {expected}, but it succeeded"));
    let msg = err
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| err.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default();
    assert!(msg.contains(expected), "expected {expected}, got {msg}");
}

/// The mocked runtime at `now` (unix seconds), called by `who` with `deposit` attached.
pub fn at(now: u64, who: &str, deposit: u128) {
    testing_env!(VMContextBuilder::new()
        .current_account_id(VAULT.parse().unwrap())
        .predecessor_account_id(who.parse().unwrap())
        .signer_account_id(who.parse().unwrap())
        .block_timestamp(now * 1_000_000_000)
        .attached_deposit(NearToken::from_yoctonear(deposit))
        .prepaid_gas(Gas::from_tgas(1000))
        .build());
}

pub fn verifier_config(system: u8, seed: u8, epoch: u64) -> VerifierConfig {
    VerifierConfig {
        system,
        key: Hex32([seed; 32]),
        anchor: Hex32([seed ^ 0xff; 32]),
        epoch,
        genesis_time: SEPOLIA_GENESIS,
    }
}

/// An epoch whose lag ends a day after `now`.
pub fn epoch_at(now: u64) -> u64 {
    (now - SEPOLIA_GENESIS) / 384
}

/// A test: the vault, the clock, and the fixture's factory, template and index.
pub struct T {
    pub v: Vault,
    pub now: u64,
    /// The next Ethereum block a message or checkpoint is placed in.
    pub block: u64,
    pub nonce: u64,
    pub f: near_sdk::serde_json::Value,
    pub index: [u8; 20],
}

impl T {
    pub fn config(f: &near_sdk::serde_json::Value, now: u64) -> InitConfig {
        InitConfig {
            source_chain_id: U64(SEPOLIA),
            chain_id: U64(NEAR_TESTNET),
            factory: Hex20(h20(&f["factory"])),
            hub_implementation: Hex20(h20(&f["hub_implementation"])),
            p1: verifier_config(SP1, 1, epoch_at(now)),
            p2: verifier_config(RISC_ZERO, 2, epoch_at(now)),
            freezer: FREEZER.parse().unwrap(),
            recovery_proposer: RECOVERY.parse().unwrap(),
            native_cap: U128(1_000_000 * ONE),
            native_floor: U128(ONE),
        }
    }

    /// The vault initialized a little before the fixture's settled intake's deadline, with its index registered and a
    /// first checkpoint, at block 1, which deposits wait for (B1-04).
    pub fn new() -> Self {
        let mut t = Self::bare();
        t.advance(1);
        t
    }

    /// As `new`, before any checkpoint.
    pub fn bare() -> Self {
        let f = json();
        let now = f["settled_intake"]["deadline"].as_u64().unwrap() - 600;
        at(now, RELAYER, 0);
        let v = Vault::new(Self::config(&f, now));
        let index = h20(&f["index"]);
        let mut t = T {
            v,
            now,
            block: 1_000,
            nonce: 0,
            f,
            index,
        };
        let salt = Hex32(h32(&t.f["salt"]));
        t.call(RELAYER, ONE, |v| v.register_index(Hex20(index), salt));
        t
    }

    /// Runs `f` on the vault at the current time, as `who` with `deposit`.
    pub fn call<R>(&mut self, who: &str, deposit: u128, f: impl FnOnce(&mut Vault) -> R) -> R {
        at(self.now, who, deposit);
        f(&mut self.v)
    }

    pub fn warp(&mut self, seconds: u64) {
        self.now += seconds;
    }

    /// The body of the factory's FREEZE of a freeze it began now: it ends FREEZE_DURATION from now.
    pub fn freeze_body(&self) -> Vec<u8> {
        freeze_body(self.now + FREEZE_DURATION as u64)
    }

    pub fn vault_id() -> [u8; 32] {
        keccak(&[VAULT.as_bytes()])
    }

    /// `VaultMessages.encode`: a message of `kind` from `emitter` with `body`, to this vault.
    pub fn payload(&mut self, kind: u8, emitter: &[u8; 20], body: &[u8]) -> Vec<u8> {
        self.nonce += 1;
        Self::payload_with(kind, emitter, body, self.nonce, NEAR_TESTNET)
    }

    pub fn payload_with(
        kind: u8,
        emitter: &[u8; 20],
        body: &[u8],
        nonce: u64,
        dest: u64,
    ) -> Vec<u8> {
        encode::message(SEPOLIA, kind, emitter, body, nonce, dest, &Self::vault_id())
    }

    /// P1's and P2's proof of `payload`'s log by `emitter`, in a block of its own, whose range both recorded.
    pub fn event_proof(&mut self, emitter: &[u8; 20], payload: &[u8], block: u64) -> Vec<u8> {
        let (proof, root) = encode::event_proof(emitter, payload, block, self.now);
        self.record(root, block);
        proof
    }

    /// Both P1 and P2 recorded the one-block range `block` under `root`, as a proof of the statement would have.
    pub fn record(&mut self, root: [u8; 32], block: u64) {
        let (p1, p2) = (self.v.p1, self.v.p2);
        self.record_for(&p1, root, block);
        self.record_for(&p2, root, block);
    }

    pub fn record_for(&mut self, verifier: &[u8; 32], root: [u8; 32], block: u64) {
        self.v.ranges.insert((*verifier, root), (block, block));
    }

    /// Delivers `payload` from `emitter`, in the next block, on P1's proof, P2's, or both.
    pub fn deliver_by(&mut self, emitter: &[u8; 20], payload: &[u8], p1: bool, p2: bool) {
        let block = self.next_block();
        self.deliver_at(emitter, payload, p1, p2, block);
    }

    pub fn deliver_at(
        &mut self,
        emitter: &[u8; 20],
        payload: &[u8],
        p1: bool,
        p2: bool,
        block: u64,
    ) {
        let proof = self.event_proof(emitter, payload, block);
        let proof = Base64VecU8(proof);
        let (a, b) = (p1.then(|| proof.clone()), p2.then(|| proof.clone()));
        let payload = Base64VecU8(payload.to_vec());
        self.call(RELAYER, ONE, |v| v.deliver(payload, block, a, b));
    }

    /// A message of `kind` from the index, on both proofs, from a block the checkpoint covers.
    pub fn deliver(&mut self, kind: u8, body: &[u8]) -> Vec<u8> {
        let index = self.index;
        let payload = self.payload(kind, &index, body);
        self.deliver_by(&index, &payload, true, true);
        payload
    }

    /// The next block for a message: one the vault's checkpoint already covers.
    pub fn next_block(&mut self) -> u64 {
        let covered = self.v.checkpoint.block;
        if covered < self.block + 1 {
            self.advance(self.block + 100);
        }
        self.block += 1;
        self.block
    }

    /// A checkpoint at `block`, now, with a state root of its own, that P1 and P2 both prove; a second later first if
    /// the last checkpoint is dated now, since a checkpoint must be newer in time too.
    pub fn advance(&mut self, block: u64) {
        if self.v.checkpoint.timestamp >= self.now {
            self.warp(1);
        }
        let root = keccak(&[b"state", &block.to_le_bytes()]);
        self.advance_to(block, self.now, root);
    }

    /// Whether the vault is stalled at the test's clock.
    pub fn stalled(&mut self) -> bool {
        self.call(RELAYER, 0, |v| v.stalled())
    }

    pub fn advance_to(&mut self, block: u64, timestamp: u64, state_root: [u8; 32]) {
        let c = Checkpoint {
            block,
            timestamp,
            state_root: Hex32(state_root),
        };
        let proofs = self.checkpoint_proofs(&c, None);
        self.call(RELAYER, 0, |v| v.advance_checkpoint(c, proofs));
    }

    /// The pair's proofs of checkpoint `c`, its block recorded by `pair` (P1 and P2 in force when none).
    pub fn checkpoint_proofs(
        &mut self,
        c: &Checkpoint,
        pair: Option<([u8; 32], [u8; 32])>,
    ) -> PairProofs {
        let (head, root) = header(c.block, c.timestamp, &c.state_root.0, &[9u8; 32]);
        let (p1, p2) = pair.unwrap_or((self.v.p1, self.v.p2));
        self.record_for(&p1, root, c.block);
        self.record_for(&p2, root, c.block);
        PairProofs {
            proof1: Base64VecU8(head.clone()),
            proof2: Base64VecU8(head),
        }
    }

    /// Deposits `amount` into a fresh intake from `who`, and settles it on both proofs: the index holds it.
    pub fn fund(&mut self, amount: u128) -> [u8; 32] {
        self.nonce += 1;
        let intake = intake_id(self.now + 3600, self.nonce);
        self.deposit(ALICE, &intake, amount);
        self.deliver(INTAKE_SETTLED, &intake);
        intake
    }

    pub fn deposit(&mut self, who: &str, intake: &[u8; 32], amount: u128) {
        let (index, intake) = (Hex20(self.index), Hex32(*intake));
        self.call(who, amount + ONE, |v| {
            v.deposit(index, intake, U128(amount))
        });
    }

    pub fn balance(&self) -> u128 {
        self.v.indexes.get(&self.index).unwrap().balance
    }
}

/// The transfers the call scheduled, their receivers and amounts, leaving out the relayer's change: the relayer, which
/// sends every message here, is never a payee.
pub fn transfers() -> Vec<(AccountId, u128)> {
    near_sdk::test_utils::get_created_receipts()
        .into_iter()
        .filter(|r| r.receiver_id.as_str() != RELAYER)
        .flat_map(|r| {
            let to = r.receiver_id.clone();
            r.actions.into_iter().filter_map(move |a| match a {
                near_sdk::mock::MockAction::Transfer { deposit, .. } => {
                    Some((to.clone(), deposit.as_yoctonear()))
                }
                _ => None,
            })
        })
        .collect()
}

/// The events the call logged, by name.
pub fn events() -> Vec<String> {
    near_sdk::test_utils::get_logs()
        .into_iter()
        .filter_map(|l| {
            let v: near_sdk::serde_json::Value =
                near_sdk::serde_json::from_str(l.strip_prefix("EVENT_JSON:")?).ok()?;
            Some(v["event"].as_str()?.to_string())
        })
        .collect()
}
