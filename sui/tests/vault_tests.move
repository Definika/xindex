/// Creation, registration, deposits, refunds, the stall and `attest`: the NEAR twin's `setup` tests, and the EVM vault's
/// `XindexVault.t.sol` rules of the same names.
#[test_only]
module xindex_vault::vault_tests;

use sui::bcs;
use sui::test_scenario as ts;
use xindex_vault::abi;
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::harness::{Self, T};
use xindex_vault::light_client;
use xindex_vault::vault::{Self, Attestation};

const ONE: u64 = 1_000_000_000;

// ---------------------------------------------------------------------
// Creation: `DeployVault`'s refusals, where Move can see them
// ---------------------------------------------------------------------

fun bare(): T {
    harness::bare(f::settled_intake_deadline() - 600)
}

fun create(t: &mut T, source: u64, chain: u64, freezer: address, recovery: address, cap: u64, floor: u64): ID {
    let (p1, p2) = (t.p1_id(), t.p2_id());
    t.create_with(harness::creator(), source, chain, f::hub_factory(), p1, p2, freezer, recovery, cap, floor)
}

#[test]
fun a_vault_is_created_with_its_settings() {
    let mut t = harness::new();
    let v = t.take(harness::relayer());
    assert!(vault::source_chain_id(&v) == harness::sepolia() && vault::chain_id(&v) == harness::sui_testnet());
    assert!(vault::factory(&v) == f::hub_factory() && vault::hub_implementation(&v) == f::hub_implementation());
    assert!(vault::p1(&v) == t.p1_id() && vault::p2(&v) == t.p2_id());
    assert!(vault::freezer(&v) == harness::freezer() && vault::recovery_proposer(&v) == harness::recovery());
    assert!(vault::cap(&v) == 1_000_000 * ONE && vault::outflow_floor(&v) == ONE && vault::held(&v) == 0);
    let (block, timestamp, root) = vault::checkpoint(&v);
    // Its first week's grace: the checkpoint is dated at creation, with no state.
    assert!(block == 0 && timestamp == t.now() && bytes::is_zero(&root));
    assert!(vault::vault_id(&v) == object::id(&v).to_bytes());
    assert!(vault::vault_id(&v) == f::hub_vault(), 0);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EUnknownSource)]
fun an_unknown_source_is_refused() {
    let mut t = bare();
    create(&mut t, 5, harness::sui_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongChain)]
fun sepolias_vault_is_sui_testnets() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), 13_762_264_207_064_992_463, harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongChain)]
fun ethereums_vault_is_sui_mainnets() {
    let mut t = bare();
    create(&mut t, 1, harness::sui_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_missing_factory_is_refused() {
    let mut t = bare();
    let (p1, p2) = (t.p1_id(), t.p2_id());
    t.create_with(harness::creator(), harness::sepolia(), harness::sui_testnet(), vector::tabulate!(20, |_| 0u8), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EBadLength)]
fun a_factory_of_another_length_is_refused() {
    let mut t = bare();
    let (p1, p2) = (t.p1_id(), t.p2_id());
    t.create_with(harness::creator(), harness::sepolia(), harness::sui_testnet(), bytes::zero32(), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun p1_must_be_sp1_and_p2_risc_zero() {
    let mut t = bare();
    let (p1, p2) = (t.p1_id(), t.p2_id());
    t.create_with(harness::creator(), harness::sepolia(), harness::sui_testnet(), f::hub_factory(), p2, p1, harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EWrongVerifier)]
fun the_clients_must_follow_the_source_chain() {
    let mut t = bare();
    let p1 = t.client_with(light_client::sp1(), 1_606_824_023);
    let p2 = t.p2_id();
    t.create_with(harness::creator(), harness::sepolia(), harness::sui_testnet(), f::hub_factory(), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EAnchorTooOld)]
fun clients_past_their_lag_are_refused() {
    let mut t = bare();
    t.warp(2 * 86_400);
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_missing_freezer_is_refused() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), @0x0, harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAddress)]
fun a_missing_recovery_proposer_is_refused() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::freezer(), @0x0, 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::ESameRole)]
fun the_freezer_is_not_the_recovery_proposer() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::freezer(), harness::freezer(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::ERoleIsCreator)]
fun the_freezer_is_not_the_creating_key() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::creator(), harness::recovery(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::ERoleIsCreator)]
fun the_recovery_proposer_is_not_the_creating_key() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::freezer(), harness::creator(), 10, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EFloorAboveCap)]
fun a_floor_above_the_cap_is_refused() {
    let mut t = bare();
    create(&mut t, harness::sepolia(), harness::sui_testnet(), harness::freezer(), harness::recovery(), 10, 11);
    t.end();
}

// ---------------------------------------------------------------------
// Indexes
// ---------------------------------------------------------------------

/// An index registers by the factory's CREATE2 formula, once, and its digest is written where the hub reads it.
#[test]
fun an_index_registers_by_create2() {
    let mut t = harness::new();
    let mut v = t.take(harness::relayer());
    assert!(vault::is_index(&v, f::hub_index()));
    let slot = vault::index_slot(&f::hub_index());
    assert!(vault::slot(&v, slot) == f::enc_index_digest_empty());
    // Again: nothing changes.
    vault::register_index(&mut v, f::hub_index(), f::hub_salt());
    // The second version of the index, the migration's target.
    vault::register_index(&mut v, f::migrate_new_index(), f::migrate_new_salt());
    assert!(vault::is_index(&v, f::migrate_new_index()));
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun another_salt_is_no_index() {
    let mut t = harness::new();
    let mut v = t.take(harness::relayer());
    vault::register_index(&mut v, f::hub_index(), f::migrate_new_salt());
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EBadLength)]
fun an_index_of_another_length_is_refused() {
    let mut t = harness::new();
    let mut v = t.take(harness::relayer());
    vault::register_index(&mut v, bytes::zero32(), f::hub_salt());
    harness::put(v);
    t.end();
}

// ---------------------------------------------------------------------
// Deposits
// ---------------------------------------------------------------------

/// A deposit opens its intake, is booked to its depositor and counted in `held`, and the intake's digest is written
/// where the hub reads it, as Solidity encodes it.
#[test]
fun a_deposit_opens_its_intake() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    t.deposit(harness::bob(), intake, ONE);
    t.deposit(harness::alice(), intake, 2 * ONE);
    let v = t.take(harness::relayer());
    let (state, total, digest) = vault::intake(&v, f::hub_index(), intake);
    assert!(state == 1 && total == 6 * ONE);
    assert!(vault::deposited(&v, f::hub_index(), intake, harness::alice()) == 5 * ONE);
    assert!(vault::deposited(&v, f::hub_index(), intake, harness::bob()) == ONE);
    assert!(vault::held(&v) == 6 * ONE && vault::coins(&v) == 6 * ONE);
    let expected = abi::intake_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 1, true, 6 * ONE);
    assert!(digest == expected);
    assert!(vault::slot(&v, vault::intake_slot(&f::hub_index(), &intake)) == expected);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAnIndex)]
fun a_deposit_to_no_index_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    let mut v = t.take(harness::alice());
    let coin = sui::coin::mint_for_testing<sui::sui::SUI>(ONE, t.ctx());
    let (clock, ctx) = t.parts();
    vault::deposit(&mut v, f::migrate_new_index(), intake, coin, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EZeroAmount)]
fun an_empty_deposit_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 0);
    t.end();
}

#[test, expected_failure(abort_code = vault::EBadLength)]
fun an_intake_id_of_another_length_is_refused() {
    let mut t = harness::new();
    t.deposit(harness::alice(), vector[1, 2, 3], ONE);
    t.end();
}

/// Deposits close at the deadline in the id, for everyone.
#[test]
fun a_deposit_at_the_deadline_is_taken() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.warp(3600);
    t.deposit(harness::alice(), intake, ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeClosed)]
fun a_deposit_past_the_deadline_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, ONE);
    t.warp(3601);
    t.deposit(harness::bob(), intake, ONE);
    t.end();
}

/// A first deposit may set a deadline at most MAX_INTAKE_LIFE ahead.
#[test]
fun a_deadline_a_week_ahead_is_taken() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 7 * 86_400, 1);
    t.deposit(harness::alice(), intake, ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeTooLong)]
fun a_deadline_past_a_week_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 7 * 86_400 + 1, 1);
    t.deposit(harness::alice(), intake, ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::ECapExceeded)]
fun a_deposit_past_the_cap_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 1_000_000 * ONE);
    t.deposit(harness::alice(), intake, 1);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeClosed)]
fun a_deposit_to_a_settled_intake_is_refused() {
    let mut t = harness::new();
    let intake = t.fund(ONE);
    t.deposit(harness::bob(), intake, ONE);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVaultFrozen)]
fun a_deposit_while_frozen_is_refused() {
    let mut t = harness::new();
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, ONE);
    t.end();
}

/// A week without a checkpoint stalls the vault, which then takes no deposit: it may never again see the message that
/// would settle or fail an intake.
#[test]
fun test_stall_a_week_without_a_checkpoint() {
    let mut t = harness::new();
    t.warp(7 * 86_400);
    assert!(!t.stalled());
    t.warp(1);
    assert!(t.stalled());
    t.advance(10);
    assert!(!t.stalled());
    t.end();
}

#[test, expected_failure(abort_code = vault::EVaultStalled)]
fun a_stalled_vault_takes_no_deposit() {
    let mut t = harness::new();
    t.warp(7 * 86_400 + 1);
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, ONE);
    t.end();
}

// ---------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------

/// A failed intake's depositor takes back exactly what it deposited, once.
#[test]
fun a_failed_intakes_deposit_is_refunded() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    t.deposit(harness::bob(), intake, ONE);
    t.deliver(3, intake);
    assert!(t.intake_state(intake) == 3);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    assert!(t.received(harness::alice()) == 3 * ONE);
    assert!(t.held() == ONE);
    let v = t.take(harness::relayer());
    let (_, total, digest) = vault::intake(&v, f::hub_index(), intake);
    assert!(total == ONE);
    assert!(digest == abi::intake_digest(harness::sui_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 3, true, ONE));
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENothingToRefund)]
fun a_refund_is_taken_once() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    t.deliver(3, intake);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENothingToRefund)]
fun a_stranger_has_nothing_to_refund() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    t.deliver(3, intake);
    let mut v = t.take(harness::bob());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeNotOpen)]
fun an_open_intake_refunds_nothing() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EIntakeNotOpen)]
fun a_settled_intake_refunds_nothing() {
    let mut t = harness::new();
    let intake = t.fund(ONE);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::EVaultFrozen)]
fun a_refund_while_frozen_is_refused() {
    let mut t = harness::new();
    let intake = harness::intake_id(t.now() + 3600, 1);
    t.deposit(harness::alice(), intake, 3 * ONE);
    t.deliver(3, intake);
    let mut v = t.take(harness::freezer());
    let (clock, ctx) = t.parts();
    vault::freeze_vault(&mut v, clock, ctx);
    harness::put(v);
    let mut v = t.take(harness::alice());
    let (clock, ctx) = t.parts();
    vault::refund(&mut v, f::hub_index(), intake, clock, ctx);
    harness::put(v);
    t.end();
}

// ---------------------------------------------------------------------
// attest
// ---------------------------------------------------------------------

/// `attest` writes one `Attestation`, frozen, whose record is what `SuiStateVerifier.attestRecord` writes for the same
/// slots and values (`test/fixtures/sui/vault-attest.json`, checked against the Solidity side by
/// `test/SuiStateVerifier.vault.t.sol`), and whose BCS is the id then the record as a byte string: the contents the
/// verifier hashes into the object's digest.
#[test]
fun attest_writes_the_record_the_verifier_reads() {
    let mut t = harness::new();
    t.deposit(harness::alice(), f::attest_intake_id(), 3 * ONE);
    t.set_ms(f::attest_timestamp_ms());
    let v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::attest(&v, f::attest_slots(), f::attest_values(), clock, ctx);
    harness::put(v);
    t.scenario().next_tx(harness::relayer());
    let a = t.scenario().take_immutable<Attestation>();
    assert!(vault::record(&a) == f::attest_record());
    let mut contents = object::id(&a).to_bytes();
    // The record's length, 448 bytes, as ULEB128.
    contents.append(vector[0xc0, 0x03]);
    contents.append(f::attest_record());
    assert!(vault::record(&a).length() == 448);
    assert!(bcs::to_bytes(&a) == contents);
    ts::return_immutable(a);
    t.end();
}

/// Every slot the hub reads holds what the vault wrote there, an unwritten one zero; anything else aborts.
#[test]
fun attest_vouches_only_for_what_the_vault_holds() {
    let mut t = harness::new();
    let intake = t.fund(5 * ONE);
    let v = t.take(harness::relayer());
    let (_, _, _, index_digest, _) = vault::index_state(&v, f::hub_index(), t.clock());
    let (_, _, intake_digest) = vault::intake(&v, f::hub_index(), intake);
    let slots = vector[vault::index_slot(&f::hub_index()), vault::intake_slot(&f::hub_index(), &intake), bytes::word64(25)];
    let (clock, ctx) = t.parts();
    vault::attest(&v, slots, vector[index_digest, intake_digest, bytes::zero32()], clock, ctx);
    let (clock, ctx) = t.parts();
    vault::attest(&v, vector[], vector[], clock, ctx);
    harness::put(v);
    t.end();
}

fun attest_refused(slot: vector<u8>, value: vector<u8>) {
    let mut t = harness::new();
    let v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::attest(&v, vector[slot], vector[value], clock, ctx);
    harness::put(v);
    t.end();
}

#[test, expected_failure(abort_code = vault::ENotAttested)]
fun attest_refuses_another_value() {
    attest_refused(vault::index_slot(&f::hub_index()), bytes::zero32());
}

#[test, expected_failure(abort_code = vault::ENotAttested)]
fun attest_refuses_a_value_in_an_unwritten_slot() {
    attest_refused(bytes::word64(25), bytes::word64(1));
}

#[test, expected_failure(abort_code = vault::ENotAttested)]
fun attest_refuses_a_short_slot() {
    attest_refused(vector[25], bytes::zero32());
}

#[test, expected_failure(abort_code = vault::ENotAttested)]
fun attest_refuses_a_short_value() {
    attest_refused(bytes::word64(25), vector[0]);
}

#[test, expected_failure(abort_code = vault::ENotAttested)]
fun attest_refuses_unpaired_slots() {
    let mut t = harness::new();
    let v = t.take(harness::relayer());
    let (clock, ctx) = t.parts();
    vault::attest(&v, vector[bytes::word64(25)], vector[], clock, ctx);
    harness::put(v);
    t.end();
}
