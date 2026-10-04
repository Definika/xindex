/// The factory's governance messages: a freeze and a lower cap on one proof, VLT-2's delay on everything that loosens a
/// rule, VLT-4's nonce marks, and rotations to new light clients. The NEAR twin's `governance` tests.
#[test_only]
module xindex_vault::governance_tests;

use sui::hash::keccak256;
use xindex_vault::abi;
use xindex_vault::bytes;
use xindex_vault::harness::{Self, T};
use xindex_vault::vault;

const ONE: u64 = 1_000_000_000;
const CAP_UPDATE: u8 = 5;
const FREEZE: u8 = 6;
const FREEZER_CHANGE: u8 = 7;
const VERIFIER_ROTATION: u8 = 8;
const GOVERNANCE_DELAY: u64 = 7 * 86_400;
const FREEZE_DURATION: u64 = 14 * 86_400;

fun cap_of(t: &mut T): (u64, u64) {
    let v = t.take(harness::relayer());
    let (cap, floor) = (vault::cap(&v), vault::outflow_floor(&v));
    harness::put(v);
    (cap, floor)
}

fun frozen_until(t: &mut T): u64 {
    let v = t.take(harness::relayer());
    let until = vault::frozen_until(&v);
    harness::put(v);
    until
}

fun apply(t: &mut T, kind: u8, body: vector<u8>) {
    let mut v = t.take(harness::relayer());
    vault::apply_change(&mut v, kind, body, t.clock());
    harness::put(v);
}

fun cancel(t: &mut T, who: address, kind: u8) {
    let mut v = t.take(who);
    vault::cancel_change(&mut v, kind, t.ctx());
    harness::put(v);
}

fun freeze_by(t: &mut T, who: address) {
    let mut v = t.take(who);
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
}

/// A freeze, and a cap update that raises neither figure, apply at once on either proof alone; a freeze extends and
/// never shortens.
#[test]
fun a_freeze_and_a_lower_cap_need_one_proof() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(500 * ONE, ONE / 2), 1, false, true);
    let (cap, floor) = cap_of(&mut t);
    assert!(cap == 500 * ONE && floor == ONE / 2);
    t.govern(FREEZE, vector[], 2, true, false);
    assert!(frozen_until(&mut t) == t.now() + FREEZE_DURATION);
    t.warp(100);
    freeze_by(&mut t, harness::freezer());
    assert!(frozen_until(&mut t) == t.now() + FREEZE_DURATION);
    // A factory freeze of an earlier time leaves the later one.
    t.govern(FREEZE, vector[], 3, true, true);
    assert!(frozen_until(&mut t) == t.now() + FREEZE_DURATION);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotFreezer)]
fun only_the_freezer_freezes() {
    let mut t = harness::new();
    freeze_by(&mut t, harness::alice());
    t.end();
}

#[test, expected_failure(abort_code = vault::EBadMessage)]
fun a_freeze_has_no_body() {
    let mut t = harness::new();
    t.govern(FREEZE, bytes::zero32(), 1, true, true);
    t.end();
}

/// Raising only the floor loosens a rule as well.
#[test, expected_failure(abort_code = vault::EBothProofsRequired)]
fun a_raised_floor_needs_both_proofs() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(ONE, 2 * ONE), 1, true, false);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotNative)]
fun a_cap_update_names_the_native_coin() {
    let mut t = harness::new();
    let mut body = harness::cap_body(ONE, ONE);
    *&mut body[31] = 1;
    t.govern(CAP_UPDATE, body, 1, true, true);
    t.end();
}

#[test, expected_failure(abort_code = abi::EOverflow)]
fun a_cap_past_64_bits_is_refused() {
    let mut t = harness::new();
    let mut body = bytes::zero32();
    body.append(bytes::word(1 << 64));
    body.append(bytes::word64(1));
    t.govern(CAP_UPDATE, body, 1, true, true);
    t.end();
}

/// VLT-2: a raised cap needs both proofs, then waits GOVERNANCE_DELAY on the vault before anyone applies it, once.
#[test]
fun test_vlt2_a_raise_waits_then_applies_once() {
    let mut t = harness::new();
    let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    let (cap, _) = cap_of(&mut t);
    assert!(cap == 1_000_000 * ONE);
    let v = t.take(harness::relayer());
    let (hash, ready_at) = vault::pending(&v, CAP_UPDATE);
    assert!(hash == keccak256(&raise) && ready_at == t.now() + GOVERNANCE_DELAY);
    harness::put(v);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, raise);
    let (cap, floor) = cap_of(&mut t);
    assert!(cap == 2_000_000 * ONE && floor == 2 * ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::EBothProofsRequired)]
fun test_vlt2_a_raise_on_one_proof_is_refused() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(2_000_000 * ONE, 2 * ONE), 1, true, false);
    t.end();
}

#[test, expected_failure(abort_code = vault::EChangeNotReady)]
fun test_vlt2_a_raise_is_not_ready_before_the_delay() {
    let mut t = harness::new();
    let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    t.warp(GOVERNANCE_DELAY - 1);
    apply(&mut t, CAP_UPDATE, raise);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun test_vlt2_only_the_waiting_body_applies() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(2_000_000 * ONE, 2 * ONE), 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, harness::cap_body(1, 1));
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun test_vlt2_a_change_applies_once() {
    let mut t = harness::new();
    let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, raise);
    apply(&mut t, CAP_UPDATE, raise);
    t.end();
}

/// The freezer may drop a waiting raise.
#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun test_vlt2_the_freezer_drops_a_raise() {
    let mut t = harness::new();
    let raise = harness::cap_body(3_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    cancel(&mut t, harness::freezer(), CAP_UPDATE);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, raise);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotFreezer)]
fun test_vlt2_only_the_freezer_drops_a_change() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(3_000_000 * ONE, 2 * ONE), 1, true, true);
    cancel(&mut t, harness::alice(), CAP_UPDATE);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun nothing_waiting_cannot_be_dropped() {
    let mut t = harness::new();
    cancel(&mut t, harness::freezer(), CAP_UPDATE);
    t.end();
}

/// A newer lower cap replaces a waiting raise: the raise can no longer apply.
#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun a_lower_cap_replaces_a_waiting_raise() {
    let mut t = harness::new();
    let raise = harness::cap_body(3_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    t.govern(CAP_UPDATE, harness::cap_body(10 * ONE, ONE), 2, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, raise);
    t.end();
}

/// VLT-2: the freezer cannot drop its own replacement, nor hold it off with a freeze; once applied, the old key no
/// longer freezes and the new one does.
#[test]
fun test_vlt2_the_freezer_cannot_block_its_replacement() {
    let mut t = harness::new();
    let new_key = @0x4b4b;
    let body = sui::address::to_bytes(new_key);
    t.govern(FREEZER_CHANGE, body, 1, true, true);
    freeze_by(&mut t, harness::freezer());
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, FREEZER_CHANGE, body);
    let v = t.take(harness::relayer());
    assert!(vault::freezer(&v) == new_key);
    harness::put(v);
    freeze_by(&mut t, new_key);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotFreezer)]
fun test_vlt2_the_freezer_cannot_drop_its_replacement() {
    let mut t = harness::new();
    t.govern(FREEZER_CHANGE, sui::address::to_bytes(@0x4b4b), 1, true, true);
    cancel(&mut t, harness::freezer(), FREEZER_CHANGE);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotFreezer)]
fun test_vlt2_the_old_freezer_no_longer_freezes() {
    let mut t = harness::new();
    let body = sui::address::to_bytes(@0x4b4b);
    t.govern(FREEZER_CHANGE, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, FREEZER_CHANGE, body);
    freeze_by(&mut t, harness::freezer());
    t.end();
}

/// While frozen, a raise waits even once ready.
#[test, expected_failure(abort_code = vault::EVaultFrozen)]
fun test_vlt2_a_freeze_holds_a_ready_raise() {
    let mut t = harness::new();
    let raise = harness::cap_body(4_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, raise, 1, true, true);
    freeze_by(&mut t, harness::freezer());
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, CAP_UPDATE, raise);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_freezer_of_zero_is_refused() {
    let mut t = harness::new();
    let body = bytes::zero32();
    t.govern(FREEZER_CHANGE, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, FREEZER_CHANGE, body);
    t.end();
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_freezer_change_carries_one_word() {
    let mut t = harness::new();
    t.govern(FREEZER_CHANGE, vector[1, 2, 3], 1, true, true);
    t.end();
}

// ---------------------------------------------------------------------
// VLT-4
// ---------------------------------------------------------------------

fun nonces(t: &mut T): vector<u64> {
    let v = t.take(harness::relayer());
    let n = vault::nonces(&v);
    harness::put(v);
    n
}

/// VLT-4: a forged lower cap at a huge nonce, on one proof, applies (it only protects) but moves no mark, so the
/// factory's honest change at its next nonce still runs and moves it.
#[test]
fun test_vlt4_one_proof_moves_no_mark() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(10 * ONE, ONE), 1_000_000, true, false);
    assert!(nonces(&mut t) == vector[0, 0, 0]);
    let (cap, _) = cap_of(&mut t);
    assert!(cap == 10 * ONE);
    t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 5, true, true);
    assert!(nonces(&mut t) == vector[5, 0, 0]);
    t.govern(FREEZER_CHANGE, sui::address::to_bytes(@0x4b4b), 9, true, true);
    assert!(nonces(&mut t) == vector[5, 9, 0]);
    t.end();
}

/// An older message of the kind, delivered last, is refused: it cannot undo a newer one.
#[test, expected_failure(abort_code = vault::EStaleGovernance)]
fun test_vlt4_an_older_message_is_stale() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(20 * ONE, ONE), 5, true, true);
    t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 4, true, true);
    t.end();
}

/// SOL-3's twin: an older freezer change, delivered after a newer one, cannot undo it.
#[test, expected_failure(abort_code = vault::EStaleGovernance)]
fun test_sol3_an_older_freezer_change_cannot_undo_a_newer_one() {
    let mut t = harness::new();
    t.govern(FREEZER_CHANGE, sui::address::to_bytes(@0x4b4b), 5, true, true);
    t.govern(FREEZER_CHANGE, sui::address::to_bytes(@0x5c5c), 4, true, true);
    t.end();
}

#[test, expected_failure(abort_code = vault::EStaleGovernance)]
fun test_vlt4_the_same_nonce_is_stale() {
    let mut t = harness::new();
    t.govern(CAP_UPDATE, harness::cap_body(20 * ONE, ONE), 5, true, true);
    t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 5, true, true);
    t.end();
}

// ---------------------------------------------------------------------
// Rotations
// ---------------------------------------------------------------------

fun rotate(t: &mut T, body: vector<u8>, a: ID, b: ID) {
    let mut v = t.take(harness::relayer());
    let (c1, c2) = (t.client(a), t.client(b));
    vault::apply_rotation(&mut v, body, &c1, &c2, t.clock());
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
}

/// A rotation names two light clients, one SP1 and one RISC Zero, which become P1 and P2 once it applies, and through
/// which every later message is proven.
#[test]
fun a_rotation_installs_two_light_clients() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, a, b);
    let (p1, p2) = t.pair();
    assert!(p1 == a && p2 == b);
    // The new pair proves what follows.
    t.fund(10 * ONE);
    assert!(t.balance() == 10 * ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVerifiersRequired)]
fun a_rotation_is_applied_with_its_clients() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    apply(&mut t, VERIFIER_ROTATION, body);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun a_rotation_takes_only_the_clients_it_names() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let (c, _) = t.new_pair(21);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, c, b);
    t.end();
}

/// Two clients of one proof system are no pair.
#[test, expected_failure(abort_code = vault::EVerifiersNotDistinct)]
fun a_rotation_to_one_system_is_refused() {
    let mut t = harness::new();
    let (a, _) = t.new_pair(11);
    let (c, _) = t.new_pair(21);
    let body = harness::pair_body(a, c);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, a, c);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVerifiersNotDistinct)]
fun a_rotation_to_one_client_twice_is_refused() {
    let mut t = harness::new();
    let (a, _) = t.new_pair(11);
    let body = harness::pair_body(a, a);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    // A transaction may pass one shared object twice by reference.
    let mut v = t.take(harness::relayer());
    let c = t.client(a);
    vault::apply_rotation(&mut v, body, &c, &c, t.clock());
    harness::put_client(c);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EChangeNotReady)]
fun a_rotation_waits_the_delay() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY - 1);
    rotate(&mut t, body, a, b);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENoPendingChange)]
fun the_freezer_drops_a_rotation() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    cancel(&mut t, harness::freezer(), VERIFIER_ROTATION);
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, a, b);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVaultFrozen)]
fun a_freeze_holds_a_rotation() {
    let mut t = harness::new();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    freeze_by(&mut t, harness::freezer());
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, a, b);
    t.end();
}

/// After a rotation, the old pair proves nothing to the vault.
#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun the_old_pair_is_retired() {
    let mut t = harness::new();
    let (old1, old2) = t.pair();
    let (a, b) = t.new_pair(11);
    let body = harness::pair_body(a, b);
    t.govern(VERIFIER_ROTATION, body, 1, true, true);
    t.warp(GOVERNANCE_DELAY);
    rotate(&mut t, body, a, b);
    let intake = harness::intake_id(t.now() + 3600, 1);
    let index = t.index();
    let settle = t.payload(2, &index, &intake);
    let block = t.next_block();
    let proof = t.proof_for(&index, &settle, block);
    let mut v = t.take(harness::relayer());
    let (c1, c2) = (t.client(old1), t.client(old2));
    let (clock, ctx) = t.parts();
    vault::deliver(&mut v, &c1, &c2, settle, block, proof, proof, clock, ctx);
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
    t.end();
}
