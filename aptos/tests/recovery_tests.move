#[test_only]
/// Checkpoints, the stall and stall recovery (LG-2, LG-3), and the snapshot's start (VLT-5), against the EVM vault's
/// rules (Stage B spec, section 5.6): the Sui twin's `recovery_tests`.
module xindex_vault::recovery_tests {
    use aptos_std::aptos_hash::keccak256;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness::{Self, Pair, T};
    use xindex_vault::light_client;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;
    const STALL_PERIOD: u64 = 7 * 86_400;
    const RECOVERY_DELAY: u64 = 30 * 86_400;
    const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
    const INTAKE_SETTLED: u8 = 2;
    const FREEZE: u8 = 6;

    fun advance_with(t: &T, block: u64, timestamp: u64, root: vector<u8>, p2_root: vector<u8>) {
        let (p1, p2) = t.pair();
        let proof1 = harness::checkpoint_proof(block, timestamp, &root, p1, p2);
        let proof2 = harness::checkpoint_proof(block, timestamp, &p2_root, p1, p2);
        vault::advance_checkpoint(t.vault(), block, timestamp, root, proof1, proof2);
    }

    #[test]
    /// A checkpoint needs both P1 and P2, each proving the same block, time and state root, newer than the last.
    fun a_checkpoint_needs_both_and_is_newer() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(60);
        let root = bytes::repeat(7, 32);
        let now = harness::now();
        advance_with(&t, 1_010, now, root, root);
        let (block, timestamp, state_root) = t.checkpoint();
        assert!(block == 1_010 && timestamp == now && state_root == root);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheCheckpoint, location = light_client)]
    /// P2's proof of another root is not the checkpoint.
    fun the_pair_must_prove_the_same_checkpoint() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(60);
        let now = harness::now();
        advance_with(&t, 1_010, now, bytes::repeat(7, 32), bytes::repeat(8, 32));
    }

    #[test, expected_failure(abort_code = vault::ENotNewer, location = vault)]
    fun an_older_block_is_refused() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(60);
        let now = harness::now();
        advance_with(&t, 999, now, bytes::repeat(7, 32), bytes::repeat(7, 32));
    }

    #[test, expected_failure(abort_code = vault::ENotNewer, location = vault)]
    fun the_same_time_is_refused() {
        let t = harness::new();
        t.advance(1_000);
        let (_, timestamp, _) = t.checkpoint();
        advance_with(&t, 1_001, timestamp, bytes::repeat(7, 32), bytes::repeat(7, 32));
    }

    #[test, expected_failure(abort_code = vault::ENotNewer, location = vault)]
    fun a_checkpoint_in_the_future_is_refused() {
        let t = harness::new();
        t.advance(1_000);
        let now = harness::now();
        advance_with(&t, 1_001, now + 1, bytes::repeat(7, 32), bytes::repeat(7, 32));
    }

    #[test, expected_failure(abort_code = vault::ENotNewer, location = vault)]
    fun a_checkpoint_without_a_state_is_refused() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(1);
        let now = harness::now();
        advance_with(&t, 1_001, now, bytes::zero32(), bytes::zero32());
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// A checkpoint only other clients recorded proves nothing to the vault's P1 and P2.
    fun a_checkpoint_by_other_clients_is_refused() {
        let t = harness::new();
        let (a, b) = t.new_pair(30);
        let root = bytes::repeat(7, 32);
        harness::warp(1);
        let now = harness::now();
        let proof = harness::checkpoint_proof(10, now, &root, a, b);
        vault::advance_checkpoint(t.vault(), 10, now, root, proof, proof);
    }

    // ---------------------------------------------------------------------
    // Proposal, review, adoption
    // ---------------------------------------------------------------------

    #[test]
    /// A stall, a successor proposed by the recovery proposer, 30 days of review, adoption on a fresh checkpoint: the
    /// vault runs on the new pair and no longer stalls.
    fun recovery_propose_review_adopt() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        let (a, b, review_ends) = t.successor();
        let (pa, pb) = (pair.first(), pair.second());
        assert!(a == pa && b == pb && review_ends == harness::now() + RECOVERY_DELAY);
        harness::warp(RECOVERY_DELAY);
        t.adopt(pair, 3_000);
        let (p1, p2) = t.pair();
        assert!(p1 == pa && p2 == pb);
        let (block, timestamp, _) = t.checkpoint();
        assert!(block == 3_000 && timestamp == harness::now());
        let (_, _, ends) = t.successor();
        assert!(ends == 0 && !t.stalled());
        // The new pair proves what follows.
        t.fund(ONE);
        assert!(t.balance() == ONE);
    }

    #[test]
    /// The entry form takes the continuity test's parts as arguments.
    fun recovery_by_the_entry_function() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let (a, b) = (pair.first(), pair.second());
        let (last_block, last_ts, last_root) = t.checkpoint();
        let last = harness::checkpoint_proof(last_block, last_ts, &last_root, a, b);
        let recent_root = bytes::repeat(0x33, 32);
        let now = harness::now();
        let recent = harness::checkpoint_proof(2_000, now, &recent_root, a, b);
        vault::propose_successor_entry(
            &harness::signer_of(harness::recovery()),
            t.vault(),
            a,
            b,
            last,
            last,
            2_000,
            now,
            recent_root,
            recent,
            recent,
            vector[],
            0,
            vector[],
            vector[],
        );
        let (sa, _, _) = t.successor();
        assert!(sa == a);
    }

    #[test, expected_failure(abort_code = vault::ENotStalled, location = vault)]
    fun no_successor_without_a_stall() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::ENotRecoveryProposer, location = vault)]
    fun only_the_recovery_proposer_proposes() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::alice(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::ESuccessorPending, location = vault)]
    fun one_successor_at_a_time() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::EReviewNotOver, location = vault)]
    fun adoption_waits_for_the_review() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        harness::warp(RECOVERY_DELAY - 1);
        t.adopt(pair, 2_500);
    }

    #[test, expected_failure(abort_code = vault::ENoSuccessor, location = vault)]
    fun nothing_to_adopt() {
        let t = harness::new();
        let pair = t.successor_pair(30);
        t.adopt(pair, 2_500);
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// Only the proposed pair is adopted: a checkpoint another pair proves is unknown to the successor.
    fun only_the_proposed_pair_is_adopted() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        let other = t.successor_pair(50);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        harness::warp(RECOVERY_DELAY);
        t.adopt(other, 3_000);
    }

    #[test, expected_failure(abort_code = vault::ENotRecent, location = vault)]
    /// Adoption needs a recent checkpoint, one that ends the stall.
    fun adoption_needs_a_recent_checkpoint() {
        let t = harness::new();
        t.advance(1_000);
        let pair = t.successor_pair(30);
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        harness::warp(RECOVERY_DELAY);
        let (_, last_ts, _) = t.checkpoint();
        let old = last_ts + 1;
        let root = bytes::repeat(0x44, 32);
        let proof = harness::checkpoint_proof(3_000, old, &root, pair.first(), pair.second());
        vault::adopt_successor(t.vault(), 3_000, old, root, proof, proof);
    }

    // ---------------------------------------------------------------------
    // The continuity test
    // ---------------------------------------------------------------------

    /// A vault whose last message is the settle `fund` delivered, stalled; the settle, its block, and a new pair.
    fun continuity_setup(t: &mut T): (vector<u8>, u64, Pair) {
        let intake = t.fund(10 * ONE);
        let index = t.index();
        let vault_id = t.vault_id();
        let settle = harness::message(harness::sepolia(), INTAKE_SETTLED, &index, &intake, t.nonce(), harness::aptos_testnet(), &vault_id);
        assert!(keccak256(settle) == t.last_message());
        let block = t.last_block();
        harness::warp(STALL_PERIOD + 100);
        let pair = t.successor_pair(40);
        (settle, block, pair)
    }

    #[test]
    fun the_continuity_test_passes_with_the_last_message() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let c = t.continuity(pair, 9_000, settle, block);
        t.propose(harness::recovery(), pair, c);
        let (a, _, _) = t.successor();
        assert!(a == pair.first());
    }

    #[test, expected_failure(abort_code = vault::EDiscontinuous, location = vault)]
    /// (c) missing.
    fun the_last_message_must_be_proven() {
        let t = harness::new();
        let (_, _, pair) = continuity_setup(&mut t);
        let c = t.continuity(pair, 9_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::EDiscontinuous, location = vault)]
    /// (c) another message.
    fun another_message_is_not_the_last() {
        let t = harness::new();
        let (_, block, pair) = continuity_setup(&mut t);
        let index = t.index();
        let vault_id = t.vault_id();
        let other = harness::message(harness::sepolia(), INTAKE_SETTLED, &index, &bytes::word64(1), 3, harness::aptos_testnet(), &vault_id);
        let c = t.continuity(pair, 9_000, other, block);
        t.propose(harness::recovery(), pair, c);
    }

    /// A continuity test of `pair`'s own making: the vault's last checkpoint as `last_root` says, a checkpoint at
    /// `recent_ts`, and the last message, its block recorded by P1 alone when `only_p1`.
    fun handmade(t: &T, pair: Pair, last_root: vector<u8>, recent_ts: u64, settle: vector<u8>, block: u64, only_p1: bool): vault::Continuity {
        let (a, b) = (pair.first(), pair.second());
        let (last_block, last_ts, _) = t.checkpoint();
        let last = harness::checkpoint_proof(last_block, last_ts, &last_root, a, b);
        let root = bytes::repeat(0x5a, 32);
        let recent = harness::checkpoint_proof(9_000, recent_ts, &root, a, b);
        let index = t.index();
        let now = harness::now();
        let (proof, headers) = harness::event_proof(&index, &settle, block, now);
        harness::record_for(a, headers, block);
        if (!only_p1) harness::record_for(b, headers, block);
        vault::continuity(last, last, 9_000, recent_ts, root, recent, recent, settle, block, proof, proof)
    }

    #[test]
    /// The handmade test passes as `continuity`'s does: the cases below each break one part of it.
    fun a_handmade_continuity_passes() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let (_, _, root) = t.checkpoint();
        let now = harness::now();
        let c = handmade(&t, pair, root, now, settle, block, false);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// (c) the last message, but P2 of the new pair cannot prove it.
    fun both_must_prove_the_last_message() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let (_, _, root) = t.checkpoint();
        let now = harness::now();
        let c = handmade(&t, pair, root, now, settle, block, true);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::ENotRecent, location = vault)]
    /// (b) not recent: a checkpoint dated before the stall began.
    fun the_recent_checkpoint_must_be_recent() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let (_, _, root) = t.checkpoint();
        let old = harness::now() - STALL_PERIOD - 1;
        let c = handmade(&t, pair, root, old, settle, block, false);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheCheckpoint, location = light_client)]
    /// (a) another last checkpoint.
    fun the_last_checkpoint_must_be_the_vaults() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let now = harness::now();
        let c = handmade(&t, pair, bytes::repeat(0x5e, 32), now, settle, block, false);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::EVerifiersNotDistinct, location = vault)]
    /// One proof system twice is no pair.
    fun a_successor_of_one_system_is_refused() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let a = pair.first();
        let c = t.successor_pair(50).first();
        let mixed = harness::pair_of(a, c);
        let cont = t.continuity(mixed, 9_000, settle, block);
        t.propose(harness::recovery(), mixed, cont);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// A successor must be light clients of this package.
    fun a_successor_must_be_light_clients() {
        let t = harness::new();
        let (settle, block, pair) = continuity_setup(&mut t);
        let mixed = harness::pair_of(pair.first(), @0xbad);
        let cont = t.continuity(pair, 9_000, settle, block);
        t.propose(harness::recovery(), mixed, cont);
    }

    // ---------------------------------------------------------------------
    // Vetoes and lapse (LG-2)
    // ---------------------------------------------------------------------

    #[test]
    /// The freezer vetoes at most twice a stall; a checkpoint from the pair in force that ends the stall lapses a
    /// successor and begins a new count.
    fun vetoes_and_lapse() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(60);
        let i = 0;
        while (i < 2) {
            let c = t.continuity(pair, 2_000 + i, vector[], 0);
            t.propose(harness::recovery(), pair, c);
            t.veto(harness::freezer());
            i += 1;
        };
        assert!(t.vetoes() == 2);
        let c = t.continuity(pair, 2_010, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        // The pair in force proves a recent checkpoint: the stall is over, and so is the successor.
        t.advance(2_020);
        let (_, _, ends) = t.successor();
        assert!(ends == 0 && t.vetoes() == 0);
        // A new stall, a new count.
        harness::warp(STALL_PERIOD + 1);
        let c = t.continuity(pair, 2_030, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        assert!(t.vetoes() == 1);
    }

    #[test, expected_failure(abort_code = vault::EVetoesExhausted, location = vault)]
    fun a_third_veto_is_refused() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(60);
        let i = 0;
        while (i < 3) {
            let c = t.continuity(pair, 2_000 + i, vector[], 0);
            t.propose(harness::recovery(), pair, c);
            t.veto(harness::freezer());
            i += 1;
        };
    }

    #[test, expected_failure(abort_code = vault::ENoSuccessor, location = vault)]
    fun nothing_to_veto() {
        let t = harness::new();
        t.veto(harness::freezer());
    }

    #[test, expected_failure(abort_code = vault::ENotFreezer, location = vault)]
    fun only_the_freezer_vetoes() {
        let t = harness::new();
        t.advance(1_000);
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(60);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::alice());
    }

    #[test]
    /// LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the checkpoint but
    /// stale. Such an advance leaves the stall as it was: the successor under review stays, and so does the freezer's
    /// count, so nobody can lapse the review or win the freezer new vetoes one stale block at a time. Adoption ends
    /// both.
    fun test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes() {
        let t = harness::new();
        t.advance(1_000);
        let (_, last_ts, _) = t.checkpoint();
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(70);
        let c = t.continuity(pair, 9_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        let c = t.continuity(pair, 9_001, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        let (_, _, review_ends) = t.successor();
        // A day before the review ends, a stranger advances by one stale block.
        harness::set_now(review_ends - 86_400);
        t.advance_to(1_001, last_ts + 12, bytes::repeat(0x51, 32));
        assert!(t.stalled());
        let (_, _, ends) = t.successor();
        assert!(ends == review_ends, 0);
        assert!(t.vetoes() == 1, 1);
        // The freezer's second veto is its last in this stall, stale advances or not.
        t.veto(harness::freezer());
        t.advance_to(1_002, last_ts + 24, bytes::repeat(0x52, 32));
        let c = t.continuity(pair, 9_002, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.advance_to(1_003, last_ts + 36, bytes::repeat(0x53, 32));
        assert!(t.vetoes() == 2, 2);
        // The review runs its course and the successor is adopted, which ends the stall and the count.
        let (_, _, ends) = t.successor();
        harness::set_now(ends);
        t.adopt(pair, 9_100);
        let (p1, _) = t.pair();
        assert!(p1 == pair.first() && t.vetoes() == 0 && !t.stalled());
    }

    #[test, expected_failure(abort_code = vault::EVetoesExhausted, location = vault)]
    fun test_lg2_stale_checkpoints_win_no_new_veto() {
        let t = harness::new();
        t.advance(1_000);
        let (_, last_ts, _) = t.checkpoint();
        harness::warp(STALL_PERIOD + 86_400);
        let pair = t.successor_pair(70);
        let c = t.continuity(pair, 9_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        t.advance_to(1_001, last_ts + 12, bytes::repeat(0x51, 32));
        let c = t.continuity(pair, 9_001, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
        t.advance_to(1_002, last_ts + 24, bytes::repeat(0x52, 32));
        let c = t.continuity(pair, 9_002, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        t.veto(harness::freezer());
    }

    #[test]
    /// LG-3: only a message on both proofs becomes the last message a successor must prove again. With one proof
    /// system broken, a forged one-proof freeze still freezes, but it cannot keep an honest successor out.
    fun test_lg3_a_one_proof_message_is_not_the_last_message() {
        let t = harness::new();
        let (settle, block, _) = continuity_setup(&mut t);
        let real = keccak256(settle);
        let forged = t.govern(FREEZE, vector[], 1, true, false);
        assert!(vault::used(t.vault(), keccak256(forged)) && vault::frozen_until(t.vault()) > 0);
        t.govern(FREEZE, vector[], 2, false, true);
        assert!(t.last_message() == real);
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(80);
        let c = t.continuity(pair, 9_000, settle, block);
        t.propose(harness::recovery(), pair, c);
        let (a, _, _) = t.successor();
        assert!(a == pair.first());
    }

    #[test, expected_failure(abort_code = vault::EDiscontinuous, location = vault)]
    /// A freeze on both proofs is the last message: a successor must prove it.
    fun a_two_proof_freeze_is_the_last_message() {
        let t = harness::new();
        let (settle, block, _) = continuity_setup(&mut t);
        t.govern(FREEZE, vector[], 1, true, true);
        harness::warp(STALL_PERIOD + 1);
        let pair = t.successor_pair(80);
        let c = t.continuity(pair, 9_000, settle, block);
        t.propose(harness::recovery(), pair, c);
    }

    // ---------------------------------------------------------------------
    // The snapshot's start (VLT-5)
    // ---------------------------------------------------------------------

    #[test]
    /// 180 days into a stall the last checkpoint becomes the snapshot, for good: a successor under review lapses, and
    /// the snapshot's root is in the slot the hub reads (25).
    fun the_snapshot_begins_after_180_days_of_stall() {
        let t = harness::new();
        t.advance(1_000);
        let (block, timestamp, root) = t.checkpoint();
        let due = timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY;
        harness::set_now(due - 1);
        let pair = t.successor_pair(90);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
        harness::set_now(due);
        t.begin_snapshot();
        let (b, ts, r) = vault::exit_snapshot(t.vault());
        assert!(b == block && ts == timestamp && r == root);
        let (_, _, ends) = vault::successor(t.vault());
        assert!(ends == 0, 0);
        assert!(vault::slot(t.vault(), bytes::word64(25)) == root);
    }

    #[test, expected_failure(abort_code = vault::ESnapshotNotDue, location = vault)]
    fun the_snapshot_waits_180_days_into_the_stall() {
        let t = harness::new();
        t.advance(1_000);
        let (_, timestamp, _) = t.checkpoint();
        harness::set_now(timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY - 1);
        t.begin_snapshot();
    }

    #[test, expected_failure(abort_code = vault::ENoCheckpoint, location = vault)]
    /// Without a checkpoint there is no state to pay from.
    fun no_snapshot_without_a_checkpoint() {
        let t = harness::new();
        let start = t.stall_start();
        harness::set_now(start + SNAPSHOT_EXIT_DELAY);
        t.begin_snapshot();
    }

    fun snapshotted(): T {
        let t = harness::new();
        t.advance(1_000);
        let start = t.stall_start();
        harness::set_now(start + SNAPSHOT_EXIT_DELAY);
        t.begin_snapshot();
        t
    }

    #[test, expected_failure(abort_code = vault::ESnapshotTaken, location = vault)]
    fun one_snapshot() {
        let t = snapshotted();
        t.begin_snapshot();
    }

    #[test, expected_failure(abort_code = vault::ESnapshotTaken, location = vault)]
    fun no_checkpoint_after_the_snapshot() {
        let t = snapshotted();
        t.advance(5_000);
    }

    #[test, expected_failure(abort_code = vault::ESnapshotTaken, location = vault)]
    fun no_proposal_after_the_snapshot() {
        let t = snapshotted();
        let pair = t.successor_pair(90);
        let c = t.continuity(pair, 2_000, vector[], 0);
        t.propose(harness::recovery(), pair, c);
    }

    #[test, expected_failure(abort_code = vault::ESnapshotTaken, location = vault)]
    /// VLT-5: nothing freezes the vault after its snapshot, neither the freezer nor the factory's message.
    fun test_vlt5_the_freezer_cannot_freeze_after_the_snapshot() {
        let t = snapshotted();
        t.freeze_by(harness::freezer());
    }

    #[test, expected_failure(abort_code = vault::ESnapshotTaken, location = vault)]
    fun test_vlt5_the_factory_cannot_freeze_after_the_snapshot() {
        let t = harness::new();
        t.advance(1_000);
        let factory = f::hub_factory();
        let vault_id = t.vault_id();
        let freeze = harness::message(harness::sepolia(), FREEZE, &factory, &vector[], 1, harness::aptos_testnet(), &vault_id);
        let proof = t.proof_for(&factory, &freeze, 900);
        let start = t.stall_start();
        harness::set_now(start + SNAPSHOT_EXIT_DELAY);
        t.begin_snapshot();
        t.deliver_raw(freeze, 900, proof, proof);
    }

    #[test, expected_failure(abort_code = vault::EIssuedAfterSnapshot, location = vault)]
    /// A message from a block after the snapshot never runs.
    fun test_vlt5_no_message_from_after_the_snapshot() {
        let t = snapshotted();
        let factory = f::hub_factory();
        let vault_id = t.vault_id();
        let freeze = harness::message(harness::sepolia(), FREEZE, &factory, &vector[], 1, harness::aptos_testnet(), &vault_id);
        let proof = t.proof_for(&factory, &freeze, 1_001);
        t.deliver_raw(freeze, 1_001, proof, proof);
    }
}
