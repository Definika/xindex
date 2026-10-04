#[test_only]
/// The snapshot exit on a real hub's storage (`tests/fixtures/hub.json`, written by `tests/fixtures/generate.py` from a
/// hub on anvil with Aptos testnet's registry id and this vault's id): open intakes resolved from the hub's settled
/// mark, a burn or migration in flight paid from the hub's sent mark, and holders paid their shares at the snapshot
/// (VLT-1, SOL-9), each read through a storage proof under the snapshot's state root. The Sui twin's `exit_tests`.
module xindex_vault::exit_tests {
    use std::bcs;
    use aptos_std::aptos_hash::keccak256;
    use aptos_std::from_bcs;
    use aptos_std::secp256k1;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness::{Self, T};
    use xindex_vault::mpt;
    use xindex_vault::snapshot;
    use xindex_vault::state_reader;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;
    const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
    /// One share's APT at the fixture's units: 15 APT.
    const UNIT: u64 = 1_500_000_000;

    /// The vault as it stands at the hub's last block: the index registered, the settled order's APT and an open
    /// order's deposited before their deadlines, and its checkpoint at that block, whose state root the reads are
    /// under.
    fun exit(): T {
        let t = harness::new();
        t.deposit(harness::alice(), f::settled_intake_id(), f::settled_intake_amount());
        harness::set_now(f::hub_timestamp() + 60);
        t.deposit(harness::bob(), f::open_intake_id(), f::open_intake_amount());
        t.advance_to(f::hub_block(), f::hub_timestamp(), f::hub_state_root());
        t
    }

    fun snapshot_now(t: &T) {
        let start = t.stall_start();
        harness::set_now(start + SNAPSHOT_EXIT_DELAY);
        t.begin_snapshot();
    }

    /// The exit begun and the settled order resolved: the index holds its 150 APT.
    fun settled(): T {
        let t = exit();
        snapshot_now(&t);
        resolve(&t, f::settled_intake_id(), f::settled_intake_proof());
        t
    }

    fun resolve(t: &T, intake: vector<u8>, proof: vector<u8>) {
        vault::resolve_intake(t.vault(), f::hub_index(), intake, proof);
    }

    fun recorded(t: &T, payload: vector<u8>, proof: vector<u8>) {
        vault::deliver_recorded(t.vault(), payload, proof);
    }

    fun claim(t: &T, holder: vector<u8>, component: u64, recipient: address, signature: vector<u8>, proof: vector<u8>) {
        vault::claim_snapshot(t.vault(), f::hub_index(), holder, component, recipient, signature, proof);
    }

    fun claim_a(t: &T, recipient: address, component: u64, signature: vector<u8>) {
        let proof = if (component == 0) f::holder_a_claim0_proof()
        else if (component == 1) f::holder_a_claim1_proof()
        else f::holder_a_claim2_proof();
        claim(t, f::holder_a(), component, recipient, signature, proof);
    }

    fun claim_b(t: &T, recipient: address) {
        claim(t, f::holder_b(), 1, recipient, vector[], f::holder_b_claim1_proof());
    }

    fun recipient_a(): address { from_bcs::to_address(f::holder_a_recipient()) }

    fun recipient_b(): address { from_bcs::to_address(f::holder_b_recipient()) }

    #[test]
    /// The whole exit, on a real hub's storage: each open intake settled or failed from the hub's mark at the snapshot,
    /// a burn in flight paid from the hub's record, and holders paid their shares at the snapshot's units plus their
    /// claims, within the speed limit, by signature or to their recovery address, once.
    fun the_snapshot_exit_reads_a_real_hub() {
        let t = exit();
        snapshot_now(&t);
        // The settled order joins the index; the open one fails, and its depositor takes its APT back.
        resolve(&t, f::settled_intake_id(), f::settled_intake_proof());
        assert!(t.intake_state(f::settled_intake_id()) == 2);
        assert!(t.balance() == 10 * UNIT);
        resolve(&t, f::open_intake_id(), f::open_intake_proof());
        assert!(t.intake_state(f::open_intake_id()) == 3);
        vault::refund(&harness::signer_of(harness::bob()), t.vault(), f::hub_index(), f::open_intake_id());
        assert!(t.received(harness::bob()) == UNIT);

        // The burn in flight: one share's APT, of which the speed limit lets 4% of 150 APT out today.
        recorded(&t, f::burn_payload(), f::burn_proof());
        let burn_to = from_bcs::to_address(f::burn_recipient());
        let today = 10 * UNIT * 4 / 100;
        assert!(t.received(burn_to) == today, 0);
        assert!(t.owed_remaining(f::burn_id()) == UNIT - today);

        // Holder A: 4 shares, plus a claim of one share's APT, to the recipient it signed for. Today's limit is spent.
        claim_a(&t, recipient_a(), 1, f::holder_a_signature());
        assert!(t.received(recipient_a()) == 0);
        let id_a = snapshot::claim_id(&f::hub_index(), &f::holder_a());
        assert!(t.owed_remaining(id_a) == 5 * UNIT, 1);
        // Holder B: 3 shares, to the recovery address it registered in the hub, with no signature.
        claim_b(&t, recipient_b());
        let id_b = snapshot::claim_id(&f::hub_index(), &f::holder_b());
        assert!(t.owed_remaining(id_b) == 3 * UNIT, 2);

        // A day on, the speed limit pays the next part: 4% of the 150 APT less today's.
        harness::warp(25 * 3600);
        t.release(id_a);
        let next = (10 * UNIT - today) * 4 / 100;
        assert!(t.received(recipient_a()) == next, 3);
        assert!(t.owed_remaining(id_a) == 5 * UNIT - next);
        assert!(t.held() == 10 * UNIT - today - next);
    }

    #[test, expected_failure(abort_code = vault::ENoSnapshot, location = vault)]
    fun no_resolution_before_the_snapshot() {
        let t = exit();
        resolve(&t, f::settled_intake_id(), f::settled_intake_proof());
    }

    #[test, expected_failure(abort_code = vault::ENoSnapshot, location = vault)]
    fun no_recorded_delivery_before_the_snapshot() {
        let t = exit();
        recorded(&t, f::burn_payload(), f::burn_proof());
    }

    #[test, expected_failure(abort_code = vault::ENoSnapshot, location = vault)]
    fun no_claim_before_the_snapshot() {
        let t = exit();
        claim_a(&t, recipient_a(), 1, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    fun an_intake_resolves_once() {
        let t = settled();
        resolve(&t, f::settled_intake_id(), f::settled_intake_proof());
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    fun a_recorded_burn_runs_once() {
        let t = settled();
        recorded(&t, f::burn_payload(), f::burn_proof());
        recorded(&t, f::burn_payload(), f::burn_proof());
    }

    #[test, expected_failure(abort_code = vault::EAlreadyClaimed, location = vault)]
    fun a_holder_claims_once() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, f::holder_a_signature());
        claim_a(&t, recipient_a(), 1, f::holder_a_signature());
    }

    // ---------------------------------------------------------------------
    // VLT-1
    // ---------------------------------------------------------------------

    #[test, expected_failure(abort_code = snapshot::EWrongComponent, location = snapshot)]
    /// VLT-1: a claim reads a component only inside the hub's components array, and only this chain's coin there.
    /// WETH, the first component, is refused; so is the empty slot just past the array's end, and storage further past
    /// it that holds APT at a far larger unit count, as storage a holder could fill.
    fun test_vlt1_another_component_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 0, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = snapshot::EWrongComponent, location = snapshot)]
    fun test_vlt1_the_slot_past_the_end_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 2, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = snapshot::EWrongComponent, location = snapshot)]
    fun test_vlt1_storage_past_the_end_is_refused() {
        let t = settled();
        // What lies there is APT at a far larger unit count.
        let values = f::holder_a_past_the_end_values();
        assert!(bytes::slice(&values[1], 12, 20) == f::hub_apt_token());
        claim(&t, f::holder_a(), 7, recipient_a(), f::holder_a_signature(), f::holder_a_past_the_end_proof());
    }

    #[test]
    fun test_vlt1_the_component_inside_the_array_is_paid() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, f::holder_a_signature());
        assert!(t.received(recipient_a()) == 10 * UNIT * 4 / 100);
    }

    // ---------------------------------------------------------------------
    // Where a claim is paid
    // ---------------------------------------------------------------------

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    /// The signature names its recipient: another one is not what the holder signed.
    fun a_signature_pays_only_its_recipient() {
        let t = settled();
        claim_a(&t, @0x77, 1, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    fun no_signature_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, vector[]);
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    fun a_short_signature_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, bytes::slice(&f::holder_a_signature(), 0, 64));
    }

    fun with_v(v: u8): vector<u8> {
        let s = f::holder_a_signature();
        s[64] = v;
        s
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    fun v_29_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, with_v(29));
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    /// v as the raw recovery id, 0 or 1, recovers the same key: OpenZeppelin takes only 27 and 28.
    fun a_raw_recovery_id_is_refused() {
        let t = settled();
        let v = f::holder_a_signature()[64];
        claim_a(&t, recipient_a(), 1, with_v(v - 27));
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    /// The same signature with s in the upper half and v flipped recovers the same key; OpenZeppelin refuses it.
    fun a_malleable_signature_is_refused() {
        let t = settled();
        let sig = f::holder_a_signature();
        let n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        let s = bytes::u256_at(&sig, 32);
        let out = bytes::slice(&sig, 0, 32);
        out.append(bytes::word(n - s));
        out.push_back(if (sig[64] == 27) 28 else 27);
        claim_a(&t, recipient_a(), 1, out);
    }

    #[test]
    /// The malleable signature does recover the holder: only the rule refuses it.
    fun the_malleable_signature_recovers_the_holder() {
        let sig = f::holder_a_signature();
        let n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        let s = bytes::u256_at(&sig, 32);
        let raw = bytes::slice(&sig, 0, 32);
        raw.append(bytes::word(n - s));
        let id = if (sig[64] == 27) 1 else 0;
        let message = snapshot::claim_message(&f::hub_vault(), harness::aptos_testnet(), &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
        let key = secp256k1::ecdsa_recover(keccak256(message), id, &secp256k1::ecdsa_signature_from_bytes(raw));
        let key = secp256k1::ecdsa_raw_public_key_to_bytes(&key.destroy_some());
        assert!(bytes::slice(&keccak256(key), 12, 20) == f::holder_a());
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    /// An `r` that is no point's x-coordinate recovers no key: refused, here, with the rule's own code.
    fun an_r_off_the_curve_is_refused() {
        let message = snapshot::claim_message(&f::hub_vault(), harness::aptos_testnet(), &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
        // x = 5 has no point on secp256k1 (5^3 + 7 = 132 is no square mod p).
        let sig = bytes::word(5);
        sig.append(bytes::word(1));
        sig.push_back(27);
        snapshot::check_signature(&message, &sig, &f::holder_a());
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    fun an_r_of_zero_is_refused() {
        let message = snapshot::claim_message(&f::hub_vault(), harness::aptos_testnet(), &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
        let sig = bytes::zero32();
        sig.append(bytes::word(1));
        sig.push_back(27);
        snapshot::check_signature(&message, &sig, &f::holder_a());
    }

    #[test, expected_failure(abort_code = snapshot::EBadSignature, location = snapshot)]
    /// Another key's signature of the very claim is not the holder's: holder B signed holder A's claim.
    fun another_keys_signature_is_refused() {
        let t = settled();
        claim_a(&t, recipient_a(), 1, f::holder_a_signature_by_b());
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_claim_to_no_one_is_refused() {
        let t = settled();
        claim_a(&t, @0x0, 1, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = vault::EWrongRecipient, location = vault)]
    /// SOL-9's twin for claims: a claim never pays the vault's own object, where the APT would be stranded.
    fun test_sol9_a_claim_never_pays_the_vault() {
        let t = settled();
        claim_a(&t, from_bcs::to_address(f::hub_vault()), 1, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = vault::EWrongRecipient, location = vault)]
    /// Nor the coins' store's object.
    fun test_sol9_a_claim_never_pays_the_store() {
        let t = settled();
        claim_a(&t, vault::store(t.vault()), 1, f::holder_a_signature());
    }

    #[test, expected_failure(abort_code = vault::EWrongRecipient, location = vault)]
    /// Holder B registered a recovery address: paid there and only there, signature or not.
    fun a_registered_holder_is_paid_only_there() {
        let t = settled();
        claim_b(&t, @0x77);
    }

    #[test]
    fun a_registered_holder_needs_no_signature() {
        let t = settled();
        claim_b(&t, recipient_b());
        assert!(t.received(recipient_b()) == 10 * UNIT * 4 / 100);
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun a_claim_on_no_index_is_refused() {
        let t = settled();
        vault::claim_snapshot(t.vault(), f::migrate_new_index(), f::holder_a(), 1, recipient_a(), f::holder_a_signature(), f::holder_a_claim1_proof());
    }

    #[test, expected_failure(abort_code = vault::EBadLength, location = vault)]
    fun a_holder_of_another_length_is_refused() {
        let t = settled();
        claim(&t, bytes::zero32(), 1, recipient_a(), f::holder_a_signature(), f::holder_a_claim1_proof());
    }

    // ---------------------------------------------------------------------
    // Recorded messages
    // ---------------------------------------------------------------------

    #[test, expected_failure(abort_code = vault::ENotRecorded, location = vault)]
    /// A burn or migration runs after the snapshot only on the index's own mark of it.
    fun an_unsent_burn_is_not_recorded() {
        let t = settled();
        recorded(&t, f::unsent_burn_payload(), f::unsent_burn_proof());
    }

    #[test, expected_failure(abort_code = vault::EUnknownKind, location = vault)]
    /// A message of another kind resolves another way: refused before anything is read.
    fun only_burns_and_migrations_are_recorded() {
        let t = settled();
        let settle = f::burn_payload();
        settle[2 * 32 + 31] = 2;
        recorded(&t, settle, f::unsent_burn_proof());
    }

    #[test, expected_failure(abort_code = vault::EWrongRoute, location = vault)]
    /// A recorded message is routed here, as a delivered one.
    fun a_recorded_message_for_another_chain_is_refused() {
        let t = settled();
        let burn = f::burn_payload();
        burn[3 * 32 + 31] ^= 1;
        recorded(&t, burn, f::burn_proof());
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun a_recorded_migration_needs_its_target_registered() {
        let t = settled();
        recorded(&t, f::migrate_payload(), f::migrate_proof());
    }

    #[test]
    /// A real migration into the index's second version, which its creator seeded with its last share, is paid into
    /// that version's balance within the speed limit; then the burn, today's limit spent, is owed in full.
    fun a_recorded_migration_moves_coins_within_the_limit() {
        let t = settled();
        vault::register_index(t.vault(), f::migrate_new_index(), f::migrate_new_salt());
        recorded(&t, f::migrate_payload(), f::migrate_proof());
        let today = 10 * UNIT * 4 / 100;
        let (_, balance, _, _, _) = t.index_state(f::migrate_new_index());
        assert!(balance == today);
        assert!(t.owed_remaining(f::migrate_id()) == UNIT - today);
        assert!(t.held() == 10 * UNIT + UNIT);
        recorded(&t, f::burn_payload(), f::burn_proof());
        assert!(t.owed_remaining(f::burn_id()) == UNIT);
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    /// A message delivered before the snapshot is not run again from the hub's record.
    fun a_delivered_burn_is_not_recorded_again() {
        let t = exit();
        let burn = f::burn_payload();
        let index = f::hub_index();
        // Delivered on both proofs before the snapshot, from a block the checkpoint covers.
        let proof = t.proof_for(&index, &burn, f::hub_block());
        // The settled intake joins first, so the burn has a balance to pay from.
        let settle = harness::message(harness::sepolia(), 2, &index, &f::settled_intake_id(), 1, harness::aptos_testnet(), &f::hub_vault());
        let settle_proof = t.proof_for(&index, &settle, f::hub_block() - 1);
        t.deliver_raw(settle, f::hub_block() - 1, settle_proof, settle_proof);
        t.deliver_raw(burn, f::hub_block(), proof, proof);
        snapshot_now(&t);
        recorded(&t, f::burn_payload(), f::burn_proof());
    }

    // ---------------------------------------------------------------------
    // The state proofs
    // ---------------------------------------------------------------------

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    /// Every node is checked against the snapshot's root: a proof tampered with, cut short or followed by anything does
    /// not prove the hub's storage.
    fun a_tampered_proof_is_refused() {
        let t = exit();
        snapshot_now(&t);
        let proof = f::settled_intake_proof();
        let middle = proof.length() / 2;
        proof[middle] ^= 1;
        resolve(&t, f::settled_intake_id(), proof);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_short_proof_is_refused() {
        let t = exit();
        snapshot_now(&t);
        let proof = f::settled_intake_proof();
        proof.pop_back();
        resolve(&t, f::settled_intake_id(), proof);
    }

    #[test, expected_failure(abort_code = state_reader::EBadStateProof, location = state_reader)]
    fun a_proof_with_bytes_after_it_is_refused() {
        let t = exit();
        snapshot_now(&t);
        let proof = f::settled_intake_proof();
        proof.push_back(0);
        resolve(&t, f::settled_intake_id(), proof);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    /// A proof under another root: the open intake's, which is a real proof of another slot, read for the settled one.
    fun a_proof_of_another_slot_is_refused() {
        let t = exit();
        snapshot_now(&t);
        resolve(&t, f::settled_intake_id(), f::open_intake_proof());
    }

    #[test]
    /// An account the state does not hold has no storage: every slot reads zero.
    fun an_absent_account_reads_zero() {
        let values = state_reader::read_slots(&f::hub_state_root(), &f::absent_account(), &vector[bytes::zero32()], &f::absent_account_proof());
        assert!(values == vector[bytes::zero32()]);
    }

    #[test]
    /// What the vault computes of Ethereum's encodings, against what Solidity's encoder and `cast` computed for the same
    /// hub: every slot a claim, a resolution and a recorded delivery read, the values the proofs show, and the EIP-712
    /// digest a holder signs, whose signature recovers to the holder.
    fun the_reads_and_the_digest_are_soliditys() {
        assert!(f::hub_chain_id() == harness::aptos_testnet());
        assert!(snapshot::claim_slots(&f::holder_a(), 0, harness::aptos_testnet()) == f::holder_a_claim0_slots());
        assert!(snapshot::claim_slots(&f::holder_a(), 1, harness::aptos_testnet()) == f::holder_a_claim1_slots());
        assert!(snapshot::claim_slots(&f::holder_a(), 2, harness::aptos_testnet()) == f::holder_a_claim2_slots());
        assert!(snapshot::claim_slots(&f::holder_b(), 1, harness::aptos_testnet()) == f::holder_b_claim1_slots());
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
        let message = snapshot::claim_message(&f::hub_vault(), harness::aptos_testnet(), &index, &f::holder_a(), &f::holder_a_recipient());
        assert!(keccak256(message) == f::holder_a_digest());
        snapshot::check_signature(&message, &f::holder_a_signature(), &f::holder_a());
        // The shares, as the hub holds them: four at 15 APT, plus a claim of 15; three to a recovery address.
        let (amount, registered) = snapshot::share(&f::holder_a_claim1_values(), 1, harness::aptos_testnet());
        assert!(amount == 5 * UNIT && registered.is_none());
        let (amount, registered) = snapshot::share(&f::holder_b_claim1_values(), 1, harness::aptos_testnet());
        assert!(amount == 3 * UNIT && registered.destroy_some() == f::holder_b_recipient());
        assert!(ONE * 15 == UNIT);
        assert!(bcs::to_bytes(&recipient_b()) == f::holder_b_recipient());
    }

    #[test, expected_failure(abort_code = snapshot::EOverflow, location = snapshot)]
    fun a_share_past_64_bits_is_refused() {
        let values = f::holder_a_claim1_values();
        values[2] = bytes::word(0xffffffffffffffff);
        snapshot::share(&values, 1, harness::aptos_testnet());
    }

    #[test, expected_failure(abort_code = snapshot::EOverflow, location = snapshot)]
    fun shares_past_128_bits_are_refused() {
        let values = f::holder_a_claim1_values();
        values[0] = bytes::word(1 << 128);
        snapshot::share(&values, 1, harness::aptos_testnet());
    }

    #[test, expected_failure(abort_code = snapshot::EOverflow, location = snapshot)]
    fun a_claim_past_128_bits_is_refused() {
        let values = f::holder_a_claim1_values();
        values[2] = bytes::word(1 << 128);
        snapshot::share(&values, 1, harness::aptos_testnet());
    }

    #[test, expected_failure(abort_code = snapshot::EZeroAmount, location = snapshot)]
    fun a_holder_of_nothing_is_refused() {
        let values = f::holder_a_claim1_values();
        values[0] = bytes::zero32();
        values[2] = bytes::zero32();
        snapshot::share(&values, 1, harness::aptos_testnet());
    }

    #[test, expected_failure(abort_code = snapshot::EBadStateProof, location = snapshot)]
    fun a_share_reads_five_values() {
        let values = f::holder_a_claim1_values();
        values.pop_back();
        snapshot::share(&values, 1, harness::aptos_testnet());
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    /// An intake never opened here has nothing to resolve.
    fun an_unknown_intake_resolves_nothing() {
        let t = settled();
        resolve(&t, harness::intake_id(1, 1), f::settled_intake_proof());
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    /// A recorded message names a registered index, as a delivered one must.
    fun a_recorded_burn_from_a_stranger_is_refused() {
        let t = settled();
        let stranger = bytes::repeat(0x77, 20);
        let burn = harness::message(harness::sepolia(), 1, &stranger, &harness::burn_body(ONE, @0xbeef), 1, harness::aptos_testnet(), &f::hub_vault());
        recorded(&t, burn, f::burn_proof());
    }
}
