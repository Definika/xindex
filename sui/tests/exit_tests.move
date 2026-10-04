/// The snapshot exit on a real hub's storage (`tests/fixtures/hub.json`, written by `tests/fixtures/generate.py` from a
/// hub on anvil with Sui testnet's registry id and this vault's id): open intakes resolved from the hub's settled mark,
/// a burn or migration in flight paid from the hub's sent mark, and holders paid their shares at the snapshot (VLT-1,
/// SOL-9), each read through a storage proof under the snapshot's state root. The NEAR twin's `exit` tests.
#[test_only]
module xindex_vault::exit_tests;

use sui::hash::keccak256;
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::harness::{Self, T};
use xindex_vault::mpt;
use xindex_vault::snapshot;
use xindex_vault::state_reader;
use xindex_vault::vault;

const ONE: u64 = 1_000_000_000;
const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
const UNIT: u64 = 7_500_000_000;

/// The vault as it stands at the hub's last block: the index registered, the settled order's SUI and an open order's
/// deposited before their deadlines, and its checkpoint at that block, whose state root the reads are under.
fun exit(): T {
    let mut t = harness::new();
    t.deposit(harness::alice(), f::settled_intake_id(), f::settled_intake_amount());
    t.set_now(f::hub_timestamp() + 60);
    t.deposit(harness::bob(), f::open_intake_id(), f::open_intake_amount());
    t.advance_to(f::hub_block(), f::hub_timestamp(), f::hub_state_root());
    t
}

fun snapshot_now(t: &mut T) {
    let start = t.stall_start();
    t.set_now(start + SNAPSHOT_EXIT_DELAY);
    t.begin_snapshot();
}

/// The exit begun and the settled order resolved: the index holds its 75 SUI.
fun settled(): T {
    let mut t = exit();
    snapshot_now(&mut t);
    resolve(&mut t, f::settled_intake_id(), f::settled_intake_proof());
    t
}

fun resolve(t: &mut T, intake: vector<u8>, proof: vector<u8>) {
    let mut v = t.take(harness::relayer());
    vault::resolve_intake(&mut v, f::hub_index(), intake, proof);
    harness::put(v);
}

fun recorded(t: &mut T, payload: vector<u8>, proof: vector<u8>) {
    let mut v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::deliver_recorded(&mut v, payload, proof, clock, ctx);
    harness::put(v);
}

fun claim(t: &mut T, holder: vector<u8>, component: u64, recipient: address, signature: vector<u8>, proof: vector<u8>) {
    let mut v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::claim_snapshot(&mut v, f::hub_index(), holder, component, recipient, signature, proof, clock, ctx);
    harness::put(v);
}

fun claim_a(t: &mut T, recipient: address, component: u64, signature: vector<u8>) {
    let proof = if (component == 0) f::holder_a_claim0_proof()
    else if (component == 1) f::holder_a_claim1_proof()
    else f::holder_a_claim2_proof();
    claim(t, f::holder_a(), component, recipient, signature, proof);
}

fun claim_b(t: &mut T, recipient: address) {
    claim(t, f::holder_b(), 1, recipient, vector[], f::holder_b_claim1_proof());
}

fun recipient_a(): address { sui::address::from_bytes(f::holder_a_recipient()) }

fun recipient_b(): address { sui::address::from_bytes(f::holder_b_recipient()) }

/// The whole exit, on a real hub's storage: each open intake settled or failed from the hub's mark at the snapshot, a
/// burn in flight paid from the hub's record, and holders paid their shares at the snapshot's units plus their claims,
/// within the speed limit, by signature or to their recovery address, once.
#[test]
fun the_snapshot_exit_reads_a_real_hub() {
    let mut t = exit();
    snapshot_now(&mut t);
    // The settled order joins the index; the open one fails, and its depositor takes its SUI back.
    resolve(&mut t, f::settled_intake_id(), f::settled_intake_proof());
    assert!(t.intake_state(f::settled_intake_id()) == 2);
    assert!(t.balance() == 10 * UNIT);
    resolve(&mut t, f::open_intake_id(), f::open_intake_proof());
    assert!(t.intake_state(f::open_intake_id()) == 3);
    let mut v = t.take(harness::bob());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), f::open_intake_id(), clock, ctx);
    harness::put(v);
    assert!(t.received(harness::bob()) == UNIT);

    // The burn in flight: one share's SUI, of which the speed limit lets 4% of 75 SUI out today.
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    let burn_to = sui::address::from_bytes(f::burn_recipient());
    let today = 10 * UNIT * 4 / 100;
    assert!(t.received(burn_to) == today, 0);
    assert!(t.owed_remaining(f::burn_id()) == UNIT - today);

    // Holder A: 4 shares, plus a claim of one share's SUI, to the recipient it signed for. Today's limit is spent.
    claim_a(&mut t, recipient_a(), 1, f::holder_a_signature());
    assert!(t.received(recipient_a()) == 0);
    let id_a = snapshot::claim_id(&f::hub_index(), &f::holder_a());
    assert!(t.owed_remaining(id_a) == 5 * UNIT, 1);
    // Holder B: 3 shares, to the recovery address it registered in the hub, with no signature.
    claim_b(&mut t, recipient_b());
    let id_b = snapshot::claim_id(&f::hub_index(), &f::holder_b());
    assert!(t.owed_remaining(id_b) == 3 * UNIT, 2);

    // A day on, the speed limit pays the next part: 4% of the 75 SUI less today's.
    t.warp(25 * 3600);
    t.release(id_a);
    let next = (10 * UNIT - today) * 4 / 100;
    assert!(t.received(recipient_a()) == next, 3);
    assert!(t.owed_remaining(id_a) == 5 * UNIT - next);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoSnapshot)]
fun no_resolution_before_the_snapshot() {
    let mut t = exit();
    resolve(&mut t, f::settled_intake_id(), f::settled_intake_proof());
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoSnapshot)]
fun no_recorded_delivery_before_the_snapshot() {
    let mut t = exit();
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoSnapshot)]
fun no_claim_before_the_snapshot() {
    let mut t = exit();
    claim_a(&mut t, recipient_a(), 1, f::holder_a_signature());
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeNotOpen)]
fun an_intake_resolves_once() {
    let mut t = settled();
    resolve(&mut t, f::settled_intake_id(), f::settled_intake_proof());
    t.end();
}

#[test, expected_failure(abort_code = vault::EAlreadyDelivered)]
fun a_recorded_burn_runs_once() {
    let mut t = settled();
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    t.end();
}

#[test, expected_failure(abort_code = vault::EAlreadyClaimed)]
fun a_holder_claims_once() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 1, f::holder_a_signature());
    claim_a(&mut t, recipient_a(), 1, f::holder_a_signature());
    t.end();
}

// ---------------------------------------------------------------------
// VLT-1
// ---------------------------------------------------------------------

/// VLT-1: a claim reads a component only inside the hub's components array, and only this chain's coin there. WETH, the
/// first component, is refused; so is the empty slot just past the array's end, and storage further past it that holds
/// SUI at a far larger unit count, as storage a holder could fill.
#[test, expected_failure(abort_code = snapshot::EWrongComponent)]
fun test_vlt1_another_component_is_refused() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 0, f::holder_a_signature());
    t.end();
}

#[test, expected_failure(abort_code = snapshot::EWrongComponent)]
fun test_vlt1_the_slot_past_the_end_is_refused() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 2, f::holder_a_signature());
    t.end();
}

#[test, expected_failure(abort_code = snapshot::EWrongComponent)]
fun test_vlt1_storage_past_the_end_is_refused() {
    let mut t = settled();
    // What lies there is SUI at a far larger unit count.
    let values = f::holder_a_past_the_end_values();
    assert!(bytes::slice(&values[1], 12, 20) == f::hub_sui_token());
    claim(&mut t, f::holder_a(), 7, recipient_a(), f::holder_a_signature(), f::holder_a_past_the_end_proof());
    t.end();
}

#[test]
fun test_vlt1_the_component_inside_the_array_is_paid() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 1, f::holder_a_signature());
    assert!(t.received(recipient_a()) == 10 * UNIT * 4 / 100);
    t.end();
}

// ---------------------------------------------------------------------
// Where a claim is paid
// ---------------------------------------------------------------------

/// The signature names its recipient: another one is not what the holder signed.
#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun a_signature_pays_only_its_recipient() {
    let mut t = settled();
    claim_a(&mut t, @0x77, 1, f::holder_a_signature());
    t.end();
}

#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun no_signature_is_refused() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 1, vector[]);
    t.end();
}

#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun a_short_signature_is_refused() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 1, bytes::slice(&f::holder_a_signature(), 0, 64));
    t.end();
}

fun with_v(v: u8): vector<u8> {
    let mut s = f::holder_a_signature();
    *&mut s[64] = v;
    s
}

#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun v_29_is_refused() {
    let mut t = settled();
    claim_a(&mut t, recipient_a(), 1, with_v(29));
    t.end();
}

/// v as the raw recovery id, 0 or 1, recovers the same key: OpenZeppelin takes only 27 and 28.
#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun a_raw_recovery_id_is_refused() {
    let mut t = settled();
    let v = f::holder_a_signature()[64];
    claim_a(&mut t, recipient_a(), 1, with_v(v - 27));
    t.end();
}

/// The same signature with s in the upper half and v flipped recovers the same key; OpenZeppelin refuses it.
#[test, expected_failure(abort_code = snapshot::EBadSignature)]
fun a_malleable_signature_is_refused() {
    let mut t = settled();
    let sig = f::holder_a_signature();
    let n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    let s = bytes::u256_at(&sig, 32);
    let mut out = bytes::slice(&sig, 0, 32);
    out.append(bytes::word(n - s));
    out.push_back(if (sig[64] == 27) 28 else 27);
    claim_a(&mut t, recipient_a(), 1, out);
    t.end();
}

/// The malleable signature does recover the holder: only the rule refuses it.
#[test]
fun the_malleable_signature_recovers_the_holder() {
    let sig = f::holder_a_signature();
    let n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    let s = bytes::u256_at(&sig, 32);
    let mut raw = bytes::slice(&sig, 0, 32);
    raw.append(bytes::word(n - s));
    raw.push_back(if (sig[64] == 27) 1 else 0);
    let message = snapshot::claim_message(&f::hub_vault(), harness::sui_testnet(), &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
    let key = sui::ecdsa_k1::decompress_pubkey(&sui::ecdsa_k1::secp256k1_ecrecover(&raw, &message, 0));
    assert!(bytes::slice(&keccak256(&bytes::slice(&key, 1, 64)), 12, 20) == f::holder_a());
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_claim_to_no_one_is_refused() {
    let mut t = settled();
    claim_a(&mut t, @0x0, 1, f::holder_a_signature());
    t.end();
}

/// SOL-9's twin for claims: a claim never pays the vault's own object, where the coin would be stranded.
#[test, expected_failure(abort_code = vault::EWrongRecipient)]
fun test_sol9_a_claim_never_pays_the_vault() {
    let mut t = settled();
    claim_a(&mut t, sui::address::from_bytes(f::hub_vault()), 1, f::holder_a_signature());
    t.end();
}

/// Holder B registered a recovery address: paid there and only there, signature or not.
#[test, expected_failure(abort_code = vault::EWrongRecipient)]
fun a_registered_holder_is_paid_only_there() {
    let mut t = settled();
    claim_b(&mut t, @0x77);
    t.end();
}

#[test]
fun a_registered_holder_needs_no_signature() {
    let mut t = settled();
    claim_b(&mut t, recipient_b());
    assert!(t.received(recipient_b()) == 10 * UNIT * 4 / 100);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_claim_on_no_index_is_refused() {
    let mut t = settled();
    let mut v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::claim_snapshot(&mut v, f::migrate_new_index(), f::holder_a(), 1, recipient_a(), f::holder_a_signature(), f::holder_a_claim1_proof(), clock, ctx);
    harness::put(v);
    t.end();
}

// ---------------------------------------------------------------------
// Recorded messages
// ---------------------------------------------------------------------

/// A burn or migration runs after the snapshot only on the index's own mark of it.
#[test, expected_failure(abort_code = vault::ENotRecorded)]
fun an_unsent_burn_is_not_recorded() {
    let mut t = settled();
    recorded(&mut t, f::unsent_burn_payload(), f::unsent_burn_proof());
    t.end();
}

/// A message of another kind resolves another way: refused before anything is read.
#[test, expected_failure(abort_code = vault::EUnknownKind)]
fun only_burns_and_migrations_are_recorded() {
    let mut t = settled();
    let mut settle = f::burn_payload();
    *&mut settle[2 * 32 + 31] = 2;
    recorded(&mut t, settle, f::unsent_burn_proof());
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_recorded_migration_needs_its_target_registered() {
    let mut t = settled();
    recorded(&mut t, f::migrate_payload(), f::migrate_proof());
    t.end();
}

/// A real migration into the index's second version, which its creator seeded with its last share, is paid into that
/// version's balance within the speed limit; then the burn, today's limit spent, is owed in full.
#[test]
fun a_recorded_migration_moves_coins_within_the_limit() {
    let mut t = settled();
    let mut v = t.take(harness::relayer());
    vault::register_index(&mut v, f::migrate_new_index(), f::migrate_new_salt());
    harness::put(v);
    recorded(&mut t, f::migrate_payload(), f::migrate_proof());
    let today = 10 * UNIT * 4 / 100;
    let (_, balance, _, _, _) = t.index_state(f::migrate_new_index());
    assert!(balance == today);
    assert!(t.owed_remaining(f::migrate_id()) == UNIT - today);
    assert!(t.held() == 10 * UNIT + UNIT);
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    assert!(t.owed_remaining(f::burn_id()) == UNIT);
    t.end();
}

/// A message delivered before the snapshot is not run again from the hub's record.
#[test, expected_failure(abort_code = vault::EAlreadyDelivered)]
fun a_delivered_burn_is_not_recorded_again() {
    let mut t = exit();
    let burn = f::burn_payload();
    let index = f::hub_index();
    // Delivered on both proofs before the snapshot, from a block the checkpoint covers.
    let proof = t.proof_for(&index, &burn, f::hub_block());
    // The settled intake joins first, so the burn has a balance to pay from.
    let settle = harness::message(harness::sepolia(), 2, &index, &f::settled_intake_id(), 1, harness::sui_testnet(), &f::hub_vault());
    let settle_proof = t.proof_for(&index, &settle, f::hub_block() - 1);
    t.deliver_raw(settle, f::hub_block() - 1, settle_proof, settle_proof);
    t.deliver_raw(burn, f::hub_block(), proof, proof);
    snapshot_now(&mut t);
    recorded(&mut t, f::burn_payload(), f::burn_proof());
    t.end();
}

// ---------------------------------------------------------------------
// The state proofs
// ---------------------------------------------------------------------

/// Every node is checked against the snapshot's root: a proof tampered with, cut short or followed by anything does not
/// prove the hub's storage.
#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_tampered_proof_is_refused() {
    let mut t = exit();
    snapshot_now(&mut t);
    let mut proof = f::settled_intake_proof();
    let middle = proof.length() / 2;
    let b = proof[middle];
    *&mut proof[middle] = b ^ 1;
    resolve(&mut t, f::settled_intake_id(), proof);
    t.end();
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_short_proof_is_refused() {
    let mut t = exit();
    snapshot_now(&mut t);
    let mut proof = f::settled_intake_proof();
    proof.pop_back();
    resolve(&mut t, f::settled_intake_id(), proof);
    t.end();
}

#[test, expected_failure(abort_code = state_reader::EBadStateProof)]
fun a_proof_with_bytes_after_it_is_refused() {
    let mut t = exit();
    snapshot_now(&mut t);
    let mut proof = f::settled_intake_proof();
    proof.push_back(0);
    resolve(&mut t, f::settled_intake_id(), proof);
    t.end();
}

/// A proof under another root: the open intake's, which is a real proof of another slot, read for the settled one.
#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_proof_of_another_slot_is_refused() {
    let mut t = exit();
    snapshot_now(&mut t);
    resolve(&mut t, f::settled_intake_id(), f::open_intake_proof());
    t.end();
}

/// An account the state does not hold has no storage: every slot reads zero.
#[test]
fun an_absent_account_reads_zero() {
    let values = state_reader::read_slots(&f::hub_state_root(), &f::absent_account(), &vector[bytes::zero32()], &f::absent_account_proof());
    assert!(values == vector[bytes::zero32()]);
}

/// What the vault computes of Ethereum's encodings, against what Solidity's encoder and `cast` computed for the same
/// hub: every slot a claim, a resolution and a recorded delivery read, the values the proofs show, and the EIP-712
/// digest a holder signs, whose signature recovers to the holder.
#[test]
fun the_reads_and_the_digest_are_soliditys() {
    assert!(f::hub_chain_id() == harness::sui_testnet());
    assert!(snapshot::claim_slots(&f::holder_a(), 0, harness::sui_testnet()) == f::holder_a_claim0_slots());
    assert!(snapshot::claim_slots(&f::holder_a(), 1, harness::sui_testnet()) == f::holder_a_claim1_slots());
    assert!(snapshot::claim_slots(&f::holder_a(), 2, harness::sui_testnet()) == f::holder_a_claim2_slots());
    assert!(snapshot::claim_slots(&f::holder_b(), 1, harness::sui_testnet()) == f::holder_b_claim1_slots());
    assert!(snapshot::settled_slot(&f::settled_intake_id()) == f::settled_intake_slot());
    assert!(snapshot::settled_slot(&f::open_intake_id()) == f::open_intake_slot());
    assert!(snapshot::sent_slot(&f::burn_id()) == f::burn_slot());
    assert!(snapshot::sent_slot(&f::migrate_id()) == f::migrate_slot());
    assert!(snapshot::sent_slot(&f::unsent_burn_id()) == f::unsent_burn_slot());
    // The values each proof shows under the root.
    let root = f::hub_state_root();
    let index = f::hub_index();
    assert!(state_reader::read_slots(&root, &index, &f::holder_a_claim1_slots(), &f::holder_a_claim1_proof()) == f::holder_a_claim1_values());
    assert!(state_reader::read_slots(&root, &index, &f::holder_b_claim1_slots(), &f::holder_b_claim1_proof()) == f::holder_b_claim1_values());
    assert!(state_reader::read_slots(&root, &index, &vector[f::settled_intake_slot()], &f::settled_intake_proof()) == vector[f::settled_intake_mark()]);
    assert!(state_reader::read_slots(&root, &index, &vector[f::open_intake_slot()], &f::open_intake_proof()) == vector[bytes::zero32()]);
    assert!(state_reader::read_slots(&root, &index, &vector[f::unsent_burn_slot()], &f::unsent_burn_proof()) == vector[bytes::zero32()]);
    let message = snapshot::claim_message(&f::hub_vault(), harness::sui_testnet(), &index, &f::holder_a(), &f::holder_a_recipient());
    assert!(keccak256(&message) == f::holder_a_digest());
    snapshot::check_signature(&message, &f::holder_a_signature(), &f::holder_a());
    // The shares, as the hub holds them: four at 7.5 SUI, plus a claim of 7.5; three to a recovery address.
    let (amount, registered) = snapshot::share(&f::holder_a_claim1_values(), 1, harness::sui_testnet());
    assert!(amount == 5 * UNIT && registered.is_none());
    let (amount, registered) = snapshot::share(&f::holder_b_claim1_values(), 1, harness::sui_testnet());
    assert!(amount == 3 * UNIT && registered.destroy_some() == f::holder_b_recipient());
    assert!(ONE == UNIT * 2 / 15);
}

#[test, expected_failure(abort_code = snapshot::EOverflow)]
fun a_share_past_64_bits_is_refused() {
    let mut values = f::holder_a_claim1_values();
    *&mut values[2] = bytes::word(0xffffffffffffffff);
    snapshot::share(&values, 1, harness::sui_testnet());
}

#[test, expected_failure(abort_code = snapshot::EOverflow)]
fun shares_past_128_bits_are_refused() {
    let mut values = f::holder_a_claim1_values();
    *&mut values[0] = bytes::word(1 << 128);
    snapshot::share(&values, 1, harness::sui_testnet());
}

#[test, expected_failure(abort_code = snapshot::EZeroAmount)]
fun a_holder_of_nothing_is_refused() {
    let values = f::holder_a_claim1_values();
    let mut empty = values;
    *&mut empty[0] = bytes::zero32();
    *&mut empty[2] = bytes::zero32();
    snapshot::share(&empty, 1, harness::sui_testnet());
}

#[test, expected_failure(abort_code = snapshot::EBadStateProof)]
fun a_share_reads_five_values() {
    let mut values = f::holder_a_claim1_values();
    values.pop_back();
    snapshot::share(&values, 1, harness::sui_testnet());
}
