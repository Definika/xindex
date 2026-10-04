//! Checkpoints, the stall and stall recovery on the Stellar vault, against the EVM vault's rules (Stage B spec, section
//! 5.6) and the Solana vault's tests: the continuity test, vetoes, adoption, LG-2 and LG-3, the snapshot's start, VLT-5,
//! and the verifiers' pinned code, the twin of SOL-2.

mod common;

use common::*;
use soroban_sdk::{
    Address, Bytes, ContractExecutable, ContractExecutableRef, Env, Executable, String,
};
use xindex_core::constants::*;
use xindex_vault::error::VaultError;
use xindex_vault::types::*;

fn err<T: core::fmt::Debug + PartialEq>(
    r: Result<
        Result<T, soroban_sdk::ConversionError>,
        Result<soroban_sdk::Error, soroban_sdk::InvokeError>,
    >,
    e: VaultError,
) {
    match r {
        Err(Ok(got)) => assert_eq!(got, code(e)),
        other => panic!("expected {e:?}, got {other:?}"),
    }
}

/// The continuity test for a successor pair: the vault's last checkpoint, a recent one at `recent` now, and the last
/// message, each proven by the mocks' "proofs".
fn continuity(
    h: &H,
    recent: u64,
    message: Option<(&[u8], u64)>,
) -> (Continuity, Option<LastMessage>) {
    let last = h.config().checkpoint;
    let r = h.checkpoint_at(recent, h.now());
    let c = Continuity {
        last1: h.cp_proof(&last),
        last2: h.cp_proof(&last),
        recent1: h.cp_proof(&r),
        recent2: h.cp_proof(&r),
        recent: r,
    };
    let m = message.map(|(p, block)| LastMessage {
        payload: bytes(&h.env, p),
        block,
        proof1: h.proof_of(p, block),
        proof2: h.proof_of(p, block),
    });
    (c, m)
}

fn mocks(env: &Env) -> (Address, Address) {
    (
        env.register(MockVerifier, (false,)),
        env.register(MockVerifier, (false,)),
    )
}

/// A checkpoint needs both verifiers and must be newer, in blocks and in time, and not in the future.
#[test]
fn a_checkpoint_needs_both_proofs_and_is_always_newer() {
    let h = H::ready();
    h.warp(3600);
    let c = h.checkpoint_at(1_010, h.now() - 1200);
    let good = h.cp_proof(&c);
    let bad = Bytes::from_array(&h.env, &[1u8; 32]);
    assert!(h.v().try_advance_checkpoint(&c, &good, &bad).is_err());
    assert!(h.v().try_advance_checkpoint(&c, &bad, &good).is_err());
    for (block, t) in [
        (1_000, h.now()),
        (1_011, h.config().checkpoint.timestamp),
        (1_011, h.now() + 1),
    ] {
        let c = h.checkpoint_at(block, t);
        let p = h.cp_proof(&c);
        err(
            h.v().try_advance_checkpoint(&c, &p, &p),
            VaultError::NotNewer,
        );
    }
    h.v().advance_checkpoint(&c, &good, &good);
    assert_eq!(h.config().checkpoint, c);
}

/// The recovery proposer must be a contract, not the freezer; only it proposes, and only in a stall.
#[test]
fn recovery_propose_review_adopt() {
    let mut h = H::ready();
    let id = h.fund(10 * XLM);
    let settle = h.payload_last_settle(&id);
    let (n1, n2) = mocks(&h.env);
    let c = continuity(&h, 2_000, Some((&settle, 1)));
    err(
        h.v().try_propose_successor(&n1, &n2, &c.0, &c.1),
        VaultError::NotStalled,
    );
    h.warp(STALL_PERIOD as u64 + 1);
    let c = continuity(&h, 2_000, Some((&settle, 1)));
    err(
        h.v().try_propose_successor(&n1, &n1, &c.0, &c.1),
        VaultError::VerifiersNotDistinct,
    );
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    assert!(h.env.auths().iter().any(|(a, _)| *a == h.recovery));
    err(
        h.v().try_propose_successor(&n1, &n2, &c.0, &c.1),
        VaultError::SuccessorPending,
    );
    let fresh = h.checkpoint_at(3_000, h.now());
    let p = h.cp_proof(&fresh);
    err(
        h.v().try_adopt_successor(&fresh, &p, &p),
        VaultError::ReviewNotOver,
    );
    h.warp(RECOVERY_DELAY as u64);
    // The successor's proof of a checkpoint a month old is not recent.
    err(
        h.v().try_adopt_successor(&fresh, &p, &p),
        VaultError::NotRecent,
    );
    let fresh = h.checkpoint_at(3_000, h.now());
    let p = h.cp_proof(&fresh);
    h.v().adopt_successor(&fresh, &p, &p);
    let cfg = h.config();
    assert_eq!((cfg.p1.address, cfg.p2.address), (n1, n2));
    assert!(!h.v().stalled());
    assert!(h.v().successor().is_none());
    err(
        h.v().try_adopt_successor(&fresh, &p, &p),
        VaultError::NoSuccessor,
    );
}

/// What a successor must prove: (a) the checkpoint the pair in force last accepted, (b) a recent one, (c) the last
/// message delivered on both proofs.
#[test]
fn the_continuity_test() {
    let mut h = H::ready();
    let id = h.fund(10 * XLM);
    let settle = h.payload_last_settle(&id);
    let (n1, n2) = mocks(&h.env);
    h.warp(STALL_PERIOD as u64 + 10);
    // (a) another last checkpoint.
    let mut c = continuity(&h, 2_000, Some((&settle, 1)));
    let other = h.checkpoint_at(999, 1);
    c.0.last1 = h.cp_proof(&other);
    assert!(h.v().try_propose_successor(&n1, &n2, &c.0, &c.1).is_err());
    // (b) a recent checkpoint that is not recent: newer than the last, but over a week old.
    let mut c = continuity(&h, 2_000, Some((&settle, 1)));
    c.0.recent = h.checkpoint_at(2_000, h.config().checkpoint.timestamp + 1);
    assert!(c.0.recent.timestamp + (STALL_PERIOD as u64) < h.now());
    c.0.recent1 = h.cp_proof(&c.0.recent);
    c.0.recent2 = h.cp_proof(&c.0.recent);
    err(
        h.v().try_propose_successor(&n1, &n2, &c.0, &c.1),
        VaultError::NotRecent,
    );
    // (c) another message, or none.
    let other = h.burn_payload(1, &key_of("bob"));
    let c = continuity(&h, 2_000, Some((&other, 1)));
    err(
        h.v().try_propose_successor(&n1, &n2, &c.0, &c.1),
        VaultError::Discontinuous,
    );
    let c = continuity(&h, 2_000, None);
    err(
        h.v().try_propose_successor(&n1, &n2, &c.0, &c.1),
        VaultError::Discontinuous,
    );
    let c = continuity(&h, 2_000, Some((&settle, 1)));
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
}

/// The freezer vetoes at most twice a stall; a checkpoint from the pair in force lapses a successor and begins a new
/// stall's count.
#[test]
fn vetoes_and_lapse() {
    let h = H::ready();
    h.warp(STALL_PERIOD as u64 + 1);
    let (n1, n2) = mocks(&h.env);
    err(h.v().try_veto_successor(), VaultError::NoSuccessor);
    for i in 0..2u64 {
        let c = continuity(&h, 2_000 + i, None);
        h.v().propose_successor(&n1, &n2, &c.0, &c.1);
        h.v().veto_successor();
    }
    let c = continuity(&h, 2_010, None);
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    err(h.v().try_veto_successor(), VaultError::VetoesExhausted);
    assert_eq!(h.config().vetoes, 2);
    h.advance(2_020);
    assert!(h.v().successor().is_none());
    assert_eq!(h.config().vetoes, 0);
}

/// LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the checkpoint but
/// stale. Such an advance lets burns sent before the break run (VLT-3), and leaves the stall as it was: the successor
/// under review stays, and so does the freezer's count.
#[test]
fn test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes() {
    let h = H::ready();
    let last = h.config().checkpoint;
    h.warp(8 * DAY);
    let (n1, n2) = mocks(&h.env);
    let c = continuity(&h, 9_000, None);
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    h.v().veto_successor();
    let c = continuity(&h, 9_001, None);
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    let review_ends = h.v().successor().unwrap().review_ends;
    h.set_time(review_ends - DAY);
    let stale = h.checkpoint_at(1_001, last.timestamp + 12);
    h.advance_to(&stale);
    assert!(h.v().stalled());
    assert_eq!(
        h.v().successor().unwrap().review_ends,
        review_ends,
        "the review goes on"
    );
    assert_eq!(h.config().vetoes, 1, "the count goes on");
    h.v().veto_successor();
    let stale = h.checkpoint_at(1_002, last.timestamp + 24);
    h.advance_to(&stale);
    let c = continuity(&h, 9_002, None);
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    err(h.v().try_veto_successor(), VaultError::VetoesExhausted);
    h.set_time(h.v().successor().unwrap().review_ends);
    let fresh = h.checkpoint_at(9_100, h.now());
    let p = h.cp_proof(&fresh);
    h.v().adopt_successor(&fresh, &p, &p);
    assert_eq!(h.config().vetoes, 0);
}

/// LG-3: only a message on both proofs becomes the last message a successor must prove again. A forged one-proof
/// freeze still freezes, but cannot keep an honest successor out.
#[test]
fn test_lg3_a_one_proof_message_is_not_the_last_message() {
    let mut h = H::ready();
    let id = h.fund(10 * XLM);
    let settle = h.payload_last_settle(&id);
    let real = h.config().last_message;
    let forged = h.freeze_payload(FACTORY);
    h.deliver(&forged, By::P1);
    assert!(h.config().frozen_until > h.now());
    assert_eq!(h.config().last_message, real);
    h.warp(15 * DAY);
    let (n1, n2) = mocks(&h.env);
    let c = continuity(&h, 2_000, Some((&settle, 1)));
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
}

/// The snapshot begins 180 days into a stall, lapses any successor, and is final: no checkpoint, proposal or freeze
/// after it (VLT-5), and no message from a later block.
#[test]
fn the_snapshot_begins_after_180_days_of_stall() {
    let mut h = H::ready();
    let last = h.config().checkpoint;
    let due = h.v().stall_start() + SNAPSHOT_EXIT_DELAY as u64;
    h.set_time(due - 1);
    let (n1, n2) = mocks(&h.env);
    let c = continuity(&h, 2_000, None);
    h.v().propose_successor(&n1, &n2, &c.0, &c.1);
    err(h.v().try_begin_snapshot(), VaultError::SnapshotNotDue);
    h.set_time(due);
    h.v().begin_snapshot();
    let cfg = h.config();
    assert_eq!(cfg.snapshot, last);
    assert!(h.v().successor().is_none());
    // The snapshot's root is the slot the hub reads at bytes32(25).
    assert_eq!(h.v().slot(&b32(&h.env, &u256(25))), last.state_root);
    err(h.v().try_begin_snapshot(), VaultError::SnapshotTaken);
    let later = h.checkpoint_at(5_000, h.now());
    let p = h.cp_proof(&later);
    err(
        h.v().try_advance_checkpoint(&later, &p, &p),
        VaultError::SnapshotTaken,
    );
    h.block = 1_001;
    let q = h.payload(INTAKE_SETTLED, h.index, &[0u8; 32]);
    let r = h.try_deliver(&q, By::Both);
    assert_eq!(r, Err(code(VaultError::IssuedAfterSnapshot)));
}

/// VLT-5: nothing freezes the vault after its snapshot, neither the freezer nor the factory's message.
#[test]
fn test_vlt5_no_freeze_after_the_snapshot() {
    let mut h = H::ready();
    h.set_time(h.v().stall_start() + SNAPSHOT_EXIT_DELAY as u64);
    h.v().begin_snapshot();
    err(h.v().try_freeze(), VaultError::SnapshotTaken);
    let p = h.freeze_payload(FACTORY);
    assert_eq!(
        h.try_deliver(&p, By::P1),
        Err(code(VaultError::SnapshotTaken))
    );
}

/// Without a checkpoint there is nothing to take as the snapshot.
#[test]
fn no_snapshot_without_a_checkpoint() {
    let h = H::deployed();
    h.set_time(h.v().stall_start() + SNAPSHOT_EXIT_DELAY as u64);
    err(h.v().try_begin_snapshot(), VaultError::NoCheckpoint);
}

/// The twin of SOL-2: a verifier whose code changes after the vault took it, by its own upgrade or behind an
/// executable reference, is refused, so a verifier's operator cannot rewrite P1 or P2 past the 30-day rotation.
#[test]
fn test_sol2_a_verifier_whose_code_changed_is_refused() {
    let h = H::ready();
    let other = h
        .env
        .deployer()
        .upload_contract_wasm(wasm("p1_verifier").as_slice());
    let p1 = h.p1.clone();
    h.env.as_contract(&p1, || {
        h.env
            .deployer()
            .update_current_contract(ContractExecutable::Wasm(other.clone()));
    });
    let c = h.checkpoint_at(1_001, h.now());
    let p = h.cp_proof(&c);
    err(
        h.v().try_advance_checkpoint(&c, &p, &p),
        VaultError::VerifierChanged,
    );
}

/// The same behind an executable reference (CAP-0085): a verifier that runs its pinned code through another contract's
/// reference still works, and is refused once that contract points the reference at other code.
#[test]
fn test_sol2_a_verifier_behind_a_reference_is_refused_once_it_moves() {
    let h = H::ready();
    let pinned = match h.p1.executable() {
        Some(Executable::Wasm(code)) => code,
        other => panic!("{other:?}"),
    };
    let other = h
        .env
        .deployer()
        .upload_contract_wasm(wasm("p1_verifier").as_slice());
    let owner = h.env.register(MockMultisig, ());
    let tag = String::from_str(&h.env, "p1");
    h.env
        .as_contract(&owner, || h.env.executable_refs().set(&tag, &pinned));
    let p1 = h.p1.clone();
    h.env.as_contract(&p1, || {
        h.env
            .deployer()
            .update_current_contract(ContractExecutable::ExternalRef(ContractExecutableRef {
                owner: owner.clone(),
                tag: tag.clone(),
            }));
    });
    h.warp(1);
    let c = h.checkpoint_at(1_001, h.now());
    let p = h.cp_proof(&c);
    h.v().advance_checkpoint(&c, &p, &p);
    h.env
        .as_contract(&owner, || h.env.executable_refs().set(&tag, &other));
    h.warp(1);
    let c = h.checkpoint_at(1_002, h.now());
    let p = h.cp_proof(&c);
    err(
        h.v().try_advance_checkpoint(&c, &p, &p),
        VaultError::VerifierChanged,
    );
}

impl HExt for H {
    fn payload_last_settle(&mut self, _id: &[u8; 32]) -> std::vec::Vec<u8> {
        // The settle message `fund` delivered is the last on both proofs: rebuild it under the nonce it took.
        let nonce = self.nonce;
        payload_with(INTAKE_SETTLED, self.index, nonce, _id)
    }
}

trait HExt {
    fn payload_last_settle(&mut self, id: &[u8; 32]) -> std::vec::Vec<u8>;
}
