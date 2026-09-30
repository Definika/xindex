//! The statement end to end on a synthetic chain: 300 validators of 2,048 ETH with real keys and signatures, a
//! checkpoint block whose state and body commit to what the proof reads, and execution headers as RLP. Each refusal
//! is reached by changing one thing.

use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{G1Affine, G2Projective, Scalar};
use group::Curve;
use sha2::Sha256;
use xindex_finality::beacon::{
    compute_domain, fork_version, signing_root, AttestationData, BeaconBlockHeader, Checkpoint,
    DOMAIN_BEACON_ATTESTER, GENESIS_VALIDATORS_ROOT,
};
use xindex_finality::bls::DST;
use xindex_finality::execution::{keccak, keccak_root, parse_header};
use xindex_finality::registry::{validators_root, Validator};
use xindex_finality::ssz::{hash_pair, merkleize};
use xindex_finality::statement::{UncompressedKey, MARGIN_PER_EPOCH_GWEI, MAX_EPOCH_GAP};
use xindex_finality::{verify, Aggregate, Anchor, Error, Input, Root};

const N: usize = 300;
const BALANCE: u64 = 2_048_000_000_000;
const E0: u64 = 411_400;

struct Chain {
    secrets: Vec<Scalar>,
    validators: Vec<Validator>,
    keys: Vec<UncompressedKey>,
}

fn chain(balance: u64) -> Chain {
    let secrets: Vec<Scalar> = (0..N).map(|i| Scalar::from(1_000 + i as u64)).collect();
    let mut validators = Vec::new();
    let mut keys = Vec::new();
    for s in &secrets {
        let point = (G1Affine::generator() * s).to_affine();
        validators.push(Validator {
            pubkey: point.to_compressed(),
            withdrawal_credentials: [0x01; 32],
            effective_balance: balance,
            slashed: false,
            activation_eligibility_epoch: 0,
            activation_epoch: 0,
            exit_epoch: u64::MAX,
            withdrawable_epoch: u64::MAX,
        });
        keys.push(UncompressedKey(point.to_uncompressed()));
    }
    Chain {
        secrets,
        validators,
        keys,
    }
}

fn sign(chain: &Chain, signers: &[u32], data: &AttestationData) -> [u8; 96] {
    let domain = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        fork_version(data.target.epoch).unwrap(),
        &GENESIS_VALIDATORS_ROOT,
    );
    let message = signing_root(&data.hash_tree_root(), &domain);
    let hashed =
        <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&message[..]], DST);
    let secret = signers
        .iter()
        .fold(Scalar::zero(), |acc, &i| acc + chain.secrets[i as usize]);
    (hashed * secret).to_affine().to_compressed()
}

// ---------------------------------------------------------------------
// RLP, as an execution client writes a header
// ---------------------------------------------------------------------

fn rlp_bytes(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    let mut out = length_prefix(b.len(), 0x80);
    out.extend_from_slice(b);
    out
}

fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let payload: Vec<u8> = items.concat();
    let mut out = length_prefix(payload.len(), 0xc0);
    out.extend(payload);
    out
}

fn length_prefix(len: usize, base: u8) -> Vec<u8> {
    if len <= 55 {
        return vec![base + len as u8];
    }
    let be: Vec<u8> = len
        .to_be_bytes()
        .iter()
        .copied()
        .skip_while(|b| *b == 0)
        .collect();
    let mut out = vec![base + 55 + be.len() as u8];
    out.extend(be);
    out
}

fn rlp_int(x: u64) -> Vec<u8> {
    let be: Vec<u8> = x
        .to_be_bytes()
        .iter()
        .copied()
        .skip_while(|b| *b == 0)
        .collect();
    rlp_bytes(&be)
}

/// A Prague header with every field an execution client writes.
fn exec_header(parent: Root, number: u64) -> Vec<u8> {
    rlp_list(&[
        rlp_bytes(&parent),
        rlp_bytes(&[0x1d; 32]),
        rlp_bytes(&[0x95; 20]),
        rlp_bytes(&keccak(&[b"state", &number.to_be_bytes()])),
        rlp_bytes(&[0x56; 32]),
        rlp_bytes(&keccak(&[b"receipts", &number.to_be_bytes()])),
        rlp_bytes(&[0u8; 256]),
        rlp_int(0),
        rlp_int(number),
        rlp_int(36_000_000),
        rlp_int(12_345_678),
        rlp_int(1_750_000_000 + 12 * number),
        rlp_bytes(b"xindex"),
        rlp_bytes(&[0x33; 32]),
        rlp_bytes(&[0u8; 8]),
        rlp_int(7),
        rlp_bytes(&[0x44; 32]),
        rlp_int(0),
        rlp_int(0),
        rlp_bytes(&[0x55; 32]),
        rlp_bytes(&[0x66; 32]),
    ])
}

// ---------------------------------------------------------------------
// SSZ trees for the checkpoint's state and body
// ---------------------------------------------------------------------

/// The root of `leaves` (a power of two long) and the branch of leaf `index`, bottom up.
fn tree(leaves: &[Root], index: usize) -> (Root, Vec<Root>) {
    let mut layer = leaves.to_vec();
    let mut i = index;
    let mut branch = Vec::new();
    while layer.len() > 1 {
        branch.push(layer[i ^ 1]);
        layer = layer.chunks(2).map(|p| hash_pair(&p[0], &p[1])).collect();
        i /= 2;
    }
    (layer[0], branch)
}

struct Built {
    input: Input,
}

/// A chain where the anchor is at `E0` and `C1` at `E0 + gap`, with `signers` voting on both links, and `headers`
/// execution blocks since the anchor.
fn build(gap: u64, signers: &[u32], headers: u64) -> Built {
    build_with(gap, signers, headers, BALANCE)
}

/// As `build`, every validator holding `balance`: a day's margin is more than 300 validators of 2,048 ETH hold.
fn build_with(gap: u64, signers: &[u32], headers: u64, balance: u64) -> Built {
    let chain = chain(balance);
    let anchor_exec = keccak(&[b"the anchor's block"]);
    let anchor = Anchor {
        epoch: E0,
        validators_root: validators_root(&chain.validators),
        exec_hash: anchor_exec,
        exec_number: 20_000_000,
    };

    // Execution headers from the anchor's block on.
    let mut exec_headers = Vec::new();
    let mut parent = anchor_exec;
    for k in 1..=headers {
        let rlp = exec_header(parent, anchor.exec_number + k);
        parent = keccak(&[&rlp]);
        exec_headers.push(rlp);
    }
    let block_hash = parent;

    // C1's block: a state holding the next registry at field 11, and a body holding the payload's block hash.
    let new_validators_root = keccak(&[b"the registry at C1"]);
    let mut state_leaves: Vec<Root> = (0..64u8).map(|i| [i; 32]).collect();
    state_leaves[11] = new_validators_root;
    let (state_root, validators_branch) = tree(&state_leaves, 11);
    let mut body_leaves = vec![[0u8; 32]; 512];
    body_leaves[300] = block_hash;
    let (body_root, block_hash_branch) = tree(&body_leaves, 300);
    let header = BeaconBlockHeader {
        slot: (E0 + gap) * 32,
        proposer_index: 7,
        parent_root: [9; 32],
        state_root,
        body_root,
    };

    let e1 = E0 + gap;
    let source = Checkpoint {
        epoch: e1 - 1,
        root: [0x51; 32],
    };
    let c1 = Checkpoint {
        epoch: e1,
        root: header.hash_tree_root(),
    };
    let c2 = Checkpoint {
        epoch: e1 + 1,
        root: [0x52; 32],
    };
    let justification = votes(&chain, signers, source, c1);
    let finalization = votes(&chain, signers, c1, c2);
    let keys = chain.keys.clone();
    let validators = chain.validators.clone();
    Built {
        input: Input {
            anchor,
            validators,
            keys,
            justification,
            finalization,
            header,
            new_validators_root,
            validators_branch,
            block_hash,
            block_hash_branch,
            exec_headers,
        },
    }
}

/// `signers` split into two aggregates at two slots of the target epoch, overlapping by one.
fn votes(chain: &Chain, signers: &[u32], source: Checkpoint, target: Checkpoint) -> Vec<Aggregate> {
    let half = signers.len() / 2;
    let parts = [&signers[..half + 1], &signers[half..]];
    parts
        .iter()
        .enumerate()
        .map(|(k, part)| {
            let data = AttestationData {
                slot: target.epoch * 32 + k as u64,
                index: 0,
                beacon_block_root: [0x70 + k as u8; 32],
                source,
                target,
            };
            Aggregate {
                data,
                signature: sign(chain, part, &data),
                signers: part.to_vec(),
            }
        })
        .collect()
}

fn range(n: u32) -> Vec<u32> {
    (0..n).collect()
}

/// Two thirds of 300 validators is 200, and the finalization link's target is two epochs past the anchor, so its
/// margin counts three epochs: 6,144 ETH, three validators. So 203 must sign.
const NEEDED: u32 = 203;

#[test]
fn a_finalized_checkpoint_moves_the_anchor() {
    let b = build(1, &range(NEEDED), 64);
    let out = verify(&b.input).expect("the statement holds");
    let input = &b.input;
    assert_eq!(out.anchor_in, input.anchor.hash());
    assert_eq!(out.epoch, E0 + 1);
    assert_eq!(out.first_number, input.anchor.exec_number + 1);
    assert_eq!(out.last_number, input.anchor.exec_number + 64);
    let leaves: Vec<Root> = input
        .exec_headers
        .iter()
        .map(|r| parse_header(r).unwrap().leaf())
        .collect();
    assert_eq!(out.headers_root, keccak_root(&leaves));
    let next = Anchor {
        epoch: E0 + 1,
        validators_root: input.new_validators_root,
        exec_hash: input.block_hash,
        exec_number: input.anchor.exec_number + 64,
    };
    assert_eq!(out.anchor_out, next.hash());
    // The ABI the verifier contracts decode: six words.
    let abi = out.abi_encode();
    assert_eq!(abi.len(), 6 * 32);
    assert_eq!(&abi[..32], &out.anchor_in);
    assert_eq!(abi[64 + 31], ((E0 + 1) & 0xff) as u8);
}

#[test]
fn the_threshold_is_two_thirds_plus_the_margin() {
    assert!(verify(&build(1, &range(NEEDED), 1).input).is_ok());
    match verify(&build(1, &range(NEEDED - 1), 1).input) {
        Err(Error::BelowThreshold {
            signed,
            total,
            margin,
        }) => {
            assert_eq!(signed, (NEEDED as u128 - 1) * BALANCE as u128);
            assert_eq!(total, N as u128 * BALANCE as u128);
            assert_eq!(margin, 3 * MARGIN_PER_EPOCH_GWEI, "the finalization link");
        }
        other => panic!("{other:?}"),
    }
    // The justification link's target is one epoch nearer the anchor, so it needs one validator fewer.
    match verify(&build(1, &range(NEEDED - 2), 1).input) {
        Err(Error::BelowThreshold { margin, .. }) => assert_eq!(margin, 2 * MARGIN_PER_EPOCH_GWEI),
        other => panic!("{other:?}"),
    }
    // Further from the anchor, more must sign: three epochs more, three validators more.
    assert!(matches!(
        verify(&build(4, &range(NEEDED + 2), 1).input),
        Err(Error::BelowThreshold { .. })
    ));
    assert!(verify(&build(4, &range(NEEDED + 3), 1).input).is_ok());
}

#[test]
fn only_unslashed_active_stake_counts_and_only_once() {
    // A signer slashed, one not yet active, and one exited by the target epoch: none counts.
    for change in 0..3 {
        let mut b = build(1, &range(NEEDED), 1);
        let v = &mut b.input.validators[0];
        match change {
            0 => v.slashed = true,
            1 => v.activation_epoch = E0 + 5,
            _ => v.exit_epoch = E0 + 1,
        }
        b.input.anchor.validators_root = validators_root(&b.input.validators);
        assert!(
            matches!(verify(&b.input), Err(Error::BelowThreshold { .. })),
            "change {change}"
        );
    }
    // A signer listed twice in one aggregate counts once, and signs twice: the signature no longer matches.
    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[0].signers.push(0);
    assert_eq!(verify(&b.input), Err(Error::BadSignature));
    // The same signers repeated in another aggregate add nothing.
    let mut b = build(1, &range(NEEDED - 1), 1);
    let extra = b.input.justification[0].clone();
    b.input.justification.push(extra);
    assert!(matches!(
        verify(&b.input),
        Err(Error::BelowThreshold { .. })
    ));
}

#[test]
fn the_registry_and_its_keys_are_the_anchors() {
    let mut b = build(1, &range(NEEDED), 1);
    b.input.validators[5].effective_balance += 1;
    assert_eq!(verify(&b.input), Err(Error::RegistryMismatch));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.keys.pop();
    assert_eq!(verify(&b.input), Err(Error::KeyCountMismatch));

    // Another point's uncompressed form, even the key's own negation, is refused.
    let mut b = build(1, &range(NEEDED), 1);
    let point = Option::<G1Affine>::from(G1Affine::from_uncompressed(&b.input.keys[3].0)).unwrap();
    b.input.keys[3] = UncompressedKey((-point).to_uncompressed());
    assert_eq!(verify(&b.input), Err(Error::BadKey(3)));

    // A point off the curve with the key's x and the same sign of y compresses to the same bytes: refused, since
    // pairing on such a point is where invalid-curve attacks start.
    let mut b = build(1, &range(NEEDED), 1);
    let mut off = b.input.keys[4].0;
    off[95] ^= 1;
    let point = Option::<G1Affine>::from(G1Affine::from_uncompressed_unchecked(&off)).unwrap();
    assert!(!bool::from(point.is_on_curve()));
    assert_eq!(
        point.to_compressed(),
        b.input.validators[4].pubkey,
        "it compresses to the key"
    );
    b.input.keys[4] = UncompressedKey(off);
    assert_eq!(verify(&b.input), Err(Error::BadKey(4)));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[1].signers.push(N as u32);
    assert_eq!(verify(&b.input), Err(Error::BadSigner(N as u32)));
}

#[test]
fn every_vote_is_for_the_same_link_in_its_target_epoch() {
    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[1].data.source.root = [0x99; 32];
    assert_eq!(verify(&b.input), Err(Error::LinksDisagree));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.finalization[0].data.source.root = [0x99; 32];
    assert_eq!(
        verify(&b.input),
        Err(Error::LinksDisagree),
        "the finalization must start at C1"
    );

    let mut b = build(1, &range(NEEDED), 1);
    for a in b.input.finalization.iter_mut() {
        a.data.target.epoch += 1;
    }
    assert_eq!(
        verify(&b.input),
        Err(Error::LinksDisagree),
        "C2 is C1's direct child"
    );

    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[0].data.slot -= 32;
    assert_eq!(verify(&b.input), Err(Error::SlotOutsideTarget));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.finalization.clear();
    assert_eq!(verify(&b.input), Err(Error::NoVotes));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[1].signers.clear();
    assert_eq!(verify(&b.input), Err(Error::NoVotes));

    // A signature over anything else fails.
    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[0].data.beacon_block_root = [0x01; 32];
    assert_eq!(verify(&b.input), Err(Error::BadSignature));
}

#[test]
fn the_checkpoint_is_after_the_anchor_and_within_a_day() {
    let mut b = build(1, &range(NEEDED), 1);
    b.input.anchor.epoch = E0 + 1;
    b.input.anchor.validators_root = validators_root(&b.input.validators);
    assert_eq!(verify(&b.input), Err(Error::NotAfterAnchor));

    // A day's margin is 227 epochs of 2,048 ETH: with 300 validators of 20,000 ETH, 224 must sign.
    let big = 20_000_000_000_000;
    let b = build_with(MAX_EPOCH_GAP + 1, &range(N as u32), 1, big);
    assert_eq!(verify(&b.input), Err(Error::TooFarFromAnchor));
    assert!(
        verify(&build_with(MAX_EPOCH_GAP, &range(224), 1, big).input).is_ok(),
        "a day exactly"
    );
    let short = build_with(MAX_EPOCH_GAP, &range(223), 1, big);
    assert!(matches!(
        verify(&short.input),
        Err(Error::BelowThreshold { .. })
    ));

    // Before Electra, no domain is known.
    let mut b = build(1, &range(NEEDED), 1);
    b.input.anchor.epoch = 100;
    let c1 = Checkpoint {
        epoch: 150,
        root: b.input.header.hash_tree_root(),
    };
    for a in b.input.justification.iter_mut() {
        a.data.source.epoch = 149;
        a.data.target = c1;
        a.data.slot = 150 * 32;
    }
    for a in b.input.finalization.iter_mut() {
        a.data.source = c1;
        a.data.target.epoch = 151;
        a.data.slot = 151 * 32;
    }
    assert_eq!(verify(&b.input), Err(Error::UnknownFork(150)));
}

#[test]
fn the_block_commits_to_the_registry_and_the_execution_block() {
    let mut b = build(1, &range(NEEDED), 3);
    b.input.header.proposer_index += 1;
    assert_eq!(verify(&b.input), Err(Error::HeaderMismatch));

    let mut b = build(1, &range(NEEDED), 3);
    b.input.new_validators_root[0] ^= 1;
    assert_eq!(verify(&b.input), Err(Error::BadStateBranch));

    let mut b = build(1, &range(NEEDED), 3);
    b.input.validators_branch.pop();
    assert_eq!(verify(&b.input), Err(Error::BadStateBranch));

    let mut b = build(1, &range(NEEDED), 3);
    b.input.block_hash[0] ^= 1;
    assert_eq!(verify(&b.input), Err(Error::BadBlockHashBranch));
}

#[test]
fn the_execution_headers_are_one_unbroken_chain() {
    // A header that is not the parent of the next.
    let mut b = build(1, &range(NEEDED), 4);
    b.input.exec_headers[1] = exec_header([0x77; 32], b.input.anchor.exec_number + 2);
    assert_eq!(verify(&b.input), Err(Error::BrokenChain(1)));

    // One skipped.
    let mut b = build(1, &range(NEEDED), 4);
    b.input.exec_headers.remove(2);
    assert_eq!(verify(&b.input), Err(Error::BrokenChain(2)));

    // The last one short of C1's block.
    let mut b = build(1, &range(NEEDED), 4);
    b.input.exec_headers.pop();
    assert_eq!(verify(&b.input), Err(Error::BrokenChain(3)));

    // Linked by parent hash, but numbered one too far: the block range would no longer match the leaves.
    let mut b = build(1, &range(NEEDED), 4);
    let first = exec_header(b.input.anchor.exec_hash, b.input.anchor.exec_number + 2);
    let mut parent = keccak(&[&first]);
    let mut headers = vec![first];
    for k in 3..=5 {
        let rlp = exec_header(parent, b.input.anchor.exec_number + k);
        parent = keccak(&[&rlp]);
        headers.push(rlp);
    }
    b.input.exec_headers = headers;
    assert_eq!(verify(&b.input), Err(Error::BrokenChain(0)));

    // Not RLP.
    let mut b = build(1, &range(NEEDED), 4);
    b.input.exec_headers[0].push(0);
    assert_eq!(verify(&b.input), Err(Error::BadExecHeader(0)));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.exec_headers.clear();
    assert_eq!(verify(&b.input), Err(Error::WrongHeaderCount));
}

/// The pieces the contracts recompute: the anchor's hash, the header leaf and the keccak tree, pinned against `cast`.
#[test]
fn the_encodings_match_solidity() {
    let anchor = Anchor {
        epoch: 411_400,
        validators_root: [0x11; 32],
        exec_hash: [0x22; 32],
        exec_number: 20_000_000,
    };
    // cast keccak $(cast abi-encode "f(uint64,bytes32,bytes32,uint64)" 411400 0x11..11 0x22..22 20000000)
    assert_eq!(anchor.hash(), HASH_OF_ANCHOR);
    let leaf = parse_header(&exec_header([0x22; 32], 20_000_001))
        .unwrap()
        .leaf();
    let a = keccak(&[b"a"]);
    let b = keccak(&[b"b"]);
    let c = keccak(&[b"c"]);
    assert_eq!(keccak_root(&[leaf]), leaf, "one leaf is its own root");
    assert_eq!(
        keccak_root(&[a, b, c]),
        keccak(&[&keccak(&[&a, &b]), &keccak(&[&c, &[0u8; 32]])])
    );
    assert_eq!(merkleize(&[a], 0), a);
}

const HASH_OF_ANCHOR: Root = [
    0x00, 0x7f, 0xbc, 0x8b, 0xdf, 0xae, 0xc6, 0xa6, 0xa6, 0xf7, 0xb7, 0x71, 0x4f, 0x02, 0x12, 0x7e,
    0x40, 0xcd, 0xab, 0x87, 0x79, 0x06, 0xc8, 0xdf, 0xcf, 0x99, 0x65, 0xa4, 0x89, 0x07, 0x97, 0x33,
];
