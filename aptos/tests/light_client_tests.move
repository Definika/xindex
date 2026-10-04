#[test_only]
/// The light client's rules on real data: block 26,092,387's receipts trie (`test/fixtures/ethereum/receipts.json`),
/// under a headers root a proof would have recorded; and the anchor's step and lag, as `EthereumFinalityVerifier.t.sol`
/// and the core's `tests/light_client.rs` check them. The Sui twin's `light_client_tests`.
module xindex_vault::light_client_tests {
    use aptos_std::aptos_hash::keccak256;
    use xindex_vault::abi;
    use xindex_vault::bytes;
    use xindex_vault::ethereum;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness;
    use xindex_vault::light_client;
    use xindex_vault::mpt;
    use xindex_vault::proofs;

    const GENESIS: u64 = 1_606_824_023;

    /// A mainnet SP1 client anchored at epoch 400,000, its clock a day before its lag ends.
    fun client(): address {
        harness::boot(GENESIS + 400_000 * 384);
        light_client::create(
            &harness::signer_of(harness::creator()),
            b"lc",
            light_client::sp1(),
            bytes::repeat(1, 32),
            bytes::repeat(0xaa, 32),
            400_000,
            GENESIS,
        )
    }

    /// A proof over five blocks, the real one second: its header part, the five recorded by `lc`.
    fun five(lc: address, receipts_root: vector<u8>): vector<u8> {
        let (number, timestamp, state) = (f::block_number(), f::block_timestamp(), f::block_state_root());
        let first = number - 1;
        let leaves = vector[];
        let i = 0;
        while (i < 5) {
            if (i == 1) {
                leaves.push_back(harness::leaf(number, timestamp, &state, &receipts_root));
            } else {
                let seed = bytes::repeat((i as u8), 32);
                leaves.push_back(harness::leaf(first + i, timestamp, &seed, &seed));
            };
            i += 1;
        };
        let (root, path) = harness::tree(leaves, 1);
        harness::record_range(lc, root, first, first + 4);
        harness::header_with(&root, number, timestamp, &state, &receipts_root, &path)
    }

    fun case_proof(lc: address, i: u64): vector<u8> {
        let head = five(lc, f::block_receipts_root());
        let (nodes, tx, log) = if (i == 0) {
            (f::case0_nodes(), f::case0_tx(), f::case0_log())
        } else if (i == 1) {
            (f::case1_nodes(), f::case1_tx(), f::case1_log())
        } else {
            (f::case2_nodes(), f::case2_tx(), f::case2_log())
        };
        let proof = head;
        proof.append(harness::receipt_part(&nodes, tx, log));
        proof
    }

    fun claim(i: u64): (vector<u8>, vector<u8>, vector<u8>, vector<u8>) {
        if (i == 0) (f::case0_emitter(), f::case0_topic0(), f::case0_topic1(), f::case0_data())
        else if (i == 1) (f::case1_emitter(), f::case1_topic0(), f::case1_topic1(), f::case1_data())
        else (f::case2_emitter(), f::case2_topic0(), f::case2_topic1(), f::case2_data())
    }

    #[test]
    /// Every real log verifies: a one-byte key, a two-byte key (index 130), and a legacy receipt with no type byte.
    fun real_receipts_verify() {
        let lc = client();
        let i = 0;
        while (i < 3) {
            let proof = case_proof(lc, i);
            let (emitter, topic0, topic1, data) = claim(i);
            light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
            i += 1;
        };
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun another_block_is_not_the_log() {
        let lc = client();
        let proof = case_proof(lc, 0);
        let (emitter, topic0, topic1, data) = claim(0);
        light_client::verify_event(lc, &proof, f::block_number() + 1, &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun another_emitter_is_not_the_log() {
        let lc = client();
        let proof = case_proof(lc, 1);
        let (_, topic0, topic1, data) = claim(1);
        light_client::verify_event(lc, &proof, f::block_number(), &bytes::repeat(9, 20), &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun another_first_topic_is_not_the_log() {
        let lc = client();
        let proof = case_proof(lc, 2);
        let (emitter, _, topic1, data) = claim(2);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &bytes::zero32(), &topic1, &data);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun another_topic_is_not_the_log() {
        let lc = client();
        let proof = case_proof(lc, 2);
        let (emitter, topic0, _, data) = claim(2);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &bytes::zero32(), &data);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheLog, location = light_client)]
    fun other_data_is_not_the_log() {
        let lc = client();
        let proof = case_proof(lc, 0);
        let (emitter, topic0, topic1, data) = claim(0);
        data.push_back(0);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = ethereum::EBadEventProof, location = ethereum)]
    fun a_trailing_byte_is_refused() {
        let lc = client();
        let proof = case_proof(lc, 0);
        proof.push_back(0);
        let (emitter, topic0, topic1, data) = claim(0);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = ethereum::EBadEventProof, location = ethereum)]
    fun a_proof_without_its_receipt_is_refused() {
        let lc = client();
        let proof = five(lc, f::block_receipts_root());
        let (emitter, topic0, topic1, data) = claim(0);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = ethereum::EBadEventProof, location = ethereum)]
    fun a_short_header_is_refused() {
        let lc = client();
        light_client::verify_checkpoint(lc, &bytes::repeat(0, 112), 1, 1, &bytes::zero32());
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    fun a_headers_root_no_proof_recorded_is_refused() {
        let lc = client();
        let proof = harness::header_with(
            &bytes::repeat(7, 32),
            f::block_number(),
            f::block_timestamp(),
            &f::block_state_root(),
            &f::block_receipts_root(),
            &vector[],
        );
        proof.append(harness::receipt_part(&f::case0_nodes(), f::case0_tx(), f::case0_log()));
        let (emitter, topic0, topic1, data) = claim(0);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = light_client::ENoClient, location = light_client)]
    fun no_client_at_another_address() {
        client();
        light_client::verify_checkpoint(@0xbad, &vector[], 1, 1, &bytes::zero32());
    }

    fun refused(nodes: vector<u8>, tx: u64, log: u64, receipts_root: vector<u8>) {
        let lc = client();
        let proof = five(lc, receipts_root);
        proof.append(harness::receipt_part(&nodes, tx, log));
        let (emitter, topic0, topic1, data) = claim(0);
        light_client::verify_event(lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    }

    #[test, expected_failure(abort_code = ethereum::EFailedTransaction, location = ethereum)]
    fun a_failed_transaction_is_refused() {
        refused(f::failed_nodes(), f::failed_tx(), 0, f::block_receipts_root());
    }

    #[test, expected_failure(abort_code = ethereum::ENoReceipt, location = ethereum)]
    fun an_absent_receipt_is_refused() {
        refused(f::absent_nodes(), f::absent_tx(), 0, f::block_receipts_root());
    }

    #[test, expected_failure(abort_code = ethereum::ENoReceipt, location = ethereum)]
    fun a_transaction_past_two_bytes_is_refused() {
        refused(f::case0_nodes(), 0x10000, 0, f::block_receipts_root());
    }

    #[test, expected_failure(abort_code = ethereum::ENoLog, location = ethereum)]
    fun a_log_of_one_topic_is_refused() {
        refused(f::onetopic_nodes(), f::onetopic_tx(), f::onetopic_log(), f::block_receipts_root());
    }

    #[test, expected_failure(abort_code = ethereum::ENoLog, location = ethereum)]
    fun a_log_past_the_receipts_last_is_refused() {
        refused(f::case0_nodes(), f::case0_tx(), 99, f::block_receipts_root());
    }

    #[test, expected_failure(abort_code = ethereum::EBadReceiptProof, location = ethereum)]
    fun a_malformed_receipt_is_refused() {
        refused(f::malformed_nodes(), 0, 0, f::malformed_receipts_root());
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_under_another_root_is_refused() {
        refused(f::case0_nodes(), f::case0_tx(), f::case0_log(), f::malformed_receipts_root());
    }

    /// LG-1: a receipt that also holds another log of `k` bytes, as a permissionless call that emits logs of its own
    /// makes it. The vault's log is found past it, the leaf's length read as a u32.
    fun bloated(proof: vector<u8>, root: vector<u8>) {
        let lc = client();
        harness::record_range(lc, root, 10, 10);
        let payload = f::bloated_payload();
        let id = keccak256(payload);
        let topic = abi::event_topic();
        light_client::verify_event(lc, &proof, 10, &f::hub_index(), &topic, &id, &abi::log_data(&payload));
    }

    #[test]
    fun test_lg1_a_receipt_with_2_kb_of_other_logs() {
        bloated(f::bloated_2000_proof(), f::bloated_2000_root());
    }

    #[test]
    fun test_lg1_a_receipt_with_8_kb_of_other_logs() {
        bloated(f::bloated_8000_proof(), f::bloated_8000_root());
    }

    #[test]
    fun test_lg1_a_receipt_with_16_kb_of_other_logs() {
        bloated(f::bloated_16000_proof(), f::bloated_16000_root());
    }

    #[test]
    fun test_lg1_a_receipt_with_32_kb_of_other_logs() {
        bloated(f::bloated_32000_proof(), f::bloated_32000_root());
    }

    // ---------------------------------------------------------------------
    // Checkpoints
    // ---------------------------------------------------------------------

    #[test]
    /// A checkpoint is the very block: its number, timestamp and state root at their place under a recorded root.
    fun a_checkpoint_is_the_very_block() {
        let lc = client();
        let proof = five(lc, f::block_receipts_root());
        light_client::verify_checkpoint(lc, &proof, f::block_number(), f::block_timestamp(), &f::block_state_root());
        let r = light_client::range(lc, bytes::slice(&proof, 0, 32)).destroy_some();
        assert!(light_client::range_first(&r) == f::block_number() - 1 && light_client::range_last(&r) == f::block_number() + 3);
        assert!(light_client::range(lc, bytes::zero32()).is_none());
    }

    fun wrong_checkpoint(block: u64, timestamp: u64, root: vector<u8>) {
        let lc = client();
        let proof = five(lc, f::block_receipts_root());
        light_client::verify_checkpoint(lc, &proof, block, timestamp, &root);
    }

    #[test, expected_failure(abort_code = light_client::ENotTheCheckpoint, location = light_client)]
    fun another_number_is_not_the_checkpoint() {
        wrong_checkpoint(f::block_number() + 1, f::block_timestamp(), f::block_state_root());
    }

    #[test, expected_failure(abort_code = light_client::ENotTheCheckpoint, location = light_client)]
    fun another_timestamp_is_not_the_checkpoint() {
        wrong_checkpoint(f::block_number(), f::block_timestamp() + 1, f::block_state_root());
    }

    #[test, expected_failure(abort_code = light_client::ENotTheCheckpoint, location = light_client)]
    fun another_state_root_is_not_the_checkpoint() {
        wrong_checkpoint(f::block_number(), f::block_timestamp(), bytes::zero32());
    }

    #[test, expected_failure(abort_code = ethereum::EBadEventProof, location = ethereum)]
    /// A checkpoint proof is the header part alone: an event proof is not one.
    fun an_event_proof_is_no_checkpoint_proof() {
        let lc = client();
        let proof = case_proof(lc, 0);
        light_client::verify_checkpoint(lc, &proof, f::block_number(), f::block_timestamp(), &f::block_state_root());
    }

    /// The real block under the five-block root, its range recorded as `first..last`, its path cut to `depth` steps.
    fun misplaced(first: u64, last: u64, depth: u64) {
        let lc = client();
        let proof = five(lc, f::block_receipts_root());
        let root = bytes::slice(&proof, 0, 32);
        harness::record_range(lc, root, first, last);
        let cut = bytes::slice(&proof, 0, 112);
        cut.push_back((depth as u8));
        cut.append(bytes::slice(&proof, 113, 32 * depth));
        light_client::verify_checkpoint(lc, &cut, f::block_number(), f::block_timestamp(), &f::block_state_root());
    }

    #[test]
    fun the_whole_path_places_the_block() {
        misplaced(f::block_number() - 1, f::block_number() + 3, 3);
    }

    #[test, expected_failure(abort_code = ethereum::ENotInRange, location = ethereum)]
    fun a_block_outside_its_range_is_refused() {
        misplaced(f::block_number() + 1, f::block_number() + 5, 3);
    }

    #[test, expected_failure(abort_code = ethereum::ENotInRange, location = ethereum)]
    fun a_block_past_its_range_is_refused() {
        misplaced(f::block_number() - 5, f::block_number() - 1, 3);
    }

    #[test, expected_failure(abort_code = ethereum::EBadHeaderPath, location = ethereum)]
    fun a_block_placed_elsewhere_is_refused() {
        misplaced(f::block_number() - 2, f::block_number() + 2, 3);
    }

    #[test, expected_failure(abort_code = ethereum::EBadHeaderPath, location = ethereum)]
    fun a_path_of_the_wrong_depth_is_refused() {
        misplaced(f::block_number() - 1, f::block_number() + 3, 2);
    }

    // ---------------------------------------------------------------------
    // The anchor and the lag (LG-4)
    // ---------------------------------------------------------------------

    fun values(anchor_in: u8, anchor_out: u8, epoch: u64, first: u64, last: u64): vector<u8> {
        let v = bytes::repeat(anchor_in, 32);
        v.append(bytes::repeat(anchor_out, 32));
        v.append(bytes::word64(epoch));
        v.append(bytes::repeat(0x77, 32));
        v.append(bytes::word64(first));
        v.append(bytes::word64(last));
        v
    }

    #[test]
    /// Each proof starts from the stored anchor and moves it one step: as `EthereumFinalityVerifier.update`.
    fun an_update_follows_the_anchor() {
        let lc = client();
        light_client::advance_for_testing(lc, values(0xaa, 0xbb, 400_001, 100, 163));
        assert!(light_client::anchor(lc) == bytes::repeat(0xbb, 32) && light_client::epoch(lc) == 400_001);
        let r = light_client::range(lc, bytes::repeat(0x77, 32)).destroy_some();
        assert!(light_client::range_first(&r) == 100 && light_client::range_last(&r) == 163);
        light_client::advance_for_testing(lc, values(0xbb, 0xcc, 400_002, 164, 200));
        assert!(light_client::epoch(lc) == 400_002);
        assert!(light_client::key(lc) == bytes::repeat(1, 32) && light_client::genesis_time(lc) == GENESIS);
        assert!(light_client::system(lc) == light_client::sp1() && light_client::is_client(lc));
    }

    #[test, expected_failure(abort_code = light_client::EWrongAnchor, location = light_client)]
    fun an_update_from_another_anchor_is_refused() {
        let lc = client();
        light_client::advance_for_testing(lc, values(0xab, 0xbb, 400_001, 100, 163));
    }

    #[test, expected_failure(abort_code = light_client::EBadPublicValues, location = light_client)]
    fun an_epoch_past_64_bits_is_refused() {
        let lc = client();
        let v = values(0xaa, 0xbb, 400_001, 100, 163);
        v[2 * 32] = 1;
        light_client::advance_for_testing(lc, v);
    }

    #[test, expected_failure(abort_code = light_client::EBadPublicValues, location = light_client)]
    fun a_last_block_past_64_bits_is_refused() {
        let lc = client();
        let v = values(0xaa, 0xbb, 400_001, 100, 163);
        v[5 * 32 + 23] = 1;
        light_client::advance_for_testing(lc, v);
    }

    #[test, expected_failure(abort_code = light_client::EBadPublicValues, location = light_client)]
    fun short_public_values_are_refused() {
        let lc = client();
        let v = values(0xaa, 0xbb, 400_001, 100, 163);
        v.pop_back();
        light_client::advance_for_testing(lc, v);
    }

    #[test]
    fun test_b501_a_recent_checkpoint_is_taken_up_to_its_bound() {
        let lc = client();
        let fresh_until = GENESIS + 400_001 * 384 + 21_600;
        light_client::advance_at_for_testing(lc, values(0xaa, 0xbb, 400_001, 100, 163), fresh_until);
        assert!(light_client::epoch(lc) == 400_001);
    }

    #[test, expected_failure(abort_code = light_client::EStale, location = light_client)]
    /// B5-01: an update must end at a checkpoint whose epoch began at most MAX_UPDATE_AGE before now, as
    /// `FinalityVerifier.update`: a stale one-epoch step would void the proofs in flight while aging the anchor.
    fun test_b501_a_stale_checkpoint_is_refused() {
        let lc = client();
        let fresh_until = GENESIS + 400_001 * 384 + 21_600;
        light_client::advance_at_for_testing(lc, values(0xaa, 0xbb, 400_001, 100, 163), fresh_until + 1);
    }

    #[test]
    /// LG-4: the last second an update is taken is exactly a day after the anchor's epoch began, saturating.
    fun test_lg4_the_lag_ends_a_day_after_the_anchors_epoch() {
        let lc = client();
        assert!(light_client::lag_ends(lc) == GENESIS + 400_000 * 384 + 86_400);
        let far = light_client::create(
            &harness::signer_of(harness::creator()),
            b"far",
            light_client::sp1(),
            bytes::repeat(1, 32),
            bytes::repeat(2, 32),
            0xffffffffffffffff,
            GENESIS,
        );
        assert!(light_client::lag_ends(far) == 0xffffffffffffffff);
    }

    /// The fixture's proof submitted to a client of `system` at `us_past_lag` microseconds past its lag's last second.
    fun real_update(system: u8, us_past_lag: u64, sp1_proof: bool) {
        harness::boot(GENESIS + 400_000 * 384);
        let key = if (system == light_client::sp1()) f::sp1_program_key() else f::risc0_image_id();
        let lc = light_client::create(&harness::signer_of(harness::creator()), b"real", system, key, bytes::repeat(0xaa, 32), 400_000, GENESIS);
        harness::set_us(light_client::lag_ends(lc) * 1_000_000 + us_past_lag);
        if (sp1_proof) light_client::update(lc, f::sp1_public_values(), f::sp1_proof())
        else light_client::update(lc, f::risc0_journal(), f::risc0_seal());
    }

    #[test, expected_failure(abort_code = light_client::EBadPublicValues, location = light_client)]
    /// LG-4 on the real proofs: at the lag's last second, SP1's own proof passes the check, and then its public values,
    /// SP1's fixture's and not this statement's six words, are refused.
    fun test_lg4_a_real_sp1_proof_is_checked_within_the_lag() {
        real_update(light_client::sp1(), 999_999, true);
    }

    #[test, expected_failure(abort_code = light_client::ELagging, location = light_client)]
    /// A second past the lag, the same update is refused before any check.
    fun test_lg4_a_real_sp1_proof_is_refused_a_second_past_the_lag() {
        real_update(light_client::sp1(), 1_000_000, true);
    }

    #[test, expected_failure(abort_code = light_client::EBadPublicValues, location = light_client)]
    fun test_lg4_a_real_risc0_proof_is_checked_within_the_lag() {
        real_update(light_client::risc_zero(), 0, false);
    }

    #[test, expected_failure(abort_code = light_client::ELagging, location = light_client)]
    fun test_lg4_a_real_risc0_proof_is_refused_a_second_past_the_lag() {
        real_update(light_client::risc_zero(), 1_000_000, false);
    }

    #[test, expected_failure(abort_code = proofs::EWrongLength, location = proofs)]
    /// P1 takes only SP1's proofs and P2 only RISC Zero's: each system's proof fails the other's check.
    fun p1_takes_no_risc0_seal() {
        real_update(light_client::sp1(), 0, false);
    }

    #[test, expected_failure(abort_code = proofs::EWrongLength, location = proofs)]
    fun p2_takes_no_sp1_proof() {
        real_update(light_client::risc_zero(), 0, true);
    }

    #[test, expected_failure(abort_code = light_client::ENoClient, location = light_client)]
    fun no_update_without_a_client() {
        harness::boot(GENESIS + 400_000 * 384);
        light_client::update(@0xbad, f::sp1_public_values(), f::sp1_proof());
    }

    #[test, expected_failure(abort_code = light_client::EUnknownSystem, location = light_client)]
    fun a_client_of_an_unknown_system_is_refused() {
        harness::boot(GENESIS);
        light_client::create(&harness::signer_of(harness::creator()), b"x", 3, bytes::repeat(1, 32), bytes::repeat(2, 32), 1, GENESIS);
    }

    #[test, expected_failure(abort_code = light_client::EZeroValue, location = light_client)]
    fun a_client_without_a_key_is_refused() {
        harness::boot(GENESIS);
        light_client::create(&harness::signer_of(harness::creator()), b"x", 1, bytes::zero32(), bytes::repeat(2, 32), 1, GENESIS);
    }

    #[test, expected_failure(abort_code = light_client::EZeroValue, location = light_client)]
    fun a_client_with_a_short_key_is_refused() {
        harness::boot(GENESIS);
        light_client::create(&harness::signer_of(harness::creator()), b"x", 1, bytes::repeat(1, 31), bytes::repeat(2, 32), 1, GENESIS);
    }

    #[test, expected_failure(abort_code = light_client::EZeroValue, location = light_client)]
    fun a_client_without_an_anchor_is_refused() {
        harness::boot(GENESIS);
        light_client::create(&harness::signer_of(harness::creator()), b"x", 2, bytes::repeat(1, 32), bytes::zero32(), 1, GENESIS);
    }

    #[test, expected_failure(abort_code = light_client::EZeroValue, location = light_client)]
    fun a_client_without_a_genesis_is_refused() {
        harness::boot(GENESIS);
        light_client::create(&harness::signer_of(harness::creator()), b"x", 2, bytes::repeat(1, 32), bytes::repeat(2, 32), 1, 0);
    }

    #[test]
    /// The entry form makes the same client at `object::create_object_address(creator, seed)`.
    fun a_client_by_the_entry_function() {
        harness::boot(GENESIS);
        light_client::create_client(&harness::signer_of(harness::creator()), b"entry", 2, bytes::repeat(1, 32), bytes::repeat(2, 32), 1, GENESIS);
        let at = aptos_framework::object::create_object_address(&harness::creator(), b"entry");
        assert!(light_client::is_client(at) && light_client::system(at) == light_client::risc_zero());
    }
}
