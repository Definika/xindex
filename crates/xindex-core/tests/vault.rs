//! The vault's shared rules against Ethereum's own encodings: the message format and digests against `cast
//! abi-encode`, and the snapshot's reads, slots, EIP-712 digest and signature against a real hub's storage
//! (`solana/programs/xindex-vault/tests/fixtures/hub.json`, which `generate.py` there captures from the repository's
//! own hub on anvil); plus the speed limit and the checkpoint rules.

mod common;

use common::*;
use serde_json::Value;
use xindex_core::abi::*;
use xindex_core::checkpoint::{self, Checkpoint};
use xindex_core::constants::*;
use xindex_core::crypto::Crypto;
use xindex_core::snapshot::{self, SnapshotError};
use xindex_core::state_reader::{read_slots, BadStateProof};
use xindex_core::{hex, speed};

const VAULT: &str = "1111111111111111111111111111111111111111";
const INDEX: &str = "2222222222222222222222222222222222222222";

fn h20s(s: &str) -> [u8; 20] {
    hex(s).try_into().unwrap()
}

fn h32s(s: &str) -> [u8; 32] {
    hex(s).try_into().unwrap()
}

#[test]
fn the_constants_are_their_hashes() {
    let k = |s: &[u8]| C.keccak256(&[s]);
    assert_eq!(k(b"xindex.v4.vault-message"), DOMAIN);
    assert_eq!(k(b"VaultMessage(bytes32,bytes)"), EVENT_TOPIC);
    assert_eq!(k(b"xindex.v4.vault.index-digest"), INDEX_DIGEST_DOMAIN);
    assert_eq!(k(b"xindex.v4.vault.intake-digest"), INTAKE_DIGEST_DOMAIN);
    assert_eq!(k(b"xindex.v4.vault-token"), VAULT_TOKEN_DOMAIN);
    assert_eq!(
        k(b"EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)"),
        EIP712_DOMAIN_TYPEHASH
    );
    assert_eq!(
        k(b"SnapshotClaim(address index,address holder,bytes32 recipient)"),
        SNAPSHOT_CLAIM_TYPEHASH
    );
    assert_eq!(k(b"Xindex vault"), EIP712_NAME_HASH);
    assert_eq!(k(b"1"), EIP712_VERSION_HASH);
}

/// Against `cast abi-encode` of the same arguments, then `cast keccak`.
#[test]
fn digests_match_solidity() {
    // An EVM vault's id is its address as a word, which encodes exactly as the address did.
    let (v, i) = (address_word(&h20s(VAULT)), h20s(INDEX));
    assert_eq!(
        index_digest(&C, 900, &v, &i, true, 5000, 70),
        h32s("28f9869e4f8936341babb928cb7b6888fba387b81c11825a1781134c8ee69a4a")
    );
    assert_eq!(
        index_digest(&C, 900, &v, &i, false, 0, 0),
        h32s("38135e9824ef7b5dd023173ff6c58dc1a539c4e73da45a2f981d3590a02569d2")
    );
    let id = h32s("0000000066000000000000000000000000000000000000000000000000000007");
    assert_eq!(
        intake_digest(&C, 900, &v, &i, &id, 1, true, 1_400_000_000),
        h32s("0afe82d8eca28b59179df3c684949af67c44cf3ab186628d6c07690fd1e13cce")
    );
    assert_eq!(
        intake_digest(&C, 900, &v, &i, &id, 2, false, 0),
        h32s("6a4afe70fb1fde2003ca24af9451d14d8657374390fae92bad4e6a8ae513653d")
    );
    // A vault whose id is a whole 32-byte key, as Solana's.
    let v = h32s("9f1cb2a7e3c34a8d1e6f0b5a2c7d9e1f3a5b7c9d0e2f4a6b8c0d1e3f5a7b9c1d");
    assert_eq!(
        index_digest(&C, 900, &v, &i, true, 5000, 70),
        h32s("c0727678a1e5c7216f562387517c5901ba76884e63cd6a4d93cdf8b4b7a06d84")
    );
    assert_eq!(
        intake_digest(&C, 900, &v, &i, &id, 1, true, 1_400_000_000),
        h32s("f22a0990b2764e04aa005e7e4e73010f37e17fbe990e3552aaa4e143c7457f75")
    );
    assert_eq!(deadline_of(&id), 0x66000000);
}

/// Against `cast compute-address` over the EIP-1167 creation code.
#[test]
fn the_clone_address_is_create2s() {
    let got = predict_clone(
        &C,
        &h20s("3333333333333333333333333333333333333333"),
        &h32s("5555555555555555555555555555555555555555555555555555555555555555"),
        &h20s("4444444444444444444444444444444444444444"),
    );
    assert_eq!(got, h20s("c93ae4f4ad09ddf3f73bb4591134b372268e1138"));
}

const BURN_PAYLOAD: &str = "bd3cf7d103abd331f0285cc3baa9b84878b3a414fec18667ce7824a74f7004a00000000000000000000000000000000000000000000000000000000000aa36a7000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003849999999999999999999999999999999999999999999999999999999999999999000000000000000000000000222222222222222222222222222222222222222200000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000053724e007777777777777777777777777777777777777777777777777777777777777777";

#[test]
fn a_burn_decodes() {
    let p = hex(BURN_PAYLOAD);
    let m = decode_message(&p).unwrap();
    assert_eq!(m.source_chain_id, 11_155_111);
    assert_eq!(m.kind, BURN);
    assert_eq!(m.dest_chain_id, 900);
    assert_eq!(m.vault, [0x99; 32]);
    assert_eq!(m.index, h20s(INDEX));
    assert_eq!(
        to_u64(body_word(m.body, 3, 1).unwrap()).unwrap(),
        1_400_000_000
    );
    assert_eq!(*body_word(m.body, 3, 2).unwrap(), [0x77; 32]);
    assert_eq!(
        message_id(&C, &p),
        h32s("d96d23eda6686b98ba93d99e2b34ca449fb421958b59a98ec94043eba68b3aac")
    );
    assert_eq!(index_in(&p), h20s(INDEX));
    assert_eq!(body_word_in(&p, 2), [0x77; 32]);
    assert_eq!(address_in_body(&p, 2), [0x77; 20]);
    assert_eq!(index_in(&p[..100]), [0u8; 20]);
    assert_eq!(body_word_in(&p[..300], 0), [0u8; 32]);
    assert_eq!(
        log_data_hash(&C, &p),
        h32s("b8d83ce716606d07066b4090f8ecf185878a751d0c2cdee3238b1cece2b39591")
    );
}

#[test]
fn only_the_canonical_encoding_decodes() {
    let p = hex(BURN_PAYLOAD);
    let mut longer = p.clone();
    longer.extend_from_slice(&[0u8; 32]);
    assert_eq!(decode_message(&longer).err(), Some(AbiError::BadMessage));
    assert_eq!(
        decode_message(&p[..p.len() - 1]).err(),
        Some(AbiError::BadMessage)
    );
    let mut domain = p.clone();
    domain[0] ^= 1;
    assert_eq!(decode_message(&domain).err(), Some(AbiError::BadMessage));
    let mut kind = p.clone();
    kind[2 * 32 + 30] = 1;
    assert_eq!(decode_message(&kind).err(), Some(AbiError::BadMessage));
    let mut index = p.clone();
    index[5 * 32] = 1;
    assert_eq!(decode_message(&index).err(), Some(AbiError::BadMessage));
    let mut offset = p.clone();
    offset[7 * 32 + 31] = 0x20;
    assert_eq!(decode_message(&offset).err(), Some(AbiError::BadMessage));
    let mut chain = p.clone();
    chain[32] = 1;
    assert_eq!(
        decode_message(&chain).err(),
        Some(AbiError::Overflow),
        "a chain id above 64 bits"
    );
    assert_eq!(
        body_word(decode_message(&p).unwrap().body, 2, 0).err(),
        Some(AbiError::BadMessage)
    );
}

fn fixture() -> Value {
    json("solana/programs/xindex-vault/tests/fixtures/hub.json")
}

/// Every slot a claim, a resolution and a recorded delivery read, the coin's token id, the claim's EIP-712 digest and
/// its signature, as Solidity and `cast` computed them for the same hub.
#[test]
fn the_reads_and_the_digest_are_solidity_s() {
    let f = fixture();
    let chain = f["chain_id"].as_u64().unwrap();
    let holder = h20(&f["holder_a"]["address"]);
    for c in 0..3 {
        let want: Vec<[u8; 32]> = f["holder_a"]["claims"][c]["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(h32)
            .collect();
        assert_eq!(
            snapshot::claim_slots(&C, &holder, c as u64, chain).to_vec(),
            want
        );
    }
    assert_eq!(
        snapshot::settled_slot(&C, &h32(&f["settled_intake"]["id"])),
        h32(&f["settled_intake"]["proof"]["slots"][0])
    );
    assert_eq!(
        snapshot::sent_slot(&C, &h32(&f["burn"]["id"])),
        h32(&f["burn"]["proof"]["slots"][0])
    );
    assert_eq!(snapshot::vault_token(&C, chain), h20(&f["sol_token"]));

    let index = h20(&f["index"]);
    let recipient = h32(&f["holder_a"]["recipient"]);
    let source = f["source_chain_id"].as_u64().unwrap();
    let digest = snapshot::claim_digest(&C, &h32(&f["vault"]), source, &index, &holder, &recipient);
    assert_eq!(digest, h32(&f["holder_a"]["digest"]));
    let signature = bytes(&f["holder_a"]["signature"]);
    assert_eq!(
        snapshot::check_signature(&C, &digest, &signature, &holder),
        Ok(())
    );
    let bad = Err(SnapshotError::BadSignature);
    assert_eq!(
        snapshot::check_signature(&C, &digest, &signature, &[1u8; 20]),
        bad
    );
    assert_eq!(
        snapshot::check_signature(&C, &digest, &malleable(&signature), &holder),
        bad,
        "the other signature of the same key, s above half the order"
    );
    for v in [0u8, 1, 29] {
        let mut s = signature.clone();
        s[64] = v;
        assert_eq!(snapshot::check_signature(&C, &digest, &s, &holder), bad);
    }
    assert_eq!(
        snapshot::check_signature(&C, &digest, &signature[..64], &holder),
        bad
    );
}

/// `s' = n - s`, with `v` flipped: the same key's other signature, which OpenZeppelin refuses.
fn malleable(signature: &[u8]) -> Vec<u8> {
    const N: [u8; 32] = hex::h("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
    let mut out = signature.to_vec();
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = N[i] as i16 - signature[32 + i] as i16 - borrow;
        out[32 + i] = d.rem_euclid(256) as u8;
        borrow = i16::from(d < 0);
    }
    out[64] = if signature[64] == 27 { 28 } else { 27 };
    out
}

/// A claim's share from the values the hub's storage holds: the fixture's holder A, at each of its components, and the
/// component past the array's end (VLT-1).
#[test]
fn a_share_is_the_holders_backing_and_claim() {
    let f = fixture();
    let chain = f["chain_id"].as_u64().unwrap();
    let values = |case: &Value| -> Vec<[u8; 32]> {
        case["values"].as_array().unwrap().iter().map(h32).collect()
    };
    let shares: Vec<_> = (0..3)
        .map(|c| snapshot::share(&C, &values(&f["holder_a"]["claims"][c]), c as u64, chain))
        .collect();
    let paid: Vec<_> = shares.iter().filter_map(|s| s.ok()).collect();
    assert_eq!(paid.len(), 1, "one component is this chain's coin");
    assert!(paid[0].0 > 0);
    assert!(shares
        .iter()
        .filter(|s| s.is_err())
        .all(|s| *s == Err(SnapshotError::WrongComponent)));
    assert_eq!(
        snapshot::share(&C, &values(&f["holder_a"]["past_the_end"]), 3, chain),
        Err(SnapshotError::WrongComponent)
    );
    assert_eq!(
        snapshot::share(&C, &values(&f["holder_a"]["claims"][0])[..4], 0, chain),
        Err(SnapshotError::BadStateProof)
    );
}

/// The state reader on the fixture's proofs: the values `eth_getProof` reported, zero for a slot proven absent, zero
/// for every slot of an account the state does not hold, and nothing proven under another root or from a proof with a
/// byte more or less.
#[test]
fn the_state_reader_reads_what_eth_get_proof_reported() {
    let f = fixture();
    let root = h32(&f["state_root"]);
    let index = h20(&f["index"]);
    for case in [
        &f["holder_a"]["claims"][1],
        &f["holder_b"]["claims"][2],
        &f["open_intake"]["proof"],
        &f["unsent_burn"]["proof"],
    ] {
        let slots: Vec<[u8; 32]> = case["slots"].as_array().unwrap().iter().map(h32).collect();
        let want: Vec<[u8; 32]> = case["values"].as_array().unwrap().iter().map(h32).collect();
        assert_eq!(
            read_slots(&C, &root, &index, &slots, &bytes(&case["proof"])),
            Ok(want)
        );
    }
    let absent = &f["absent_account"];
    assert_eq!(
        read_slots(
            &C,
            &root,
            &h20(&absent["address"]),
            &[[0u8; 32]],
            &bytes(&absent["proof"]["proof"]),
        ),
        Ok(vec![[0u8; 32]])
    );
    let proof = bytes(&f["settled_intake"]["proof"]["proof"]);
    let slot = [h32(&f["settled_intake"]["proof"]["slots"][0])];
    assert_eq!(
        read_slots(&C, &[0x22; 32], &index, &slot, &proof),
        Err(BadStateProof)
    );
    let mut longer = proof.clone();
    longer.push(0);
    assert_eq!(
        read_slots(&C, &root, &index, &slot, &longer),
        Err(BadStateProof)
    );
    assert_eq!(
        read_slots(&C, &root, &index, &slot, &proof[..proof.len() - 1]),
        Err(BadStateProof)
    );
}

/// 4% of the balance before the recent outflow, or the floor if larger; an hour's bucket accumulates, and one 25 hours
/// old reads as empty.
#[test]
fn the_speed_limit() {
    let now = 1_800_000_000i64;
    let hour = speed::hour_of(now);
    assert_eq!(speed::available(10_000, 0, 1), 400);
    assert_eq!(
        speed::available(9_700, 300, 1),
        100,
        "4% of 10,000 less 300"
    );
    assert_eq!(speed::available(10_000, 0, 1_000), 1_000, "the floor");
    assert_eq!(speed::available(100, 500, 400), 0, "never below zero");
    let bucket = speed::record((hour, 0), 50, now);
    assert_eq!(bucket, (hour, 50));
    assert_eq!(
        speed::record(bucket, 25, now + 10),
        (hour, 75),
        "the same hour"
    );
    assert_eq!(
        speed::record(bucket, 25, now + 25 * 3600),
        (hour + 25, 25),
        "a new hour in the same slot"
    );
    assert_eq!(speed::slot_of(hour), speed::slot_of(hour + 25));
    let buckets = [(hour, 10), (hour - 24, 20), (hour - 25, 40)];
    assert_eq!(speed::recent(buckets, now), 30);
}

/// The 128-bit variants a chain whose coin needs more than 64 bits runs, NEAR's yoctoNEAR: digests against Solidity's
/// encoder with amounts past 2^64 and NEAR's registry id, the 64-bit functions unchanged where both apply, the speed
/// limit, and the snapshot's 256-bit `shares * units / 1e18`.
#[test]
fn wide_amounts_match_solidity() {
    const NEAR: u64 = 339_552_387_624_818_629;
    let v = h32s("9f1cb2a7e3c34a8d1e6f0b5a2c7d9e1f3a5b7c9d0e2f4a6b8c0d1e3f5a7b9c1d");
    let i = h20s(INDEX);
    let id = h32s("0000000066000000000000000000000000000000000000000000000000000007");
    let (supply, paid, total) = (
        1_200_000_000 * 10u128.pow(24),
        3 * 10u128.pow(24),
        25 * 10u128.pow(24),
    );
    assert_eq!(
        index_digest_wide(&C, NEAR, &v, &i, true, supply, paid),
        h32s("3c4c52e76aaddd56a8b0e88928a5d73dd0976991a9108da0bcf9a1698224374e")
    );
    assert_eq!(
        intake_digest_wide(&C, NEAR, &v, &i, &id, 1, true, total),
        h32s("1b69281771199b2e1df05943449a731aa2f7fd811b1e21a107a3526345efdf80")
    );
    assert_eq!(
        index_digest_wide(&C, 900, &v, &i, true, 5000, 70),
        index_digest(&C, 900, &v, &i, true, 5000, 70)
    );
    assert_eq!(
        intake_digest_wide(&C, 900, &v, &i, &id, 1, true, 1_400_000_000),
        intake_digest(&C, 900, &v, &i, &id, 1, true, 1_400_000_000)
    );
    assert_eq!(u256_wide(supply)[16..], supply.to_be_bytes());
    assert_eq!(to_u128(&u256_wide(u128::MAX)), Ok(u128::MAX));
    let mut past = [0u8; 32];
    past[15] = 1;
    assert_eq!(to_u128(&past), Err(AbiError::Overflow));

    let now = 1_800_000_000i64;
    let hour = speed::hour_of(now);
    assert_eq!(speed::available_wide(supply, 0, 1), supply / 25);
    assert_eq!(speed::available_wide(100, 500, 400), 0);
    assert_eq!(
        speed::record_wide((hour, 7), supply, now),
        (hour, supply + 7)
    );
    let buckets = [(hour, supply), (hour - 25, supply)];
    assert_eq!(speed::recent_wide(buckets, now), supply);

    // A million shares at 7.7e25 yocto a share: the product passes 2^128, the share does not.
    let (shares, units) = (10u128.pow(24), 77 * 10u128.pow(24));
    assert!(shares.checked_mul(units).is_none());
    assert_eq!(
        snapshot::mul_div_wad(shares, units),
        Some(77 * 10u128.pow(30))
    );
    assert_eq!(
        snapshot::mul_div_wad(1 << 100, 1 << 90),
        None,
        "a quotient past 2^128"
    );
    for (a, b) in [
        (0, 5),
        (1, 1),
        (999, 10u128.pow(18) + 1),
        (u64::MAX as u128, u64::MAX as u128),
    ] {
        assert_eq!(snapshot::mul_div_wad(a, b), Some(a * b / 10u128.pow(18)));
    }
}

/// `share_wide` reads the same claim as `share`, and pays where `share`'s 128-bit product would overflow: the fixture's
/// holder A, and the same claim with its shares scaled past where `share` overflows.
#[test]
fn a_wide_share_is_the_same_share() {
    let f = fixture();
    let chain = f["chain_id"].as_u64().unwrap();
    let values = |case: &Value| -> Vec<[u8; 32]> {
        case["values"].as_array().unwrap().iter().map(h32).collect()
    };
    for c in 0..3 {
        let v = values(&f["holder_a"]["claims"][c]);
        let narrow = snapshot::share(&C, &v, c as u64, chain);
        let wide = snapshot::share_wide(&C, &v, c as u64, chain);
        assert_eq!(narrow.map(|(a, r)| (a as u128, r)), wide);
    }
    let coin = (0..3)
        .find(|c| {
            snapshot::share(&C, &values(&f["holder_a"]["claims"][*c]), *c as u64, chain).is_ok()
        })
        .unwrap();
    let mut v = values(&f["holder_a"]["claims"][coin]);
    // Shares of 2^100 at the component's units: past `share`'s 128-bit product, inside `share_wide`'s.
    v[0] = u256_wide(1 << 100);
    v[2] = [0u8; 32];
    assert_eq!(
        snapshot::share(&C, &v, coin as u64, chain),
        Err(SnapshotError::Overflow)
    );
    let mut units = [0u8; 16];
    units[4..].copy_from_slice(&v[1][..12]);
    let units = u128::from_be_bytes(units);
    let (amount, _) = snapshot::share_wide(&C, &v, coin as u64, chain).unwrap();
    assert_eq!(Some(amount), snapshot::mul_div_wad(1 << 100, units));
}

#[test]
fn checkpoints_are_newer_and_recent() {
    let last = Checkpoint {
        block: 100,
        timestamp: 1_000,
        state_root: [1; 32],
    };
    let next = Checkpoint {
        block: 101,
        timestamp: 1_012,
        state_root: [2; 32],
    };
    assert!(checkpoint::is_newer(&last, &next, 1_012));
    assert!(
        !checkpoint::is_newer(&last, &next, 1_011),
        "from the future"
    );
    assert!(!checkpoint::is_newer(&next, &last, 2_000));
    assert!(!checkpoint::is_newer(
        &last,
        &Checkpoint {
            state_root: [0; 32],
            ..next
        },
        2_000
    ));
    assert!(!checkpoint::is_newer(
        &last,
        &Checkpoint {
            timestamp: 1_000,
            ..next
        },
        2_000
    ));
    let week = STALL_PERIOD;
    assert_eq!(checkpoint::stall_start(1_000), 1_000 + week);
    assert!(!checkpoint::stalled(1_000, 1_000 + week));
    assert!(checkpoint::stalled(1_000, 1_000 + week + 1));
    assert!(checkpoint::is_recent(&next, 1_012 + week));
    assert!(!checkpoint::is_recent(&next, 1_013 + week));
    assert!(!checkpoint::needs_both(FREEZE, false));
    assert!(!checkpoint::needs_both(CAP_UPDATE, true), "a lowering");
    assert!(checkpoint::needs_both(CAP_UPDATE, false), "a raise");
    for kind in [
        BURN,
        INTAKE_SETTLED,
        INTAKE_FAILED,
        MIGRATE,
        FREEZER_CHANGE,
        VERIFIER_ROTATION,
    ] {
        assert!(checkpoint::needs_both(kind, true));
    }
}

/// B1-01: a timestamp is a `u64`, and one past `i64::MAX` is later than any now, as it is to `XindexVault`'s `uint256`
/// comparisons. Cast with `as i64` it wrapped into the past: a forged checkpoint dated 2^63 passed `is_newer`, stalled
/// the vault at once and made the snapshot exit due at once.
#[test]
fn test_b101_a_timestamp_past_i64_is_in_the_future() {
    let now = 1_790_000_000;
    let last = Checkpoint {
        block: 100,
        timestamp: 1_000,
        state_root: [1; 32],
    };
    for timestamp in [i64::MAX as u64 + 1, 1u64 << 63 | 12, u64::MAX] {
        let forged = Checkpoint {
            block: 101,
            timestamp,
            state_root: [2; 32],
        };
        assert!(!checkpoint::is_newer(&last, &forged, now), "{timestamp}");
        assert!(!checkpoint::stalled(timestamp, now), "{timestamp}");
        assert_eq!(checkpoint::stall_start(timestamp), i64::MAX, "{timestamp}");
        // As `XindexVault` reads it, such a checkpoint is no older than a week; `is_newer` is what refuses it.
        assert!(checkpoint::is_recent(&forged, now), "{timestamp}");
    }
    // The largest timestamp that fits is still compared exactly.
    let edge = Checkpoint {
        block: 101,
        timestamp: i64::MAX as u64,
        state_root: [2; 32],
    };
    assert!(checkpoint::is_newer(&last, &edge, i64::MAX));
    assert!(!checkpoint::is_newer(&last, &edge, i64::MAX - 1));
    assert_eq!(checkpoint::stall_start(i64::MAX as u64), i64::MAX);
}

#[test]
fn an_array_slot_adds_with_carry() {
    let mut a = [0u8; 32];
    a[31] = 0xff;
    a[30] = 0xff;
    let b = snapshot::add(&a, 1);
    assert_eq!(&b[29..], &[1, 0, 0]);
    assert_eq!(snapshot::add(&[0xff; 32], 1), [0u8; 32]);
}

/// B1-06: the snapshot claim's domain names Ethereum's chain id, where the holder's wallet is, not the registry's id
/// for the vault chain, which no EVM network carries and wallets refuse to sign for. The fixture's holder signed the
/// digest under Sepolia's id; under the registry's id, the domain the claim had before, the digest is another.
#[test]
fn test_b106_the_claim_domain_names_ethereum() {
    let f = fixture();
    let (source, chain) = (
        f["source_chain_id"].as_u64().unwrap(),
        f["chain_id"].as_u64().unwrap(),
    );
    assert_eq!(source, 11_155_111);
    let (vault, index, holder) = (
        h32(&f["vault"]),
        h20(&f["index"]),
        h20(&f["holder_a"]["address"]),
    );
    let recipient = h32(&f["holder_a"]["recipient"]);
    let digest = snapshot::claim_digest(&C, &vault, source, &index, &holder, &recipient);
    assert_eq!(digest, h32(&f["holder_a"]["digest"]));
    // By hand: the domain is `EIP712Domain("Xindex vault", "1", 11155111, vault)`.
    let domain = C.keccak256(&[
        &EIP712_DOMAIN_TYPEHASH,
        &EIP712_NAME_HASH,
        &EIP712_VERSION_HASH,
        &u256(11_155_111),
        &vault,
    ]);
    let claim = C.keccak256(&[
        &SNAPSHOT_CLAIM_TYPEHASH,
        &address_word(&index),
        &address_word(&holder),
        &recipient,
    ]);
    assert_eq!(digest, C.keccak256(&[b"\x19\x01", &domain, &claim]));
    let registry = snapshot::claim_digest(&C, &vault, chain, &index, &holder, &recipient);
    assert_eq!(
        registry,
        h32s("9d8a129de2a566b39324866db6cc2fa7b829760bf8bca9f8e0f9757fc7237db5"),
        "the digest the fixture held under the registry's id"
    );
    let signature = bytes(&f["holder_a"]["signature"]);
    assert_eq!(
        snapshot::check_signature(&C, &digest, &signature, &holder),
        Ok(())
    );
    assert_eq!(
        snapshot::check_signature(&C, &registry, &signature, &holder),
        Err(SnapshotError::BadSignature)
    );
}

/// B2-05: the body's length word is read whole. Cut to a 32-bit `usize` with `as`, as NEAR's and Soroban's Wasm cut it,
/// a length of 2^32 + 96 read as the body's own 96 bytes, and that second encoding of the same message decoded. A
/// length within a word of 2^64 overflowed the padding's sum, a panic under overflow checks (every chain's release
/// build, and this crate's tests) and a wrap without them.
#[test]
fn test_b205_a_body_length_is_read_whole() {
    let p = hex(BURN_PAYLOAD);
    let len = 8 * 32;
    let mut wide = p.clone();
    wide[len + 27] = 1;
    assert_eq!(
        to_u64(wide[len..len + 32].try_into().unwrap()),
        Ok((1 << 32) + 96)
    );
    assert_eq!(decode_message(&wide).err(), Some(AbiError::BadMessage));
    for k in 0..64u64 {
        let mut huge = p.clone();
        huge[len + 24..len + 32].copy_from_slice(&(u64::MAX - k).to_be_bytes());
        assert_eq!(
            decode_message(&huge).err(),
            Some(AbiError::BadMessage),
            "{k}"
        );
        assert_eq!(
            decode_message(&huge[..len + 32]).err(),
            Some(AbiError::BadMessage),
            "{k}, nothing after the length"
        );
    }
    assert!(decode_message(&p).is_ok());
}

/// A decimal number as a 256-bit big-endian word.
fn decimal_word(s: &str) -> [u8; 32] {
    let mut w = [0u8; 32];
    for d in s.bytes() {
        let mut carry = (d - b'0') as u32;
        for b in w.iter_mut().rev() {
            let x = *b as u32 * 10 + carry;
            *b = x as u8;
            carry = x >> 8;
        }
        assert_eq!(carry, 0, "{s} fits 256 bits");
    }
    w
}

/// C1-02: every governance and settlement kind as `VaultMessages.encode` writes it
/// (`test/fixtures/vault-messages.json`, which Solidity pins), decoded by the core's own decoder: the envelope, the id,
/// and every body field where each vault reads it.
#[test]
fn test_c102_the_message_bodies_are_soliditys() {
    let f = json("test/fixtures/vault-messages.json");
    let source = f["sourceChainId"].as_u64().unwrap();
    let dest = f["destChainId"].as_u64().unwrap();
    let (vault, index) = (h32(&f["vault"]), h20(&f["index"]));
    let messages = f["messages"].as_array().unwrap();
    let mut kinds: Vec<u8> = Vec::new();
    for m in messages {
        let name = m["name"].as_str().unwrap();
        let p = bytes(&m["payload"]);
        let d = decode_message(&p).unwrap_or_else(|e| panic!("{name}: {e:?}"));
        assert_eq!(d.kind as u64, m["kind"].as_u64().unwrap(), "{name}");
        assert_eq!(d.nonce, m["nonce"].as_u64().unwrap(), "{name}");
        assert_eq!(
            (d.source_chain_id, d.dest_chain_id),
            (source, dest),
            "{name}"
        );
        assert_eq!((d.vault, d.index), (vault, index), "{name}");
        assert_eq!(d.body, bytes(&m["body"]).as_slice(), "{name}");
        assert_eq!(message_id(&C, &p), h32(&m["id"]), "{name}");
        assert_eq!(index_in(&p), index, "{name}");
        let fields = &m["fields"];
        let field = |k: &str| fields[k].as_str().unwrap();
        match d.kind {
            INTAKE_SETTLED | INTAKE_FAILED => {
                let id = decimal_word(field("intakeId"));
                assert_eq!(*body_word(d.body, 1, 0).unwrap(), id, "{name}");
                assert_eq!(body_word_in(&p, 0), id, "{name}");
                assert_eq!(deadline_of(&id), 1_800_000_000, "{name}");
            }
            MIGRATE => {
                assert_eq!(
                    to_address(body_word(d.body, 3, 0).unwrap()),
                    Ok(h20(&fields["newIndex"]))
                );
                assert_eq!(address_in_body(&p, 0), h20(&fields["newIndex"]));
                assert_eq!(*body_word(d.body, 3, 1).unwrap(), h32(&fields["token"]));
                assert_eq!(
                    to_u64(body_word(d.body, 3, 2).unwrap()),
                    Ok(field("amount").parse().unwrap())
                );
            }
            CAP_UPDATE => {
                assert_eq!(*body_word(d.body, 3, 0).unwrap(), h32(&fields["token"]));
                assert_eq!(
                    *body_word(d.body, 3, 1).unwrap(),
                    decimal_word(field("cap"))
                );
                assert_eq!(
                    to_u128(body_word(d.body, 3, 1).unwrap()),
                    Ok(500 * 10u128.pow(18))
                );
                assert_eq!(
                    to_u64(body_word(d.body, 3, 1).unwrap()),
                    Err(AbiError::Overflow),
                    "a cap past 64 bits, as CAP_UPDATE may carry (B1-05)"
                );
                assert_eq!(
                    to_u64(body_word(d.body, 3, 2).unwrap()),
                    Ok(field("floor").parse().unwrap())
                );
            }
            FREEZE => {
                assert_eq!(
                    to_u64(body_word(d.body, 1, 0).unwrap()),
                    Ok(field("until").parse().unwrap()),
                    "a freeze carries its end (A3-03)"
                );
            }
            FREEZER_CHANGE => {
                assert_eq!(*body_word(d.body, 1, 0).unwrap(), h32(&fields["freezer"]));
            }
            VERIFIER_ROTATION => {
                assert_eq!(*body_word(d.body, 2, 0).unwrap(), h32(&fields["p1"]));
                assert_eq!(*body_word(d.body, 2, 1).unwrap(), h32(&fields["p2"]));
            }
            other => panic!("an unexpected kind {other}"),
        }
        kinds.push(d.kind);
    }
    assert_eq!(
        kinds,
        [
            INTAKE_SETTLED,
            INTAKE_FAILED,
            MIGRATE,
            CAP_UPDATE,
            FREEZE,
            FREEZER_CHANGE,
            VERIFIER_ROTATION
        ],
        "one payload per kind but BURN, which `a_burn_decodes` pins"
    );
}

/// A3-03, B4-04: a FREEZE carries the end of the factory's own freeze, `abi.encode(until)`, and the vault's freeze ends
/// there, never more than FREEZE_DURATION from now. One delivered after its freeze ended freezes nothing, so an
/// undelivered FREEZE is no 14-day pause anyone may fire at a time of their choosing. Its body is exactly one word.
#[test]
fn test_a303_b404_a_freeze_ends_with_the_factorys() {
    let now = 1_800_000_000i64;
    let body = |until: u64| u256(until).to_vec();
    assert_eq!(freeze_end(&body(now as u64 - 1), now), Ok(None), "over");
    assert_eq!(freeze_end(&body(now as u64), now), Ok(None), "over now");
    assert_eq!(freeze_end(&body(0), now), Ok(None));
    assert_eq!(
        freeze_end(&body(now as u64 + 3600), now),
        Ok(Some(now + 3600)),
        "mid-freeze: only to the factory's end"
    );
    assert_eq!(
        freeze_end(&body((now + FREEZE_DURATION) as u64), now),
        Ok(Some(now + FREEZE_DURATION))
    );
    for until in [
        (now + FREEZE_DURATION) as u64 + 1,
        i64::MAX as u64,
        i64::MAX as u64 + 1,
        u64::MAX,
    ] {
        assert_eq!(
            freeze_end(&body(until), now),
            Ok(Some(now + FREEZE_DURATION)),
            "{until}: never past FREEZE_DURATION"
        );
    }
    let mut wide = [0xffu8; 32];
    wide[0] = 0x7f;
    assert_eq!(
        freeze_end(&wide, now),
        Ok(Some(now + FREEZE_DURATION)),
        "a uint256 past 64 bits saturates"
    );
    for bad in [0usize, 31, 33, 64] {
        assert_eq!(
            freeze_end(&vec![0u8; bad], now),
            Err(AbiError::BadMessage),
            "a body of {bad} bytes"
        );
    }
    // The factory's own FREEZE, as Solidity encodes it.
    let f = json("test/fixtures/vault-messages.json");
    let freeze = f["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["name"] == "FREEZE")
        .unwrap();
    let p = bytes(&freeze["payload"]);
    let m = decode_message(&p).unwrap();
    assert_eq!(freeze_end(m.body, now - 3600), Ok(Some(now)));
    assert_eq!(freeze_end(m.body, now), Ok(None));
}
