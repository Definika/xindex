/// Checkpoints, the stall and stall recovery (LG-2, LG-3), and the snapshot's start (VLT-5), against the EVM vault's
/// rules (Stage B spec, section 5.6): the NEAR twin's `recovery` tests.
#[test_only]
module xindex_vault::recovery_tests;

use sui::hash::keccak256;
use xindex_vault::bytes;
use xindex_vault::harness::{Self, Pair, T};
use xindex_vault::light_client;
use xindex_vault::vault;

const ONE: u64 = 1_000_000_000;
const STALL_PERIOD: u64 = 7 * 86_400;
const RECOVERY_DELAY: u64 = 30 * 86_400;
const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
const INTAKE_SETTLED: u8 = 2;
const FREEZE: u8 = 6;

fun advance_with(t: &mut T, block: u64, timestamp: u64, root: vector<u8>, p2_root: vector<u8>) {
    let (p1, p2) = t.pair();
    let proof1 = t.checkpoint_proof(block, timestamp, &root, p1, p2);
    let proof2 = t.checkpoint_proof(block, timestamp, &p2_root, p1, p2);
    let mut v = t.take(harness::relayer());
    let (c1, c2) = (t.client(p1), t.client(p2));
    vault::advance_checkpoint(&mut v, &c1, &c2, block, timestamp, root, proof1, proof2, t.clock());
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
}

/// A checkpoint needs both P1 and P2, each proving the same block, time and state root, newer than the last.
#[test]
fun a_checkpoint_needs_both_and_is_newer() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(60);
    let root = vector::tabulate!(32, |_| 7u8);
    let now = t.now();
    advance_with(&mut t, 1_010, now, root, root);
    let (block, timestamp, state_root) = t.checkpoint();
    assert!(block == 1_010 && timestamp == now && state_root == root);
    t.end();
}

/// P2's proof of another root is not the checkpoint.
#[test, expected_failure(abort_code = light_client::ENotTheCheckpoint)]
fun the_pair_must_prove_the_same_checkpoint() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(60);
    let now = t.now();
    advance_with(&mut t, 1_010, now, vector::tabulate!(32, |_| 7u8), vector::tabulate!(32, |_| 8u8));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNewer)]
fun an_older_block_is_refused() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(60);
    let now = t.now();
    advance_with(&mut t, 999, now, vector::tabulate!(32, |_| 7u8), vector::tabulate!(32, |_| 7u8));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNewer)]
fun the_same_time_is_refused() {
    let mut t = harness::new();
    t.advance(1_000);
    let (_, timestamp, _) = t.checkpoint();
    advance_with(&mut t, 1_001, timestamp, vector::tabulate!(32, |_| 7u8), vector::tabulate!(32, |_| 7u8));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNewer)]
fun a_checkpoint_in_the_future_is_refused() {
    let mut t = harness::new();
    t.advance(1_000);
    let now = t.now();
    advance_with(&mut t, 1_001, now + 1, vector::tabulate!(32, |_| 7u8), vector::tabulate!(32, |_| 7u8));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNewer)]
fun a_checkpoint_without_a_state_is_refused() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(1);
    let now = t.now();
    advance_with(&mut t, 1_001, now, bytes::zero32(), bytes::zero32());
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun a_checkpoint_by_other_clients_is_refused() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(30);
    let root = vector::tabulate!(32, |_| 7u8);
    t.warp(1);
    let now = t.now();
    let proof = t.checkpoint_proof(10, now, &root, a, b);
    let mut v = t.take(harness::relayer());
    let (c1, c2) = (t.client(a), t.client(b));
    vault::advance_checkpoint(&mut v, &c1, &c2, 10, now, root, proof, proof, t.clock());
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
    t.end();
}

// ---------------------------------------------------------------------
// Proposal, review, adoption
// ---------------------------------------------------------------------

/// A stall, a successor proposed by the recovery proposer, 30 days of review, adoption on a fresh checkpoint: the vault
/// runs on the new pair and no longer stalls.
#[test]
fun recovery_propose_review_adopt() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    let (a, b, review_ends) = t.successor();
    let (pa, pb) = (pair.first(), pair.second());
    assert!(a == pa && b == pb && review_ends == t.now() + RECOVERY_DELAY);
    t.warp(RECOVERY_DELAY);
    t.adopt(pair, 3_000);
    let (p1, p2) = t.pair();
    assert!(p1 == pa && p2 == pb);
    let (block, timestamp, _) = t.checkpoint();
    assert!(block == 3_000 && timestamp == t.now());
    let (_, _, ends) = t.successor();
    assert!(ends == 0 && !t.stalled());
    // The new pair proves what follows.
    t.fund(ONE);
    assert!(t.balance() == ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotStalled)]
fun no_successor_without_a_stall() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotRecoveryProposer)]
fun only_the_recovery_proposer_proposes() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::alice(), pair, c);
    t.end();
}

#[test, expected_failure(abort_code = vault::ESuccessorPending)]
fun one_successor_at_a_time() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

#[test, expected_failure(abort_code = vault::EReviewNotOver)]
fun adoption_waits_for_the_review() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.warp(RECOVERY_DELAY - 1);
    t.adopt(pair, 2_500);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoSuccessor)]
fun nothing_to_adopt() {
    let mut t = harness::new();
    let pair = t.successor_pair(30);
    t.adopt(pair, 2_500);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun only_the_proposed_pair_is_adopted() {
    let mut t = harness::new();
    t.advance(1_000);
    let pair = t.successor_pair(30);
    let other = t.successor_pair(50);
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.warp(RECOVERY_DELAY);
    t.adopt(other, 3_000);
    t.end();
}

// ---------------------------------------------------------------------
// The continuity test
// ---------------------------------------------------------------------

/// A vault whose last message is the settle `fund` delivered, stalled; the settle, its block, and a new pair.
fun continuity_setup(t: &mut T): (vector<u8>, u64, Pair) {
    let intake = t.fund(10 * ONE);
    let index = t.index();
    let vault_id = t.vault_id();
    let settle = harness::message(harness::sepolia(), INTAKE_SETTLED, &index, &intake, t.nonce(), harness::sui_testnet(), &vault_id);
    assert!(keccak256(&settle) == t.last_message());
    let block = t.last_block();
    t.warp(STALL_PERIOD + 100);
    let pair = t.successor_pair(40);
    (settle, block, pair)
}

#[test]
fun the_continuity_test_passes_with_the_last_message() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let c = t.continuity(pair, 9_000, settle, block);
    t.propose(harness::recovery(), pair, c);
    let (a, _, _) = t.successor();
    let pa = pair.first();
    assert!(a == pa);
    t.end();
}

/// (c) missing.
#[test, expected_failure(abort_code = vault::EDiscontinuous)]
fun the_last_message_must_be_proven() {
    let mut t = harness::new();
    let (_, _, pair) = continuity_setup(&mut t);
    let c = t.continuity(pair, 9_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// (c) another message.
#[test, expected_failure(abort_code = vault::EDiscontinuous)]
fun another_message_is_not_the_last() {
    let mut t = harness::new();
    let (_, block, pair) = continuity_setup(&mut t);
    let index = t.index();
    let vault_id = t.vault_id();
    let other = harness::message(harness::sepolia(), INTAKE_SETTLED, &index, &bytes::word64(1), 3, harness::sui_testnet(), &vault_id);
    let c = t.continuity(pair, 9_000, other, block);
    t.propose(harness::recovery(), pair, c);
    t.end();
}




/// A continuity test of `pair`'s own making: the vault's last checkpoint as `last_root` says, a checkpoint at
/// `recent_ts`, and the last message, its block recorded by P1 alone when `only_p1`.
fun handmade(t: &mut T, pair: Pair, last_root: vector<u8>, recent_ts: u64, settle: vector<u8>, block: u64, only_p1: bool): vault::Continuity {
    let (a, b) = (pair.first(), pair.second());
    let (last_block, last_ts, _) = t.checkpoint();
    let last = t.checkpoint_proof(last_block, last_ts, &last_root, a, b);
    let root = vector::tabulate!(32, |_| 0x5au8);
    let recent = t.checkpoint_proof(9_000, recent_ts, &root, a, b);
    let index = t.index();
    let now = t.now();
    let (proof, headers) = harness::event_proof(&index, &settle, block, now);
    t.record_for(a, headers, block);
    if (!only_p1) t.record_for(b, headers, block);
    vault::continuity(last, last, 9_000, recent_ts, root, recent, recent, settle, block, proof, proof)
}

/// The handmade test passes as `continuity`'s does: the cases below each break one part of it.
#[test]
fun a_handmade_continuity_passes() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let (_, _, root) = t.checkpoint();
    let now = t.now();
    let c = handmade(&mut t, pair, root, now, settle, block, false);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// (c) the last message, but P2 of the new pair cannot prove it.
#[test, expected_failure(abort_code = light_client::EUnknownHeaders)]
fun both_must_prove_the_last_message() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let (_, _, root) = t.checkpoint();
    let now = t.now();
    let c = handmade(&mut t, pair, root, now, settle, block, true);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// (b) not recent: a checkpoint dated before the stall began.
#[test, expected_failure(abort_code = vault::ENotRecent)]
fun the_recent_checkpoint_must_be_recent() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let (_, _, root) = t.checkpoint();
    let old = t.now() - STALL_PERIOD - 1;
    let c = handmade(&mut t, pair, root, old, settle, block, false);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// (a) another last checkpoint.
#[test, expected_failure(abort_code = light_client::ENotTheCheckpoint)]
fun the_last_checkpoint_must_be_the_vaults() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let now = t.now();
    let c = handmade(&mut t, pair, vector::tabulate!(32, |_| 0x5eu8), now, settle, block, false);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// One proof system twice is no pair.
#[test, expected_failure(abort_code = vault::EVerifiersNotDistinct)]
fun a_successor_of_one_system_is_refused() {
    let mut t = harness::new();
    let (settle, block, pair) = continuity_setup(&mut t);
    let a = pair.first();
    let c = t.successor_pair(50).first();
    let mixed = harness::pair_of(a, c);
    let cont = t.continuity(mixed, 9_000, settle, block);
    t.propose(harness::recovery(), mixed, cont);
    t.end();
}

// ---------------------------------------------------------------------
// Vetoes and lapse (LG-2)
// ---------------------------------------------------------------------

/// The freezer vetoes at most twice a stall; a checkpoint from the pair in force that ends the stall lapses a successor
/// and begins a new count.
#[test]
fun vetoes_and_lapse() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(60);
    let mut i = 0;
    while (i < 2) {
        let c = t.continuity(pair, 2_000 + i, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        i = i + 1;
    };
    assert!(t.vetoes() == 2);
    let c = t.continuity(pair, 2_010, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    // The pair in force proves a recent checkpoint: the stall is over, and so is the successor.
    t.advance(2_020);
    let (_, _, ends) = t.successor();
    assert!(ends == 0 && t.vetoes() == 0);
    // A new stall, a new count.
    t.warp(STALL_PERIOD + 1);
    let c = t.continuity(pair, 2_030, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::freezer());
    assert!(t.vetoes() == 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVetoesExhausted)]
fun a_third_veto_is_refused() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(60);
    let mut i = 0;
    while (i < 3) {
        let c = t.continuity(pair, 2_000 + i, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        i = i + 1;
    };
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoSuccessor)]
fun nothing_to_veto() {
    let mut t = harness::new();
    t.veto(harness::freezer());
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotFreezer)]
fun only_the_freezer_vetoes() {
    let mut t = harness::new();
    t.advance(1_000);
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(60);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::alice());
    t.end();
}

/// LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the checkpoint but
/// stale. Such an advance leaves the stall as it was: the successor under review stays, and so does the freezer's count,
/// so nobody can lapse the review or win the freezer new vetoes one stale block at a time. Adoption ends both.
#[test]
fun test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes() {
    let mut t = harness::new();
    t.advance(1_000);
    let (_, last_ts, _) = t.checkpoint();
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(70);
    let c = t.continuity(pair, 9_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::freezer());
    let c = t.continuity(pair, 9_001, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    let (_, _, review_ends) = t.successor();
    // A day before the review ends, a stranger advances by one stale block.
    t.set_now(review_ends - 86_400);
    t.advance_to(1_001, last_ts + 12, vector::tabulate!(32, |_| 0x51u8));
    assert!(t.stalled());
    let (_, _, ends) = t.successor();
    assert!(ends == review_ends, 0);
    assert!(t.vetoes() == 1, 1);
    // The freezer's second veto is its last in this stall, stale advances or not.
    t.veto(harness::freezer());
    t.advance_to(1_002, last_ts + 24, vector::tabulate!(32, |_| 0x52u8));
    let c = t.continuity(pair, 9_002, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.advance_to(1_003, last_ts + 36, vector::tabulate!(32, |_| 0x53u8));
    assert!(t.vetoes() == 2, 2);
    // The review runs its course and the successor is adopted, which ends the stall and the count.
    let (_, _, ends) = t.successor();
    t.set_now(ends);
    t.adopt(pair, 9_100);
    let (p1, _) = t.pair();
    let pa = pair.first();
    assert!(p1 == pa && t.vetoes() == 0 && !t.stalled());
    t.end();
}

#[test, expected_failure(abort_code = vault::EVetoesExhausted)]
fun test_lg2_stale_checkpoints_win_no_new_veto() {
    let mut t = harness::new();
    t.advance(1_000);
    let (_, last_ts, _) = t.checkpoint();
    t.warp(STALL_PERIOD + 86_400);
    let pair = t.successor_pair(70);
    let c = t.continuity(pair, 9_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::freezer());
    t.advance_to(1_001, last_ts + 12, vector::tabulate!(32, |_| 0x51u8));
    let c = t.continuity(pair, 9_001, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::freezer());
    t.advance_to(1_002, last_ts + 24, vector::tabulate!(32, |_| 0x52u8));
    let c = t.continuity(pair, 9_002, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.veto(harness::freezer());
    t.end();
}

/// LG-3: only a message on both proofs becomes the last message a successor must prove again. With one proof system
/// broken, a forged one-proof freeze still freezes, but it cannot keep an honest successor out.
#[test]
fun test_lg3_a_one_proof_message_is_not_the_last_message() {
    let mut t = harness::new();
    let (settle, block, _) = continuity_setup(&mut t);
    let real = keccak256(&settle);
    let forged = t.govern(FREEZE, vector[], 1, true, false);
    let v = t.take(harness::relayer());
    assert!(vault::used(&v, keccak256(&forged)) && vault::frozen_until(&v) > 0);
    harness::put(v);
    t.govern(FREEZE, vector[], 2, false, true);
    assert!(t.last_message() == real);
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(80);
    let c = t.continuity(pair, 9_000, settle, block);
    t.propose(harness::recovery(), pair, c);
    let (a, _, _) = t.successor();
    let pa = pair.first();
    assert!(a == pa);
    t.end();
}

/// A freeze on both proofs is the last message: a successor must prove it.
#[test, expected_failure(abort_code = vault::EDiscontinuous)]
fun a_two_proof_freeze_is_the_last_message() {
    let mut t = harness::new();
    let (settle, block, _) = continuity_setup(&mut t);
    t.govern(FREEZE, vector[], 1, true, true);
    t.warp(STALL_PERIOD + 1);
    let pair = t.successor_pair(80);
    let c = t.continuity(pair, 9_000, settle, block);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

// ---------------------------------------------------------------------
// The snapshot's start (VLT-5)
// ---------------------------------------------------------------------

/// 180 days into a stall the last checkpoint becomes the snapshot, for good: a successor under review lapses, and the
/// snapshot's root is in the slot the hub reads (25).
#[test]
fun the_snapshot_begins_after_180_days_of_stall() {
    let mut t = harness::new();
    t.advance(1_000);
    let (block, timestamp, root) = t.checkpoint();
    let due = timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY;
    t.set_now(due - 1);
    let pair = t.successor_pair(90);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.set_now(due);
    t.begin_snapshot();
    let v = t.take(harness::relayer());
    let (b, ts, r) = vault::exit_snapshot(&v);
    assert!(b == block && ts == timestamp && r == root);
    let (_, _, ends) = vault::successor(&v);
    assert!(ends == 0, 0);
    assert!(vault::slot(&v, bytes::word64(25)) == root);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ESnapshotNotDue)]
fun the_snapshot_waits_180_days_into_the_stall() {
    let mut t = harness::new();
    t.advance(1_000);
    let (_, timestamp, _) = t.checkpoint();
    t.set_now(timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY - 1);
    t.begin_snapshot();
    t.end();
}

/// Without a checkpoint there is no state to pay from.
#[test, expected_failure(abort_code = vault::ENoCheckpoint)]
fun no_snapshot_without_a_checkpoint() {
    let mut t = harness::new();
    let start = t.stall_start();
    t.set_now(start + SNAPSHOT_EXIT_DELAY);
    t.begin_snapshot();
    t.end();
}

fun snapshotted(): T {
    let mut t = harness::new();
    t.advance(1_000);
    let start = t.stall_start();
    t.set_now(start + SNAPSHOT_EXIT_DELAY);
    t.begin_snapshot();
    t
}

#[test, expected_failure(abort_code = vault::ESnapshotTaken)]
fun one_snapshot() {
    let mut t = snapshotted();
    t.begin_snapshot();
    t.end();
}

#[test, expected_failure(abort_code = vault::ESnapshotTaken)]
fun no_checkpoint_after_the_snapshot() {
    let mut t = snapshotted();
    t.advance(5_000);
    t.end();
}

#[test, expected_failure(abort_code = vault::ESnapshotTaken)]
fun no_proposal_after_the_snapshot() {
    let mut t = snapshotted();
    let pair = t.successor_pair(90);
    let c = t.continuity(pair, 2_000, vector[], 0);
    t.propose(harness::recovery(), pair, c);
    t.end();
}

/// VLT-5: nothing freezes the vault after its snapshot, neither the freezer nor the factory's message.
#[test, expected_failure(abort_code = vault::ESnapshotTaken)]
fun test_vlt5_the_freezer_cannot_freeze_after_the_snapshot() {
    let mut t = snapshotted();
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ESnapshotTaken)]
fun test_vlt5_the_factory_cannot_freeze_after_the_snapshot() {
    let mut t = harness::new();
    t.advance(1_000);
    let factory = xindex_vault::fixtures::hub_factory();
    let vault_id = t.vault_id();
    let freeze = harness::message(harness::sepolia(), FREEZE, &factory, &vector[], 1, harness::sui_testnet(), &vault_id);
    let proof = t.proof_for(&factory, &freeze, 900);
    let start = t.stall_start();
    t.set_now(start + SNAPSHOT_EXIT_DELAY);
    t.begin_snapshot();
    t.deliver_raw(freeze, 900, proof, proof);
    t.end();
}

/// A message from a block after the snapshot never runs.
#[test, expected_failure(abort_code = vault::EIssuedAfterSnapshot)]
fun test_vlt5_no_message_from_after_the_snapshot() {
    let mut t = snapshotted();
    let factory = xindex_vault::fixtures::hub_factory();
    let vault_id = t.vault_id();
    let freeze = harness::message(harness::sepolia(), FREEZE, &factory, &vector[], 1, harness::sui_testnet(), &vault_id);
    let proof = t.proof_for(&factory, &freeze, 1_001);
    t.deliver_raw(freeze, 1_001, proof, proof);
    t.end();
}
