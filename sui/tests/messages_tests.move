/// Messages from Ethereum: their proofs, route and emitter; the checkpoint they wait for (VLT-3); burns under the speed
/// limit, never to the vault itself (SOL-9); intakes settled and failed; migrations. The NEAR twin's `messages` tests.
#[test_only]
module xindex_vault::messages_tests;

use sui::hash::keccak256;
use xindex_vault::abi;
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::harness::{Self, T};
use xindex_vault::light_client;
use xindex_vault::vault;

const ONE: u64 = 1_000_000_000;
const BURN: u8 = 1;
const INTAKE_SETTLED: u8 = 2;
const INTAKE_FAILED: u8 = 3;
const MIGRATE: u8 = 4;
const FREEZE: u8 = 6;

/// A settle message for a fresh intake holding 4 SUI, its block, and both clients' proof of it.
fun settle_setup(t: &mut T): (vector<u8>, u64, vector<u8>) {
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 4 * ONE);
    let index = t.index();
    let settle = t.payload(INTAKE_SETTLED, &index, &intake);
    let block = t.next_block();
    let proof = t.proof_for(&index, &settle, block);
    (settle, block, proof)
}

/// A message runs on a log both P1 and P2 prove, of the index it names, routed here, once; and is the last message.
#[test]
fun a_message_runs_once_on_both_proofs() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    t.deliver_raw(settle, block, proof, proof);
    assert!(t.balance() == 4 * ONE);
    let v = t.take(harness::relayer());
    assert!(vault::used(&v, keccak256(&settle)));
    assert!(vault::last_message(&v) == keccak256(&settle));
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EAlreadyDelivered)]
fun a_message_runs_only_once() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    t.deliver_raw(settle, block, proof, proof);
    t.deliver_raw(settle, block, proof, proof);
    t.end();
}

/// LG-1: anyone may emit a marked message again with `resendMessage`, so the same payload's log lies in another block
/// too. The vault runs a message once by its id, from whichever block it is proven in first.
#[test, expected_failure(abort_code = vault::EAlreadyDelivered)]
fun test_lg1_a_message_sent_again_runs_once() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    t.deliver_raw(settle, block, proof, proof);
    let index = t.index();
    let again = t.next_block();
    let resent = t.proof_for(&index, &settle, again);
    t.deliver_raw(settle, again, resent, resent);
    t.end();
}

/// LG-1: a message whose first log never arrived runs from its resent log.
#[test]
fun test_lg1_a_resent_message_runs_from_its_new_block() {
    let mut t = harness::new();
    let (settle, block, _) = settle_setup(&mut t);
    let index = t.index();
    let again = t.next_block();
    assert!(again > block);
    let resent = t.proof_for(&index, &settle, again);
    t.deliver_raw(settle, again, resent, resent);
    assert!(t.balance() == 4 * ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoProof)]
fun a_message_needs_a_proof() {
    let mut t = harness::new();
    let (settle, block, _) = settle_setup(&mut t);
    t.deliver_raw(settle, block, vector[], vector[]);
    t.end();
}

/// One proof never moves coins: P1's alone, or P2's alone.
#[test, expected_failure(abort_code = vault::EBothProofsRequired)]
fun p1_alone_moves_no_coins() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    t.deliver_raw(settle, block, proof, vector[]);
    t.end();
}

#[test, expected_failure(abort_code = vault::EBothProofsRequired)]
fun p2_alone_moves_no_coins() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    t.deliver_raw(settle, block, vector[], proof);
    t.end();
}

/// A proof of another payload's log is not this log's.
#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun another_logs_proof_is_refused() {
    let mut t = harness::new();
    let (settle, block, _) = settle_setup(&mut t);
    let index = t.index();
    let intake = harness::intake_id(t.now() + 3600, 1);
    let other = t.payload(INTAKE_SETTLED, &index, &intake);
    let other_proof = t.proof_for(&index, &other, block);
    t.deliver_raw(settle, block, other_proof, other_proof);
    t.end();
}

/// A log in a block no proof recorded.
#[test, expected_failure(abort_code = light_client::EUnknownHeaders)]
fun an_unrecorded_block_is_refused() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    let mut unrecorded = proof;
    let b = unrecorded[0];
    *&mut unrecorded[0] = b ^ 1;
    t.deliver_raw(settle, block, unrecorded, proof);
    t.end();
}

/// P1 and P2 must prove the same log: a log P2 proves in another block is not the one delivered.
#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun the_proofs_must_agree_on_the_block() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    let index = t.index();
    let later = t.proof_for(&index, &settle, block + 1);
    t.deliver_raw(settle, block, proof, later);
    t.end();
}

fun routed(source: u64, dest: u64, vault_id: vector<u8>) {
    let mut t = harness::new();
    let index = t.index();
    let payload = harness::message(source, INTAKE_SETTLED, &index, &harness::intake_id(t.now() + 3600, 1), 50, dest, &vault_id);
    t.deliver_by(&index, payload, true, true);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongRoute)]
fun a_message_to_another_chain_is_refused() {
    routed(harness::sepolia(), harness::sui_testnet() + 1, f::hub_vault());
}

#[test, expected_failure(abort_code = vault::EWrongRoute)]
fun a_message_from_another_chain_is_refused() {
    routed(1, harness::sui_testnet(), f::hub_vault());
}

#[test, expected_failure(abort_code = vault::EWrongRoute)]
fun a_message_to_another_vault_is_refused() {
    routed(harness::sepolia(), harness::sui_testnet(), bytes::zero32());
}

/// A governance kind is the factory's alone.
#[test, expected_failure(abort_code = vault::EWrongEmitter)]
fun a_freeze_from_an_index_is_refused() {
    let mut t = harness::new();
    let body = harness::freeze_body(t.now() + 86_400);
    t.deliver(FREEZE, body);
    t.end();
}

#[test, expected_failure(abort_code = vault::EUnknownKind)]
fun an_unknown_kind_is_refused() {
    let mut t = harness::new();
    t.deliver(9, bytes::zero32());
    t.end();
}

#[test, expected_failure(abort_code = vault::EUnknownKind)]
fun kind_zero_is_refused() {
    let mut t = harness::new();
    t.deliver(0, bytes::zero32());
    t.end();
}

/// Any Ethereum contract can emit a message naming itself: only the factory's clones registered here are indexes.
#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_message_from_a_stranger_is_refused() {
    let mut t = harness::new();
    let stranger = vector::tabulate!(20, |_| 0x77u8);
    let intake = harness::intake_id(t.now() + 3600, 1);
    let payload = t.payload(INTAKE_SETTLED, &stranger, &intake);
    t.deliver_by(&stranger, payload, true, true);
    t.end();
}

/// Only the vault's own P1 and P2 prove anything to it: other clients, even ones that recorded the block, are refused.
#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun other_clients_are_refused() {
    let mut t = harness::new();
    let (settle, block, proof) = settle_setup(&mut t);
    let (a, b) = t.new_pair(40);
    let mut v = t.take(harness::relayer());
    let (c1, c2) = (t.client(a), t.client(b));
    let (clock, ctx) = t.parts();
    vault::deliver(&mut v, &c1, &c2, settle, block, proof, proof, clock, ctx);
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
    t.end();
}

/// A message claimed in a real receipt: the proof walks block 26,092,387's real receipts trie to each case's receipt,
/// and finds its log is not the message.
fun real_receipt(case: u64) {
    let mut t = harness::new();
    let number = f::block_number();
    t.advance(number + 10);
    let (p1, p2) = t.pair();
    let first = number - 1;
    let receipts_root = f::block_receipts_root();
    let state = f::block_state_root();
    let leaves = vector::tabulate!(5, |i| {
        if (i == 1) {
            harness::leaf(number, f::block_timestamp(), &state, &receipts_root)
        } else {
            let seed = vector::tabulate!(32, |_| (i as u8));
            harness::leaf(first + i, f::block_timestamp(), &seed, &seed)
        }
    });
    let (root, path) = harness::tree(leaves, 1);
    t.record_range(p1, root, first, first + 4);
    t.record_range(p2, root, first, first + 4);
    let mut proof = harness::header_with(&root, number, f::block_timestamp(), &state, &receipts_root, &path);
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
    t.end();
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun a_real_receipt_holds_no_message_of_ours_one_byte_key() {
    real_receipt(0);
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun a_real_receipt_holds_no_message_of_ours_two_byte_key() {
    real_receipt(1);
}

#[test, expected_failure(abort_code = light_client::ENotTheLog)]
fun a_real_receipt_holds_no_message_of_ours_legacy() {
    real_receipt(2);
}

// ---------------------------------------------------------------------
// VLT-3
// ---------------------------------------------------------------------

/// VLT-3: a message that moves coins runs only from a block the vault's checkpoint covers, so the snapshot, which is the
/// last checkpoint, never pays a holder whose burn the vault also paid. Once the checkpoint covers the block, it runs.
#[test, expected_failure(abort_code = vault::ENotCheckpointed)]
fun test_vlt3_a_message_after_the_checkpoint_waits_for_it() {
    let mut t = harness::new();
    t.advance(1_000);
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 4 * ONE);
    let index = t.index();
    let settle = t.payload(INTAKE_SETTLED, &index, &intake);
    let proof = t.proof_for(&index, &settle, 1_001);
    t.deliver_raw(settle, 1_001, proof, proof);
    t.end();
}

#[test]
fun test_vlt3_a_message_runs_once_its_block_is_checkpointed() {
    let mut t = harness::new();
    t.advance(1_000);
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 4 * ONE);
    let index = t.index();
    let settle = t.payload(INTAKE_SETTLED, &index, &intake);
    let proof = t.proof_for(&index, &settle, 1_001);
    t.advance(1_001);
    t.deliver_raw(settle, 1_001, proof, proof);
    assert!(t.balance() == 4 * ONE);
    t.end();
}

// ---------------------------------------------------------------------
// Intakes
// ---------------------------------------------------------------------

/// A settled intake's deposits join the index: its balance, its digest, SUI among its tokens.
#[test]
fun a_settled_intake_joins_the_index() {
    let mut t = harness::new();
    let intake = t.fund(7 * ONE);
    let (has, balance, paid, digest, _) = t.index_state(f::hub_index());
    assert!(has && balance == 7 * ONE && paid == 0);
    assert!(digest == abi::index_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), true, 7 * ONE, 0));
    let v = t.take(harness::relayer());
    assert!(vault::slot(&v, vault::index_slot(&f::hub_index())) == digest);
    let (state, total, intake_digest) = vault::intake(&v, f::hub_index(), intake);
    assert!(state == 2 && total == 7 * ONE);
    assert!(intake_digest == abi::intake_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 2, true, 7 * ONE));
    harness::put(v);
    t.end();
}

/// An intake nobody deposited into settles or fails empty, and its digest says so.
#[test]
fun an_intake_without_deposits_settles_empty() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 9);
    t.deliver(INTAKE_SETTLED, intake);
    let (has, balance, _, _, _) = t.index_state(f::hub_index());
    assert!(!has && balance == 0);
    let v = t.take(harness::relayer());
    let (state, _, digest) = vault::intake(&v, f::hub_index(), intake);
    assert!(state == 2);
    assert!(digest == abi::intake_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 2, false, 0));
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeNotOpen)]
fun a_settled_intake_settles_once() {
    let mut t = harness::new();
    let intake = t.fund(ONE);
    t.deliver(INTAKE_SETTLED, intake);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeNotOpen)]
fun a_settled_intake_cannot_fail() {
    let mut t = harness::new();
    let intake = t.fund(ONE);
    t.deliver(INTAKE_FAILED, intake);
    t.end();
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun an_intake_message_carries_one_word() {
    let mut t = harness::new();
    let mut body = harness::intake_id(t.now() + 3600, 1);
    body.push_back(0);
    t.deliver(INTAKE_SETTLED, body);
    t.end();
}

// ---------------------------------------------------------------------
// Burns and the speed limit
// ---------------------------------------------------------------------

/// A burn pays its recipient what the speed limit allows now, 4% of the index's balance in any 24 hours, and owes the
/// rest, which anyone releases as the limit allows; a frozen vault pays nothing, and an explicit release that can pay
/// nothing aborts.
#[test]
fun a_burn_pays_within_the_speed_limit_and_owes_the_rest() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let to = @0xbeef;
    let burn = t.deliver(BURN, harness::burn_body(100 * ONE, to));
    assert!(t.received(to) == 40 * ONE, 0);
    let id = keccak256(&burn);
    assert!(t.owed_remaining(id) == 60 * ONE);
    assert!(t.balance() == 960 * ONE && t.held() == 960 * ONE);
    // 24 hours later the payout is still inside the window: nothing more.
    t.warp(24 * 3600);
    let (_, _, _, _, available) = t.index_state(f::hub_index());
    assert!(available == 0, 1);
    t.warp(3600);
    t.release(id);
    assert!(t.received(to) == 960 * ONE / 25, 2);
    let (_, balance, paid, digest, _) = t.index_state(f::hub_index());
    assert!(paid == 40 * ONE + 960 * ONE / 25 && balance == 1_000 * ONE - paid);
    assert!(digest == abi::index_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), true, balance, paid));
    assert!(t.held() == balance);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENothingPayable)]
fun a_release_that_pays_nothing_aborts() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
    t.release(keccak256(&burn));
    t.end();
}

/// Frozen: nothing is paid, and an explicit release aborts; the freeze over, it pays.
#[test, expected_failure(abort_code = vault::ENothingPayable)]
fun a_frozen_vault_pays_nothing() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    t.warp(25 * 3600);
    t.release(keccak256(&burn));
    t.end();
}

#[test]
fun a_freeze_over_pays_again() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == 40 * ONE);
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    t.warp(14 * 86_400);
    t.release(keccak256(&burn));
    assert!(t.received(@0xbeef) == 960 * ONE / 25);
    t.end();
}

/// A burn delivered while frozen is accepted and owed, and pays nothing until the freeze is over.
#[test]
fun a_burn_delivered_while_frozen_waits() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    let burn = t.deliver(BURN, harness::burn_body(100 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == 0);
    assert!(t.owed_remaining(keccak256(&burn)) == 100 * ONE);
    t.end();
}

/// The outflow floor: a small index may still pay the floor in a day, more than 4% of it.
#[test]
fun the_floor_pays_a_small_index() {
    let mut t = harness::new();
    t.fund(10 * ONE);
    t.deliver(BURN, harness::burn_body(5 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == ONE);
    t.end();
}

/// Never more than the index holds, whatever the floor.
#[test]
fun a_payout_never_passes_the_balance() {
    let mut t = harness::new();
    t.fund(ONE / 2);
    t.deliver(BURN, harness::burn_body(5 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == ONE / 2);
    assert!(t.balance() == 0);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_burn_to_no_one_is_refused() {
    let mut t = harness::new();
    t.fund(100 * ONE);
    t.deliver(BURN, harness::burn_body(ONE, @0x0));
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAmount)]
fun a_burn_of_nothing_is_refused() {
    let mut t = harness::new();
    t.fund(100 * ONE);
    t.deliver(BURN, harness::burn_body(0, @0xbeef));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNative)]
fun a_burn_of_another_token_is_refused() {
    let mut t = harness::new();
    t.fund(100 * ONE);
    let mut body = harness::burn_body(ONE, @0xbeef);
    *&mut body[31] = 1;
    t.deliver(BURN, body);
    t.end();
}

/// An amount from Ethereum that does not fit 64 bits is refused (interfaces doc).
#[test, expected_failure(abort_code = abi::EOverflow)]
fun a_burn_past_64_bits_is_refused() {
    let mut t = harness::new();
    t.fund(100 * ONE);
    let mut body = bytes::zero32();
    body.append(bytes::word(1 << 64));
    body.append(sui::address::to_bytes(@0xbeef));
    t.deliver(BURN, body);
    t.end();
}

/// SOL-9's Sui twin: a coin sent to the vault's own object would be stranded, since nothing here ever receives one.
#[test, expected_failure(abort_code = vault::EWrongRecipient)]
fun test_sol9_the_vault_is_no_recipient() {
    let mut t = harness::new();
    t.fund(100 * ONE);
    let own = sui::address::from_bytes(f::hub_vault());
    t.deliver(BURN, harness::burn_body(ONE, own));
    t.end();
}

// ---------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------

fun register_v2(t: &mut T) {
    let mut v = t.take(harness::relayer());
    vault::register_index(&mut v, f::migrate_new_index(), f::migrate_new_salt());
    harness::put(v);
}

/// A migration moves coins two versions share from the old index's balance into the new one's, within the speed limit;
/// the coins never leave the vault, so `held` stays.
#[test]
fun a_migration_moves_coins_between_indexes_within_the_limit() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    register_v2(&mut t);
    let payload = t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 50 * ONE));
    assert!(t.balance() == 480 * ONE, 0);
    let (has, balance, _, digest, _) = t.index_state(f::migrate_new_index());
    assert!(has && balance == 20 * ONE, 1);
    assert!(digest == abi::index_digest(harness::sui_testnet(), &f::hub_vault(), &f::migrate_new_index(), true, 20 * ONE, 0));
    assert!(t.held() == 500 * ONE);
    let v = t.take(harness::relayer());
    let (to_index, _, new_index, remaining) = vault::owed(&v, f::hub_index(), keccak256(&payload));
    assert!(to_index && new_index == f::migrate_new_index() && remaining == 30 * ONE);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_migration_to_an_unregistered_index_is_refused() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 10 * ONE));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_migration_to_itself_is_refused() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    t.deliver(MIGRATE, harness::migrate_body(&f::hub_index(), 10 * ONE));
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAmount)]
fun a_migration_of_nothing_is_refused() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    register_v2(&mut t);
    t.deliver(MIGRATE, harness::migrate_body(&f::migrate_new_index(), 0));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNative)]
fun a_migration_of_another_token_is_refused() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    register_v2(&mut t);
    let mut body = harness::migrate_body(&f::migrate_new_index(), ONE);
    *&mut body[63] = 1;
    t.deliver(MIGRATE, body);
    t.end();
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_migration_to_no_address_is_refused() {
    let mut t = harness::new();
    t.fund(500 * ONE);
    let mut body = harness::migrate_body(&f::migrate_new_index(), ONE);
    *&mut body[0] = 1;
    t.deliver(MIGRATE, body);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENothingOwed)]
fun nothing_owed_releases_nothing() {
    let mut t = harness::new();
    t.release(bytes::zero32());
    t.end();
}

#[test, expected_failure(abort_code = vault::ENothingOwed)]
fun a_burn_paid_in_full_is_owed_no_more() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    let burn = t.deliver(BURN, harness::burn_body(10 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == 10 * ONE);
    t.release(keccak256(&burn));
    t.end();
}
