#[test_only]
/// Messages from Ethereum: their proofs, route and emitter; the checkpoint they wait for (VLT-3); burns under the speed
/// limit, never to the vault itself (SOL-9); intakes settled and failed; migrations. The Sui twin's `messages_tests`.
module xindex_vault::messages_tests {
    use std::bcs;
    use aptos_std::aptos_hash::keccak256;
    use xindex_vault::abi;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness::{Self, T};
    use xindex_vault::light_client;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;
    const BURN: u8 = 1;
    const INTAKE_SETTLED: u8 = 2;
    const INTAKE_FAILED: u8 = 3;
    const MIGRATE: u8 = 4;
    const FREEZE: u8 = 6;

    /// A settle message for a fresh intake holding 4 APT, its block, and both clients' proof of it.
    fun settle_setup(t: &mut T): (vector<u8>, u64, vector<u8>) {
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 4 * ONE);
        let index = t.index();
        let settle = t.payload(INTAKE_SETTLED, &index, &intake);
        let block = t.next_block();
        let proof = t.proof_for(&index, &settle, block);
        (settle, block, proof)
    }

    #[test]
    /// A message runs on a log both P1 and P2 prove, of the index it names, routed here, once; and is the last message.
    fun a_message_runs_once_on_both_proofs() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        t.deliver_raw(settle, block, proof, proof);
        assert!(t.balance() == 4 * ONE);
        assert!(vault::used(t.vault(), keccak256(settle)));
        assert!(vault::last_message(t.vault()) == keccak256(settle));
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    fun a_message_runs_only_once() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        t.deliver_raw(settle, block, proof, proof);
        t.deliver_raw(settle, block, proof, proof);
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    /// LG-1: anyone may emit a marked message again with `resendMessage`, so the same payload's log lies in another
    /// block too. The vault runs a message once by its id, from whichever block it is proven in first.
    fun test_lg1_a_message_sent_again_runs_once() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        t.deliver_raw(settle, block, proof, proof);
        let index = t.index();
        let again = t.next_block();
        let resent = t.proof_for(&index, &settle, again);
        t.deliver_raw(settle, again, resent, resent);
    }

    #[test]
    /// LG-1: a message whose first log never arrived runs from its resent log.
    fun test_lg1_a_resent_message_runs_from_its_new_block() {
        let t = harness::new();
        let (settle, block, _) = settle_setup(&mut t);
        let index = t.index();
        let again = t.next_block();
        assert!(again > block);
        let resent = t.proof_for(&index, &settle, again);
        t.deliver_raw(settle, again, resent, resent);
        assert!(t.balance() == 4 * ONE);
    }

    #[test, expected_failure(abort_code = vault::ENoProof, location = vault)]
    fun a_message_needs_a_proof() {
        let t = harness::new();
        let (settle, block, _) = settle_setup(&mut t);
        t.deliver_raw(settle, block, vector[], vector[]);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    /// One proof never moves coins: P1's alone, or P2's alone.
    fun p1_alone_moves_no_coins() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        t.deliver_raw(settle, block, proof, vector[]);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    fun p2_alone_moves_no_coins() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        t.deliver_raw(settle, block, vector[], proof);
    }

    /// A message of `kind` from the index with `body`, on P1's proof alone.
    fun on_p1_alone(kind: u8, body: vector<u8>) {
        let t = harness::new();
        t.fund(100 * ONE);
        vault::register_index(t.vault(), f::migrate_new_index(), f::migrate_new_salt());
        let index = t.index();
        let payload = t.payload(kind, &index, &body);
        t.deliver_by(&index, payload, true, false);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    /// Every kind that moves coins needs both: a burn,
    fun a_burn_on_one_proof_is_refused() {
        on_p1_alone(BURN, harness::burn_body(ONE, @0xbeef));
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    /// a migration,
    fun a_migration_on_one_proof_is_refused() {
        on_p1_alone(MIGRATE, harness::migrate_body(&f::migrate_new_index(), ONE));
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    /// and a failure, which opens refunds.
    fun a_failure_on_one_proof_is_refused() {
        on_p1_alone(INTAKE_FAILED, harness::intake_id(1_900_000_000, 99));
    }

    #[test, expected_failure(abort_code = vault::ENotCheckpointed, location = vault)]
    /// VLT-3 for a burn: on both proofs, but from a block the checkpoint does not cover.
    fun test_vlt3_a_burn_after_the_checkpoint_waits_for_it() {
        let t = harness::new();
        t.fund(100 * ONE);
        let (covered, _, _) = t.checkpoint();
        let index = t.index();
        let burn = t.payload(BURN, &index, &harness::burn_body(ONE, @0xbeef));
        t.deliver_at(&index, burn, true, true, covered + 1);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    /// A proof of another payload's log is not this log's.
    fun another_logs_proof_is_refused() {
        let t = harness::new();
        let (settle, block, _) = settle_setup(&mut t);
        let index = t.index();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        let other = t.payload(INTAKE_SETTLED, &index, &intake);
        let other_proof = t.proof_for(&index, &other, block);
        t.deliver_raw(settle, block, other_proof, other_proof);
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// A log in a block no proof recorded.
    fun an_unrecorded_block_is_refused() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        let unrecorded = proof;
        unrecorded[0] ^= 1;
        t.deliver_raw(settle, block, unrecorded, proof);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    /// P1 and P2 must prove the same log: a log P2 proves in another block is not the one delivered.
    fun the_proofs_must_agree_on_the_block() {
        let t = harness::new();
        let (settle, block, proof) = settle_setup(&mut t);
        let index = t.index();
        let later = t.proof_for(&index, &settle, block + 1);
        t.deliver_raw(settle, block, proof, later);
    }

    fun routed(source: u64, dest: u64, vault_id: vector<u8>) {
        let t = harness::new();
        let index = t.index();
        let payload = harness::message(source, INTAKE_SETTLED, &index, &harness::intake_id(harness::now() + 3600, 1), 50, dest, &vault_id);
        t.deliver_by(&index, payload, true, true);
    }

    #[test, expected_failure(abort_code = vault::EWrongRoute, location = vault)]
    fun a_message_to_another_chain_is_refused() {
        routed(harness::sepolia(), harness::aptos_testnet() + 1, f::hub_vault());
    }

    #[test, expected_failure(abort_code = vault::EWrongRoute, location = vault)]
    fun a_message_from_another_chain_is_refused() {
        routed(1, harness::aptos_testnet(), f::hub_vault());
    }

    #[test, expected_failure(abort_code = vault::EWrongRoute, location = vault)]
    fun a_message_to_another_vault_is_refused() {
        routed(harness::sepolia(), harness::aptos_testnet(), bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::EWrongEmitter, location = vault)]
    /// A governance kind is the factory's alone.
    fun a_freeze_from_an_index_is_refused() {
        let t = harness::new();
        t.deliver(FREEZE, harness::freeze_body(harness::now() + 86_400));
    }

    #[test, expected_failure(abort_code = vault::EUnknownKind, location = vault)]
    fun an_unknown_kind_is_refused() {
        let t = harness::new();
        t.deliver(9, bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::EUnknownKind, location = vault)]
    fun kind_zero_is_refused() {
        let t = harness::new();
        t.deliver(0, bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    /// Any Ethereum contract can emit a message naming itself: only the factory's clones registered here are indexes.
    fun a_message_from_a_stranger_is_refused() {
        let t = harness::new();
        let stranger = bytes::repeat(0x77, 20);
        let intake = harness::intake_id(harness::now() + 3600, 1);
        let payload = t.payload(INTAKE_SETTLED, &stranger, &intake);
        t.deliver_by(&stranger, payload, true, true);
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// Only the vault's own P1 and P2 prove anything to it: a block other clients recorded is unknown to them.
    fun other_clients_are_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 4 * ONE);
        let index = t.index();
        let settle = t.payload(INTAKE_SETTLED, &index, &intake);
        let block = t.next_block();
        let (a, b) = t.new_pair(40);
        let (proof, root) = harness::event_proof(&index, &settle, block, harness::now());
        harness::record_for(a, root, block);
        harness::record_for(b, root, block);
        t.deliver_raw(settle, block, proof, proof);
    }

    /// A message claimed in a real receipt: the proof walks block 26,092,387's real receipts trie to each case's
    /// receipt, and finds its log is not the message.
    fun real_receipt(case: u64) {
        let t = harness::new();
        let number = f::block_number();
        t.advance(number + 10);
        let (p1, p2) = t.pair();
        let first = number - 1;
        let receipts_root = f::block_receipts_root();
        let state = f::block_state_root();
        let leaves = vector[];
        let i = 0;
        while (i < 5) {
            if (i == 1) {
                leaves.push_back(harness::leaf(number, f::block_timestamp(), &state, &receipts_root));
            } else {
                let seed = bytes::repeat((i as u8), 32);
                leaves.push_back(harness::leaf(first + i, f::block_timestamp(), &seed, &seed));
            };
            i += 1;
        };
        let (root, path) = harness::tree(leaves, 1);
        harness::record_range(p1, root, first, first + 4);
        harness::record_range(p2, root, first, first + 4);
        let proof = harness::header_with(&root, number, f::block_timestamp(), &state, &receipts_root, &path);
        let (nodes, tx, log) = if (case == 0) {
            (f::case0_nodes(), f::case0_tx(), f::case0_log())
        } else if (case == 1) {
            (f::case1_nodes(), f::case1_tx(), f::case1_log())
        } else {
            (f::case2_nodes(), f::case2_tx(), f::case2_log())
        };
        proof.append(harness::receipt_part(&nodes, tx, log));
        let index = t.index();
        let burn = t.payload(BURN, &index, &harness::burn_body(ONE, @0x42));
        t.deliver_raw(burn, number, proof, proof);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun a_real_receipt_holds_no_message_of_ours_one_byte_key() {
        real_receipt(0);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun a_real_receipt_holds_no_message_of_ours_two_byte_key() {
        real_receipt(1);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun a_real_receipt_holds_no_message_of_ours_legacy() {
        real_receipt(2);
    }

    // ---------------------------------------------------------------------
    // VLT-3
    // ---------------------------------------------------------------------

    #[test, expected_failure(abort_code = vault::ENotCheckpointed, location = vault)]
    /// VLT-3: a message that moves coins runs only from a block the vault's checkpoint covers, so the snapshot, which is
    /// the last checkpoint, never pays a holder whose burn the vault also paid. Once the checkpoint covers the block, it
    /// runs.
    fun test_vlt3_a_message_after_the_checkpoint_waits_for_it() {
        let t = harness::new();
        t.advance(1_000);
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 4 * ONE);
        let index = t.index();
        let settle = t.payload(INTAKE_SETTLED, &index, &intake);
        let proof = t.proof_for(&index, &settle, 1_001);
        t.deliver_raw(settle, 1_001, proof, proof);
    }

    #[test]
    fun test_vlt3_a_message_runs_once_its_block_is_checkpointed() {
        let t = harness::new();
        t.advance(1_000);
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 4 * ONE);
        let index = t.index();
        let settle = t.payload(INTAKE_SETTLED, &index, &intake);
        let proof = t.proof_for(&index, &settle, 1_001);
        t.advance(1_001);
        t.deliver_raw(settle, 1_001, proof, proof);
        assert!(t.balance() == 4 * ONE);
    }

    // ---------------------------------------------------------------------
    // Intakes
    // ---------------------------------------------------------------------

    #[test]
    /// A settled intake's deposits join the index: its balance, its digest, APT among its tokens.
    fun a_settled_intake_joins_the_index() {
        let t = harness::new();
        let intake = t.fund(7 * ONE);
        let (has, balance, paid, digest, _) = t.index_state(f::hub_index());
        assert!(has && balance == 7 * ONE && paid == 0);
        assert!(digest == abi::index_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), true, 7 * ONE, 0));
        assert!(vault::slot(t.vault(), vault::index_slot(&f::hub_index())) == digest);
        let (state, total, intake_digest) = vault::intake(t.vault(), f::hub_index(), intake);
        assert!(state == 2 && total == 7 * ONE);
        assert!(intake_digest == abi::intake_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 2, true, 7 * ONE));
    }

    #[test]
    /// An intake nobody deposited into settles or fails empty, and its digest says so.
    fun an_intake_without_deposits_settles_empty() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 9);
        t.deliver(INTAKE_SETTLED, intake);
        let (has, balance, _, _, _) = t.index_state(f::hub_index());
        assert!(!has && balance == 0);
        let (state, _, digest) = vault::intake(t.vault(), f::hub_index(), intake);
        assert!(state == 2);
        assert!(digest == abi::intake_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 2, false, 0));
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    fun a_settled_intake_settles_once() {
        let t = harness::new();
        let intake = t.fund(ONE);
        t.deliver(INTAKE_SETTLED, intake);
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    fun a_settled_intake_cannot_fail() {
        let t = harness::new();
        let intake = t.fund(ONE);
        t.deliver(INTAKE_FAILED, intake);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun an_intake_message_carries_one_word() {
        let t = harness::new();
        let body = harness::intake_id(harness::now() + 3600, 1);
        body.push_back(0);
        t.deliver(INTAKE_SETTLED, body);
    }

    // ---------------------------------------------------------------------
    // Burns and the speed limit
    // ---------------------------------------------------------------------

    #[test]
    /// A burn pays its recipient what the speed limit allows now, 4% of the index's balance in any 24 hours, and owes
    /// the rest, which anyone releases as the limit allows; a frozen vault pays nothing, and an explicit release that
    /// can pay nothing aborts.
    fun a_burn_pays_within_the_speed_limit_and_owes_the_rest() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        let to = @0xbeef;
        let burn = t.deliver(BURN, harness::burn_body(100 * ONE, to));
        assert!(t.received(to) == 40 * ONE, 0);
        let id = keccak256(burn);
        assert!(t.owed_remaining(id) == 60 * ONE);
        assert!(t.balance() == 960 * ONE && t.held() == 960 * ONE);
        // 24 hours later the payout is still inside the window: nothing more.
        harness::warp(24 * 3600);
        let (_, _, _, _, available) = t.index_state(f::hub_index());
        assert!(available == 0, 1);
        harness::warp(3600);
        t.release(id);
        assert!(t.received(to) == 960 * ONE / 25, 2);
        let (_, balance, paid, digest, _) = t.index_state(f::hub_index());
        assert!(paid == 40 * ONE + 960 * ONE / 25 && balance == 1_000 * ONE - paid);
        assert!(digest == abi::index_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), true, balance, paid));
        assert!(t.held() == balance);
    }

    #[test]
    /// The window is exact over any 24 hours: payouts spread over the hours add up to 4%, and each leaves the window
    /// 25 hourly buckets later.
    fun the_window_slides_hour_by_hour() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        t.deliver(BURN, harness::burn_body(10 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 10 * ONE);
        harness::warp(10 * 3600);
        let burn2 = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
        // 4% of the balance before today's outflow, less the 10 already out.
        assert!(t.received(@0xbeef) == 30 * ONE);
        let id2 = keccak256(burn2);
        // The first payout leaves the window 25 hours after its hour began; until then nothing more.
        harness::warp(14 * 3600);
        let (_, _, _, _, available) = t.index_state(f::hub_index());
        assert!(available == 0);
        harness::warp(3600);
        t.release(id2);
        // 4% of 960 and the 30 still in the window, less those 30.
        assert!(t.received(@0xbeef) == 96 * ONE / 10);
    }

    #[test, expected_failure(abort_code = vault::ENothingPayable, location = vault)]
    fun a_release_that_pays_nothing_aborts() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
        t.release(keccak256(burn));
    }

    #[test, expected_failure(abort_code = vault::ENothingPayable, location = vault)]
    /// Frozen: nothing is paid, and an explicit release aborts; the freeze over, it pays.
    fun a_frozen_vault_pays_nothing() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
        t.freeze_by(harness::freezer());
        harness::warp(25 * 3600);
        t.release(keccak256(burn));
    }

    #[test]
    fun a_freeze_over_pays_again() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 40 * ONE);
        t.freeze_by(harness::freezer());
        harness::warp(14 * 86_400);
        t.release(keccak256(burn));
        assert!(t.received(@0xbeef) == 960 * ONE / 25);
    }

    #[test]
    /// A burn delivered while frozen is accepted and owed, and pays nothing until the freeze is over.
    fun a_burn_delivered_while_frozen_waits() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        t.freeze_by(harness::freezer());
        let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 0);
        assert!(t.owed_remaining(keccak256(burn)) == 100 * ONE);
    }

    #[test]
    /// The outflow floor: a small index may still pay the floor in a day, more than 4% of it.
    fun the_floor_pays_a_small_index() {
        let t = harness::new();
        t.fund(10 * ONE);
        t.deliver(BURN, harness::burn_body(5 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == ONE);
    }

    #[test]
    /// Never more than the index holds, whatever the floor.
    fun a_payout_never_passes_the_balance() {
        let t = harness::new();
        t.fund(ONE / 2);
        t.deliver(BURN, harness::burn_body(5 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == ONE / 2);
        assert!(t.balance() == 0);
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_burn_to_no_one_is_refused() {
        let t = harness::new();
        t.fund(100 * ONE);
        t.deliver(BURN, harness::burn_body(ONE, @0x0));
    }

    #[test, expected_failure(abort_code = vault::EZeroAmount, location = vault)]
    fun a_burn_of_nothing_is_refused() {
        let t = harness::new();
        t.fund(100 * ONE);
        t.deliver(BURN, harness::burn_body(0, @0xbeef));
    }

    #[test, expected_failure(abort_code = vault::ENotNative, location = vault)]
    fun a_burn_of_another_token_is_refused() {
        let t = harness::new();
        t.fund(100 * ONE);
        let body = harness::burn_body(ONE, @0xbeef);
        body[31] = 1;
        t.deliver(BURN, body);
    }

    #[test, expected_failure(abort_code = abi::EOverflow, location = abi)]
    /// An amount from Ethereum that does not fit 64 bits is refused (interfaces doc).
    fun a_burn_past_64_bits_is_refused() {
        let t = harness::new();
        t.fund(100 * ONE);
        let body = bytes::zero32();
        body.append(bytes::word(1 << 64));
        body.append(bcs::to_bytes(&@0xbeef));
        t.deliver(BURN, body);
    }

    #[test, expected_failure(abort_code = vault::EWrongRecipient, location = vault)]
    /// SOL-9's Aptos twin: APT sent to the vault's own object would be stranded, since nothing here ever withdraws
    /// from the object's primary store.
    fun test_sol9_the_vault_is_no_recipient() {
        let t = harness::new();
        t.fund(100 * ONE);
        let own = t.vault();
        t.deliver(BURN, harness::burn_body(ONE, own));
    }

    #[test, expected_failure(abort_code = vault::EWrongRecipient, location = vault)]
    /// SOL-9 on Aptos: nor to the coins' store's object, whose primary store nothing withdraws from either.
    fun test_sol9_the_store_is_no_recipient() {
        let t = harness::new();
        t.fund(100 * ONE);
        let store = vault::store(t.vault());
        t.deliver(BURN, harness::burn_body(ONE, store));
    }

    // ---------------------------------------------------------------------
    // Migrations
    // ---------------------------------------------------------------------

    fun register_v2(t: &T) {
        vault::register_index(t.vault(), f::migrate_new_index(), f::migrate_new_salt());
    }

    #[test]
    /// A migration moves coins two versions share from the old index's balance into the new one's, within the speed
    /// limit; the coins never leave the vault, so `held` stays.
    fun a_migration_moves_coins_between_indexes_within_the_limit() {
        let t = harness::new();
        t.fund(500 * ONE);
        register_v2(&t);
        let payload = t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 50 * ONE));
        assert!(t.balance() == 480 * ONE, 0);
        let (has, balance, _, digest, _) = t.index_state(f::migrate_new_index());
        assert!(has && balance == 20 * ONE, 1);
        assert!(digest == abi::index_digest(harness::aptos_testnet(), &f::hub_vault(), &f::migrate_new_index(), true, 20 * ONE, 0));
        assert!(t.held() == 500 * ONE);
        let (to_index, _, new_index, remaining) = vault::owed(t.vault(), f::hub_index(), keccak256(payload));
        assert!(to_index && new_index == f::migrate_new_index() && remaining == 30 * ONE);
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun a_migration_to_an_unregistered_index_is_refused() {
        let t = harness::new();
        t.fund(500 * ONE);
        t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 10 * ONE));
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun a_migration_to_itself_is_refused() {
        let t = harness::new();
        t.fund(500 * ONE);
        t.deliver(MIGRATE, harness::migrate_body(&f::hub_index(), 10 * ONE));
    }

    #[test, expected_failure(abort_code = vault::EZeroAmount, location = vault)]
    fun a_migration_of_nothing_is_refused() {
        let t = harness::new();
        t.fund(500 * ONE);
        register_v2(&t);
        t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 0));
    }

    #[test, expected_failure(abort_code = vault::ENotNative, location = vault)]
    fun a_migration_of_another_token_is_refused() {
        let t = harness::new();
        t.fund(500 * ONE);
        register_v2(&t);
        let body = harness::migrate_body(&f::migrate_new_index(), ONE);
        body[63] = 1;
        t.deliver(MIGRATE, body);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_migration_to_no_address_is_refused() {
        let t = harness::new();
        t.fund(500 * ONE);
        let body = harness::migrate_body(&f::migrate_new_index(), ONE);
        body[0] = 1;
        t.deliver(MIGRATE, body);
    }

    #[test, expected_failure(abort_code = vault::ENothingOwed, location = vault)]
    fun nothing_owed_releases_nothing() {
        let t = harness::new();
        t.release(bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::ENothingOwed, location = vault)]
    fun a_burn_paid_in_full_is_owed_no_more() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        let burn = t.deliver(BURN, harness::burn_body(10 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 10 * ONE);
        t.release(keccak256(burn));
    }

    #[test]
    /// Two payouts in one hour share its bucket: together they stay within 4%.
    fun two_payouts_in_one_hour_share_a_bucket() {
        let t = harness::new();
        t.fund(1_000 * ONE);
        t.deliver(BURN, harness::burn_body(25 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 25 * ONE);
        let burn = t.deliver(BURN, harness::burn_body(25 * ONE, @0xbeef));
        assert!(t.received(@0xbeef) == 15 * ONE);
        assert!(t.owed_remaining(keccak256(burn)) == 10 * ONE);
        let (_, _, paid, _, available) = t.index_state(f::hub_index());
        assert!(paid == 40 * ONE && available == 0);
    }
}
