#[test_only]
/// Pairs of tests whose difference is one call: each `gas_*_call` test does what its `*_base` does, then the call. The
/// unit-test runner meters no gas, so the README's figures come from these pairs' instruction counts, read from the
/// coverage map `aptos move test --coverage` writes for one test at a time, priced with mainnet's gas schedule
/// (`tests/fixtures/gas.py`). The proofs are precomputed (`fixtures::gas_*`, written by `vectors.py` and checked against
/// the harness's own builder below), so a setup spends nothing building them.
module xindex_vault::gas_tests {
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness::{Self, T};
    use xindex_vault::light_client;
    use xindex_vault::proofs;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;

    #[test]
    /// The precomputed proofs are what the harness builds.
    fun the_precomputed_proofs_are_the_harnesss() {
        let start = f::settled_intake_deadline() - 600;
        let (proof, root) = harness::event_proof(&f::hub_index(), &f::gas_settle(), 1_001, start);
        assert!(proof == f::gas_settle_proof() && root == f::gas_settle_root());
        let (proof, root) = harness::event_proof(&f::hub_index(), &f::gas_burn(), 1_002, start);
        assert!(proof == f::gas_burn_proof() && root == f::gas_burn_root());
    }

    fun deposit_setup(): T {
        let t = harness::new();
        harness::mint(harness::alice(), ONE);
        t
    }

    #[test]
    fun gas_deposit_base() {
        deposit_setup();
    }

    #[test]
    /// A first deposit into an intake: the intake, the depositor's entry and the intake's slot are new.
    fun gas_deposit_call() {
        let t = deposit_setup();
        vault::deposit(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), f::gas_intake(), ONE);
    }

    /// The vault with 4 APT in the gas intake, its settle's block recorded by both clients and checkpointed.
    fun settle_setup(): T {
        let t = harness::new();
        t.deposit(harness::alice(), f::gas_intake(), 4 * ONE);
        let (p1, p2) = t.pair();
        harness::record_for(p1, f::gas_settle_root(), 1_001);
        harness::record_for(p2, f::gas_settle_root(), 1_001);
        t.advance(1_100);
        t
    }

    #[test]
    fun gas_settle_base() {
        settle_setup();
    }

    #[test]
    /// An intake settled on both proofs.
    fun gas_settle_call() {
        let t = settle_setup();
        t.deliver_raw(f::gas_settle(), 1_001, f::gas_settle_proof(), f::gas_settle_proof());
        assert!(t.balance() == 4 * ONE);
    }

    /// The index funded with 1,000 APT, credited directly so the setup stays cheap, and the burn's block recorded.
    fun burn_setup(): T {
        let t = harness::new();
        vault::credit_for_testing(t.vault(), f::hub_index(), aptos_framework::aptos_coin::mint_apt_fa_for_test(1_000 * ONE));
        let (p1, p2) = t.pair();
        harness::record_for(p1, f::gas_burn_root(), 1_002);
        harness::record_for(p2, f::gas_burn_root(), 1_002);
        t.advance(1_100);
        t
    }

    #[test]
    fun gas_burn_base() {
        burn_setup();
    }

    #[test]
    /// A burn of 100 APT on both proofs, of which 40 are paid at once and 60 owed.
    fun gas_burn_call() {
        let t = burn_setup();
        t.deliver_raw(f::gas_burn(), 1_002, f::gas_burn_proof(), f::gas_burn_proof());
        assert!(t.received(@0xbeef) == 40 * ONE);
    }

    fun attest_setup(): T {
        let t = harness::new();
        t.deposit(harness::alice(), f::attest_intake_id(), 3 * ONE);
        harness::set_us(f::attest_timestamp_us());
        t
    }

    #[test]
    fun gas_attest_base() {
        attest_setup();
    }

    #[test]
    /// `attest` of three slots: an index's digest, an intake's and the snapshot's root.
    fun gas_attest_call() {
        let t = attest_setup();
        vault::attest_for_testing(t.vault(), f::attest_slots(), f::attest_values());
    }

    #[test]
    fun gas_check_base() {
        harness::boot(1_800_000_000);
        let (_, _, _) = (f::sp1_program_key(), f::sp1_public_values(), f::sp1_proof());
    }

    #[test]
    /// P1's proof check, the SP1 Groth16 proof as SP1 hands it to an EVM verifier.
    fun gas_sp1_call() {
        harness::boot(1_800_000_000);
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &f::sp1_proof());
    }

    #[test]
    /// P2's proof check, RISC Zero's seal and journal.
    fun gas_risc0_call() {
        harness::boot(1_800_000_000);
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &f::risc0_seal());
    }

    fun step_values(): vector<u8> {
        let values = bytes::repeat(0xfe, 32);
        values.append(bytes::repeat(0xbb, 32));
        values.append(bytes::word64(2));
        values.append(bytes::repeat(0x77, 32));
        values.append(bytes::word64(100));
        values.append(bytes::word64(163));
        values
    }

    fun step_setup(): (address, vector<u8>) {
        harness::boot(1_800_000_000);
        let lc = harness::light_client(harness::creator(), b"gas", light_client::sp1(), 1, 1);
        (lc, step_values())
    }

    #[test]
    fun gas_step_base() {
        step_setup();
    }

    #[test]
    /// The rest of `update` after the proof check: the anchor's step and the recorded range.
    fun gas_step_call() {
        let (lc, values) = step_setup();
        light_client::advance_for_testing(lc, values);
    }

    /// A light client that recorded the bloated receipts' block, and the message whose log it proves.
    fun bloat_setup(root: vector<u8>): (address, vector<u8>, vector<u8>) {
        harness::boot(1_800_000_000);
        let lc = harness::light_client(harness::creator(), b"bloat", light_client::sp1(), 1, 1);
        harness::record_range(lc, root, 10, 10);
        let payload = f::bloated_payload();
        (lc, aptos_std::aptos_hash::keccak256(payload), xindex_vault::abi::log_data(&payload))
    }

    #[test]
    fun gas_bloat8_base() {
        bloat_setup(f::bloated_8000_root());
    }

    #[test]
    /// One event proof (LG-1): the message's log after another log of 8 KB in its receipt.
    fun gas_bloat8_call() {
        let (lc, id, data) = bloat_setup(f::bloated_8000_root());
        let topic = xindex_vault::abi::event_topic();
        light_client::verify_event(lc, &f::bloated_8000_proof(), 10, &f::hub_index(), &topic, &id, &data);
    }

    #[test]
    fun gas_bloat32_base() {
        bloat_setup(f::bloated_32000_root());
    }

    #[test]
    /// The same after 32 KB.
    fun gas_bloat32_call() {
        let (lc, id, data) = bloat_setup(f::bloated_32000_root());
        let topic = xindex_vault::abi::event_topic();
        light_client::verify_event(lc, &f::bloated_32000_proof(), 10, &f::hub_index(), &topic, &id, &data);
    }
}
