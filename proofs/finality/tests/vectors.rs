//! The library against vectors it did not produce: the consensus specs' own SSZ library and py_ecc (`vectors.py`),
//! and real mainnet data, a finalized block header and an aggregate attestation with its signers' keys.

use bls12_381::{G1Affine, G1Projective};
use group::Curve;
use xindex_finality::beacon::{
    compute_domain, signing_root, AttestationData, BeaconBlockHeader, Checkpoint,
    DOMAIN_BEACON_ATTESTER,
};
use xindex_finality::bls;
use xindex_finality::registry::{validators_root, Validator};

fn h<const N: usize>(s: &str) -> [u8; N] {
    let s = s.trim_start_matches("0x");
    let v: Vec<u8> = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect();
    v.try_into().expect("length")
}

const FAR: u64 = u64::MAX;

/// Mainnet's `genesis_validators_root`, which `vectors.py` computed its domain with: a literal, so the comparison with the
/// specs' libraries runs whichever network the crate is built for.
const MAINNET_GENESIS_VALIDATORS_ROOT: &str =
    "4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95";

fn key(s: &str) -> G1Affine {
    Option::from(G1Affine::from_compressed(&h::<48>(s))).expect("a valid key")
}

fn credentials(prefix: u8, fill: u8) -> [u8; 32] {
    let mut c = [0u8; 32];
    c[0] = prefix;
    c[12..].fill(fill);
    c
}

/// `vectors.py`: three validators, the registry, a vote, a header, the domain, and an aggregate signature by keys 1, 2
/// and 3.
#[test]
fn ssz_and_bls_match_the_consensus_specs_libraries() {
    let keys = [
        "97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb",
        "a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e",
        "89ece308f9d1f0131765212deca99697b112d61f9be9a5f1f3780a51335b3ff981747a0b2ca2179b96d2c0c9024e5224",
    ];
    let validators = vec![
        Validator {
            pubkey: h(keys[0]),
            withdrawal_credentials: credentials(1, 0x11),
            effective_balance: 32_000_000_000,
            slashed: false,
            activation_eligibility_epoch: 0,
            activation_epoch: 0,
            exit_epoch: FAR,
            withdrawable_epoch: FAR,
        },
        Validator {
            pubkey: h(keys[1]),
            withdrawal_credentials: credentials(2, 0x22),
            effective_balance: 2_048_000_000_000,
            slashed: true,
            activation_eligibility_epoch: 5,
            activation_epoch: 9,
            exit_epoch: 400_000,
            withdrawable_epoch: 400_256,
        },
        Validator {
            pubkey: h(keys[2]),
            withdrawal_credentials: [0u8; 32],
            effective_balance: 31_000_000_000,
            slashed: false,
            activation_eligibility_epoch: FAR,
            activation_epoch: FAR,
            exit_epoch: FAR,
            withdrawable_epoch: FAR,
        },
    ];
    assert_eq!(
        validators[1].hash_tree_root(),
        h("43c4a000920a24bcace2405e43d0a3f1a053aed8024aa163c4de9dbf36a87497")
    );
    assert_eq!(
        validators_root(&validators),
        h("0187f8e5bd07159ce791b5d0909a3d811f77fae71aa565125628205b45f89331")
    );

    let data = AttestationData {
        slot: 13_164_577,
        index: 0,
        beacon_block_root: [0xaa; 32],
        source: Checkpoint {
            epoch: 411_392,
            root: [0xbb; 32],
        },
        target: Checkpoint {
            epoch: 411_393,
            root: [0xcc; 32],
        },
    };
    assert_eq!(
        data.hash_tree_root(),
        h("46f285c77c984f3787dd5fb630cdd5dd39cb452b2f6e74a51204f309dc7bf6d1")
    );
    let header = BeaconBlockHeader {
        slot: 13_164_544,
        proposer_index: 123_456,
        parent_root: [1; 32],
        state_root: [2; 32],
        body_root: [3; 32],
    };
    assert_eq!(
        header.hash_tree_root(),
        h("1a8b2f9b957c222202c430d8e8e1a8c342cd21f8792a93133c50a1e3176db11c")
    );
    let domain = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        [6, 0, 0, 0],
        &h(MAINNET_GENESIS_VALIDATORS_ROOT),
    );
    assert_eq!(
        domain,
        h("0100000082fae541f8a3db43adb5e7997ac5f562cf682ce6bc41b8ec28ba1a07")
    );
    let root = signing_root(&data.hash_tree_root(), &domain);
    assert_eq!(
        root,
        h("ca644277b9763356bfee4400cbcc61c580e915abcc726570f84af13e0e27c108")
    );

    let signature = h::<96>(
        "a15be6d8f5ce5e70202b7faf0f8922baf76cb9625a8d7b19cddf130bdc8cb7c4ce574142ca637c44d0e50f0657d337e715b935b209d37b7ba909dbae241b5b89b80eaf1f5f03b2790d856500c6e428500bdcd950e75475fea46151353a14d27c",
    );
    let aggregate = keys
        .iter()
        .fold(G1Projective::identity(), |acc, k| acc + key(k))
        .to_affine();
    assert!(bls::verify(&aggregate, &root, &signature));
    let two = (G1Projective::from(key(keys[0])) + key(keys[1])).to_affine();
    assert!(!bls::verify(&two, &root, &signature), "a signer short");
    assert!(
        !bls::verify(&aggregate, &[0u8; 32], &signature),
        "another message"
    );
}

/// A finalized mainnet block header (slot 15,331,008), whose root the beacon API gave.
#[test]
fn a_real_header_hashes_to_its_root() {
    let header = BeaconBlockHeader {
        slot: 15_331_008,
        proposer_index: 1_743_089,
        parent_root: h("753b893c87ac9d91c371c32d49baff522ddaa77c158d44e3392c4a8091f46a22"),
        state_root: h("6243e6eeb33892aea5ce05aec3b40395c3a9b43d1666c97b1a534540b926fa34"),
        body_root: h("0aac69638f66e6a6cb104e871d6c5eb7b2505563cd54b988f9a838a1248690b2"),
    };
    assert_eq!(
        header.hash_tree_root(),
        h("91b302ee732de62aad38a3b5342ff28a4e304cd5ca52a4aaa93277c1c7ff0672")
    );
}

/// A real mainnet aggregate from the block at slot 15,331,008: nine validators across nine committees vote at slot
/// 15,331,007, under Fulu's fork version. Their keys come from the beacon API; the signature verifies only with all
/// nine, over this data, under this domain. It pins mainnet's constants, so it runs in mainnet's build only;
/// `sepolia.rs` pins Sepolia's.
#[cfg(not(feature = "sepolia"))]
#[test]
fn a_real_aggregate_verifies() {
    use xindex_finality::beacon::{fork_version, GENESIS_VALIDATORS_ROOT};

    let data = AttestationData {
        slot: 15_331_007,
        index: 0,
        beacon_block_root: h("46e3e445b0fe3460d6c150d1a6efd9adea0bddfff700bf1580470ff62c59a373"),
        source: Checkpoint {
            epoch: 479_092,
            root: h("f9dd2a8eef8a2e6c0585477d9e19aa7e6d9551cd0173ab716aecca146a85eee6"),
        },
        target: Checkpoint {
            epoch: 479_093,
            root: h("f1d759d9bc1c4df9b2c4102491fd2e5e81e23617f64ba4e71f880dafa03233ed"),
        },
    };
    let signature = h::<96>(
        "941b7e6205e8374a30dc666be681e973adcb29e500ce3a568c23e7b9025cd53fbfa545925dbd088ed80e332e8e3e447c0a9af64a43ff9769340e01ae2e501c555a15cea6065531e25b606a006ca55217e29e3d19cb0d875a645870767882737d",
    );
    let keys: Vec<G1Affine> = [
        "b10f3271e8eb82f55da8c6af8369c441293a6fa272096f33ac5025d828cc2f5ec33f63d1f478d191470ed032f2fdc65d",
        "98ee9b4108c4b173be3a9196a8d2dbf407fc988c8e735aa7ebaa4a3ef67be64bc32c3615f9c39001af8ac8fd07d42885",
        "acbb307cfa81c54f18bd0df1dc49a0887f74188cb272bceb5bdd16310df5b3bc2f7df5843f0124ad35cbf80f8d792427",
        "b38657a54e326001a4d762cb5ebdb1c0149065c0ba20d1417d76e71757e6535223244f0919c324ae34791b29ccc0da50",
        "9138df4cec1146ff4c9f5c633ddd837e5d23c79df4dac37cdba66dce49da01835c1ea764aed80e8a755041da79a7a088",
        "a8062cf8a9f6d94df4f22fe21c24b9c219d63a869b051706ef20837b2a0f6d9e91bf8a14cc8b6c1acd7edac646f7526b",
        "aa331f0ba7aab587f99e6f98739d667b5327e812ed4c5670c67bb0b3747f2dbcac230fd30f659ac5e752cbec3aa18ae6",
        "a32d9ac60f8097e1e3a4877497eeb6c427cc7cfc08111070ec1e41db0b8d77b6b92f6bf5a3208b8dfce9c836df0c79a8",
        "84351705f4abcbad7873a9fbb573c1fd42e81226212f6df6348407605b015a23d2339cbf05e23d2d41708cf1a7529f35",
    ]
    .iter()
    .map(|k| key(k))
    .collect();
    let version = fork_version(data.target.epoch).expect("Fulu");
    assert_eq!(version, [6, 0, 0, 0]);
    let domain = compute_domain(DOMAIN_BEACON_ATTESTER, version, &GENESIS_VALIDATORS_ROOT);
    let root = signing_root(&data.hash_tree_root(), &domain);
    let all = keys
        .iter()
        .fold(G1Projective::identity(), |acc, k| acc + k)
        .to_affine();
    assert!(bls::verify(&all, &root, &signature));

    // Each key, read the way the statement reads a registry key, from its uncompressed form.
    for k in &keys {
        let compressed = k.to_compressed();
        assert_eq!(
            bls::registry_key(&k.to_uncompressed(), &compressed),
            Some(*k)
        );
        let negated = (-*k).to_uncompressed();
        assert_eq!(
            bls::registry_key(&negated, &compressed),
            None,
            "the other y"
        );
    }
    let eight = keys[..8]
        .iter()
        .fold(G1Projective::identity(), |acc, k| acc + k)
        .to_affine();
    assert!(!bls::verify(&eight, &root, &signature), "a signer short");
    let electra = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        [5, 0, 0, 0],
        &GENESIS_VALIDATORS_ROOT,
    );
    assert!(
        !bls::verify(
            &all,
            &signing_root(&data.hash_tree_root(), &electra),
            &signature
        ),
        "the wrong fork"
    );
    assert_eq!(fork_version(364_031), None, "before Electra");
    assert_eq!(fork_version(364_032), Some([5, 0, 0, 0]));
    assert_eq!(fork_version(411_391), Some([5, 0, 0, 0]));
}
