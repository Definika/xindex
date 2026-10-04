#[test_only]
/// The factory's governance messages: a freeze and a lower cap on one proof, VLT-2's delay on everything that loosens a
/// rule, VLT-4's nonce marks, and rotations to new light clients. The Sui twin's `governance_tests`.
module xindex_vault::governance_tests {
    use std::bcs;
    use aptos_std::aptos_hash::keccak256;
    use aptos_std::from_bcs;
    use xindex_vault::abi;
    use xindex_vault::bytes;
    use xindex_vault::harness::{Self, T};
    use xindex_vault::light_client;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;
    const CAP_UPDATE: u8 = 5;
    const FREEZE: u8 = 6;
    const FREEZER_CHANGE: u8 = 7;
    const VERIFIER_ROTATION: u8 = 8;
    const GOVERNANCE_DELAY: u64 = 7 * 86_400;
    const FREEZE_DURATION: u64 = 14 * 86_400;
    const MAINNET_GENESIS: u64 = 1_606_824_023;

    fun cap_of(t: &T): (u64, u64) {
        (vault::cap(t.vault()), vault::outflow_floor(t.vault()))
    }

    fun frozen_until(t: &T): u64 {
        vault::frozen_until(t.vault())
    }

    fun apply(t: &T, kind: u8, body: vector<u8>) {
        vault::apply_change(t.vault(), kind, body);
    }

    fun cancel(t: &T, who: address, kind: u8) {
        vault::cancel_change(&harness::signer_of(who), t.vault(), kind);
    }

    fun address_body(a: address): vector<u8> {
        bcs::to_bytes(&a)
    }

    #[test]
    /// A freeze, and a cap update that raises neither figure, apply at once on either proof alone; a freeze extends and
    /// never shortens.
    fun a_freeze_and_a_lower_cap_need_one_proof() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(500 * ONE, ONE / 2), 1, false, true);
        let (cap, floor) = cap_of(&t);
        assert!(cap == 500 * ONE && floor == ONE / 2);
        let until = harness::now() + FREEZE_DURATION;
        t.govern(FREEZE, harness::freeze_body(until), 2, true, false);
        assert!(frozen_until(&t) == until);
        harness::warp(100);
        t.freeze_by(harness::freezer());
        let later = harness::now() + FREEZE_DURATION;
        assert!(frozen_until(&t) == later);
        // A factory freeze that ends earlier leaves the later one.
        t.govern(FREEZE, harness::freeze_body(until), 3, true, true);
        assert!(frozen_until(&t) == later);
    }

    #[test, expected_failure(abort_code = vault::ENotFreezer, location = vault)]
    fun only_the_freezer_freezes() {
        let t = harness::new();
        t.freeze_by(harness::alice());
    }

    #[test]
    /// A3-03: a freeze carries the end of the factory's freeze. Delivered once that end has passed, however late, it
    /// freezes nothing, though it is used up; delivered while the factory's freeze runs, it freezes the vault until that
    /// end, not FREEZE_DURATION from its delivery.
    fun test_a303_a_late_freeze_ends_with_the_factorys_freeze() {
        let t = harness::new();
        let until = harness::now() + FREEZE_DURATION;
        let factory = xindex_vault::fixtures::hub_factory();
        let stale = harness::message(harness::sepolia(), FREEZE, &factory, &harness::freeze_body(until), 1, harness::aptos_testnet(), &t.vault_id());
        // Nobody delivers it while the factory's freeze runs; once it is over, a stranger does.
        harness::set_now(until);
        t.deliver_by(&factory, stale, true, false);
        assert!(frozen_until(&t) == 0);
        assert!(vault::used(t.vault(), keccak256(stale)));
        // One the factory sent 11 days ago, delivered now, freezes for the 3 days its freeze has left.
        let ends = harness::now() + 3 * 86_400;
        t.govern(FREEZE, harness::freeze_body(ends), 2, true, false);
        assert!(frozen_until(&t) == ends);
    }

    #[test]
    /// A3-03: whatever end a freeze carries, it freezes for at most FREEZE_DURATION from its delivery; an end past 64
    /// bits saturates.
    fun test_a303_a_freeze_lasts_at_most_freeze_duration() {
        let t = harness::new();
        t.govern(FREEZE, bytes::word(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff), 1, true, false);
        assert!(frozen_until(&t) == harness::now() + FREEZE_DURATION);
    }

    #[test, expected_failure(abort_code = vault::EBadMessage, location = vault)]
    /// B4-04: a freeze's body is one word, the end of the factory's freeze; an empty one is refused.
    fun test_b404_a_freeze_body_is_one_word() {
        let t = harness::new();
        t.govern(FREEZE, vector[], 1, true, true);
    }

    #[test, expected_failure(abort_code = vault::EBadMessage, location = vault)]
    /// B4-04: and so is a longer one.
    fun test_b404_a_freeze_body_of_two_words_is_refused() {
        let t = harness::new();
        let body = harness::freeze_body(harness::now() + FREEZE_DURATION);
        body.append(bytes::zero32());
        t.govern(FREEZE, body, 1, true, true);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    /// Raising only the floor loosens a rule as well.
    fun a_raised_floor_needs_both_proofs() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(ONE, 2 * ONE), 1, true, false);
    }

    #[test, expected_failure(abort_code = vault::ENotNative, location = vault)]
    fun a_cap_update_names_the_native_coin() {
        let t = harness::new();
        let body = harness::cap_body(ONE, ONE);
        body[31] = 1;
        t.govern(CAP_UPDATE, body, 1, true, true);
    }

    #[test]
    /// B1-05: the factory proposes a cap in 256 bits, knowing no chain's width. Past 64 bits it means `u64::MAX` here, a
    /// raise like any other: both proofs, the delay, then it applies. Refused, it could never be delivered.
    fun test_b105_a_cap_wider_than_the_native_type_saturates() {
        let t = harness::new();
        let body = bytes::zero32();
        body.append(bytes::word(1 << 70));
        body.append(bytes::word64(ONE));
        t.govern(CAP_UPDATE, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, body);
        let (cap, floor) = cap_of(&t);
        assert!(cap == 0xffffffffffffffff && floor == ONE);
    }

    #[test]
    /// VLT-2: a raised cap needs both proofs, then waits GOVERNANCE_DELAY on the vault before anyone applies it, once.
    fun test_vlt2_a_raise_waits_then_applies_once() {
        let t = harness::new();
        let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        let (cap, _) = cap_of(&t);
        assert!(cap == 1_000_000 * ONE);
        let (hash, ready_at) = vault::pending(t.vault(), CAP_UPDATE);
        assert!(hash == keccak256(raise) && ready_at == harness::now() + GOVERNANCE_DELAY);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, raise);
        let (cap, floor) = cap_of(&t);
        assert!(cap == 2_000_000 * ONE && floor == 2 * ONE);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    fun test_vlt2_a_raise_on_one_proof_is_refused() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(2_000_000 * ONE, 2 * ONE), 1, true, false);
    }

    #[test, expected_failure(abort_code = vault::EChangeNotReady, location = vault)]
    fun test_vlt2_a_raise_is_not_ready_before_the_delay() {
        let t = harness::new();
        let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        harness::warp(GOVERNANCE_DELAY - 1);
        apply(&t, CAP_UPDATE, raise);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    fun test_vlt2_only_the_waiting_body_applies() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(2_000_000 * ONE, 2 * ONE), 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, harness::cap_body(1, 1));
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    fun test_vlt2_a_change_applies_once() {
        let t = harness::new();
        let raise = harness::cap_body(2_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, raise);
        apply(&t, CAP_UPDATE, raise);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    /// The freezer may drop a waiting raise.
    fun test_vlt2_the_freezer_drops_a_raise() {
        let t = harness::new();
        let raise = harness::cap_body(3_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        cancel(&t, harness::freezer(), CAP_UPDATE);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, raise);
    }

    #[test, expected_failure(abort_code = vault::ENotFreezer, location = vault)]
    fun test_vlt2_only_the_freezer_drops_a_change() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(3_000_000 * ONE, 2 * ONE), 1, true, true);
        cancel(&t, harness::alice(), CAP_UPDATE);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    fun nothing_waiting_cannot_be_dropped() {
        let t = harness::new();
        cancel(&t, harness::freezer(), CAP_UPDATE);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    /// A kind with no waiting change of its own: a freeze never waits.
    fun a_freeze_never_waits() {
        let t = harness::new();
        cancel(&t, harness::freezer(), FREEZE);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    /// A newer lower cap replaces a waiting raise: the raise can no longer apply.
    fun a_lower_cap_replaces_a_waiting_raise() {
        let t = harness::new();
        let raise = harness::cap_body(3_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        t.govern(CAP_UPDATE, harness::cap_body(10 * ONE, ONE), 2, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, raise);
    }

    #[test]
    /// VLT-2: the freezer cannot drop its own replacement, nor hold it off with a freeze; once applied, the old key no
    /// longer freezes and the new one does.
    fun test_vlt2_the_freezer_cannot_block_its_replacement() {
        let t = harness::new();
        let new_key = @0x4b4b;
        let body = address_body(new_key);
        t.govern(FREEZER_CHANGE, body, 1, true, true);
        t.freeze_by(harness::freezer());
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, FREEZER_CHANGE, body);
        assert!(vault::freezer(t.vault()) == new_key);
        t.freeze_by(new_key);
    }

    #[test, expected_failure(abort_code = vault::ENotFreezer, location = vault)]
    fun test_vlt2_the_freezer_cannot_drop_its_replacement() {
        let t = harness::new();
        t.govern(FREEZER_CHANGE, address_body(@0x4b4b), 1, true, true);
        cancel(&t, harness::freezer(), FREEZER_CHANGE);
    }

    #[test, expected_failure(abort_code = vault::ENotFreezer, location = vault)]
    fun test_vlt2_the_old_freezer_no_longer_freezes() {
        let t = harness::new();
        let body = address_body(@0x4b4b);
        t.govern(FREEZER_CHANGE, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, FREEZER_CHANGE, body);
        t.freeze_by(harness::freezer());
    }

    #[test, expected_failure(abort_code = vault::EVaultFrozen, location = vault)]
    /// While frozen, a raise waits even once ready.
    fun test_vlt2_a_freeze_holds_a_ready_raise() {
        let t = harness::new();
        let raise = harness::cap_body(4_000_000 * ONE, 2 * ONE);
        t.govern(CAP_UPDATE, raise, 1, true, true);
        t.freeze_by(harness::freezer());
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, CAP_UPDATE, raise);
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_freezer_of_zero_is_refused() {
        let t = harness::new();
        let body = bytes::zero32();
        t.govern(FREEZER_CHANGE, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        apply(&t, FREEZER_CHANGE, body);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_freezer_change_carries_one_word() {
        let t = harness::new();
        t.govern(FREEZER_CHANGE, vector[1, 2, 3], 1, true, true);
    }

    // ---------------------------------------------------------------------
    // VLT-4
    // ---------------------------------------------------------------------

    #[test]
    /// VLT-4: a forged lower cap at a huge nonce, on one proof, applies (it only protects) but moves no mark, so the
    /// factory's honest change at its next nonce still runs and moves it.
    fun test_vlt4_one_proof_moves_no_mark() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(10 * ONE, ONE), 1_000_000, true, false);
        assert!(vault::nonces(t.vault()) == vector[0, 0, 0]);
        let (cap, _) = cap_of(&t);
        assert!(cap == 10 * ONE);
        t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 5, true, true);
        assert!(vault::nonces(t.vault()) == vector[5, 0, 0]);
        t.govern(FREEZER_CHANGE, address_body(@0x4b4b), 9, true, true);
        assert!(vault::nonces(t.vault()) == vector[5, 9, 0]);
        let (a, b) = t.new_pair(11);
        t.govern(VERIFIER_ROTATION, harness::pair_body(a, b), 3, true, true);
        assert!(vault::nonces(t.vault()) == vector[5, 9, 3]);
    }

    #[test, expected_failure(abort_code = vault::EStaleGovernance, location = vault)]
    /// An older message of the kind, delivered last, is refused: it cannot undo a newer one.
    fun test_vlt4_an_older_message_is_stale() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(20 * ONE, ONE), 5, true, true);
        t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 4, true, true);
    }

    #[test, expected_failure(abort_code = vault::EStaleGovernance, location = vault)]
    /// SOL-3's twin: an older freezer change, delivered after a newer one, cannot undo it.
    fun test_sol3_an_older_freezer_change_cannot_undo_a_newer_one() {
        let t = harness::new();
        t.govern(FREEZER_CHANGE, address_body(@0x4b4b), 5, true, true);
        t.govern(FREEZER_CHANGE, address_body(@0x5c5c), 4, true, true);
    }

    #[test]
    /// A3-02, A4-03: a cut taken first on one proof moves no mark, so it stays deliverable on both, which moves the
    /// mark and drops an older raise waiting under its key. Before, the one-proof delivery used up the id, and the older
    /// raise, queued behind it, undid the newer cut a week later.
    fun test_a302_a403_a_cut_on_one_proof_still_moves_the_mark_on_both() {
        let t = harness::new();
        let cut = t.govern(CAP_UPDATE, harness::cap_body(500_000 * ONE, ONE), 11, true, false);
        assert!(vault::nonces(t.vault()) == vector[0, 0, 0]);
        t.govern(CAP_UPDATE, harness::cap_body(2_000_000 * ONE, 10 * ONE), 10, true, true);
        let (_, ready_at) = vault::pending(t.vault(), CAP_UPDATE);
        assert!(ready_at != 0);
        t.deliver_by(&xindex_vault::fixtures::hub_factory(), cut, true, true);
        assert!(vault::nonces(t.vault()) == vector[11, 0, 0]);
        let (_, ready_at) = vault::pending(t.vault(), CAP_UPDATE);
        assert!(ready_at == 0);
        let (cap, _) = cap_of(&t);
        assert!(cap == 500_000 * ONE);
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    /// Once on both proofs, the cut is used up.
    fun test_a302_a_cut_on_both_proofs_is_used_up() {
        let t = harness::new();
        let cut = t.govern(CAP_UPDATE, harness::cap_body(500_000 * ONE, ONE), 11, true, true);
        t.deliver_by(&xindex_vault::fixtures::hub_factory(), cut, true, false);
    }

    #[test, expected_failure(abort_code = vault::EAlreadyDelivered, location = vault)]
    /// A freeze on one proof is used up at once: delivered again, it would re-arm the freeze.
    fun test_a302_a_freeze_on_one_proof_is_used_up() {
        let t = harness::new();
        let freeze = t.govern_freeze(2, true, false);
        t.deliver_by(&xindex_vault::fixtures::hub_factory(), freeze, true, false);
    }

    #[test, expected_failure(abort_code = vault::EStaleGovernance, location = vault)]
    fun test_vlt4_the_same_nonce_is_stale() {
        let t = harness::new();
        t.govern(CAP_UPDATE, harness::cap_body(20 * ONE, ONE), 5, true, true);
        t.govern(CAP_UPDATE, harness::cap_body(5 * ONE, ONE), 5, true, true);
    }

    #[test, expected_failure(abort_code = vault::EStaleGovernance, location = vault)]
    /// A rotation's mark is its own, and stale the same way.
    fun test_vlt4_a_rotation_at_the_same_nonce_is_stale() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        t.govern(VERIFIER_ROTATION, harness::pair_body(a, b), 5, true, true);
        t.govern(VERIFIER_ROTATION, harness::pair_body(b, a), 5, true, true);
    }

    // ---------------------------------------------------------------------
    // Rotations
    // ---------------------------------------------------------------------

    /// Applies the rotation, the light clients it names kept alive to now as their provers would keep them.
    fun rotate(t: &T, body: vector<u8>) {
        let i = 0;
        while (i < 2) {
            harness::keep_alive(from_bcs::to_address(bytes::slice(&body, 32 * i, 32)));
            i += 1;
        };
        rotate_as_is(t, body);
    }

    fun rotate_as_is(t: &T, body: vector<u8>) {
        vault::apply_change(t.vault(), VERIFIER_ROTATION, body);
    }

    #[test]
    /// A rotation names two light clients, one SP1 and one RISC Zero, which become P1 and P2 once it applies, and
    /// through which every later message is proven.
    fun a_rotation_installs_two_light_clients() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
        let (p1, p2) = t.pair();
        assert!(p1 == a && p2 == b);
        // The new pair proves what follows.
        t.fund(10 * ONE);
        assert!(t.balance() == 10 * ONE);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// A rotation to an address that holds no light client of this package is refused when it applies.
    fun a_rotation_takes_only_light_clients() {
        let t = harness::new();
        let (a, _) = t.new_pair(11);
        let body = harness::pair_body(a, @0xbad);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EVerifiersNotDistinct, location = vault)]
    /// Two clients of one proof system are no pair.
    fun a_rotation_to_one_system_is_refused() {
        let t = harness::new();
        let (a, _) = t.new_pair(11);
        let (c, _) = t.new_pair(21);
        let body = harness::pair_body(a, c);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EVerifiersNotDistinct, location = vault)]
    fun a_rotation_to_one_client_twice_is_refused() {
        let t = harness::new();
        let (a, _) = t.new_pair(11);
        let body = harness::pair_body(a, a);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EChangeNotReady, location = vault)]
    fun a_rotation_waits_the_delay() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY - 1);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EBothProofsRequired, location = vault)]
    fun a_rotation_needs_both_proofs() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        t.govern(VERIFIER_ROTATION, harness::pair_body(a, b), 1, false, true);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_rotation_carries_two_words() {
        let t = harness::new();
        let (a, _) = t.new_pair(11);
        t.govern(VERIFIER_ROTATION, bcs::to_bytes(&a), 1, true, true);
    }

    #[test, expected_failure(abort_code = vault::ENoPendingChange, location = vault)]
    fun the_freezer_drops_a_rotation() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        cancel(&t, harness::freezer(), VERIFIER_ROTATION);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EVaultFrozen, location = vault)]
    fun a_freeze_holds_a_rotation() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        t.freeze_by(harness::freezer());
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// B4-03: a rotated pair passes `create`'s checks of a pair. P1 must be the SP1 client and P2 the RISC Zero one.
    fun test_b403_a_rotation_takes_p1_as_sp1_and_p2_as_risc_zero() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(b, a);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// B4-03: both must follow the source chain's beacon genesis: Ethereum mainnet's clients cannot prove Sepolia.
    fun test_b403_a_rotation_to_another_networks_clients_is_refused() {
        let t = harness::new();
        let a = t.client_with(light_client::sp1(), MAINNET_GENESIS);
        let b = t.client_with(light_client::risc_zero(), MAINNET_GENESIS);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EAnchorTooOld, location = vault)]
    /// B4-03: both must still be within their lag when the rotation applies: a pair nobody advanced through the delay
    /// can never prove anything again, and the vault would stall on it.
    fun test_b403_a_rotation_to_clients_past_their_lag_is_refused() {
        let t = harness::new();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate_as_is(&t, body);
    }

    #[test, expected_failure(abort_code = vault::EAnchorNotBegun, location = vault)]
    /// B4-02, B4-03: and both must be anchored in an epoch that has begun, or they would not lag until their first
    /// update.
    fun test_b402_b403_a_rotation_to_clients_of_a_later_epoch_is_refused() {
        let t = harness::new();
        let later = harness::epoch_at(harness::now() + GOVERNANCE_DELAY) + 2;
        let a = t.client_at(light_client::sp1(), 11, later);
        let b = t.client_at(light_client::risc_zero(), 12, later);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate_as_is(&t, body);
    }

    #[test, expected_failure(abort_code = light_client::EUnknownHeaders, location = light_client)]
    /// After a rotation, the old pair proves nothing to the vault: a block only it recorded is unknown to the new one.
    fun the_old_pair_is_retired() {
        let t = harness::new();
        let (old1, old2) = t.pair();
        let (a, b) = t.new_pair(11);
        let body = harness::pair_body(a, b);
        t.govern(VERIFIER_ROTATION, body, 1, true, true);
        harness::warp(GOVERNANCE_DELAY);
        rotate(&t, body);
        let intake = harness::intake_id(harness::now() + 3600, 1);
        let index = t.index();
        let settle = t.payload(2, &index, &intake);
        let block = t.next_block();
        let (proof, root) = harness::event_proof(&index, &settle, block, harness::now());
        harness::record_for(old1, root, block);
        harness::record_for(old2, root, block);
        t.deliver_raw(settle, block, proof, proof);
    }
}
