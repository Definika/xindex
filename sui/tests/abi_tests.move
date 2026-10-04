/// Every encoding the vault reads or writes, pinned against Solidity's own encoder (`cast abi-encode` and `cast keccak`,
/// in `fixtures`) and against the real hub's factory; and RLP and the hex-prefix paths, as the core's unit tests check
/// them.
#[test_only]
module xindex_vault::abi_tests;

use sui::hash::keccak256;
use xindex_vault::abi;
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::harness;
use xindex_vault::mpt;
use xindex_vault::rlp;
use xindex_vault::snapshot;
use xindex_vault::vault;

const SUI_TESTNET: u64 = 10_803_649_406_359_875_205;
const SEPOLIA: u64 = 11_155_111;

#[test]
fun the_domains_are_their_hashes() {
    assert!(abi::event_topic() == keccak256(&b"VaultMessage(bytes32,bytes)"));
    let payload = f::enc_payload();
    assert!(bytes::slice(&payload, 0, 32) == keccak256(&b"xindex.v4.vault-message"));
    let mut pre = keccak256(&b"xindex.v4.vault-attest");
    pre.append(bytes::word64(SUI_TESTNET));
    let record = f::attest_record();
    assert!(bytes::slice(&record, 0, 64) == pre);
}

/// A message, as the hub's `VaultMessages.encode` writes it, decodes to its fields; its id and log data are Solidity's.
#[test]
fun a_message_decodes_as_solidity_encodes_it() {
    let payload = f::enc_payload();
    let m = abi::decode_message(&payload);
    assert!(m.source_chain_id() == 11_155_111 && m.kind() == 1 && m.dest_chain_id() == SUI_TESTNET);
    assert!(m.vault() == f::hub_vault() && m.index() == f::hub_index() && m.nonce() == 7);
    assert!(m.body() == f::enc_burn_body());
    assert!(abi::message_id(&payload) == f::enc_payload_id());
    assert!(abi::log_data(&payload) == f::enc_log_data());
    // The tests' own encoder writes what Solidity writes.
    let encoded = harness::message(11_155_111, 1, &f::hub_index(), &f::enc_burn_body(), 7, SUI_TESTNET, &f::hub_vault());
    assert!(encoded == payload);
    assert!(harness::log_data(&payload) == f::enc_log_data());
}

/// The real hub's messages decode too: a burn and a migration it sent.
#[test]
fun the_hubs_own_messages_decode() {
    let burn = abi::decode_message(&f::burn_payload());
    assert!(burn.kind() == 1 && burn.index() == f::hub_index() && burn.vault() == f::hub_vault());
    assert!(abi::body_word(&burn.body(), 3, 2) == f::burn_recipient());
    let migrate = abi::decode_message(&f::migrate_payload());
    assert!(migrate.kind() == 4 && abi::to_address(&abi::body_word(&migrate.body(), 3, 0)) == f::migrate_new_index());
}

fun with_word(payload: vector<u8>, i: u64, w: vector<u8>): vector<u8> {
    let mut p = payload;
    let mut j = 0;
    while (j < 32) {
        *&mut p[32 * i + j] = w[j];
        j = j + 1;
    };
    p
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun another_domain_is_refused() {
    abi::decode_message(&with_word(f::enc_payload(), 0, bytes::zero32()));
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_kind_past_a_byte_is_refused() {
    abi::decode_message(&with_word(f::enc_payload(), 2, bytes::word64(257)));
}

#[test, expected_failure(abort_code = abi::EOverflow)]
fun a_chain_id_past_64_bits_is_refused() {
    abi::decode_message(&with_word(f::enc_payload(), 3, bytes::word(1 << 64)));
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun an_index_with_high_bytes_is_refused() {
    let mut p = f::enc_payload();
    *&mut p[5 * 32] = 1;
    abi::decode_message(&p);
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun another_body_offset_is_refused() {
    abi::decode_message(&with_word(f::enc_payload(), 7, bytes::word64(288)));
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_nonzero_pad_is_refused() {
    let m = harness::message(1, 6, &f::hub_index(), &vector[1], 1, 2, &f::hub_vault());
    let mut p = m;
    let last = p.length() - 1;
    *&mut p[last] = 1;
    abi::decode_message(&p);
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_trailing_word_is_refused() {
    let mut p = f::enc_payload();
    p.append(bytes::zero32());
    abi::decode_message(&p);
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_short_payload_is_refused() {
    let mut p = f::enc_payload();
    p.pop_back();
    abi::decode_message(&p);
}

#[test, expected_failure(abort_code = abi::EBadMessage)]
fun a_body_of_another_length_is_refused() {
    abi::body_word(&f::enc_burn_body(), 2, 0);
}

#[test, expected_failure(abort_code = abi::EOverflow)]
fun an_amount_past_64_bits_is_refused() {
    abi::amount(&bytes::word(1 << 64));
}

#[test]
fun an_amount_of_64_bits_is_taken() {
    assert!(abi::amount(&bytes::word(0xffffffffffffffff)) == 0xffffffffffffffff);
}

/// The digests the hub proves, and the slots it reads them at, as Solidity writes them for this vault's id.
#[test]
fun the_digests_and_slots_are_soliditys() {
    let (vault, index, intake) = (f::hub_vault(), f::hub_index(), f::enc_intake_id());
    assert!(abi::index_digest(SUI_TESTNET, &vault, &index, false, 0, 0) == f::enc_index_digest_empty());
    assert!(abi::index_digest(SUI_TESTNET, &vault, &index, true, 5_000_000_000, 1250) == f::enc_index_digest());
    assert!(abi::intake_digest(SUI_TESTNET, &vault, &index, &intake, 1, true, 3_000_000_000) == f::enc_intake_digest_open());
    assert!(abi::intake_digest(SUI_TESTNET, &vault, &index, &intake, 3, false, 0) == f::enc_intake_digest_none());
    assert!(vault::index_slot(&index) == f::enc_index_slot());
    assert!(vault::intake_slot(&index, &intake) == f::enc_intake_slot());
    assert!(abi::deadline_of(&intake) == 1_800_003_600);
}

/// SUI's id on Ethereum is the factory's `vaultTokenId(chainId, 0)`: Solidity's, and the real factory's.
#[test]
fun the_vault_token_is_the_factorys() {
    assert!(snapshot::vault_token(SUI_TESTNET) == f::enc_vault_token());
    assert!(snapshot::vault_token(SUI_TESTNET) == f::hub_sui_token());
}

/// An index is the factory's CREATE2 clone of the template: the real factory's two indexes.
#[test]
fun an_index_is_the_factorys_clone() {
    assert!(abi::predict_clone(&f::hub_implementation(), &f::hub_salt(), &f::hub_factory()) == f::hub_index());
    assert!(abi::predict_clone(&f::hub_implementation(), &f::migrate_new_salt(), &f::hub_factory()) == f::migrate_new_index());
}

/// `attest`'s record is `SuiStateVerifier.attestRecord`'s, as Solidity's encoder writes it.
#[test]
fun the_attest_record_is_soliditys() {
    let record = abi::attest_record(SUI_TESTNET, &f::hub_vault(), f::attest_timestamp_ms(), &f::attest_slots(), &f::attest_values());
    assert!(record == f::attest_record());
    let empty = abi::attest_record(SUI_TESTNET, &f::hub_vault(), 1, &vector[], &vector[]);
    assert!(empty.length() == 8 * 32);
}

/// The holder's EIP-712 digest is what it signed with its Ethereum key in the fixture (`cast wallet sign`), under a
/// domain naming Sepolia, the vault's source chain.
#[test]
fun the_claim_digest_is_what_the_holder_signed() {
    let message = snapshot::claim_message(&f::hub_vault(), SEPOLIA, &f::hub_index(), &f::holder_a(), &f::holder_a_recipient());
    assert!(keccak256(&message) == f::holder_a_digest());
}

#[test]
fun a_slot_past_the_top_wraps() {
    let top = bytes::word(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    assert!(snapshot::add(&top, 1) == bytes::zero32());
    assert!(snapshot::add(&top, 2) == bytes::word64(1));
    assert!(snapshot::add(&bytes::word64(5), 7) == bytes::word64(12));
}

// ---------------------------------------------------------------------
// C1-02: every kind's body, as Solidity writes it
// ---------------------------------------------------------------------

/// `test/fixtures/vault-messages.json`: `VaultMessages.encode`'s payload for each kind but a burn, which
/// `test/VaultMessages.fixture.t.sol` pins against Solidity, copied here since Move tests read no files. They are sent
/// to chain 56 and another vault, so they test the decoder, not a delivery.
const C102_INTAKE_SETTLED: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000006b49d200000000000000000000000000000000000000000000000007";

const C102_INTAKE_FAILED: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000006b49d200000000000000000000000000000000000000000000000007";

const C102_MIGRATE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a00000000000000000000000011111111111111111111111111111111111111110000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000600000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000075bcd15";

const C102_CAP_UPDATE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b1ae4d6e2ef50000000000000000000000000000000000000000000000000000006f05b59d3b20000";

const C102_FREEZE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000006b49d200";

const C102_FREEZER_CHANGE: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7";

const C102_VERIFIER_ROTATION: vector<u8> = x"bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000038000000000000000000000000a11ce00000000000000000000000000000000a0a0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1000000000000000000000000b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

/// One fixture payload decoded with the vault's own decoder: its head is what the fixture was written from, and its id
/// the fixture's.
fun c102(payload: vector<u8>, kind: u8, nonce: u64, id: vector<u8>): vector<u8> {
    let m = abi::decode_message(&payload);
    assert!(m.source_chain_id() == 1 && m.kind() == kind && m.dest_chain_id() == 56 && m.nonce() == nonce);
    assert!(m.vault() == x"000000000000000000000000a11ce00000000000000000000000000000000a0a");
    assert!(m.index() == x"1111111111111111111111111111111111111111");
    assert!(abi::message_id(&payload) == id);
    m.body()
}

/// C1-02: each kind's body decodes, word by word where the vault reads it, to the fields Solidity encoded: a vault and
/// its tests cannot agree on a layout the hub and the factory do not write.
#[test]
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
    assert!(!i.is_list() && i.start() == 0 && i.len() == 1);
    let b = vector[0x82, 1, 2];
    assert!(rlp::bytes(&b, &rlp::to_item(&b, 0, 3)) == vector[1, 2]);
    let mut long = vector[0xb8, 56];
    long.append(vector::tabulate!(56, |_| 7u8));
    assert!(rlp::to_item(&long, 0, long.length()).len() == 56);
    let list = vector[0xc3, 0x01, 0x81, 0x80];
    let item = rlp::to_item(&list, 0, 4);
    assert!(rlp::count(&list, &item) == 2);
    assert!(rlp::uint(&list, &rlp::at(&list, &item, 0)) == 1);
    assert!(rlp::uint(&list, &rlp::at(&list, &item, 1)) == 0x80);
    let mut long_list = vector[0xf8, 56];
    long_list.append(vector::tabulate!(56, |_| 1u8));
    assert!(rlp::count(&long_list, &rlp::to_item(&long_list, 0, long_list.length())) == 56);
    let empty = vector[0xc0];
    assert!(rlp::count(&empty, &rlp::to_item(&empty, 0, 1)) == 0);
    let zero = vector[0x80];
    assert!(rlp::uint(&zero, &rlp::to_item(&zero, 0, 1)) == 0);
    // Leading zeros past 64 bits are allowed, as RlpReader's toUint allows them.
    let mut padded = vector[0x89, 0];
    padded.append(vector::tabulate!(8, |_| 0xffu8));
    assert!(rlp::uint(&padded, &rlp::to_item(&padded, 0, 10)) == 0xffffffffffffffff);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_the_empty() {
    rlp::to_item(&vector[], 0, 0);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_string_past_its_end() {
    let b = vector[0x82, 1];
    rlp::to_item(&b, 0, 2);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_long_length_past_its_end() {
    let b = vector[0xb9, 0x01];
    rlp::to_item(&b, 0, 2);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_an_item_past_its_list() {
    let b = vector[0xc2, 0x82, 1];
    let i = rlp::to_item(&b, 0, 3);
    rlp::count(&b, &i);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_the_item_past_the_last() {
    let b = vector[0xc3, 0x01, 0x81, 0x80];
    let i = rlp::to_item(&b, 0, 4);
    rlp::at(&b, &i, 2);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_trailing_bytes() {
    let b = vector[0x01, 0x02];
    rlp::to_item(&b, 0, 2);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_huge_length() {
    let b = vector[0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    rlp::to_item(&b, 0, 9);
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_a_string_is_no_list() {
    let b = vector[0x81, 0x01];
    rlp::count(&b, &rlp::to_item(&b, 0, 2));
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_a_list_is_no_string() {
    let b = vector[0xc0];
    rlp::bytes(&b, &rlp::to_item(&b, 0, 1));
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_short_bytes32() {
    let b = vector[0x82, 1, 2];
    rlp::bytes32(&b, &rlp::to_item(&b, 0, 3));
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_uint_past_64_bits() {
    let mut b = vector[0x89];
    b.append(vector::tabulate!(9, |_| 1u8));
    rlp::uint(&b, &rlp::to_item(&b, 0, 10));
}

#[test, expected_failure(abort_code = rlp::EBadRlp)]
fun rlp_refuses_a_uint_past_32_bytes() {
    let mut b = vector[0xa1];
    b.append(vector::tabulate!(33, |_| 0u8));
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

#[test, expected_failure(abort_code = mpt::EBadProof)]
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
}

/// A tiny trie of key 0x1234 = 0x07: an extension over nibbles 1 and 2, a branch, and at its child 3 a leaf of the
/// last nibble, short enough to lie embedded in the branch. The proof is the node list of the extension and the branch.
fun tiny_trie(): (vector<u8>, vector<u8>) {
    let leaf = vector[0xc2, 0x34, 0x07];
    let mut branch_items = vector[];
    let mut i = 0u64;
    while (i < 17) {
        branch_items.append(if (i == 3) leaf else vector[0x80]);
        i = i + 1;
    };
    let mut branch = vector[0xc0 + (branch_items.length() as u8)];
    branch.append(branch_items);
    let mut ext = vector[0xe4, 0x82, 0x00, 0x12, 0xa0];
    ext.append(keccak256(&branch));
    let root = keccak256(&ext);
    let mut buf = vector[2];
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

/// An extension, a branch and an embedded leaf: the value is found; a key that parts from the extension, from the
/// branch's children, or from the leaf's path is shown absent.
#[test]
fun an_embedded_leaf_under_an_extension() {
    let (buf, _) = tiny_trie();
    let found = tiny_get(vector[0x12, 0x34]);
    assert!(rlp::uint(&buf, &found.destroy_some()) == 7);
    assert!(tiny_get(vector[0x13, 0x34]).is_none());
    assert!(tiny_get(vector[0x12, 0x44]).is_none());
    assert!(tiny_get(vector[0x12, 0x35]).is_none());
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_node_missing_from_the_proof_is_refused() {
    let (buf, root) = tiny_trie();
    let (mut nodes, _) = mpt::read_nodes(&buf, 0);
    nodes.pop_back();
    mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 4);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_key_ending_inside_the_trie_is_refused() {
    let (buf, root) = tiny_trie();
    let (nodes, _) = mpt::read_nodes(&buf, 0);
    mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 2);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_key_longer_than_its_bytes_is_refused() {
    let (buf, root) = tiny_trie();
    let (nodes, _) = mpt::read_nodes(&buf, 0);
    mpt::get(&buf, &nodes, &root, &vector[0x12, 0x34], 5);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun a_node_list_past_its_end_is_refused() {
    let (mut buf, _) = tiny_trie();
    buf.pop_back();
    mpt::read_nodes(&buf, 0);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun no_such_flag() {
    mpt::test_match_path(vector[0x40], vector[0x12, 0x34], 0, 4);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun an_even_paths_pad_is_zero() {
    mpt::test_match_path(vector[0x21], vector[0x12, 0x34], 0, 4);
}

#[test, expected_failure(abort_code = mpt::EBadProof)]
fun an_empty_path_is_refused() {
    mpt::test_match_path(vector[], vector[0x12, 0x34], 0, 4);
}
