//! Alpenglow certificates, on devnet's real genesis certificate (`fixtures/devnet.json`, from `getAgGenesisCert`)
//! and its signer set (`fixtures/genesis_signers.json`, found by `examples/find_genesis_signers.rs`).

use bls12_381::{G1Affine, G2Affine};
use serde_json::Value;
use std::fs;
use xindex_solana_state::cert::*;

fn fixture(name: &str) -> Value {
    let path = format!("{}/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn bytes(v: &Value) -> Vec<u8> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|b| b.as_u64().unwrap() as u8)
        .collect()
}

fn unhex<const N: usize>(s: &str) -> [u8; N] {
    (0..N)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect::<Vec<_>>()
        .try_into()
        .unwrap()
}

struct Genesis {
    slot: u64,
    block_id: [u8; 32],
    shred_version: u16,
    signature: G2Affine,
    bitmap: Vec<u8>,
    /// The signers' keys, in the order of the bitmap's set ranks.
    signers: Vec<G1Affine>,
}

fn genesis() -> Genesis {
    let d = fixture("devnet.json");
    let s = fixture("genesis_signers.json");
    let cert = &d["genesisCert"];
    let keys: Vec<(String, G1Affine)> = d["voteAccounts"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| {
            let key = unhex::<48>(v["blsPubkeyCompressed"].as_str()?);
            Some((
                v["votePubkey"].as_str().unwrap().to_string(),
                Option::from(G1Affine::from_compressed(&key)).unwrap(),
            ))
        })
        .collect();
    let signers = s["signerVotePubkeys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| keys.iter().find(|k| k.0 == p.as_str().unwrap()).unwrap().1)
        .collect();
    Genesis {
        slot: cert["block"]["slot"].as_u64().unwrap(),
        block_id: bytes(&cert["block"]["blockId"]).try_into().unwrap(),
        shred_version: s["shredVersion"].as_u64().unwrap() as u16,
        signature: signature(&bytes(&cert["signature"]["signature"])).unwrap(),
        bitmap: bytes(&cert["signature"]["bitmap"]),
        signers,
    }
}

/// A rank map whose bitmap ranks hold `signers` and whose other ranks hold `others`, each with `stake`.
fn map_for(bitmap: &[u8], signers: &[G1Affine], others: G1Affine, stake: u64) -> RankMap {
    let bits = u16::from_le_bytes([bitmap[1], bitmap[2]]) as usize;
    let set = decode_base2(bitmap, bits).unwrap();
    let mut it = signers.iter();
    let keys: Vec<G1Affine> = (0..bits)
        .map(|r| {
            if set.contains(&r) {
                *it.next().unwrap()
            } else {
                others
            }
        })
        .collect();
    RankMap {
        stakes: vec![stake; keys.len()],
        total: stake * keys.len() as u64,
        keys,
    }
}

/// The real certificate: 11 of epoch 1167's 17 ranks signed `[6] ++ slot ++ block id ++ shred version` under
/// Ethereum's ciphersuite, and the aggregate of exactly those keys verifies it.
#[test]
fn devnets_genesis_certificate_verifies() {
    let g = genesis();
    assert_eq!(g.bitmap[..3], [0, 17, 0], "Base2, 17 ranks");
    let ranks = decode_base2(&g.bitmap, 17).unwrap();
    assert_eq!(ranks, vec![0, 1, 2, 3, 4, 7, 9, 10, 14, 15, 16]);
    let payload = block_payload(GENESIS, g.slot, &g.block_id, g.shred_version);
    assert_eq!(payload.len(), 43);
    let map = map_for(&g.bitmap, &g.signers, G1Affine::generator(), 1);
    // Equal stakes: 11 of 17 is 64.7%, which passes 60% and is refused at genesis's 82%. The real ranks weighed more.
    assert_eq!(verify(&map, &payload, &g.signature, &g.bitmap, 60), Ok(11));
    assert_eq!(
        verify(&map, &payload, &g.signature, &g.bitmap, GENESIS_PCT),
        Err(CertError::NotEnoughStake {
            signed: 11,
            total: 17,
            pct: GENESIS_PCT
        })
    );
}

/// Anything else signed is refused: another shred version, slot, block id or tag; one signer short; a key swapped.
#[test]
fn the_certificate_signs_nothing_else() {
    let g = genesis();
    let map = map_for(&g.bitmap, &g.signers, G1Affine::generator(), 1);
    let mut other_id = g.block_id;
    other_id[0] ^= 1;
    for payload in [
        block_payload(GENESIS, g.slot, &g.block_id, g.shred_version + 1),
        block_payload(GENESIS, g.slot + 1, &g.block_id, g.shred_version),
        block_payload(GENESIS, g.slot, &other_id, g.shred_version),
        block_payload(NOTARIZE, g.slot, &g.block_id, g.shred_version),
    ] {
        assert_eq!(
            verify(&map, &payload, &g.signature, &g.bitmap, 0),
            Err(CertError::Invalid)
        );
    }
    let payload = block_payload(GENESIS, g.slot, &g.block_id, g.shred_version);
    let mut fewer = g.bitmap.clone();
    fewer[5] = 0; // rank 16 drops out
    assert_eq!(
        verify(&map, &payload, &g.signature, &fewer, 0),
        Err(CertError::Invalid)
    );
    let mut swapped = g.signers.clone();
    swapped[0] = G1Affine::generator();
    let map = map_for(&g.bitmap, &swapped, G1Affine::generator(), 1);
    assert_eq!(
        verify(&map, &payload, &g.signature, &g.bitmap, 0),
        Err(CertError::Invalid)
    );
}

/// The bitmap: Base2 only, its length exact and within the set; a rank past the set is refused.
#[test]
fn bitmaps() {
    assert_eq!(decode_base2(&[0, 3, 0, 0b101], 3), Ok(vec![0, 2]));
    assert_eq!(
        decode_base2(&[0, 3, 0, 0b1101], 3),
        Ok(vec![0, 2]),
        "bits past the count are ignored, as Agave does"
    );
    assert_eq!(
        decode_base2(&[1, 3, 0, 0], 3),
        Err(CertError::BadBitmap),
        "Base3"
    );
    assert_eq!(
        decode_base2(&[0, 9, 0, 0xff], 9),
        Err(CertError::BadBitmap),
        "short"
    );
    assert_eq!(
        decode_base2(&[0, 4, 0, 0xff], 3),
        Err(CertError::BadBitmap),
        "longer than the set"
    );
    let g = genesis();
    let map = RankMap {
        keys: g.signers[..5].to_vec(),
        stakes: vec![1; 5],
        total: 5,
    };
    let payload = block_payload(GENESIS, g.slot, &g.block_id, g.shred_version);
    assert_eq!(
        verify(&map, &payload, &g.signature, &[0, 6, 0, 0b100000], 0),
        Err(CertError::BadBitmap)
    );
    let map = RankMap {
        keys: g.signers[..5].to_vec(),
        stakes: vec![1; 5],
        total: 5,
    };
    assert_eq!(
        verify(&map, &payload, &g.signature, &[0, 5, 0, 0b10000], 0),
        Err(CertError::Invalid)
    );
}

/// The ranked set as Agave builds it: staked, with a key; neither key shared; by stake, then by compressed key.
#[test]
fn the_rank_map_is_agaves() {
    let v = |vote: u8, node: u8, bls: Option<u8>, stake: u64| Validator {
        vote: [vote; 32],
        node: [node; 32],
        bls: bls.map(|s| {
            G1Affine::from(G1Affine::generator() * bls12_381::Scalar::from(u64::from(s) + 1))
                .to_compressed()
        }),
        stake,
    };
    let set = vec![
        v(1, 1, Some(1), 50),
        v(2, 2, Some(2), 70),
        v(3, 3, Some(3), 50),
        v(4, 4, None, 900),   // no key: not a signer, and not in the total
        v(5, 5, Some(5), 0),  // no stake
        v(6, 6, Some(6), 40), // shares its BLS key with 7: both out
        v(7, 7, Some(6), 40),
        v(8, 9, Some(8), 30), // shares its node with 10: both out
        v(10, 9, Some(10), 30),
    ];
    let map = RankMap::new(&set).unwrap();
    assert_eq!(map.total, 170);
    assert_eq!(map.stakes, vec![70, 50, 50]);
    let tie: Vec<[u8; 48]> = {
        let mut t = vec![set[0].bls.unwrap(), set[2].bls.unwrap()];
        t.sort();
        t
    };
    assert_eq!(map.keys[0].to_compressed(), set[1].bls.unwrap());
    assert_eq!(map.keys[1].to_compressed(), tie[0]);
    assert_eq!(map.keys[2].to_compressed(), tie[1]);
}

/// Finality: slow needs a finalize and a notarize certificate, each at 60%; fast one notarize aggregate at 80%. Shown
/// on keys this test holds, since no real block's certificates are public (see the design document).
#[test]
fn finality_slow_and_fast() {
    use bls12_381::{G2Projective, Scalar};
    use group::Curve;
    use xindex_finality::bls::{hash_to_g2, DST};
    let secrets: Vec<Scalar> = (1..=5u64).map(|s| Scalar::from(1000 + s)).collect();
    let keys: Vec<G1Affine> = secrets
        .iter()
        .map(|s| (G1Affine::generator() * s).into())
        .collect();
    let map = RankMap {
        keys,
        stakes: vec![20; 5],
        total: 100,
    };
    let sign = |payload: &[u8], who: &[usize]| -> G2Affine {
        let h = hash_to_g2(payload, DST);
        who.iter()
            .fold(G2Projective::identity(), |acc, &i| acc + h * secrets[i])
            .to_affine()
    };
    let bitmap = |who: &[usize]| {
        let mut b = 0u8;
        who.iter().for_each(|i| b |= 1 << i);
        vec![0, 5, 0, b]
    };
    let (slot, id, sv) = (42u64, [7u8; 32], 9u16);
    let notar = block_payload(NOTARIZE, slot, &id, sv);
    let fin = slot_payload(FINALIZE, slot, sv);
    let three = [0, 1, 2];
    let four = [0, 1, 2, 3];
    let (n3, f3, n4) = (
        sign(&notar, &three),
        sign(&fin, &three),
        sign(&notar, &four),
    );
    let (b3, b4) = (bitmap(&three), bitmap(&four));
    let slow = Finality::Slow {
        finalize: (&f3, &b3),
        notarize: (&n3, &b3),
    };
    assert_eq!(verify_finality(&map, slot, &id, sv, &slow), Ok(()));
    // 60% notarizes, but fast finality needs 80%.
    assert!(verify_finality(&map, slot, &id, sv, &Finality::Fast((&n3, &b3))).is_err());
    assert_eq!(
        verify_finality(&map, slot, &id, sv, &Finality::Fast((&n4, &b4))),
        Ok(())
    );
    // A finalize certificate is for a slot, so it must come with the block's notarize certificate: a notarize
    // certificate of another block does not finalize this one.
    let other = [8u8; 32];
    assert!(verify_finality(&map, slot, &other, sv, &slow).is_err());
}
