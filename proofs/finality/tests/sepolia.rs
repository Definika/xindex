//! P1 built for Sepolia (`--features sepolia`), against real Sepolia data: a finalized block header and an aggregate
//! attestation with its signers' keys, from Sepolia's beacon API. The aggregate verifies only under Sepolia's genesis
//! and fork version, so it pins the three constants the feature changes.
#![cfg(feature = "sepolia")]

use bls12_381::{G1Affine, G1Projective};
use group::Curve;
use xindex_finality::beacon::{
    compute_domain, fork_version, signing_root, AttestationData, BeaconBlockHeader, Checkpoint,
    DOMAIN_BEACON_ATTESTER, GENESIS_VALIDATORS_ROOT, NETWORK,
};
use xindex_finality::bls;

fn h<const N: usize>(s: &str) -> [u8; N] {
    let s = s.trim_start_matches("0x");
    let v: Vec<u8> = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect();
    v.try_into().expect("length")
}

fn key(s: &str) -> G1Affine {
    G1Affine::from_compressed(&h::<48>(s)).unwrap()
}

/// A finalized Sepolia block header (slot 11,261,632), whose root the beacon API gave.
#[test]
fn a_real_sepolia_header_hashes_to_its_root() {
    let header = BeaconBlockHeader {
        slot: 11_261_632,
        proposer_index: 1_323,
        parent_root: h("0739236084083f23550daf86e983bb51450af0892d0be7f6759c5aa75c0f156c"),
        state_root: h("d2d08f32f9d387766b073c505cbb32ed2b3eb9dc5e64cc33518ffbdb1e856183"),
        body_root: h("33b3588d311a37de478bfd7529f08bc2efee7cf7c084b108353e339b1c6a41e7"),
    };
    assert_eq!(
        header.hash_tree_root(),
        h("65a291e809825879906069b6519f70b52feee492a26dd299b5b5c5f567dba383")
    );
}

/// A real Sepolia aggregate from the block at slot 11,261,632: 56 validators of committee 0 vote at slot
/// 11,261,631, under Fulu's fork version. The signature verifies only with all 56, over this data, under Sepolia's
/// domain: not mainnet's, and not Electra's.
#[test]
fn a_real_sepolia_aggregate_verifies() {
    assert_eq!(NETWORK, "sepolia");
    let data = AttestationData {
        slot: 11_261_631,
        index: 0,
        beacon_block_root: h("0739236084083f23550daf86e983bb51450af0892d0be7f6759c5aa75c0f156c"),
        source: Checkpoint {
            epoch: 351_924,
            root: h("abeb937e48e2ac5745466add21e20a766c07293fcc7f034106f0049d4eeaada2"),
        },
        target: Checkpoint {
            epoch: 351_925,
            root: h("6fde1a032ee757717f0af77581d1ce1d4735226c1ac7cdbacfaad6b7d63f803e"),
        },
    };
    let signature = h::<96>(
        "895b6e46896602a15c99c55d1b571067fcfe97667cbdd9a1f4cb0aafb9c890910f30ab91a8627334ea501c998e86bd9708cff4c3bdb795d1ad7893e1c54bb910285b3401a4635f8721fd3cd51f28d4dd10f1de5092dc4383543e1f4d478e7627",
    );
    let keys: Vec<G1Affine> = [
        "ad19e38fbc31a1f99e8ead1437016333ba9b15dffa43fe617d410fe82775f06fe5abd2d5f2118802914903d2c2301748",
        "884c769ff3dabc132330e4a72ecf5331490ff08a59b7dd51cf2a9cf803a1a3dbff838f40451b243786661eb1630a60d0",
        "85c9217b6f7b8baffda06ffead7174ab9d1d9ec4b10b78d99e742835796a522d6e2b5ddc5c7282757dd896c76698eafb",
        "88b2c68b425269850c1a4f4608aca194da5c641adeb99e2f7fb92e34b8245dff066e73bde072be60f7f2c3d3d13de3b6",
        "8266f9cc52944d85c50ba04d421c0ecb7ceac774f4485bca84115772ade238fdb5f5bf93f1f6c5288b3a44af177042e5",
        "b75c28941ee3f91b3535b4eaa0fb17b59ca65b5256601a1f6d0cf2bb4d66837fd16e51d6942856679012a5730a66e519",
        "b30e022b8a563655074e08e123b5f96956bbf0fe221cc629c5fedd2764a66b475916ceb98867f935b4a47212e53ae9f3",
        "987dd977d6b8d27c4065b61b3c078ec9ce3871fec02844ed00f5ad28c42f9cedecbe830ddd19e11a5c879b01eb0f8f80",
        "b8d68610fdee190ec5a1f4be4c4f750b00ad78d3e9c96b576c6913eab9e7a81e1d6d6a675ee3c6efac5d02ed4b3c093a",
        "aac995a41c14d379853ef18ffc854ad62ad77061ca9bdf5029cab3d6c2630de114e777a7fc3322455939d5205ed59c55",
        "936749ff47e5be307546564a5a4615bd8df52e2590034b2db19846939af3595a79ccabf0f6ff52ca46b9a1de3efd47a5",
        "8167484b6a9bcbdef21464cee959a7a6aab5ac92ccc46214f4a2ed520cfb4d4de8917f9b9bd6fad71e66c17bd831eeeb",
        "804c021152c3304853941847e80480fdaceba3b9676fbe018268cf77d1a1856966c2f9686bb4d4aa0c4118a7e85f83cc",
        "8614a7599c8d97aa9ca63b876f677977cf0daa969ff2a9a153f297a4a46e08fa5d91492995de94dc32cf009ce6bb5b5f",
        "8fd3881daae9d08f6c671e5c4689e27b7742e8e5878dc3693ac3ab52de58f3bd316f7bcae038971c61f232a9d51db79d",
        "a4632399c1a813e41fb2055ef293466098ea7752a9d3722d019aa01620f8c5ecdc5954f176c6c0901a770cbe6990eb11",
        "84ed656b5291cbb2843ecc8371cbf1447955256059bef4a77133f1a37e7529fb64cefaa2ea973c680329f6110999b22f",
        "80822499f96a1a8c0048f01f389dfcaaa5d8269c332dbb507fe46f270bcfd5f67c53f827fd867221592dbde77b6b37ab",
        "a448516054e31866b54f1951b9a03f0a54fb13d938b105e3f67396ed3fbb015f290a37fa538baeb077fb4f9ac86c8305",
        "8f6fde2ebbd7682c69026069cfe93aa5410071f05de9ccd7070c8c3299a6539b39b3798f01a0b4e9b1330510bdb51de7",
        "a9239a0e1250d355615eae3f43a9395d5c2943aaa37f22a1b36ed04aba544b0fb83cb5fa93b76c67c13d3f73e5e845cf",
        "b79b9289dbc045e1d6ab747360696e0a2e4ba4ab7013ca7f977b6ef6e9ce9c4aa41f2b526ec3e5209df3d2cacd548da6",
        "876afcd045c8a18967923733a3a43757652289b0974cd348238a693f30bb57f38664ecb97877a5e5f7d0185039a2bf54",
        "ae5ea228c1b91ef23c245928186fbafa1275ff1817535018d7d2d913abff0fd76bf41fd04a96d816f2f1891bd16e9264",
        "8ceeec6c85df65d52e3d56efcf95f88b59aa085b61bb026fb228b855f088d9b676ffd5f0ee2ddbae00662b2f9ce770b1",
        "a58c3a4ba86d0d6b81c8411bb73a528b4f3bc2debac0e0208f788c080a3a96541d57c927143c165f595070afe14b0517",
        "a1cf175541368768b65e523ec5059c21b6d21a18d01b2c076d36107767c8a389be0bbe51c5535c6dceb576adbdea7107",
        "8f84a01d340725976a7ba1b78e8a8046285367c2741fb27fda29de5d07b9a3564ef7b909bac9429c288bccde7381f80f",
        "8be4830a391aace561decdfea6aa610696d292a9e6b56448c6a590027df9f6762668671775272bac46ea335391ae157d",
        "b80e8516598c59dddcf13fdb7a42d8f5a52c84e01bd6a39880f4acaefe8e4b8f09cc1b1a2423cd5121f4952201f20078",
        "8d5776148c65e35d717da1902d74727b3bee21ceba8d337d77738932865f1b851e810b91346f705880da6cac63183717",
        "85554235ceabfc4e432bb1804daf45ae47b90b8dfaf33d0a85565394dd1e122dc5efdf3427a7e1b288c78c24e8ad9809",
        "983fc1ddf17f9756c9cecc00b39bb2ad432587a5c6d1c3296a383b9f539c9afe84c6c818447a709c0b686ba26ce5ea3e",
        "aafe14dd3b680f096010788226d8413ca628feedad79a2bc78cb04d47c6ad910f7f46ca87b8f8281744625d8f42d5eea",
        "a3f9dcc48290883d233100b69404b0b05cf34df5f6e6f6833a17cc7b23a2612b85c39df03c1e6e3cd380f259402c6120",
        "a4d88467136b99d6e55603b3665b6da0f7fb27c7759687f7e6977b6230272773d7b95049d999538c008f310c05ed948a",
        "8a0192ef0903d7a5ed2e5614a715901f2554b324ee72390974dc90727ff08dafa580041a21a8e6c48a3e08e1b042afab",
        "ab6e3180dae399d41243f23545e5e6d118844f9b8edba502a3503fd1162ed826f9fc610889a1d685d374b6c21e86067d",
        "84fe145491d145fbe0c7f9104c9cca07c4f77746dbb93cfefd066b8a1ee61be8fe5d592c18b153f40f41ffdd8020f11c",
        "8553bfd1a163df0d8bb1424383552b85a1c0d288dc1f46fdde90ce2d9be7e2688d7d06e1d6be06252c7099588d3488e5",
        "b40a3bae2b08c13db00f993db49e2042be99cde3d6f4f03d9991e42297933d6049394c659e31f316fcb081b60461dabf",
        "a031d95cdf2853d2d72f3efe2feeeb9f409f51f3b708f726be0096acccef3b247fbe4370c58b4b891cf156234221e0ee",
        "87587504e819bc7f0349705a05c15e8504fd6b2c25c3fd264096cdb7aaa22d8078da776215925d9d775a7f9355b6f0c0",
        "840a53b12c5bb26dfcbfbc6f6ec4b1520547382b704ba545c65adcbf80eddfa0ac3cfa25eb44707608435f8cbbd07aa4",
        "ad28da04c80723df1443d5391f998ae9700de91c9fc3f1544d03d698a97cd94fe1753f9915c1d6354185734a80bab484",
        "88ce41025aa153a94f91f22e7b96f9342b5e0e1d76274fc70c4df7d08f66d9f7ac86e55a1c6e77693b8b01b2b38bf900",
        "8b50e4e28539270576a0e8a83f5dedcd1e5369e4cd0be54a8e84069e7c3fdcc85483678429fd63fe2aa12db281012af2",
        "8126c80c3d28d61b00e9be970d7dd6054b299981e9b36c51e8596cbcf8ce1f5f6ab5eece17bf964186c4ef3e9156f909",
        "8e2e9a1a8bae9fffa594324a2c643ba0609f291146a104ceb9fc1f26d4a25604b97e9fb392c01689c88cac90c310333c",
        "9104b5af82dbca914370eadb5518b26bee7ed7edeca74b741585ba8b249204e2c998bd47a02cef4335e236f8efafef94",
        "a0dfa8c1614a05f1d73502f228f2f4f3d1d1f4946b26b99031bb4f01277d8c2718d632c88a6c7be8aaf67455a562b23e",
        "86b1cdd26ea9a3ae04d31a0b34aa3edc9e8d038437152214d195381173e79e4ccf7f8f0ce9801086724a1c927c20e4c8",
        "845982c2672fdd44b33d2e56ad676e704c02f756b09e8765bea42b924c14724484567b55f0db42ac20cb70a7f5201c14",
        "838ff6630dc3908a04c51fb44a29eca5a0d88330f48c1d0dd68b8890411a394fd728f14215482b03477d33f39645dceb",
        "860f5649c5299211728a36722a142bf1aa7cbbfbd225b671d427c67546375de96832c06709c73b7a51439b091249d34f",
        "a6aa726e5c35e0d576c7ffd4aace921a1bcefa5348397970dfebf27384583fc0aa9583cb024f4b3125d4997b44b65baf",
    ]
    .iter()
    .map(|k| key(k))
    .collect();
    let version = fork_version(data.target.epoch).expect("Fulu");
    assert_eq!(version, [0x90, 0x00, 0x00, 0x75]);
    let domain = compute_domain(DOMAIN_BEACON_ATTESTER, version, &GENESIS_VALIDATORS_ROOT);
    let root = signing_root(&data.hash_tree_root(), &domain);
    let all = keys
        .iter()
        .fold(G1Projective::identity(), |acc, k| acc + k)
        .to_affine();
    assert!(bls::verify(&all, &root, &signature));

    let short = keys[1..]
        .iter()
        .fold(G1Projective::identity(), |acc, k| acc + k)
        .to_affine();
    assert!(!bls::verify(&short, &root, &signature), "a signer short");
    let electra = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        [0x90, 0x00, 0x00, 0x74],
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
    let mainnet = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        version,
        &h("4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95"),
    );
    assert!(
        !bls::verify(
            &all,
            &signing_root(&data.hash_tree_root(), &mainnet),
            &signature
        ),
        "mainnet's genesis"
    );
}

/// Sepolia's forks, at their boundaries.
#[test]
fn sepolias_forks() {
    assert_eq!(fork_version(222_463), None, "before Electra");
    assert_eq!(fork_version(222_464), Some([0x90, 0x00, 0x00, 0x74]));
    assert_eq!(fork_version(272_639), Some([0x90, 0x00, 0x00, 0x74]));
    assert_eq!(fork_version(272_640), Some([0x90, 0x00, 0x00, 0x75]));
}
