//! Checkpoints, the stall and stall recovery on the Solana vault, against the EVM vault's rules (Stage B spec, section
//! 5.6), in LiteSVM with stub verifiers: VLT-3, LG-2 and LG-3, the continuity test, vetoes, adoption, and the snapshot's
//! start. The stub logs the checkpoint it is asked about, so the tests see what the vault asked each verifier.

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex_vault::{constants::*, error::VaultError, state::Checkpoint, vault};

/// Deposits `amount` into a fresh intake of `index` and settles it on both proofs; returns the settle message, the last
/// message a successor must prove again.
fn fund(h: &mut Harness, index: [u8; 20], amount: u64) -> Vec<u8> {
    h.nonce += 1;
    let intake = intake_id(h.now() + 3600, h.nonce);
    let depositor = Keypair::new();
    h.svm.airdrop(&depositor.pubkey(), amount + SOL).unwrap();
    h.deposit(&depositor, index, intake, amount).expect_ok();
    let payload = h.payload(INTAKE_SETTLED, index, &intake);
    h.deliver_intake_payload(index, intake, payload.clone(), By::Both)
        .expect_ok();
    payload
}

fn stall(h: &mut Harness) {
    let start = vault::stall_start(&h.config());
    h.set_time(start + 1);
    assert!(vault::stalled(&h.config(), h.now()));
}

// ---------------------------------------------------------------------
// initialization
// ---------------------------------------------------------------------

/// The recovery proposer is a multisig: an address off the curve, never a key, and never the freezer.
#[test]
fn the_recovery_proposer_is_a_multisig() {
    let mut h = Harness::new();
    let authority = h.authority.insecure_clone();
    let mut args = h.init_args();
    args.recovery_proposer = Pubkey::default();
    let ix = h.initialize_ix(&authority.pubkey(), args, h.p1, h.p2);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::ZeroAddress);
    let mut args = h.init_args();
    args.recovery_proposer = Keypair::new().pubkey();
    let ix = h.initialize_ix(&authority.pubkey(), args, h.p1, h.p2);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::RecoveryNotMultisig);
    let mut args = h.init_args();
    args.freezer = args.recovery_proposer;
    let ix = h.initialize_ix(&authority.pubkey(), args, h.p1, h.p2);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::SameRole);

    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_ok();
    let c = h.config();
    assert_eq!(c.recovery_proposer, h.recovery);
    assert_eq!(
        c.checkpoint,
        Checkpoint {
            block: 0,
            timestamp: START as u64,
            state_root: [0u8; 32]
        },
        "a week's grace from initialization"
    );
    assert_eq!(c.last_message, [0u8; 32]);
}

// ---------------------------------------------------------------------
// checkpoints and the stall
// ---------------------------------------------------------------------

/// The demo's relayer reads the checkpoint's block straight from the `config` account, at the offset its
/// `CHECKPOINT_OFFSET` (`demo/relayer/src/solana.ts`) names: this pins that offset to the account's real layout.
#[test]
fn the_relayers_checkpoint_offset() {
    const CHECKPOINT_OFFSET: usize = 8 + 16 + 40 + 96 + 56 + 120 + 2 + 32;
    let (h, _) = Harness::ready();
    let data = h.svm.get_account(&h.config).unwrap().data;
    let c = h.config().checkpoint;
    assert_eq!(c.block, 1_000);
    let at = |i: usize| u64::from_le_bytes(data[i..i + 8].try_into().unwrap());
    assert_eq!(at(CHECKPOINT_OFFSET), c.block);
    assert_eq!(at(CHECKPOINT_OFFSET + 8), c.timestamp);
    assert_eq!(
        &data[CHECKPOINT_OFFSET + 16..CHECKPOINT_OFFSET + 48],
        &c.state_root
    );
}

#[test]
fn a_checkpoint_needs_both_proofs_and_is_always_newer() {
    let (mut h, _) = Harness::ready();
    h.warp(3600);
    let t = h.now() - 1200;
    let c = Checkpoint {
        block: 1_010,
        timestamp: t as u64,
        state_root: [7u8; 32],
    };
    // P1's proof alone: P2's program is missing from the accounts.
    let (mut verifiers, mut relayers) = (Vec::new(), Vec::new());
    Harness::pair_accounts(&h.pair(), &mut verifiers, &mut relayers);
    verifiers.truncate(3);
    h.advance_with(c, verifiers, &relayers[..1])
        .expect_code(VaultError::WrongVerifier);
    // Another relayer than P2's.
    let mut forged = h.pair();
    forged.relayer2 = Keypair::new();
    h.advance_by(c, &forged)
        .expect_error("MissingRequiredSignature");

    let out = h.advance_to(c);
    out.expect_ok();
    assert_eq!(out.count("checkpoint 1010 at"), 2, "both verifiers asked");
    println!("advance_checkpoint: {} compute units", out.cu);
    assert_eq!(h.config().checkpoint, c);

    let not_newer = |block: u64, timestamp: i64, root: [u8; 32]| Checkpoint {
        block,
        timestamp: timestamp as u64,
        state_root: root,
    };
    h.advance_to(not_newer(1_010, t + 1, [7u8; 32]))
        .expect_code(VaultError::NotNewer); // no later block
    h.advance_to(not_newer(1_011, t, [7u8; 32]))
        .expect_code(VaultError::NotNewer); // no later time
    let future = h.now() + 1;
    h.advance_to(not_newer(1_011, future, [7u8; 32]))
        .expect_code(VaultError::NotNewer); // in the future
    h.advance_to(not_newer(1_011, t + 1, [0u8; 32]))
        .expect_code(VaultError::NotNewer); // no state
    h.advance(1_011).expect_ok();
}

/// A week without a checkpoint stalls the vault: it takes no deposit, which it might never be able to settle or refund,
/// until anyone brings a new checkpoint.
#[test]
fn a_week_without_a_checkpoint_stalls_the_vault() {
    let (mut h, index) = Harness::ready();
    let start = vault::stall_start(&h.config());
    assert_eq!(start, h.config().checkpoint.timestamp as i64 + STALL_PERIOD);
    h.set_time(start);
    assert!(!vault::stalled(&h.config(), h.now()));
    let alice = Keypair::new();
    h.svm.airdrop(&alice.pubkey(), 10 * SOL).unwrap();
    let intake = intake_id(start + 3600, 1);
    h.deposit(&alice, index, intake, SOL).expect_ok();
    h.set_time(start + 1);
    h.deposit(&alice, index, intake, SOL)
        .expect_code(VaultError::VaultStalled);
    h.fresh();
    h.deposit(&alice, index, intake, SOL).expect_ok();
}

/// VLT-3: a message that moves coins or loosens a rule runs only from a block the checkpoint covers, so the snapshot at
/// that checkpoint never pays a holder whose burn the vault paid too. A freeze and a lowered cap need no checkpoint.
#[test]
fn test_vlt3_a_message_after_the_checkpoint_waits_for_it() {
    let (mut h, index) = Harness::ready();
    fund(&mut h, index, 10 * SOL);
    let bob = Pubkey::new_unique();
    h.block = 1_001;
    let burn = h.payload(BURN, index, &burn_body(SOL, &bob));
    h.deliver_burn(index, burn.clone(), bob, By::Both)
        .expect_code(VaultError::NotCheckpointed);
    let intake = intake_id(h.now() + 3600, 77);
    h.deliver_intake(index, intake, INTAKE_FAILED, By::Both)
        .expect_code(VaultError::NotCheckpointed);
    let raise = h.payload(CAP_UPDATE, FACTORY, &cap_body(2 * CAP, FLOOR));
    h.deliver_governance(raise, By::Both)
        .expect_code(VaultError::NotCheckpointed);
    let lower = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 2, FLOOR));
    h.deliver_governance(lower, By::Both).expect_ok();
    assert_eq!(h.config().cap, CAP / 2);
    let freeze = h.freeze_payload(FACTORY);
    h.deliver_governance(freeze, By::P1).expect_ok();
    h.set_time(h.config().frozen_until);
    h.advance(1_001).expect_ok();
    h.deliver_burn(index, burn, bob, By::Both).expect_ok();
    assert_eq!(h.lamports(&bob), SOL);
}

// ---------------------------------------------------------------------
// stall recovery
// ---------------------------------------------------------------------

/// A stall, a successor proposed by the emergency multisig, 30 days of review, adoption on a fresh checkpoint: the
/// vault runs on the new pair and no longer stalls. The successor is asked about the last checkpoint, a recent one and
/// the last message, by both its verifiers.
#[test]
fn recovery_propose_review_adopt() {
    let (mut h, index) = Harness::ready();
    let last = fund(&mut h, index, 10 * SOL);
    assert_eq!(h.config().last_message, abi_id(&last));
    stall(&mut h);
    let pair = h.new_pair();
    let stranger = Keypair::new();
    let c = h.continuity(2_000, Some((last.clone(), 1)));
    h.propose(&pair, c.clone(), Some(&stranger))
        .expect_code(VaultError::NotRecoveryProposer);
    let twice = Pair {
        p1: pair.p1,
        p2: pair.p1,
        relayer1: pair.relayer1.insecure_clone(),
        relayer2: pair.relayer1.insecure_clone(),
    };
    h.propose(&twice, c.clone(), None)
        .expect_code(VaultError::VerifiersNotDistinct);
    let out = h.propose(&pair, c.clone(), None);
    out.expect_ok();
    println!("propose_successor: {} compute units", out.cu);
    assert_eq!(
        out.count("checkpoint 1000 at"),
        2,
        "(a) the last checkpoint"
    );
    assert_eq!(out.count("checkpoint 2000 at"), 2, "(b) a recent one");
    assert_eq!(out.count("log accepted"), 2, "(c) the last message");
    let s = h.config().successor;
    assert_eq!((s.p1, s.p2), (pair.p1, pair.p2));
    let review_ends = h.now() + RECOVERY_DELAY;
    assert_eq!(s.review_ends, review_ends);
    h.propose(&pair, c.clone(), None)
        .expect_code(VaultError::SuccessorPending);

    h.adopt(Harness::checkpoint_at(2_100, h.now()), &pair)
        .expect_code(VaultError::ReviewNotOver);
    h.set_time(review_ends);
    h.adopt(c.recent, &pair).expect_code(VaultError::NotRecent);
    // Only the successor's verifiers prove the adoption's checkpoint.
    let old = h.pair();
    h.adopt(Harness::checkpoint_at(3_000, h.now()), &old)
        .expect_code(VaultError::WrongVerifier);
    let out = h.adopt(Harness::checkpoint_at(3_000, h.now()), &pair);
    out.expect_ok();
    println!("adopt_successor: {} compute units", out.cu);
    let config = h.config();
    assert_eq!((config.p1, config.p2), (pair.p1, pair.p2));
    assert_eq!(config.checkpoint.block, 3_000);
    assert_eq!(config.successor.review_ends, 0);
    assert!(!vault::stalled(&config, h.now()));
    h.adopt(Harness::checkpoint_at(3_001, h.now()), &pair)
        .expect_code(VaultError::NoSuccessor);

    // The new pair delivers.
    h.p1 = pair.p1;
    h.p2 = pair.p2;
    h.relayer1 = pair.relayer1.insecure_clone();
    h.relayer2 = pair.relayer2.insecure_clone();
    let bob = Pubkey::new_unique();
    let burn = h.payload(BURN, index, &burn_body(SOL, &bob));
    h.deliver_burn(index, burn, bob, By::Both).expect_ok();
    assert_eq!(h.lamports(&bob), SOL);
}

fn abi_id(payload: &[u8]) -> [u8; 32] {
    xindex_vault::abi::message_id(payload)
}

/// What a successor must prove: the checkpoint the pair in force last accepted, a recent one, and the last message
/// delivered, by two different verifier programs nobody can upgrade. Only in a stall.
#[test]
fn the_continuity_test() {
    let (mut h, index) = Harness::ready();
    let last = fund(&mut h, index, 10 * SOL);
    let pair = h.new_pair();
    let c = h.continuity(2_000, Some((last.clone(), 1)));
    h.propose(&pair, c, None)
        .expect_code(VaultError::NotStalled);
    stall(&mut h);
    h.warp(DAY);

    // (b) a checkpoint no newer than the last, or not recent
    let mut c = h.continuity(1_000, Some((last.clone(), 1)));
    h.propose(&pair, c.clone(), None)
        .expect_code(VaultError::NotNewer);
    c.recent = Checkpoint {
        block: 2_000,
        timestamp: h.config().checkpoint.timestamp + 1,
        state_root: [9u8; 32],
    };
    h.propose(&pair, c, None).expect_code(VaultError::NotRecent);
    // (c) another message than the last delivered, or none
    let other = h.payload(BURN, index, &burn_body(SOL, &Pubkey::new_unique()));
    let c = h.continuity(2_000, Some((other, 1)));
    h.propose(&pair, c, None)
        .expect_code(VaultError::Discontinuous);
    let c = h.continuity(2_000, None);
    h.propose(&pair, c, None)
        .expect_code(VaultError::Discontinuous);
    // SOL-2: a successor someone could still upgrade.
    h.set_upgrade_authority(pair.p2, Some(Keypair::new().pubkey()));
    let c = h.continuity(2_000, Some((last.clone(), 1)));
    h.propose(&pair, c.clone(), None)
        .expect_code(VaultError::VerifierUpgradeable);
    h.set_upgrade_authority(pair.p2, None);
    h.propose(&pair, c, None).expect_ok();
}

/// A vault that never delivered a message needs no message proven again.
#[test]
fn a_vault_with_no_message_needs_none_proven() {
    let (mut h, _) = Harness::ready();
    stall(&mut h);
    let pair = h.new_pair();
    let c = h.continuity(2_000, None);
    let out = h.propose(&pair, c, None);
    out.expect_ok();
    assert_eq!(out.count("log accepted"), 0);
}

/// The freezer vetoes at most twice a stall; a checkpoint that ends the stall lapses a successor and starts the count
/// again.
#[test]
fn vetoes_and_lapse() {
    let (mut h, _) = Harness::ready();
    stall(&mut h);
    let pair = h.new_pair();
    let stranger = Keypair::new();
    h.veto(&stranger).expect_code(VaultError::NotFreezer);
    let freezer = h.freezer.insecure_clone();
    h.veto(&freezer).expect_code(VaultError::NoSuccessor);
    for i in 0..2u64 {
        let c = h.continuity(2_000 + i, None);
        h.propose(&pair, c, None).expect_ok();
        h.veto(&freezer).expect_ok();
        assert_eq!(h.config().vetoes, i as u8 + 1);
    }
    let c = h.continuity(2_010, None);
    h.propose(&pair, c, None).expect_ok();
    h.veto(&freezer).expect_code(VaultError::VetoesExhausted);
    assert_eq!(h.config().vetoes, 2);

    // The pair in force proves a new checkpoint: the stall is over, and so is the successor.
    h.advance(2_020).expect_ok();
    assert_eq!(h.config().successor.review_ends, 0);
    assert_eq!(h.config().vetoes, 0);
    // A new stall, a new count.
    stall(&mut h);
    let c = h.continuity(2_030, None);
    h.propose(&pair, c, None).expect_ok();
    h.veto(&freezer).expect_ok();
    assert_eq!(h.config().vetoes, 1);
}

/// LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the last checkpoint
/// but stale. Such an advance lets burns sent before the break run (VLT-3), and leaves the stall as it was: the
/// successor under review stays, and so does the freezer's count, so nobody can lapse the review or win the freezer new
/// vetoes one stale block at a time. Adoption ends the stall and the count.
#[test]
fn test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes() {
    let (mut h, _) = Harness::ready();
    let last = h.config().checkpoint;
    h.set_time(last.timestamp as i64 + 8 * DAY);
    let pair = h.new_pair();
    let freezer = h.freezer.insecure_clone();
    let c = h.continuity(9_000, None);
    h.propose(&pair, c, None).expect_ok();
    h.veto(&freezer).expect_ok();
    let c = h.continuity(9_001, None);
    h.propose(&pair, c, None).expect_ok();
    let review_ends = h.config().successor.review_ends;

    // A day before the review ends, a stranger advances by one stale block.
    h.set_time(review_ends - DAY);
    let stale = |block: u64, seconds: u64| Checkpoint {
        block,
        timestamp: last.timestamp + seconds,
        state_root: [block as u8; 32],
    };
    h.advance_to(stale(1_001, 12)).expect_ok();
    assert_eq!(h.config().checkpoint.block, 1_001);
    assert!(vault::stalled(&h.config(), h.now()));
    assert_eq!(
        h.config().successor.review_ends,
        review_ends,
        "the review goes on"
    );
    assert_eq!(h.config().vetoes, 1, "the count goes on");

    // The freezer's second veto is its last in this stall, stale advances or not.
    h.veto(&freezer).expect_ok();
    h.advance_to(stale(1_002, 24)).expect_ok();
    let c = h.continuity(9_002, None);
    h.propose(&pair, c, None).expect_ok();
    h.advance_to(stale(1_003, 36)).expect_ok();
    h.veto(&freezer).expect_code(VaultError::VetoesExhausted);

    // The review runs its course and the successor is adopted, which ends the stall and the count.
    h.set_time(h.config().successor.review_ends);
    h.adopt(Harness::checkpoint_at(9_100, h.now()), &pair)
        .expect_ok();
    assert_eq!(h.config().p1, pair.p1);
    assert!(!vault::stalled(&h.config(), h.now()));
    assert_eq!(h.config().vetoes, 0);
}

/// LG-3: only a message on both proofs becomes the last message a successor must prove again. With one proof system
/// broken, a forged one-proof freeze still freezes, but it cannot keep an honest successor out.
#[test]
fn test_lg3_a_one_proof_message_is_not_the_last_message() {
    let (mut h, index) = Harness::ready();
    let real = fund(&mut h, index, 10 * SOL);
    let real_id = h.config().last_message;
    assert_eq!(real_id, abi_id(&real));

    let forged = h.freeze_payload(FACTORY);
    h.deliver_governance(forged, By::P1).expect_ok();
    assert!(h.config().frozen_until > h.now(), "frozen");
    let forged2 = h.freeze_payload(FACTORY);
    h.deliver_governance(forged2, By::P2).expect_ok();
    assert_eq!(
        h.config().last_message,
        real_id,
        "neither one-proof message counts"
    );

    h.warp(15 * DAY);
    assert!(vault::stalled(&h.config(), h.now()));
    let pair = h.new_pair();
    let c = h.continuity(2_000, Some((real, 1)));
    h.propose(&pair, c, None).expect_ok();
    assert_eq!(h.config().successor.p1, pair.p1);
}

// ---------------------------------------------------------------------
// the snapshot's start
// ---------------------------------------------------------------------

/// A stall 180 days old: the last checkpoint becomes the snapshot for good, and a successor under review lapses. A
/// vault that never had a checkpoint has no state to pay from.
#[test]
fn the_snapshot_begins_after_180_days_of_stall() {
    let mut h = Harness::new();
    let authority = h.authority.insecure_clone();
    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_ok();
    h.set_time(vault::stall_start(&h.config()) + SNAPSHOT_EXIT_DELAY);
    h.begin_snapshot().expect_code(VaultError::NoCheckpoint);

    let (mut h, _) = Harness::ready();
    let last = h.config().checkpoint;
    let due = vault::stall_start(&h.config()) + SNAPSHOT_EXIT_DELAY;
    h.set_time(due - 1);
    let pair = h.new_pair();
    let c = h.continuity(1_001, None);
    h.propose(&pair, c.clone(), None).expect_ok();
    h.begin_snapshot().expect_code(VaultError::SnapshotNotDue);
    h.set_time(due);
    h.begin_snapshot().expect_ok();
    let config = h.config();
    assert_eq!(config.snapshot, last);
    assert_eq!(
        config.successor.review_ends, 0,
        "a successor under review lapses"
    );

    h.begin_snapshot().expect_code(VaultError::SnapshotTaken);
    h.advance(2_000).expect_code(VaultError::SnapshotTaken);
    h.propose(&pair, c, None)
        .expect_code(VaultError::SnapshotTaken);
}

/// VLT-5: after the snapshot neither the freezer nor a proven freeze can hold the exit off.
#[test]
fn test_vlt5_no_freeze_after_the_snapshot() {
    let (mut h, _) = Harness::ready();
    h.set_time(vault::stall_start(&h.config()) + SNAPSHOT_EXIT_DELAY);
    h.begin_snapshot().expect_ok();
    let freezer = h.freezer.insecure_clone();
    h.freeze(&freezer).expect_code(VaultError::SnapshotTaken);
    let freeze = h.freeze_payload(FACTORY);
    h.deliver_governance(freeze, By::Both)
        .expect_code(VaultError::SnapshotTaken);
    let freeze = h.freeze_payload(FACTORY);
    h.deliver_governance(freeze, By::P1)
        .expect_code(VaultError::SnapshotTaken);
    assert_eq!(h.config().frozen_until, 0);
}

/// After the snapshot, a message from a later Ethereum block never runs; one from its block or before does.
#[test]
fn after_the_snapshot_a_later_message_never_runs() {
    let (mut h, index) = Harness::ready();
    fund(&mut h, index, 10 * SOL);
    h.set_time(vault::stall_start(&h.config()) + SNAPSHOT_EXIT_DELAY);
    h.begin_snapshot().expect_ok();
    let bob = Pubkey::new_unique();
    let burn = h.payload(BURN, index, &burn_body(SOL, &bob));
    h.block = 1_001;
    h.deliver_burn(index, burn.clone(), bob, By::Both)
        .expect_code(VaultError::IssuedAfterSnapshot);
    h.block = 1_000;
    h.deliver_burn(index, burn, bob, By::Both).expect_ok();
    assert_eq!(h.lamports(&bob), SOL);
}
