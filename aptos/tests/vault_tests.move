#[test_only]
/// Creation, registration, deposits, refunds, the stall and `attest`: the Sui twin's `vault_tests`, and the EVM vault's
/// `XindexVault.t.sol` rules of the same names.
module xindex_vault::vault_tests {
    use std::bcs;
    use aptos_framework::fungible_asset;
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use aptos_std::type_info;
    use xindex_vault::abi;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness::{Self, T};
    use xindex_vault::light_client;
    use xindex_vault::vault;

    const ONE: u64 = 100_000_000;

    // ---------------------------------------------------------------------
    // Creation: `DeployVault`'s refusals, where Move can see them
    // ---------------------------------------------------------------------

    fun bare(): T {
        harness::bare(f::settled_intake_deadline() - 600)
    }

    fun create(t: &mut T, source: u64, chain: u64, freezer: address, recovery: address, cap: u64, floor: u64): address {
        let (p1, p2) = (t.p1_id(), t.p2_id());
        t.create_with(harness::creator(), source, chain, f::hub_factory(), p1, p2, freezer, recovery, cap, floor)
    }

    #[test]
    fun a_vault_is_created_with_its_settings() {
        let t = harness::new();
        let v = t.vault();
        assert!(vault::source_chain_id(v) == harness::sepolia() && vault::chain_id(v) == harness::aptos_testnet());
        assert!(vault::factory(v) == f::hub_factory() && vault::hub_implementation(v) == f::hub_implementation());
        assert!(vault::p1(v) == t.p1_id() && vault::p2(v) == t.p2_id());
        assert!(vault::freezer(v) == harness::freezer() && vault::recovery_proposer(v) == harness::recovery());
        assert!(vault::cap(v) == 1_000_000 * ONE && vault::outflow_floor(v) == ONE && vault::held(v) == 0);
        let (block, timestamp, root) = vault::checkpoint(v);
        // Its first week's grace: the checkpoint is dated at creation, with no state.
        assert!(block == 0 && timestamp == harness::now() && bytes::is_zero(&root));
        assert!(vault::vault_id(v) == bcs::to_bytes(&v));
        assert!(vault::vault_id(v) == f::hub_vault());
        assert!(vault::vault_address(harness::creator()) == v);
        assert!(vault::is_vault(v) && !vault::is_vault(harness::creator()));
    }

    #[test]
    /// Nobody owns the vault's object or can move it, and only the vault owns its coins' store: no account can withdraw
    /// from the store as its owner, as `fungible_asset::withdraw` lets any owner up the chain.
    fun nobody_owns_the_vault_or_its_coins() {
        let t = harness::new();
        let v = object::address_to_object<object::ObjectCore>(t.vault());
        assert!(object::owner(v) == @0x0);
        assert!(!object::ungated_transfer_allowed(v) && object::is_untransferable(v));
        let store = object::address_to_object<fungible_asset::FungibleStore>(vault::store(t.vault()));
        assert!(object::owner(store) == t.vault());
        assert!(object::is_untransferable(store));
        assert!(!object::owns(store, harness::creator()));
        assert!(fungible_asset::store_metadata(store) == vault::apt_for_testing());
        // The light clients are unowned too.
        let p1 = object::address_to_object<object::ObjectCore>(t.p1_id());
        assert!(object::owner(p1) == @0x0 && object::is_untransferable(p1));
    }

    #[test, expected_failure(abort_code = 0x50008, location = aptos_framework::fungible_asset)]
    /// The creator, once owner of the store's chain, could withdraw: it never is. Here it tries.
    fun the_creator_cannot_withdraw_the_coins() {
        let t = harness::new();
        t.deposit(harness::alice(), harness::intake_id(harness::now() + 3600, 1), ONE);
        let store = object::address_to_object<fungible_asset::FungibleStore>(vault::store(t.vault()));
        let fa = fungible_asset::withdraw(&harness::signer_of(harness::creator()), store, 1);
        primary_fungible_store::deposit(harness::creator(), fa);
    }

    #[test, expected_failure(abort_code = 0x50003, location = aptos_framework::object)]
    /// Nobody can transfer the vault's object, not even its owner `0x0`.
    fun nobody_moves_the_vault() {
        let t = harness::new();
        let v = object::address_to_object<object::ObjectCore>(t.vault());
        object::transfer(&harness::signer_of(@0x0), v, harness::creator());
    }

    #[test, expected_failure(abort_code = 0x80001, location = aptos_framework::object)]
    /// One vault per creating account: its address is the creator's and the seed's.
    fun one_vault_per_creator() {
        let t = harness::new();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EUnknownSource, location = vault)]
    fun an_unknown_source_is_refused() {
        let t = bare();
        create(&mut t, 5, harness::aptos_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongChain, location = vault)]
    fun sepolias_vault_is_aptos_testnets() {
        let t = bare();
        create(&mut t, harness::sepolia(), 549_304_973_309_166_888, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongChain, location = vault)]
    fun ethereums_vault_is_aptos_mainnets() {
        let t = bare();
        create(&mut t, 1, harness::aptos_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// Ethereum's vault on Aptos mainnet passes the chain checks, and is then refused for its clients, which follow
    /// Sepolia.
    fun ethereums_vault_needs_mainnet_clients() {
        let t = bare();
        create(&mut t, 1, 549_304_973_309_166_888, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_missing_factory_is_refused() {
        let t = bare();
        let (p1, p2) = (t.p1_id(), t.p2_id());
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), bytes::repeat(0, 20), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EBadLength, location = vault)]
    fun a_factory_of_another_length_is_refused() {
        let t = bare();
        let (p1, p2) = (t.p1_id(), t.p2_id());
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), bytes::zero32(), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    fun p1_must_be_sp1_and_p2_risc_zero() {
        let t = bare();
        let (p1, p2) = (t.p1_id(), t.p2_id());
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), f::hub_factory(), p2, p1, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// An address that holds no light client of this package is no P1.
    fun p1_must_be_a_light_client() {
        let t = bare();
        let p2 = t.p2_id();
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), f::hub_factory(), @0xbad, p2, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    fun the_clients_must_follow_the_source_chain() {
        let t = bare();
        let p1 = t.client_with(light_client::sp1(), 1_606_824_023);
        let p2 = t.p2_id();
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), f::hub_factory(), p1, p2, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EAnchorTooOld, location = vault)]
    fun clients_past_their_lag_are_refused() {
        let t = bare();
        harness::warp(2 * 86_400);
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_missing_freezer_is_refused() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), @0x0, harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EZeroAddress, location = vault)]
    fun a_missing_recovery_proposer_is_refused() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), @0x0, 10, 1);
    }

    #[test, expected_failure(abort_code = vault::ESameRole, location = vault)]
    fun the_freezer_is_not_the_recovery_proposer() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), harness::freezer(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::ERoleIsCreator, location = vault)]
    fun the_freezer_is_not_the_creating_key() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::creator(), harness::recovery(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::ERoleIsCreator, location = vault)]
    fun the_recovery_proposer_is_not_the_creating_key() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), harness::creator(), 10, 1);
    }

    #[test, expected_failure(abort_code = vault::EFloorAboveCap, location = vault)]
    fun a_floor_above_the_cap_is_refused() {
        let t = bare();
        create(&mut t, harness::sepolia(), harness::aptos_testnet(), harness::freezer(), harness::recovery(), 10, 11);
    }

    #[test, expected_failure(abort_code = vault::ENoVault, location = vault)]
    fun no_vault_at_another_address() {
        let t = harness::new();
        vault::register_index(t.p1_id(), f::hub_index(), f::hub_salt());
    }

    // ---------------------------------------------------------------------
    // Indexes
    // ---------------------------------------------------------------------

    #[test]
    /// An index registers by the factory's CREATE2 formula, once, and its digest is written where the hub reads it.
    fun an_index_registers_by_create2() {
        let t = harness::new();
        let v = t.vault();
        assert!(vault::is_index(v, f::hub_index()));
        let slot = vault::index_slot(&f::hub_index());
        assert!(vault::slot(v, slot) == f::enc_index_digest_empty());
        // Again: nothing changes.
        vault::register_index(v, f::hub_index(), f::hub_salt());
        // The second version of the index, the migration's target.
        vault::register_index(v, f::migrate_new_index(), f::migrate_new_salt());
        assert!(vault::is_index(v, f::migrate_new_index()));
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun another_salt_is_no_index() {
        let t = harness::new();
        vault::register_index(t.vault(), f::hub_index(), f::migrate_new_salt());
    }

    #[test, expected_failure(abort_code = vault::EBadLength, location = vault)]
    fun an_index_of_another_length_is_refused() {
        let t = harness::new();
        vault::register_index(t.vault(), bytes::zero32(), f::hub_salt());
    }

    // ---------------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------------

    #[test]
    /// A deposit opens its intake, is booked to its depositor and counted in `held`, and the intake's digest is written
    /// where the hub reads it, as Solidity encodes it.
    fun a_deposit_opens_its_intake() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        t.deposit(harness::bob(), intake, ONE);
        t.deposit(harness::alice(), intake, 2 * ONE);
        let v = t.vault();
        let (state, total, digest) = vault::intake(v, f::hub_index(), intake);
        assert!(state == 1 && total == 6 * ONE);
        assert!(vault::deposited(v, f::hub_index(), intake, harness::alice()) == 5 * ONE);
        assert!(vault::deposited(v, f::hub_index(), intake, harness::bob()) == ONE);
        assert!(vault::held(v) == 6 * ONE && vault::coins(v) == 6 * ONE);
        let expected = abi::intake_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 1, true, 6 * ONE);
        assert!(digest == expected);
        assert!(vault::slot(v, vault::intake_slot(&f::hub_index(), &intake)) == expected);
        // The depositors' APT left their primary stores.
        assert!(harness::apt_balance(harness::alice()) == 0 && harness::apt_balance(harness::bob()) == 0);
    }

    #[test]
    /// APT withdrawn elsewhere deposits the same way.
    fun a_deposit_of_apt_withdrawn_elsewhere() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        let fa = aptos_framework::aptos_coin::mint_apt_fa_for_test(2 * ONE);
        vault::deposit_asset(&harness::signer_of(harness::bob()), t.vault(), f::hub_index(), intake, fa);
        assert!(vault::deposited(t.vault(), f::hub_index(), intake, harness::bob()) == 2 * ONE);
        assert!(t.held() == 2 * ONE);
    }

    #[test, expected_failure(abort_code = vault::ENotNative, location = vault)]
    /// Another fungible asset is not APT, whatever it is worth.
    fun a_deposit_of_another_asset_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        let creator = harness::signer_of(harness::creator());
        let (mint, _, _) = primary_fungible_store::init_test_metadata_with_primary_store_enabled(
            &object::create_named_object(&creator, b"fake apt"),
        );
        let fa = fungible_asset::mint(&mint, 50);
        vault::deposit_asset(&harness::signer_of(harness::bob()), t.vault(), f::hub_index(), intake, fa);
    }

    #[test, expected_failure(abort_code = vault::ENotAnIndex, location = vault)]
    fun a_deposit_to_no_index_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        harness::mint(harness::alice(), ONE);
        vault::deposit(&harness::signer_of(harness::alice()), t.vault(), f::migrate_new_index(), intake, ONE);
    }

    #[test, expected_failure(abort_code = vault::EZeroAmount, location = vault)]
    fun an_empty_deposit_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 0);
    }

    #[test, expected_failure(abort_code = vault::EBadLength, location = vault)]
    fun an_intake_id_of_another_length_is_refused() {
        let t = harness::new();
        t.deposit(harness::alice(), vector[1, 2, 3], ONE);
    }

    #[test]
    /// Deposits close at the deadline in the id, for everyone.
    fun a_deposit_at_the_deadline_is_taken() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        harness::warp(3600);
        t.deposit(harness::alice(), intake, ONE);
    }

    #[test, expected_failure(abort_code = vault::EIntakeClosed, location = vault)]
    fun a_deposit_past_the_deadline_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, ONE);
        harness::warp(3601);
        t.deposit(harness::bob(), intake, ONE);
    }

    #[test]
    /// A first deposit may set a deadline at most MAX_INTAKE_LIFE ahead.
    fun a_deadline_a_week_ahead_is_taken() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 7 * 86_400, 1);
        t.deposit(harness::alice(), intake, ONE);
    }

    #[test, expected_failure(abort_code = vault::EIntakeTooLong, location = vault)]
    fun a_deadline_past_a_week_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 7 * 86_400 + 1, 1);
        t.deposit(harness::alice(), intake, ONE);
    }

    #[test, expected_failure(abort_code = vault::ECapExceeded, location = vault)]
    fun a_deposit_past_the_cap_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 1_000_000 * ONE);
        t.deposit(harness::alice(), intake, 1);
    }

    #[test, expected_failure(abort_code = vault::EIntakeClosed, location = vault)]
    fun a_deposit_to_a_settled_intake_is_refused() {
        let t = harness::new();
        let intake = t.fund(ONE);
        t.deposit(harness::bob(), intake, ONE);
    }

    #[test, expected_failure(abort_code = vault::EVaultFrozen, location = vault)]
    fun a_deposit_while_frozen_is_refused() {
        let t = harness::new();
        t.freeze_by(harness::freezer());
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, ONE);
    }

    #[test]
    /// A week without a checkpoint stalls the vault, which then takes no deposit: it may never again see the message
    /// that would settle or fail an intake.
    fun test_stall_a_week_without_a_checkpoint() {
        let t = harness::new();
        harness::warp(7 * 86_400);
        assert!(!t.stalled());
        harness::warp(1);
        assert!(t.stalled());
        t.advance(10);
        assert!(!t.stalled());
    }

    #[test, expected_failure(abort_code = vault::EVaultStalled, location = vault)]
    fun a_stalled_vault_takes_no_deposit() {
        let t = harness::new();
        harness::warp(7 * 86_400 + 1);
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, ONE);
    }

    #[test]
    /// APT sent to the vault's store directly counts nowhere: `held` and every index's books stay, and the store holds
    /// more than `held`.
    fun apt_sent_to_the_store_counts_nowhere() {
        let t = harness::new();
        t.fund(5 * ONE);
        let store = object::address_to_object<fungible_asset::FungibleStore>(vault::store(t.vault()));
        fungible_asset::deposit(store, aptos_framework::aptos_coin::mint_apt_fa_for_test(ONE));
        assert!(vault::held(t.vault()) == 5 * ONE && vault::coins(t.vault()) == 6 * ONE);
        assert!(t.balance() == 5 * ONE);
    }

    // ---------------------------------------------------------------------
    // Refunds
    // ---------------------------------------------------------------------

    #[test]
    /// A failed intake's depositor takes back exactly what it deposited, once.
    fun a_failed_intakes_deposit_is_refunded() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        t.deposit(harness::bob(), intake, ONE);
        t.deliver(3, intake);
        assert!(t.intake_state(intake) == 3);
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
        assert!(t.received(harness::alice()) == 3 * ONE);
        assert!(t.held() == ONE);
        let (_, total, digest) = vault::intake(t.vault(), f::hub_index(), intake);
        assert!(total == ONE);
        assert!(digest == abi::intake_digest(harness::aptos_testnet(), &f::hub_vault(), &f::hub_index(), &intake, 3, true, ONE));
    }

    #[test, expected_failure(abort_code = vault::ENothingToRefund, location = vault)]
    fun a_refund_is_taken_once() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        t.deliver(3, intake);
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
    }

    #[test, expected_failure(abort_code = vault::ENothingToRefund, location = vault)]
    fun a_stranger_has_nothing_to_refund() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        t.deliver(3, intake);
        vault::refund(&harness::signer_of(harness::bob()), t.vault(), f::hub_index(), intake);
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    fun an_open_intake_refunds_nothing() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    fun a_settled_intake_refunds_nothing() {
        let t = harness::new();
        let intake = t.fund(ONE);
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
    }

    #[test, expected_failure(abort_code = vault::EVaultFrozen, location = vault)]
    fun a_refund_while_frozen_is_refused() {
        let t = harness::new();
        let intake = harness::intake_id(harness::now() + 3600, 1);
        t.deposit(harness::alice(), intake, 3 * ONE);
        t.deliver(3, intake);
        t.freeze_by(harness::freezer());
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), intake);
    }

    // ---------------------------------------------------------------------
    // attest
    // ---------------------------------------------------------------------

    #[test]
    /// `attest` emits one `Attested` event whose record is what `abi.encode` writes for the same slots and values
    /// (`test/fixtures/aptos/vault-attest.json`, from Solidity's encoder), at `timestamp::now_microseconds()`, and whose
    /// BCS, the event's data on the ledger, is the record as a byte string.
    fun attest_emits_the_record_the_verifier_reads() {
        let t = harness::new();
        t.deposit(harness::alice(), f::attest_intake_id(), 3 * ONE);
        harness::set_us(f::attest_timestamp_us());
        assert!(vault::attested_for_testing().length() == 0);
        vault::attest_for_testing(t.vault(), f::attest_slots(), f::attest_values());
        let records = vault::attested_for_testing();
        assert!(records.length() == 1);
        assert!(records[0] == f::attest_record());
        // The record's length, 448 bytes, as ULEB128, then the record.
        assert!(f::attest_record().length() == 448);
        assert!(vault::attested_bcs_for_testing(f::attest_record()) == f::attest_event_data());
        let prefix = bytes::slice(&f::attest_event_data(), 0, 2);
        assert!(prefix == x"c003");
    }

    #[test]
    /// Every slot the hub reads holds what the vault wrote there, an unwritten one zero; anything else aborts.
    fun attest_vouches_only_for_what_the_vault_holds() {
        let t = harness::new();
        let intake = t.fund(5 * ONE);
        let v = t.vault();
        let (_, _, _, index_digest, _) = vault::index_state(v, f::hub_index());
        let (_, _, intake_digest) = vault::intake(v, f::hub_index(), intake);
        let slots = vector[vault::index_slot(&f::hub_index()), vault::intake_slot(&f::hub_index(), &intake), bytes::word64(25)];
        vault::attest_for_testing(v, slots, vector[index_digest, intake_digest, bytes::zero32()]);
        vault::attest_for_testing(v, vector[], vector[]);
        assert!(vault::attested_for_testing().length() == 2);
    }

    fun uleb(n: u64): vector<u8> {
        let out = vector[];
        loop {
            let b = ((n & 0x7f) as u8);
            n >>= 7;
            if (n == 0) {
                out.push_back(b);
                return out
            };
            out.push_back(b | 0x80);
        }
    }

    /// The `ContractEvent::V2` a ledger holds for an `Attested` of `record` emitted by the package at `package`, its type
    /// tag written from the vault's own type as Aptos names it: `TypeTag::Struct` (7), the package's address, the
    /// module's and the struct's names, no type arguments; then the event's BCS as a byte string.
    fun contract_event(package: vector<u8>, record: vector<u8>): vector<u8> {
        let t = type_info::type_of<vault::Attested>();
        let module_name = type_info::module_name(&t);
        let struct_name = type_info::struct_name(&t);
        let out = vector[1, 7];
        out.append(package);
        out.append(uleb(module_name.length()));
        out.append(module_name);
        out.append(uleb(struct_name.length()));
        out.append(struct_name);
        out.push_back(0);
        let data = vault::attested_bcs_for_testing(record);
        out.append(uleb(data.length()));
        out.append(data);
        out
    }

    #[test]
    /// `AptosStateVerifier`'s statement writes the `Attested` event it requires from the chain id, the vault id, the
    /// time and the slots and values (`proofs/aptos/statement/src/bcs.rs`). Rebuilt from this vault's record and its
    /// event's type, the event is the statement's byte for byte, on the statement's own synthetic chain
    /// (`proofs/aptos/fixtures/synthetic.json`: another package, another vault, Aptos mainnet's registry id).
    fun the_event_is_the_one_aptos_state_verifier_writes() {
        let record = abi::attest_record(
            f::verifier_chain_id(),
            &f::verifier_vault_id(),
            f::verifier_timestamp_us(),
            &f::verifier_slots(),
            &f::verifier_values(),
        );
        assert!(contract_event(f::verifier_package(), record) == f::verifier_attested_event());
        assert!(f::verifier_chain_id() == 549_304_973_309_166_888);
    }

    #[test]
    /// The event's type names the package's address, `PACKAGE` on the verifier, and the record the vault's id, its
    /// `VAULT_ID`: two different addresses. A real `attest`'s event, written as the ledger holds it, is the vector
    /// `test/fixtures/aptos/vault-attest.json` gives (`contractEventV2`, for the tests' package `0xc0de`).
    fun the_events_type_is_the_packages_and_its_record_the_vaults() {
        let t = harness::new();
        t.deposit(harness::alice(), f::attest_intake_id(), 3 * ONE);
        harness::set_us(f::attest_timestamp_us());
        vault::attest_for_testing(t.vault(), f::attest_slots(), f::attest_values());
        let record = vault::attested_for_testing()[0];
        let info = type_info::type_of<vault::Attested>();
        assert!(type_info::account_address(&info) == @xindex_vault);
        assert!(type_info::module_name(&info) == b"vault" && type_info::struct_name(&info) == b"Attested");
        assert!(@xindex_vault != t.vault());
        assert!(bytes::slice(&record, 64, 32) == bcs::to_bytes(&t.vault()));
        assert!(contract_event(bcs::to_bytes(&@xindex_vault), record) == f::attest_contract_event());
    }

    fun attest_refused(slot: vector<u8>, value: vector<u8>) {
        let t = harness::new();
        vault::attest_for_testing(t.vault(), vector[slot], vector[value]);
    }

    #[test, expected_failure(abort_code = vault::ENotAttested, location = vault)]
    fun attest_refuses_another_value() {
        attest_refused(vault::index_slot(&f::hub_index()), bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::ENotAttested, location = vault)]
    fun attest_refuses_a_value_in_an_unwritten_slot() {
        attest_refused(bytes::word64(25), bytes::word64(1));
    }

    #[test, expected_failure(abort_code = vault::ENotAttested, location = vault)]
    fun attest_refuses_a_short_slot() {
        attest_refused(vector[25], bytes::zero32());
    }

    #[test, expected_failure(abort_code = vault::ENotAttested, location = vault)]
    fun attest_refuses_a_short_value() {
        attest_refused(bytes::word64(25), vector[0]);
    }

    #[test, expected_failure(abort_code = vault::ENotAttested, location = vault)]
    fun attest_refuses_unpaired_slots() {
        let t = harness::new();
        vault::attest_for_testing(t.vault(), vector[bytes::word64(25)], vector[]);
    }

    #[test, expected_failure(abort_code = vault::ENoVault, location = vault)]
    fun attest_needs_a_vault() {
        let t = harness::new();
        vault::attest_for_testing(t.p1_id(), vector[], vector[]);
    }

    #[test, expected_failure(abort_code = vault::EWrongVerifier, location = vault)]
    /// Two SP1 clients are no pair either: P2 must be a RISC Zero one.
    fun p2_must_be_risc_zero() {
        let t = bare();
        let p1 = t.p1_id();
        let other = harness::light_client(harness::relayer(), b"sp1 again", light_client::sp1(), 9, harness::epoch_at(harness::now()));
        t.create_with(harness::creator(), harness::sepolia(), harness::aptos_testnet(), f::hub_factory(), p1, other, harness::freezer(), harness::recovery(), 10, 1);
    }

    #[test]
    /// The entry form makes the same vault, at the address its creator and the seed give.
    fun a_vault_by_the_entry_function() {
        let t = bare();
        vault::create_vault(
            &harness::signer_of(harness::creator()),
            harness::sepolia(),
            harness::aptos_testnet(),
            f::hub_factory(),
            f::hub_implementation(),
            t.p1_id(),
            t.p2_id(),
            harness::freezer(),
            harness::recovery(),
            10,
            1,
        );
        let v = vault::vault_address(harness::creator());
        assert!(vault::is_vault(v) && bcs::to_bytes(&v) == f::hub_vault());
    }

    #[test, expected_failure(abort_code = vault::EIntakeNotOpen, location = vault)]
    /// An intake never opened refunds nothing.
    fun an_intake_never_opened_refunds_nothing() {
        let t = harness::new();
        vault::refund(&harness::signer_of(harness::alice()), t.vault(), f::hub_index(), harness::intake_id(harness::now() + 3600, 5));
    }

    #[test]
    /// The views of what was never written read zero, and the waiting changes of each kind read none.
    fun the_views_of_nothing_read_zero() {
        let t = harness::new();
        let v = t.vault();
        let (state, total, digest) = vault::intake(v, f::hub_index(), harness::intake_id(harness::now() + 3600, 5));
        assert!(state == 0 && total == 0 && digest.length() == 0);
        let (to_index, recipient, new_index, remaining) = vault::owed(v, f::hub_index(), bytes::zero32());
        assert!(!to_index && recipient == @0x0 && new_index.length() == 0 && remaining == 0);
        assert!(vault::deposited(v, f::hub_index(), bytes::zero32(), harness::alice()) == 0);
        assert!(!vault::used(v, bytes::zero32()) && vault::slot(v, bytes::zero32()) == bytes::zero32());
        let i = 5;
        while (i <= 8) {
            let (hash, ready_at) = vault::pending(v, (i as u8));
            assert!(hash.length() == 0 && ready_at == 0);
            i += 1;
        };
        let (b, ts, root) = vault::exit_snapshot(v);
        assert!(b == 0 && ts == 0 && bytes::is_zero(&root));
        let (a, b2, ends) = vault::successor(v);
        assert!(a == @0x0 && b2 == @0x0 && ends == 0);
        assert!(vault::stall_start(v) == harness::now() + 7 * 86_400 && vault::frozen_until(v) == 0);
        assert!(vault::last_message(v) == bytes::zero32() && vault::vetoes(v) == 0);
    }
}
