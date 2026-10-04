/// The light client's rules on real data: block 26,092,387's receipts trie (`test/fixtures/ethereum/receipts.json`),
/// under a headers root a proof would have recorded; and the anchor's step and lag, as `EthereumFinalityVerifier.t.sol`
/// and the core's `tests/light_client.rs` check them.
#[test_only]
module xindex_vault::light_client_tests;

use sui::clock;
use xindex_vault::bytes;
use xindex_vault::ethereum;
use xindex_vault::fixtures as f;
use xindex_vault::harness;
use xindex_vault::light_client::{Self, LightClient};
use xindex_vault::mpt;
use xindex_vault::proofs;

const GENESIS: u64 = 1_606_824_023;

fun client(ctx: &mut TxContext): LightClient {
    light_client::new(light_client::sp1(), vector::tabulate!(32, |_| 1u8), vector::tabulate!(32, |_| 0xaau8), 400_000, GENESIS, ctx)
}

/// A proof over five blocks, the real one second: its header part, the five recorded by `lc`.
fun five(lc: &mut LightClient, receipts_root: vector<u8>): vector<u8> {
    let (number, timestamp, state) = (f::block_number(), f::block_timestamp(), f::block_state_root());
    let first = number - 1;
    let leaves = vector::tabulate!(5, |i| {
        if (i == 1) {
            harness::leaf(number, timestamp, &state, &receipts_root)
        } else {
            let seed = vector::tabulate!(32, |_| (i as u8));
            harness::leaf(first + i, timestamp, &seed, &seed)
        }
    });
    let (root, path) = harness::tree(leaves, 1);
    light_client::record_for_testing(lc, root, first, first + 4);
    harness::header_with(&root, number, timestamp, &state, &receipts_root, &path)
}

fun case_proof(lc: &mut LightClient, i: u64): vector<u8> {
    let head = five(lc, f::block_receipts_root());
    let (nodes, tx, log) = if (i == 0) {
        (f::case0_nodes(), f::case0_tx(), f::case0_log())
    } else if (i == 1) {
        (f::case1_nodes(), f::case1_tx(), f::case1_log())
    } else {
        (f::case2_nodes(), f::case2_tx(), f::case2_log())
    };
    let mut proof = head;
    proof.append(harness::receipt_part(&nodes, tx, log));
    proof
}

fun claim(i: u64): (vector<u8>, vector<u8>, vector<u8>, vector<u8>) {
    if (i == 0) (f::case0_emitter(), f::case0_topic0(), f::case0_topic1(), f::case0_data())
    else if (i == 1) (f::case1_emitter(), f::case1_topic0(), f::case1_topic1(), f::case1_data())
    else (f::case2_emitter(), f::case2_topic0(), f::case2_topic1(), f::case2_data())
}

/// Every real log verifies: a one-byte key, a two-byte key (index 130), and a legacy receipt with no type byte.
#[test]
fun real_receipts_verify() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut i = 0;
    while (i < 3) {
        let proof = case_proof(&mut lc, i);
        let (emitter, topic0, topic1, data) = claim(i);
        light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
        i = i + 1;
    };
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun another_block_is_not_the_log() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = case_proof(&mut lc, 0);
    let (emitter, topic0, topic1, data) = claim(0);
    light_client::verify_event(&lc, &proof, f::block_number() + 1, &emitter, &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun another_emitter_is_not_the_log() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = case_proof(&mut lc, 1);
    let (_, topic0, topic1, data) = claim(1);
    light_client::verify_event(&lc, &proof, f::block_number(), &vector::tabulate!(20, |_| 9u8), &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun another_topic_is_not_the_log() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = case_proof(&mut lc, 2);
    let (emitter, topic0, _, data) = claim(2);
    light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &bytes::zero32(), &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun other_data_is_not_the_log() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = case_proof(&mut lc, 0);
    let (emitter, topic0, topic1, mut data) = claim(0);
    data.push_back(0);
    light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = ethereum::EBadEventProof)]
fun a_trailing_byte_is_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut proof = case_proof(&mut lc, 0);
    proof.push_back(0);
    let (emitter, topic0, topic1, data) = claim(0);
    light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EUnknownHeaders)]
fun a_headers_root_no_proof_recorded_is_refused() {
    let mut ctx = tx_context::dummy();
    let lc = client(&mut ctx);
    let mut proof = harness::header_with(
        &vector::tabulate!(32, |_| 7u8),
        f::block_number(),
        f::block_timestamp(),
        &f::block_state_root(),
        &f::block_receipts_root(),
        &vector[],
    );
    proof.append(harness::receipt_part(&f::case0_nodes(), f::case0_tx(), f::case0_log()));
    let (emitter, topic0, topic1, data) = claim(0);
    light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

fun refused(nodes: vector<u8>, tx: u64, log: u64, receipts_root: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut proof = five(&mut lc, receipts_root);
    proof.append(harness::receipt_part(&nodes, tx, log));
    let (emitter, topic0, topic1, data) = claim(0);
    light_client::verify_event(&lc, &proof, f::block_number(), &emitter, &topic0, &topic1, &data);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = ethereum::EFailedTransaction)]
fun a_failed_transaction_is_refused() {
    refused(f::failed_nodes(), f::failed_tx(), 0, f::block_receipts_root());
}

#[test, expected_failure(abort_code = ethereum::ENoReceipt)]
fun an_absent_receipt_is_refused() {
    refused(f::absent_nodes(), f::absent_tx(), 0, f::block_receipts_root());
}

#[test, expected_failure(abort_code = ethereum::ENoLog)]
fun a_log_of_one_topic_is_refused() {
    refused(f::onetopic_nodes(), f::onetopic_tx(), f::onetopic_log(), f::block_receipts_root());
}

#[test, expected_failure(abort_code = ethereum::ENoLog)]
fun a_log_past_the_receipts_last_is_refused() {
    refused(f::case0_nodes(), f::case0_tx(), 99, f::block_receipts_root());
}

#[test, expected_failure(abort_code = ethereum::EBadReceiptProof)]
fun a_malformed_receipt_is_refused() {
    refused(f::malformed_nodes(), 0, 0, f::malformed_receipts_root());
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_node_under_another_root_is_refused() {
    refused(f::case0_nodes(), f::case0_tx(), f::case0_log(), f::malformed_receipts_root());
}

/// LG-1: a receipt that also holds another log of `k` bytes, as a permissionless call that emits logs of its own makes
/// it. The vault's log is found past it, the leaf's length read as a u32.
fun bloated(proof: vector<u8>, root: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    light_client::record_for_testing(&mut lc, root, 10, 10);
    let payload = f::bloated_payload();
    let id = sui::hash::keccak256(&payload);
    let topic = xindex_vault::abi::event_topic();
    light_client::verify_event(&lc, &proof, 10, &f::hub_index(), &topic, &id, &xindex_vault::abi::log_data(&payload));
    lc.destroy_for_testing();
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

/// A checkpoint is the very block: its number, timestamp and state root at their place under a recorded root.
#[test]
fun a_checkpoint_is_the_very_block() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = five(&mut lc, f::block_receipts_root());
    light_client::verify_checkpoint(&lc, &proof, f::block_number(), f::block_timestamp(), &f::block_state_root());
    lc.destroy_for_testing();
}

fun wrong_checkpoint(block: u64, timestamp: u64, root: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = five(&mut lc, f::block_receipts_root());
    light_client::verify_checkpoint(&lc, &proof, block, timestamp, &root);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::ENotTheCheckpoint)]
fun another_number_is_not_the_checkpoint() {
    wrong_checkpoint(f::block_number() + 1, f::block_timestamp(), f::block_state_root());
}

#[test, expected_failure(abort_code = light_client::ENotTheCheckpoint)]
fun another_timestamp_is_not_the_checkpoint() {
    wrong_checkpoint(f::block_number(), f::block_timestamp() + 1, f::block_state_root());
}

#[test, expected_failure(abort_code = light_client::ENotTheCheckpoint)]
fun another_state_root_is_not_the_checkpoint() {
    wrong_checkpoint(f::block_number(), f::block_timestamp(), bytes::zero32());
}

/// The real block under the five-block root, its range recorded as `first..last`, its path cut to `depth` steps.
fun misplaced(first: u64, last: u64, depth: u64) {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let proof = five(&mut lc, f::block_receipts_root());
    let root = bytes::slice(&proof, 0, 32);
    light_client::record_for_testing(&mut lc, root, first, last);
    let mut cut = bytes::slice(&proof, 0, 112);
    cut.push_back((depth as u8));
    cut.append(bytes::slice(&proof, 113, 32 * depth));
    light_client::verify_checkpoint(&lc, &cut, f::block_number(), f::block_timestamp(), &f::block_state_root());
    lc.destroy_for_testing();
}

#[test]
fun the_whole_path_places_the_block() {
    misplaced(f::block_number() - 1, f::block_number() + 3, 3);
}

#[test, expected_failure(abort_code = ethereum::ENotInRange)]
fun a_block_outside_its_range_is_refused() {
    misplaced(f::block_number() + 1, f::block_number() + 5, 3);
}

#[test, expected_failure(abort_code = ethereum::EBadHeaderPath)]
fun a_block_placed_elsewhere_is_refused() {
    misplaced(f::block_number() - 2, f::block_number() + 2, 3);
}

#[test, expected_failure(abort_code = ethereum::EBadHeaderPath)]
fun a_path_of_the_wrong_depth_is_refused() {
    misplaced(f::block_number() - 1, f::block_number() + 3, 2);
}

// ---------------------------------------------------------------------
// The anchor and the lag (LG-4)
// ---------------------------------------------------------------------

fun values(anchor_in: u8, anchor_out: u8, epoch: u64, first: u64, last: u64): vector<u8> {
    let mut v = vector::tabulate!(32, |_| anchor_in);
    v.append(vector::tabulate!(32, |_| anchor_out));
    v.append(bytes::word64(epoch));
    v.append(vector::tabulate!(32, |_| 0x77u8));
    v.append(bytes::word64(first));
    v.append(bytes::word64(last));
    v
}

/// Each proof starts from the stored anchor and moves it one step: as `EthereumFinalityVerifier.update`.
#[test]
fun an_update_follows_the_anchor() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    light_client::advance_for_testing(&mut lc, values(0xaa, 0xbb, 400_001, 100, 163));
    assert!(lc.anchor() == vector::tabulate!(32, |_| 0xbbu8) && lc.epoch() == 400_001);
    let r = lc.range(vector::tabulate!(32, |_| 0x77u8)).destroy_some();
    assert!(r.range_first() == 100 && r.range_last() == 163);
    light_client::advance_for_testing(&mut lc, values(0xbb, 0xcc, 400_002, 164, 200));
    assert!(lc.epoch() == 400_002);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EWrongAnchor)]
fun an_update_from_another_anchor_is_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    light_client::advance_for_testing(&mut lc, values(0xab, 0xbb, 400_001, 100, 163));
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EBadPublicValues)]
fun an_epoch_past_64_bits_is_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut v = values(0xaa, 0xbb, 400_001, 100, 163);
    *&mut v[2 * 32] = 1;
    light_client::advance_for_testing(&mut lc, v);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EBadPublicValues)]
fun a_last_block_past_64_bits_is_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut v = values(0xaa, 0xbb, 400_001, 100, 163);
    *&mut v[5 * 32 + 23] = 1;
    light_client::advance_for_testing(&mut lc, v);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EBadPublicValues)]
fun short_public_values_are_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let mut v = values(0xaa, 0xbb, 400_001, 100, 163);
    v.pop_back();
    light_client::advance_for_testing(&mut lc, v);
    lc.destroy_for_testing();
}

/// LG-4: the last second an update is taken is exactly a day after the anchor's epoch began, saturating.
#[test]
fun test_b501_a_recent_checkpoint_is_taken_up_to_its_bound() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let fresh_until = GENESIS + 400_001 * 384 + 21_600;
    light_client::advance_at_for_testing(&mut lc, values(0xaa, 0xbb, 400_001, 100, 163), fresh_until);
    lc.destroy_for_testing();
}

/// B5-01: an update must end at a checkpoint whose epoch began at most MAX_UPDATE_AGE before now, as
/// `FinalityVerifier.update`: a stale one-epoch step would void the proofs in flight while aging the anchor.
#[test, expected_failure(abort_code = light_client::EStale)]
fun test_b501_a_stale_checkpoint_is_refused() {
    let mut ctx = tx_context::dummy();
    let mut lc = client(&mut ctx);
    let fresh_until = GENESIS + 400_001 * 384 + 21_600;
    light_client::advance_at_for_testing(&mut lc, values(0xaa, 0xbb, 400_001, 100, 163), fresh_until + 1);
    lc.destroy_for_testing();
}

#[test]
fun test_lg4_the_lag_ends_a_day_after_the_anchors_epoch() {
    let mut ctx = tx_context::dummy();
    let lc = client(&mut ctx);
    assert!(lc.lag_ends() == GENESIS + 400_000 * 384 + 86_400);
    lc.destroy_for_testing();
    let far = light_client::new(light_client::sp1(), vector::tabulate!(32, |_| 1u8), vector::tabulate!(32, |_| 2u8), 0xffffffffffffffff, GENESIS, &mut ctx);
    assert!(far.lag_ends() == 0xffffffffffffffff);
    far.destroy_for_testing();
}

fun real_update(system: u8, at_ms_past_lag: u64, sp1_proof: bool) {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let key = if (system == light_client::sp1()) f::sp1_program_key() else f::risc0_image_id();
    let mut lc = light_client::new(system, key, vector::tabulate!(32, |_| 0xaau8), 400_000, GENESIS, &mut ctx);
    clock.set_for_testing(lc.lag_ends() * 1000 + at_ms_past_lag);
    if (sp1_proof) light_client::update(&mut lc, f::sp1_public_values(), f::sp1_proof(), &clock)
    else light_client::update(&mut lc, f::risc0_journal(), f::risc0_seal(), &clock);
    lc.destroy_for_testing();
    clock.destroy_for_testing();
}

/// LG-4 on the real proofs: at the lag's last second, SP1's own proof passes the check, and then its public values,
/// SP1's fixture's and not this statement's six words, are refused.
#[test, expected_failure(abort_code = light_client::EBadPublicValues)]
fun test_lg4_a_real_sp1_proof_is_checked_within_the_lag() {
    real_update(light_client::sp1(), 999, true);
}

/// A second past the lag, the same update is refused before any check.
#[test, expected_failure(abort_code = light_client::ELagging)]
fun test_lg4_a_real_sp1_proof_is_refused_a_second_past_the_lag() {
    real_update(light_client::sp1(), 1000, true);
}

#[test, expected_failure(abort_code = light_client::EBadPublicValues)]
fun test_lg4_a_real_risc0_proof_is_checked_within_the_lag() {
    real_update(light_client::risc_zero(), 0, false);
}

#[test, expected_failure(abort_code = light_client::ELagging)]
fun test_lg4_a_real_risc0_proof_is_refused_a_second_past_the_lag() {
    real_update(light_client::risc_zero(), 1000, false);
}

/// P1 takes only SP1's proofs and P2 only RISC Zero's: each system's proof fails the other's check.
#[test, expected_failure(abort_code = proofs::EWrongLength)]
fun p1_takes_no_risc0_seal() {
    real_update(light_client::sp1(), 0, false);
}

#[test, expected_failure(abort_code = proofs::EWrongLength)]
fun p2_takes_no_sp1_proof() {
    real_update(light_client::risc_zero(), 0, true);
}

#[test, expected_failure(abort_code = light_client::EUnknownSystem)]
fun a_client_of_an_unknown_system_is_refused() {
    let mut ctx = tx_context::dummy();
    let lc = light_client::new(3, vector::tabulate!(32, |_| 1u8), vector::tabulate!(32, |_| 2u8), 1, GENESIS, &mut ctx);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EZeroValue)]
fun a_client_without_a_key_is_refused() {
    let mut ctx = tx_context::dummy();
    let lc = light_client::new(1, bytes::zero32(), vector::tabulate!(32, |_| 2u8), 1, GENESIS, &mut ctx);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EZeroValue)]
fun a_client_without_an_anchor_is_refused() {
    let mut ctx = tx_context::dummy();
    let lc = light_client::new(2, vector::tabulate!(32, |_| 1u8), bytes::zero32(), 1, GENESIS, &mut ctx);
    lc.destroy_for_testing();
}

#[test, expected_failure(abort_code = light_client::EZeroValue)]
fun a_client_without_a_genesis_is_refused() {
    let mut ctx = tx_context::dummy();
    let lc = light_client::new(2, vector::tabulate!(32, |_| 1u8), vector::tabulate!(32, |_| 2u8), 1, 0, &mut ctx);
    lc.destroy_for_testing();
}
