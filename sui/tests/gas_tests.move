/// Pairs of tests whose difference in `sui move test --statistics` is one call: each `gas_*` test does what its
/// `*_baseline` does, then the call. The README's gas table is the difference. Sui prices instructions in tiers by how
/// many a transaction has run, and a test is one transaction, so every setup here is kept cheap: the proofs are
/// precomputed (`fixtures::gas_*`, written by `vectors.py` and checked against the harness's own builder below).
#[test_only]
module xindex_vault::gas_tests;

use xindex_vault::fixtures as f;
use xindex_vault::harness::{Self, T};
use xindex_vault::light_client;
use xindex_vault::proofs;
use xindex_vault::vault;

const ONE: u64 = 1_000_000_000;

/// `harness::new`'s vault, its first checkpoint landed without proofs: a deposit needs one (B1-04), and Sui prices a
/// test's instructions in tiers, so proving it would raise what every call after it measures.
fun fresh(): T {
    let mut t = harness::created();
    let now = t.now() + 1;
    t.set_now(now);
    let mut v = t.take(harness::relayer());
    vault::checkpoint_for_testing(&mut v, 1, now, sui::hash::keccak256(&b"first"));
    harness::put(v);
    t
}

fun take_all(t: &mut T) {
    let v = t.take(harness::relayer());
    let (c1, c2) = (t.client(vault::p1(&v)), t.client(vault::p2(&v)));
    harness::put_client(c1);
    harness::put_client(c2);
    harness::put(v);
}

/// The precomputed proofs are what the harness builds.
#[test]
fun the_precomputed_proofs_are_the_harnesss() {
    let start = f::settled_intake_deadline() - 600;
    let (proof, root) = harness::event_proof(&f::hub_index(), &f::gas_settle(), 1_001, start);
    assert!(proof == f::gas_settle_proof() && root == f::gas_settle_root());
    let (proof, root) = harness::event_proof(&f::hub_index(), &f::gas_burn(), 1_002, start);
    assert!(proof == f::gas_burn_proof() && root == f::gas_burn_root());
}

#[test]
fun gas_deposit_baseline() {
    let mut t = fresh();
    let v = t.take(harness::alice());
    let coin = sui::coin::mint_for_testing<sui::sui::SUI>(ONE, t.ctx());
    sui::coin::burn_for_testing(coin);
    harness::put(v);
    t.end();
}

#[test]
fun gas_deposit() {
    let mut t = fresh();
    t.deposit(harness::alice(), f::gas_intake(), ONE);
    t.end();
}

/// The vault with 4 SUI in the gas intake, its settle's block recorded by both clients and checkpointed.
fun settle_setup(amount: u64): T {
    let mut t = fresh();
    t.deposit(harness::alice(), f::gas_intake(), amount);
    let (p1, p2) = t.pair();
    t.record_for(p1, f::gas_settle_root(), 1_001);
    t.record_for(p2, f::gas_settle_root(), 1_001);
    t.advance(1_100);
    t
}

#[test]
fun gas_deliver_settle_baseline() {
    let mut t = settle_setup(4 * ONE);
    take_all(&mut t);
    t.end();
}

#[test]
fun gas_deliver_settle() {
    let mut t = settle_setup(4 * ONE);
    t.deliver_raw(f::gas_settle(), 1_001, f::gas_settle_proof(), f::gas_settle_proof());
    assert!(t.balance() == 4 * ONE);
    t.end();
}

/// The index funded with 1,000 SUI, credited directly so the setup stays cheap, and the burn's block recorded.
fun burn_setup(): T {
    let mut t = fresh();
    let mut v = t.take(harness::relayer());
    let coin = sui::coin::mint_for_testing<sui::sui::SUI>(1_000 * ONE, t.ctx());
    vault::credit_for_testing(&mut v, f::hub_index(), coin);
    harness::put(v);
    let (p1, p2) = t.pair();
    t.record_for(p1, f::gas_burn_root(), 1_002);
    t.record_for(p2, f::gas_burn_root(), 1_002);
    t.advance(1_100);
    t
}

#[test]
fun gas_deliver_burn_baseline() {
    let mut t = burn_setup();
    take_all(&mut t);
    t.end();
}

/// A burn of 100 SUI, of which 40 are paid as a coin at once and 60 owed.
#[test]
fun gas_deliver_burn() {
    let mut t = burn_setup();
    t.deliver_raw(f::gas_burn(), 1_002, f::gas_burn_proof(), f::gas_burn_proof());
    assert!(t.received(@0xbeef) == 40 * ONE);
    t.end();
}

fun attest_setup(): T {
    let mut t = fresh();
    t.deposit(harness::alice(), f::attest_intake_id(), 3 * ONE);
    t.set_ms(f::attest_timestamp_ms());
    t
}

#[test]
fun gas_attest_baseline() {
    let mut t = attest_setup();
    let v = t.take(harness::relayer());
    let (_, _) = (f::attest_slots(), f::attest_values());
    harness::put(v);
    t.end();
}

#[test]
fun gas_attest_three_slots() {
    let mut t = attest_setup();
    let v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::attest(&v, f::attest_slots(), f::attest_values(), clock, ctx);
    harness::put(v);
    t.end();
}

#[test]
fun gas_check_baseline() {
    let (_, _, _) = (f::sp1_program_key(), f::sp1_public_values(), f::sp1_proof());
}

/// P1's proof check, the SP1 Groth16 proof as SP1 hands it to an EVM verifier.
#[test]
fun gas_sp1_check() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &f::sp1_proof());
}

/// P2's proof check, RISC Zero's seal and journal.
#[test]
fun gas_risc0_check() {
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &f::risc0_seal());
}

fun step_values(): vector<u8> {
    let mut values = vector::tabulate!(32, |_| 0xfeu8);
    values.append(vector::tabulate!(32, |_| 0xbbu8));
    values.append(xindex_vault::bytes::word64(2));
    values.append(vector::tabulate!(32, |_| 0x77u8));
    values.append(xindex_vault::bytes::word64(100));
    values.append(xindex_vault::bytes::word64(163));
    values
}

#[test]
fun gas_update_step_baseline() {
    let mut ctx = tx_context::dummy();
    let lc = harness::light_client(light_client::sp1(), 1, 1, &mut ctx);
    let _ = step_values();
    lc.destroy_for_testing();
}

/// The rest of `update` after the proof check: the anchor's step and the recorded range.
#[test]
fun gas_update_step() {
    let mut ctx = tx_context::dummy();
    let mut lc = harness::light_client(light_client::sp1(), 1, 1, &mut ctx);
    light_client::advance_for_testing(&mut lc, step_values());
    lc.destroy_for_testing();
}
