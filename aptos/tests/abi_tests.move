#[test_only]
/// Every encoding the vault reads or writes, pinned against Solidity's own encoder (`cast abi-encode` and `cast keccak`,
/// in `fixtures`) and against the real hub's factory; and RLP and the hex-prefix paths, as the core's unit tests check
/// them. The Sui twin's `abi_tests`.
module xindex_vault::abi_tests {
    use std::option::Option;
    use aptos_std::aptos_hash::keccak256;
    use xindex_vault::abi;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness;
    use xindex_vault::mpt;
    use xindex_vault::rlp;
    use xindex_vault::snapshot;
    use xindex_vault::vault;

    const APTOS_TESTNET: u64 = 10_134_113_455_198_361_380;
    const APTOS_MAINNET: u64 = 549_304_973_309_166_888;
    const SEPOLIA: u64 = 11_155_111;

    #[test]
    fun the_domains_are_their_hashes() {
        assert!(abi::event_topic() == keccak256(b"VaultMessage(bytes32,bytes)"));
        let payload = f::enc_payload();
        assert!(bytes::slice(&payload, 0, 32) == keccak256(b"xindex.v4.vault-message"));
        let pre = keccak256(b"xindex.v4.vault-attest");
        pre.append(bytes::word64(APTOS_TESTNET));
        let record = f::attest_record();
        assert!(bytes::slice(&record, 0, 64) == pre);
    }

    #[test]
    /// The registry ids are the first 8 bytes of `keccak256` of the CAIP-2 names, big-endian (interfaces doc).
    fun the_chain_ids_are_the_caip2_names() {
        assert!(bytes::be_at(&keccak256(b"aptos:1"), 0, 8) == APTOS_MAINNET);
        assert!(bytes::be_at(&keccak256(b"aptos:2"), 0, 8) == APTOS_TESTNET);
    }

    #[test]
    /// A message, as the hub's `VaultMessages.encode` writes it, decodes to its fields; its id and log data are
    /// Solidity's.
    fun a_message_decodes_as_solidity_encodes_it() {
        let payload = f::enc_payload();
        let m = abi::decode_message(&payload);
        assert!(abi::source_chain_id(&m) == 11_155_111 && abi::kind(&m) == 1 && abi::dest_chain_id(&m) == APTOS_TESTNET);
        assert!(abi::vault(&m) == f::hub_vault() && abi::index(&m) == f::hub_index() && abi::nonce(&m) == 7);
        assert!(abi::body(&m) == f::enc_burn_body());
        assert!(abi::message_id(&payload) == f::enc_payload_id());
        assert!(abi::log_data(&payload) == f::enc_log_data());
        // The tests' own encoder writes what Solidity writes.
        let encoded = harness::message(11_155_111, 1, &f::hub_index(), &f::enc_burn_body(), 7, APTOS_TESTNET, &f::hub_vault());
        assert!(encoded == payload);
        assert!(harness::log_data(&payload) == f::enc_log_data());
    }

    #[test]
    /// The real hub's messages decode too: a burn and a migration it sent.
    fun the_hubs_own_messages_decode() {
        let burn = abi::decode_message(&f::burn_payload());
        assert!(abi::kind(&burn) == 1 && abi::index(&burn) == f::hub_index() && abi::vault(&burn) == f::hub_vault());
        assert!(abi::body_word(&abi::body(&burn), 3, 2) == f::burn_recipient());
        let migrate = abi::decode_message(&f::migrate_payload());
        assert!(abi::kind(&migrate) == 4 && abi::to_address(&abi::body_word(&abi::body(&migrate), 3, 0)) == f::migrate_new_index());
    }

    fun with_word(payload: vector<u8>, i: u64, w: vector<u8>): vector<u8> {
        let j = 0;
        while (j < 32) {
            payload[32 * i + j] = w[j];
            j += 1;
        };
        payload
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun another_domain_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 0, bytes::zero32()));
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_kind_past_a_byte_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 2, bytes::word64(257)));
    }

    #[test, expected_failure(abort_code = abi::EOverflow, location = abi)]
    fun a_chain_id_past_64_bits_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 3, bytes::word(1 << 64)));
    }

    #[test, expected_failure(abort_code = abi::EOverflow, location = abi)]
    fun a_nonce_past_64_bits_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 6, bytes::word(1 << 64)));
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun an_index_with_high_bytes_is_refused() {
        let p = f::enc_payload();
        p[5 * 32] = 1;
        abi::decode_message(&p);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun another_body_offset_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 7, bytes::word64(288)));
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_body_longer_than_the_payload_is_refused() {
        abi::decode_message(&with_word(f::enc_payload(), 8, bytes::word64(100_000)));
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_nonzero_pad_is_refused() {
        let p = harness::message(1, 6, &f::hub_index(), &vector[1], 1, 2, &f::hub_vault());
        let last = p.length() - 1;
        p[last] = 1;
        abi::decode_message(&p);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_trailing_word_is_refused() {
        let p = f::enc_payload();
        p.append(bytes::zero32());
        abi::decode_message(&p);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_short_payload_is_refused() {
        let p = f::enc_payload();
        p.pop_back();
        abi::decode_message(&p);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_body_of_another_length_is_refused() {
        abi::body_word(&f::enc_burn_body(), 2, 0);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun a_word_past_the_body_is_refused() {
        abi::body_word(&f::enc_burn_body(), 3, 3);
    }

    #[test, expected_failure(abort_code = abi::EOverflow, location = abi)]
    fun an_amount_past_64_bits_is_refused() {
        abi::amount(&bytes::word(1 << 64));
    }

    #[test]
    fun an_amount_of_64_bits_is_taken() {
        assert!(abi::amount(&bytes::word(0xffffffffffffffff)) == 0xffffffffffffffff);
    }

    #[test, expected_failure(abort_code = abi::EBadMessage, location = abi)]
    fun an_address_word_of_another_length_is_refused() {
        abi::to_address(&bytes::repeat(0, 20));
    }

    #[test]
    /// The digests the hub proves, and the slots it reads them at, as Solidity writes them for this vault's id.
    fun the_digests_and_slots_are_soliditys() {
        let (vault, index, intake) = (f::hub_vault(), f::hub_index(), f::enc_intake_id());
        assert!(abi::index_digest(APTOS_TESTNET, &vault, &index, false, 0, 0) == f::enc_index_digest_empty());
        assert!(abi::index_digest(APTOS_TESTNET, &vault, &index, true, 5_000_000_000, 1250) == f::enc_index_digest());
        assert!(abi::intake_digest(APTOS_TESTNET, &vault, &index, &intake, 1, true, 3_000_000_000) == f::enc_intake_digest_open());
        assert!(abi::intake_digest(APTOS_TESTNET, &vault, &index, &intake, 3, false, 0) == f::enc_intake_digest_none());
        assert!(vault::index_slot(&index) == f::enc_index_slot());
        assert!(vault::intake_slot(&index, &intake) == f::enc_intake_slot());
        assert!(abi::deadline_of(&intake) == 1_800_003_600);
    }

    #[test]
    /// APT's id on Ethereum is the factory's `vaultTokenId(chainId, 0)`: Solidity's, and the real factory's.
    fun the_vault_token_is_the_factorys() {
        assert!(snapshot::vault_token(APTOS_TESTNET) == f::enc_vault_token());
        assert!(snapshot::vault_token(APTOS_TESTNET) == f::hub_apt_token());
    }

    #[test]
    /// An index is the factory's CREATE2 clone of the template: the real factory's two indexes.
    fun an_index_is_the_factorys_clone() {
        assert!(abi::predict_clone(&f::hub_implementation(), &f::hub_salt(), &f::hub_factory()) == f::hub_index());
        assert!(abi::predict_clone(&f::hub_implementation(), &f::migrate_new_salt(), &f::hub_factory()) == f::migrate_new_index());
    }

    #[test]
    /// `attest`'s record is what Solidity's encoder writes for it, and its event's data the record as a byte string.
    fun the_attest_record_is_soliditys() {
        let record = abi::attest_record(APTOS_TESTNET, &f::hub_vault(), f::attest_timestamp_us(), &f::attest_slots(), &f::attest_values());
        assert!(record == f::attest_record());
        assert!(vault::attested_bcs_for_testing(record) == f::attest_event_data());
        let empty = abi::attest_record(APTOS_TESTNET, &f::hub_vault(), 1, &vector[], &vector[]);
        assert!(empty.length() == 8 * 32);
    }

    #[test]
    /// The holder's EIP-712 digest is what it signed with its Ethereum key in the fixture (`cast wallet sign`), under a
    /// domain naming Sepolia, the vault's source chain.
    fun the_claim_digest_is_what_the_holder_signed() {
        let message = snapshot::claim_message(&f::hub_vault(), SEPOLIA, &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
        assert!(keccak256(message) == f::holder_a_digest());
    }

    #[test]
    fun a_slot_past_the_top_wraps() {
        let top = bytes::word(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        assert!(snapshot::add(&top, 1) == bytes::zero32());
        assert!(snapshot::add(&top, 2) == bytes::word64(1));
        assert!(snapshot::add(&bytes::word64(5), 7) == bytes::word64(12));
    }

    // ---------------------------------------------------------------------
    // Bytes
    // ---------------------------------------------------------------------

    #[test]
    fun bytes_read_both_ways() {
        let v = x"0102030405060708090a";
        assert!(bytes::be_at(&v, 0, 2) == 0x0102 && bytes::le_at(&v, 0, 2) == 0x0201);
        assert!(bytes::be_at(&v, 2, 0) == 0 && bytes::le_at(&v, 9, 1) == 10);
        assert!(bytes::slice_eq(&v, 1, 2, &x"0203") && !bytes::slice_eq(&v, 1, 2, &x"0204") && !bytes::slice_eq(&v, 1, 2, &x"02"));
        assert!(bytes::word64(1) == bytes::word(1) && bytes::to_u256(&bytes::word(77)) == 77);
        assert!(bytes::le32(1)[0] == 1 && bytes::is_zero(&vector[]) && !bytes::is_zero(&x"0001"));
        assert!(bytes::address_word(&bytes::repeat(1, 20)) == x"0000000000000000000000000101010101010101010101010101010101010101");
    }

    #[test]
    /// Both ways of slicing give the same bytes: the loop for short slices, the native copy for long ones, each at its
    /// edges; and a comparison either way tells one byte's difference.
    fun slices_agree_both_ways() {
        let v = vector[];
        let i = 0;
        while (i < 5000) {
            v.push_back((((i * 7 + 3) % 256) as u8));
            i += 1;
        };
        let cases = vector[
            vector[0, 0], vector[0, 63], vector[0, 64], vector[10, 64], vector[100, 1000], vector[4000, 1000],
            vector[0, 5000], vector[4999, 1], vector[5000, 0], vector[1, 19], vector[17, 4983],
        ];
        let j = 0;
        while (j < cases.length()) {
            let (s, l) = (cases[j][0], cases[j][1]);
            let a = bytes::slice(&v, s, l);
            assert!(a == v.slice(s, s + l), j);
            assert!(bytes::slice_eq(&v, s, l, &a), j);
            if (l > 0) {
                let b = a;
                b[l - 1] ^= 1;
                assert!(!bytes::slice_eq(&v, s, l, &b), j);
                let c = a;
                c[0] ^= 1;
                assert!(!bytes::slice_eq(&v, s, l, &c), j);
            };
            j += 1;
        };
        // A short string's whole length is copied natively too.
        let w = bytes::repeat(9, 64);
        assert!(bytes::slice(&w, 0, 64) == w && bytes::slice_eq(&w, 0, 64, &w));
    }

    #[test, expected_failure(abort_code = 2, location = bytes)]
    fun bytes_refuse_more_than_eight_be() {
        bytes::be_at(&bytes::zero32(), 0, 9);
    }

    #[test, expected_failure(abort_code = 2, location = bytes)]
    fun bytes_refuse_more_than_eight_le() {
        bytes::le_at(&bytes::zero32(), 0, 9);
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_read_past_the_end() {
        bytes::slice(&bytes::zero32(), 30, 3);
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_word_past_the_end() {
        bytes::u256_at(&bytes::zero32(), 1);
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_short_word() {
        bytes::to_u256(&bytes::repeat(0, 31));
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_short_address() {
        bytes::address_word(&bytes::repeat(0, 19));
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_comparison_past_the_end() {
        bytes::slice_eq(&bytes::zero32(), 31, 2, &x"0000");
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_be_read_past_the_end() {
        bytes::be_at(&x"01", 0, 2);
    }

    #[test, expected_failure(abort_code = 1, location = bytes)]
    fun bytes_refuse_a_le_read_past_the_end() {
        bytes::le_at(&x"01", 0, 2);
    }

    // ---------------------------------------------------------------------
    // C1-02: every kind's body, as Solidity writes it
    // ---------------------------------------------------------------------

    /// `test/fixtures/vault-messages.json`: `VaultMessages.encode`'s payload for each kind but a burn, which
    /// `test/VaultMessages.fixture.t.sol` pins against Solidity, copied here since Move tests read no files. They are
    /// sent to chain 56 and another vault, so they test the decoder, not a delivery.
    const C102_INTAKE_SETTLED: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000006b49d200000000000000000000000000000000000000000000000007";

    const C102_INTAKE_FAILED: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000006b49d200000000000000000000000000000000000000000000000007";

    const C102_MIGRATE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a00000000000000000000000011111111111111111111111111111111111111110000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000600000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075bcd15";

    const C102_CAP_UPDATE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b1ae4d6e2ef50000000000000000000000000000000000000000000000000000006f05b59d3b20000";

    const C102_FREEZE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000006b49d200";

    const C102_FREEZER_CHANGE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7";

    const C102_VERIFIER_ROTATION: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1000000000000000000000000b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

    /// One fixture payload decoded with the vault's own decoder: its head is what the fixture was written from, and its
    /// id the fixture's.
    fun c102(payload: vector<u8>, kind: u8, nonce: u64, id: vector<u8>): vector<u8> {
        let m = abi::decode_message(&payload);
        assert!(abi::source_chain_id(&m) == 1 && abi::kind(&m) == kind && abi::dest_chain_id(&m) == 56);
        assert!(abi::nonce(&m) == nonce);
        assert!(abi::vault(&m) == x"000000000000000000000000a11ce00000000000000000000000000000000a0a");
        assert!(abi::index(&m) == x"1111111111111111111111111111111111111111");
        assert!(abi::message_id(&payload) == id);
        abi::body(&m)
    }

    #[test]
    /// C1-02: each kind's body decodes, word by word where the vault reads it, to the fields Solidity encoded: a vault
    /// and its tests cannot agree on a layout the hub and the factory do not write.
    fun test_c102_the_message_bodies_are_soliditys() {
        // INTAKE_SETTLED and INTAKE_FAILED: the intake id, its deadline (1,800,000,000) in the top 64 bits, then 7.
        let intake = harness::intake_id(1_800_000_000, 7);
        let body = c102(C102_INTAKE_SETTLED, 2, 1, x"eeafa2f01a3dcd76d7d49a1a2478eb53f92af4709ebdb619acdfc3dde68b66ea");
        assert!(abi::body_word(&body, 1, 0) == intake && abi::deadline_of(&intake) == 1_800_000_000);
        let body = c102(C102_INTAKE_FAILED, 3, 2, x"9fc61ee68b1b673ce066aa0fbfcec02dbb395dd966c9712c5090fbf2440564b8");
        assert!(abi::body_word(&body, 1, 0) == intake);
        // MIGRATE: the new index, the native coin, the amount.
        let body = c102(C102_MIGRATE, 4, 3, x"7a5f421ed77e3410e9a5494c7e8694506ccb4ee9b7c9848c3519865c77770d8c");
        assert!(abi::to_address(&abi::body_word(&body, 3, 0)) == x"2222222222222222222222222222222222222222");
        assert!(bytes::is_zero(&abi::body_word(&body, 3, 1)));
        assert!(abi::amount(&abi::body_word(&body, 3, 2)) == 123_456_789);
        // CAP_UPDATE: the native coin, the cap (500e18, past 64 bits, so `u64::MAX` here), the floor (0.5e18).
        let body = c102(C102_CAP_UPDATE, 5, 4, x"a410b5de5307757c5f740fc4be9024093219a8540edbe09b623fcfc728aaac9c");
        assert!(bytes::is_zero(&abi::body_word(&body, 3, 0)));
        assert!(bytes::to_u256(&abi::body_word(&body, 3, 1)) == 500_000_000_000_000_000_000);
        assert!(abi::saturating(&abi::body_word(&body, 3, 1)) == 0xffffffffffffffff);
        assert!(abi::saturating(&abi::body_word(&body, 3, 2)) == 500_000_000_000_000_000);
        // FREEZE: one word, when the factory's freeze ends.
        let body = c102(C102_FREEZE, 6, 5, x"ecb9a982bf120b2944986dcd717703a81bb1f102c6cd9059850b36d67e218b9f");
        assert!(body.length() == 32 && abi::saturating(&body) == 1_800_000_000);
        // FREEZER_CHANGE: the new freezer, a 32-byte address.
        let body = c102(C102_FREEZER_CHANGE, 7, 6, x"c2b7c9b2a08bff609bb2f1ec53d893c6c9b5814fbf67570a9b0c2184179cf416");
        assert!(abi::body_word(&body, 1, 0) == x"000000000000000000000000f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7");
        // VERIFIER_ROTATION: P1, then P2.
        let body = c102(C102_VERIFIER_ROTATION, 8, 7, x"a1596867365f7557326b154af37d743c75a56d90ebbfa02d4ef95c0d1564d40d");
        assert!(abi::body_word(&body, 2, 0) == x"000000000000000000000000b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1");
        assert!(abi::body_word(&body, 2, 1) == x"000000000000000000000000b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2");
    }

    // ---------------------------------------------------------------------
    // RLP and the hex-prefix paths
    // ---------------------------------------------------------------------

    #[test]
    fun rlp_reads_every_form() {
        let b = vector[0x05];
        let i = rlp::to_item(&b, 0, 1);
        assert!(!rlp::is_list(&i) && rlp::start(&i) == 0 && rlp::len(&i) == 1);
        let b = vector[0x82, 1, 2];
        assert!(rlp::bytes(&b, &rlp::to_item(&b, 0, 3)) == vector[1, 2]);
        let long = vector[0xb8, 56];
        long.append(bytes::repeat(7, 56));
        assert!(rlp::len(&rlp::to_item(&long, 0, long.length())) == 56);
        let list = vector[0xc3, 0x01, 0x81, 0x80];
        let item = rlp::to_item(&list, 0, 4);
        assert!(rlp::count(&list, &item) == 2);
        assert!(rlp::uint(&list, &rlp::at(&list, &item, 0)) == 1);
        assert!(rlp::uint(&list, &rlp::at(&list, &item, 1)) == 0x80);
        let long_list = vector[0xf8, 56];
        long_list.append(bytes::repeat(1, 56));
        assert!(rlp::count(&long_list, &rlp::to_item(&long_list, 0, long_list.length())) == 56);
        let empty = vector[0xc0];
        assert!(rlp::count(&empty, &rlp::to_item(&empty, 0, 1)) == 0);
        let zero = vector[0x80];
        assert!(rlp::uint(&zero, &rlp::to_item(&zero, 0, 1)) == 0);
        assert!(rlp::is_empty_string(&rlp::to_item(&zero, 0, 1)));
        // Leading zeros past 64 bits are allowed, as RlpReader's toUint allows them.
        let padded = vector[0x89, 0];
        padded.append(bytes::repeat(0xff, 8));
        assert!(rlp::uint(&padded, &rlp::to_item(&padded, 0, 10)) == 0xffffffffffffffff);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_the_empty() {
        rlp::to_item(&vector[], 0, 0);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_an_item_past_the_buffer() {
        rlp::to_item(&vector[0x01], 0, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_string_past_its_end() {
        let b = vector[0x82, 1];
        rlp::to_item(&b, 0, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_long_length_past_its_end() {
        let b = vector[0xb9, 0x01];
        rlp::to_item(&b, 0, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_long_list_length_past_its_end() {
        let b = vector[0xf9, 0x01];
        rlp::to_item(&b, 0, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_an_item_past_its_list() {
        let b = vector[0xc2, 0x82, 1];
        let i = rlp::to_item(&b, 0, 3);
        rlp::count(&b, &i);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_the_item_past_the_last() {
        let b = vector[0xc3, 0x01, 0x81, 0x80];
        let i = rlp::to_item(&b, 0, 4);
        rlp::at(&b, &i, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_trailing_bytes() {
        let b = vector[0x01, 0x02];
        rlp::to_item(&b, 0, 2);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_huge_length() {
        let b = vector[0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
        rlp::to_item(&b, 0, 9);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_a_string_is_no_list() {
        let b = vector[0x81, 0x01];
        rlp::count(&b, &rlp::to_item(&b, 0, 2));
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_a_string_has_no_items() {
        let b = vector[0x81, 0x01];
        rlp::at(&b, &rlp::to_item(&b, 0, 2), 0);
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_a_list_is_no_string() {
        let b = vector[0xc0];
        rlp::bytes(&b, &rlp::to_item(&b, 0, 1));
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_short_bytes32() {
        let b = vector[0x82, 1, 2];
        rlp::bytes32(&b, &rlp::to_item(&b, 0, 3));
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_uint_past_64_bits() {
        let b = vector[0x89];
        b.append(bytes::repeat(1, 9));
        rlp::uint(&b, &rlp::to_item(&b, 0, 10));
    }

    #[test, expected_failure(abort_code = rlp::EBadRlp, location = rlp)]
    fun rlp_refuses_a_uint_past_32_bytes() {
        let b = vector[0xa1];
        b.append(bytes::repeat(0, 33));
        rlp::uint(&b, &rlp::to_item(&b, 0, 34));
    }

    #[test]
    fun receipt_keys_are_rlp_of_the_index() {
        let (k, n) = mpt::receipt_key(0);
        assert!(k == vector[0x80] && n == 2);
        let (k, n) = mpt::receipt_key(0x7f);
        assert!(k == vector[0x7f] && n == 2);
        let (k, n) = mpt::receipt_key(130);
        assert!(k == vector[0x81, 130] && n == 4);
        let (k, n) = mpt::receipt_key(0x1234);
        assert!(k == vector[0x82, 0x12, 0x34] && n == 6);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun receipt_keys_stop_at_two_bytes() {
        mpt::receipt_key(0x10000);
    }

    #[test]
    fun hex_prefix_paths() {
        let key = vector[0x12, 0x34];
        let (l, leaf, m) = mpt::test_match_path(vector[0x20, 0x12, 0x34], key, 0, 4);
        assert!(l == 4 && leaf && m);
        let (l, leaf, m) = mpt::test_match_path(vector[0x31, 0x23], key, 0, 3);
        assert!(l == 3 && leaf && m);
        let (l, leaf, m) = mpt::test_match_path(vector[0x13, 0x4f], key, 1, 4);
        assert!(l == 3 && !leaf && !m);
        let (l, leaf, m) = mpt::test_match_path(vector[0x00, 0x12], key, 0, 4);
        assert!(l == 2 && !leaf && m);
        let (l, leaf, m) = mpt::test_match_path(vector[0x00, 0x13], key, 0, 4);
        assert!(l == 2 && !leaf && !m);
        let (l, leaf, m) = mpt::test_match_path(vector[0x20], key, 4, 4);
        assert!(l == 0 && leaf && m);
        // A path longer than what is left of the key parts from it.
        let (l, _, m) = mpt::test_match_path(vector[0x20, 0x12, 0x34], key, 1, 4);
        assert!(l == 4 && !m);
    }

    /// A tiny trie of key 0x1234 = 0x07: an extension over nibbles 1 and 2, a branch, and at its child 3 a leaf of the
    /// last nibble, short enough to lie embedded in the branch. The proof is the node list of the extension and the
    /// branch.
    fun tiny_trie(): (vector<u8>, vector<u8>) {
        let leaf = vector[0xc2, 0x34, 0x07];
        let branch_items = vector[];
        let i = 0u64;
        while (i < 17) {
            branch_items.append(if (i == 3) leaf else vector[0x80]);
            i += 1;
        };
        let branch = vector[0xc0 + (branch_items.length() as u8)];
        branch.append(branch_items);
        let ext = vector[0xe4, 0x82, 0x00, 0x12, 0xa0];
        ext.append(keccak256(branch));
        let root = keccak256(ext);
        let buf = vector[2];
        buf.append(vector[(ext.length() as u8), 0, 0, 0]);
        buf.append(ext);
        buf.append(vector[(branch.length() as u8), 0, 0, 0]);
        buf.append(branch);
        (buf, root)
    }

    fun tiny_get(key: vector<u8>): Option<rlp::Item> {
        let (buf, root) = tiny_trie();
        let (nodes, end) = mpt::read_nodes(&buf, 0);
        assert!(end == buf.length());
        mpt::get(&buf, &nodes, &root, &key, 4)
    }

    #[test]
    /// An extension, a branch and an embedded leaf: the value is found; a key that parts from the extension, from the
    /// branch's children, or from the leaf's path is shown absent.
    fun an_embedded_leaf_under_an_extension() {
        let (buf, _) = tiny_trie();
        let found = tiny_get(vector[0x12, 0x34]);
        assert!(rlp::uint(&buf, &found.destroy_some()) == 7);
        assert!(tiny_get(vector[0x13, 0x34]).is_none());
        assert!(tiny_get(vector[0x12, 0x44]).is_none());
        assert!(tiny_get(vector[0x12, 0x35]).is_none());
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_missing_from_the_proof_is_refused() {
        let (buf, root) = tiny_trie();
        let (nodes, _) = mpt::read_nodes(&buf, 0);
        mpt::drop_last(&mut nodes);
        mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 4);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_key_ending_inside_the_trie_is_refused() {
        let (buf, root) = tiny_trie();
        let (nodes, _) = mpt::read_nodes(&buf, 0);
        mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 2);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_key_longer_than_its_bytes_is_refused() {
        let (buf, root) = tiny_trie();
        let (nodes, _) = mpt::read_nodes(&buf, 0);
        mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 5);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_of_neither_kind_is_refused() {
        // A list of three items is neither a branch nor a short node.
        let node = vector[0xc3, 0x01, 0x02, 0x03];
        let buf = vector[1, 4, 0, 0, 0];
        buf.append(node);
        let (nodes, _) = mpt::read_nodes(&buf, 0);
        mpt::get(&buf, &nodes, &keccak256(node), &vector[0x12], 2);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_list_past_its_end_is_refused() {
        let (buf, _) = tiny_trie();
        buf.pop_back();
        mpt::read_nodes(&buf, 0);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_list_without_its_count_is_refused() {
        mpt::read_nodes(&vector[], 0);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun a_node_list_cut_inside_a_length_is_refused() {
        mpt::read_nodes(&vector[1, 4, 0], 0);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun no_such_flag() {
        mpt::test_match_path(vector[0x40], vector[0x12, 0x34], 0, 4);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun an_even_paths_pad_is_zero() {
        mpt::test_match_path(vector[0x21], vector[0x12, 0x34], 0, 4);
    }

    #[test, expected_failure(abort_code = mpt::EBadProof, location = mpt)]
    fun an_empty_path_is_refused() {
        mpt::test_match_path(vector[], vector[0x12, 0x34], 0, 4);
    }
}
