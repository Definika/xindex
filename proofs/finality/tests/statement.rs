//! The statement end to end on a synthetic chain: 300 validators of 2,048 ETH with real keys and signatures, a
//! checkpoint block whose state and body commit to what the proof reads, and execution headers as RLP. Each refusal
//! is reached by changing one thing.

use bls12_381::{G1Affine, G1Projective, Scalar};
use group::Curve;
use xindex_finality::beacon::{
    compute_domain, fork_version, signing_root, Checkpoint, DOMAIN_BEACON_ATTESTER,
    FAR_FUTURE_EPOCH, GENESIS_VALIDATORS_ROOT,
};
use xindex_finality::bls;
use xindex_finality::execution::{keccak, keccak_root, parse_header};
use xindex_finality::registry::{self, validators_root, Registry};
use xindex_finality::ssz::merkleize;
use xindex_finality::statement::{MARGIN_PER_EPOCH_GWEI, MAX_EPOCH_GAP};
use xindex_finality::{verify, Aggregate, Anchor, Error, Input, Root};

const N: usize = 300;
const BALANCE: u64 = 2_048_000_000_000;
const E0: u64 = 411_400;

use xindex_finality::testkit::{self, exec_header, Chain};

struct Built {
    chain: Chain,
    input: Input,
}

/// A chain where the anchor is at `E0` and `C1` at `E0 + gap`, with `signers` voting on both links, and `headers`
/// execution blocks since the anchor.
fn build(gap: u64, signers: &[u32], headers: u64) -> Built {
    build_with(gap, signers, headers, BALANCE)
}

/// As `build`, every validator holding `balance`: a day's margin is more than 300 validators of 2,048 ETH hold.
fn build_with(gap: u64, signers: &[u32], headers: u64, balance: u64) -> Built {
    build_from(testkit::chain(N, balance), gap, signers, headers)
}

fn build_from(chain: Chain, gap: u64, signers: &[u32], headers: u64) -> Built {
    let input = testkit::build(&chain, E0, gap, signers, headers);
    Built { chain, input }
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
    // A signer slashed, one not yet active, one exited by C1, and one exiting at C2, which counts for the justification
    // but not the finalization: none of them counts on both links.
    for change in 0..4 {
        let mut chain = testkit::chain(N, BALANCE);
        let v = &mut chain.validators[0];
        match change {
            0 => v.slashed = true,
            1 => v.activation_epoch = E0 + 5,
            2 => v.exit_epoch = E0 + 1,
            _ => v.exit_epoch = E0 + 2,
        }
        let b = build_from(chain, 1, &range(NEEDED), 1);
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
    // A record changed after the anchor's root was taken.
    let mut b = build(1, &range(NEEDED), 1);
    b.chain.validators[5].effective_balance += 1;
    b.input.registry = b.chain.registry(E0 + 1, &range(NEEDED));
    assert_eq!(verify(&b.input), Err(Error::RegistryMismatch));

    // A signer whose record carries no key: a key left out, or a validator that exited, whose record has none.
    let mut b = build(1, &range(NEEDED), 1);
    b.input.registry = b.chain.registry(E0 + 1, &range(NEEDED - 1));
    assert_eq!(verify(&b.input), Err(Error::MissingKey(NEEDED - 1)));
    let mut chain = testkit::chain(N, BALANCE);
    chain.validators[7].exit_epoch = E0;
    let mut b = build_from(chain, 1, &range(NEEDED), 1);
    let not_seven: Vec<u32> = range(NEEDED).into_iter().filter(|&i| i != 7).collect();
    b.input.registry = b.chain.registry(E0 + 1, &not_seven);
    assert_eq!(verify(&b.input), Err(Error::MissingKey(7)));

    // Another point's y, even the key's own negation, is refused.
    let mut b = build(1, &range(NEEDED), 1);
    let negated: [u8; 48] = (-b.chain.keys[3]).to_uncompressed()[48..]
        .try_into()
        .unwrap();
    b.input.registry = with_key_y(&b.chain, 3, negated);
    assert_eq!(verify(&b.input), Err(Error::BadKey(3)));

    // A point off the curve with the key's x and the same sign of y compresses to the same bytes: refused, since
    // pairing on such a point is where invalid-curve attacks start.
    let mut b = build(1, &range(NEEDED), 1);
    let mut off = b.chain.keys[4].to_uncompressed();
    off[95] ^= 1;
    let point = Option::<G1Affine>::from(G1Affine::from_uncompressed_unchecked(&off)).unwrap();
    assert!(!bool::from(point.is_on_curve()));
    assert_eq!(
        point.to_compressed(),
        b.chain.validators[4].pubkey,
        "it compresses to the key"
    );
    b.input.registry = with_key_y(&b.chain, 4, off[48..].try_into().unwrap());
    assert_eq!(verify(&b.input), Err(Error::BadKey(4)));

    let mut b = build(1, &range(NEEDED), 1);
    b.input.justification[1].signers.push(N as u32);
    assert_eq!(verify(&b.input), Err(Error::BadSigner(N as u32)));
}

/// The registry with validator `i`'s key given the y coordinate `y`, every one of the first `NEEDED` signing.
fn with_key_y(chain: &Chain, i: usize, y: [u8; 48]) -> Vec<u8> {
    registry::encode(&chain.validators, E0 + 1, |k| {
        (k < NEEDED as usize).then(|| if k == i { y } else { chain.key_y(k) })
    })
}

/// The compact registry reads back to the SSZ root of the whole one, whichever records are exited, pending, slashed or
/// signing, and it shows the stake active at C1's epoch and the next, plus the stake not yet given an activation epoch.
#[test]
fn the_compact_registry_has_the_registrys_root() {
    let c1 = E0 + 3;
    let mut chain = testkit::chain(N, BALANCE);
    for (i, v) in chain.validators.iter_mut().enumerate() {
        v.effective_balance = 32_000_000_000 + i as u64 * 1_000_000_000;
        match i % 6 {
            0 => (v.exit_epoch, v.withdrawable_epoch) = (E0 - 10 + i as u64 % 13, E0 + 300),
            1 => v.exit_epoch = c1 + 1,
            2 => v.activation_epoch = c1 + 1,
            3 => v.slashed = true,
            4 => v.activation_epoch = c1 + 2,
            _ if i % 12 == 5 => {
                (v.activation_eligibility_epoch, v.activation_epoch) = (E0 - 1, FAR_FUTURE_EPOCH)
            }
            _ => {}
        }
    }
    let signers: Vec<u32> = (0..N as u32).filter(|i| i % 4 == 1).collect();
    let bytes = chain.registry(c1, &signers);
    let r = Registry::read(&bytes, c1).expect("it reads");
    assert_eq!(r.root, validators_root(&chain.validators));
    assert_eq!(r.len, N);
    for (k, epoch) in [c1, c1 + 1].into_iter().enumerate() {
        let total: u128 = chain
            .validators
            .iter()
            .filter(|v| v.is_active(epoch) || v.activation_epoch == FAR_FUTURE_EPOCH)
            .map(|v| v.effective_balance as u128)
            .sum();
        assert_eq!(r.total[k], total, "epoch {epoch}");
    }
    assert_eq!(r.signers.len(), signers.len());
    for i in 0..N {
        let v = &chain.validators[i];
        match r.signer(i) {
            Some((_, s)) => {
                assert!(signers.contains(&(i as u32)));
                assert_eq!(s.key, chain.keys[i]);
                for (k, epoch) in [c1, c1 + 1].into_iter().enumerate() {
                    let counts = !v.slashed && v.is_active(epoch);
                    assert_eq!(s.stake[k], if counts { v.effective_balance } else { 0 });
                }
            }
            None => assert!(!signers.contains(&(i as u32))),
        }
    }
    // Every exited non-signer went short: 81 bytes, against 122 for a full record and 170 for a signer's.
    let exited = (0..N).filter(|&i| i % 6 == 0 && i % 4 != 1).count();
    assert_eq!(
        bytes.len(),
        81 * exited + 170 * signers.len() + 122 * (N - exited - signers.len())
    );
}

/// Each malformed record is refused by its index, before anything counts.
#[test]
fn a_malformed_registry_is_refused() {
    let b = build(1, &range(NEEDED), 1);
    let bad = |change: &dyn Fn(&mut Vec<u8>)| {
        let mut input = b.input.clone();
        change(&mut input.registry);
        verify(&input)
    };
    // An unknown tag, and a slashed flag that is no boolean. The first record is a signer's, 170 bytes.
    assert_eq!(bad(&|r| r[0] = 3), Err(Error::BadRecord(0)));
    assert_eq!(bad(&|r| r[1 + 88] = 2), Err(Error::BadRecord(0)));
    assert_eq!(bad(&|r| r[170 + 1 + 88] = 0xff), Err(Error::BadRecord(1)));
    // A record cut short, and a tag with no record after it.
    assert_eq!(
        bad(&|r| {
            r.pop();
        }),
        Err(Error::BadRecord(N as u32 - 1))
    );
    assert_eq!(bad(&|r| r.push(0)), Err(Error::BadRecord(N as u32)));
    assert_eq!(bad(&|r| r.clear()), Err(Error::RegistryMismatch));

    // An exited record for a validator still active at C1: it would hide its stake from the total.
    let mut chain = testkit::chain(N, BALANCE);
    chain.validators[250].exit_epoch = E0 + 2;
    let mut b = build_from(chain, 1, &range(NEEDED), 1);
    assert!(verify(&b.input).is_ok());
    b.input.registry = registry::encode(&b.chain.validators, E0 + 2, |k| {
        (k < NEEDED as usize).then(|| b.chain.key_y(k))
    });
    assert_eq!(verify(&b.input), Err(Error::BadRecord(250)));
}

/// Validators that exited by C1 go as four values each and count in neither the signed stake nor the total: with a
/// third of the registry exited, two thirds of the rest, plus the margin, is the threshold.
#[test]
fn exited_validators_count_in_neither_side() {
    let mut chain = testkit::chain(N, BALANCE);
    for v in chain.validators[200..].iter_mut() {
        v.exit_epoch = E0 - 1;
    }
    let short = build_from(chain, 1, &range(136), 1);
    assert!(matches!(
        verify(&short.input),
        Err(Error::BelowThreshold { .. })
    ));
    // Two thirds of 200 is 133.3, and three validators of margin: 137.
    let b = build_from(short.chain, 1, &range(137), 1);
    assert!(verify(&b.input).is_ok());
    assert_eq!(
        b.input.registry.len(),
        170 * 137 + 122 * 63 + 81 * 100,
        "the exited went short"
    );
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

fn secret_of(chain: &Chain, signers: &[u32]) -> Scalar {
    signers
        .iter()
        .fold(Scalar::zero(), |acc, &i| acc + chain.secrets[i as usize])
}

/// Validators added since the anchor sign in the same aggregates, as a slot's aggregate spans every committee: their
/// keys join with the deposits that prove their owners hold them, and count no stake.
#[test]
fn keys_added_since_the_anchor_sign_but_count_nothing() {
    let chain = testkit::chain(N, BALANCE);
    let fresh: Vec<Scalar> = (0..3u64).map(|k| Scalar::from(900_000 + k)).collect();
    let fresh_secret = fresh.iter().fold(Scalar::zero(), |acc, s| acc + s);
    let with_new = |signers: &[u32]| {
        let mut input = testkit::build(&chain, E0, 1, signers, 1);
        input.new_keys = fresh
            .iter()
            .map(|s| testkit::new_key(*s, 32_000_000_000))
            .collect();
        for a in input
            .justification
            .iter_mut()
            .chain(input.finalization.iter_mut())
        {
            let secret = secret_of(&chain, &a.signers) + fresh_secret;
            a.signers.extend((0..3).map(|k| (N + k) as u32));
            a.signature = testkit::sign_with(secret, &a.data);
        }
        input
    };
    let input = with_new(&range(NEEDED));
    assert!(verify(&input).is_ok());
    // They count nothing: one registry signer short is still short.
    assert!(matches!(
        verify(&with_new(&range(NEEDED - 1))),
        Err(Error::BelowThreshold { .. })
    ));
    // A signer past the new keys does not exist.
    let mut input = with_new(&range(NEEDED));
    input.justification[0].signers.push((N + 3) as u32);
    assert_eq!(verify(&input), Err(Error::BadSigner((N + 3) as u32)));
    // A deposit signed over anything else, or a key that does not decompress, proves nothing.
    let mut input = with_new(&range(NEEDED));
    input.new_keys[1].amount += 1;
    assert_eq!(verify(&input), Err(Error::BadNewKey(1)));
    let mut input = with_new(&range(NEEDED));
    input.new_keys[2].pubkey = [0xff; 48];
    assert_eq!(verify(&input), Err(Error::BadNewKey(2)));
}

/// The rogue-key attack the deposit check stops. An attacker who holds none of the honest validators' keys names a key
/// equal to its own minus theirs: the aggregate key of "the honest validators plus that key" is then its own, and its
/// own signature verifies for all of them. Without a proof of possession that would pass off the honest stake as
/// signing a checkpoint it never signed; the rogue key cannot sign its deposit, so it is refused.
#[test]
fn a_rogue_key_cannot_forge_the_honest_stake() {
    let chain = testkit::chain(N, BALANCE);
    let honest = range(NEEDED);
    let mut input = testkit::build(&chain, E0, 1, &honest, 1);
    let attacker = Scalar::from(424_242u64);
    let honest_key = honest.iter().fold(G1Projective::identity(), |acc, &i| {
        acc + G1Affine::generator() * chain.secrets[i as usize]
    });
    let rogue = (G1Affine::generator() * attacker - honest_key).to_affine();
    let mut rogue_key = testkit::new_key(attacker, 32_000_000_000);
    rogue_key.pubkey = rogue.to_compressed();
    input.new_keys = vec![rogue_key];
    for link in [&mut input.justification, &mut input.finalization] {
        let data = link[0].data;
        let mut signers = honest.clone();
        signers.push(N as u32);
        *link = vec![Aggregate {
            data,
            signature: testkit::sign_with(attacker, &data),
            signers,
        }];
    }
    // The forgery itself verifies: the claimed signers' keys sum to the attacker's.
    let data = input.justification[0].data;
    let domain = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        fork_version(data.target.epoch).unwrap(),
        &GENESIS_VALIDATORS_ROOT,
    );
    let sum = (honest_key + rogue).to_affine();
    assert!(bls::verify(
        &sum,
        &signing_root(&data.hash_tree_root(), &domain),
        &input.justification[0].signature
    ));
    // The statement refuses it at the rogue key's missing proof of possession.
    assert_eq!(verify(&input), Err(Error::BadNewKey(0)));
}

/// LG-6: validators queued in the anchor's registry but not yet given an activation epoch count in the total and never
/// as signed stake. Electra activates the whole queue at once when finality returns, so after a long stall they can be
/// active at C1 although no record says so: counted nowhere, a third of the registry queued would have let 137 of the
/// 200 active validators pass for two thirds.
#[test]
fn test_lg6_validators_queued_at_the_anchor_count_in_the_total() {
    let mut chain = testkit::chain(N, BALANCE);
    for v in chain.validators[200..].iter_mut() {
        (v.activation_eligibility_epoch, v.activation_epoch) = (E0 - 1, FAR_FUTURE_EPOCH);
    }
    match verify(&build_from(chain, 1, &range(137), 1).input) {
        Err(Error::BelowThreshold { signed, total, .. }) => {
            assert_eq!(signed, 137 * BALANCE as u128);
            assert_eq!(
                total,
                N as u128 * BALANCE as u128,
                "the queued count in the total"
            );
        }
        other => panic!("{other:?}"),
    }
    // They count no stake when they sign, even before they are queued: all 300 signing are the 200 active.
    let mut chain = testkit::chain(N, BALANCE);
    for v in chain.validators[200..].iter_mut() {
        (v.activation_eligibility_epoch, v.activation_epoch) = (FAR_FUTURE_EPOCH, FAR_FUTURE_EPOCH);
    }
    match verify(&build_from(chain, 1, &range(N as u32), 1).input) {
        Err(Error::BelowThreshold { signed, total, .. }) => {
            assert_eq!(signed, 200 * BALANCE as u128, "the queued sign for nothing");
            assert_eq!(total, N as u128 * BALANCE as u128);
        }
        other => panic!("{other:?}"),
    }
    // One whose activation epoch is set is counted exactly: from that epoch on, and not before.
    let mut chain = testkit::chain(N, BALANCE);
    for v in chain.validators[200..].iter_mut() {
        v.activation_epoch = E0 + 50;
    }
    assert!(verify(&build_from(chain, 1, &range(137), 1).input).is_ok());
}

/// Moves C1's block to `slot`, and re-signs both links, by every validator, for the block's new root.
fn checkpoint_block_at(chain: &Chain, input: &mut Input, slot: u64) {
    let source = input.justification[0].data.source;
    let epoch = input.justification[0].data.target.epoch;
    let c2 = input.finalization[0].data.target;
    input.header.slot = slot;
    let c1 = Checkpoint {
        epoch,
        root: input.header.hash_tree_root(),
    };
    input.justification = testkit::votes(chain, &range(N as u32), source, c1);
    input.finalization = testkit::votes(chain, &range(N as u32), c1, c2);
}

/// LG-6: C1's block may be one epoch older than C1, where C1's first slot was missed, which the margin's extra epoch
/// covers; an older block would leave the next anchor's records staler than its margin counts, and is refused.
#[test]
fn test_lg6_a_checkpoint_block_two_epochs_old_is_refused() {
    let gap = 12;
    let e1 = E0 + gap;
    for (slot, ok) in [
        (e1 * 32, true),
        (e1 * 32 - 1, true),
        ((e1 - 1) * 32, true),
        ((e1 - 1) * 32 - 1, false),
        ((e1 - 10) * 32, false),
    ] {
        let mut b = build(gap, &range(N as u32), 1);
        checkpoint_block_at(&b.chain, &mut b.input, slot);
        let r = verify(&b.input);
        if ok {
            assert_eq!(r.map(|o| o.epoch), Ok(e1), "slot {slot}");
        } else {
            assert_eq!(r, Err(Error::StaleCheckpointBlock), "slot {slot}");
        }
    }
}

/// LG-I2: the justification's source comes before C1, as every honest vote's does.
#[test]
fn test_lgi2_the_justifications_source_comes_before_c1() {
    for (shift, ok) in [(-1i64, true), (0, false), (7, false)] {
        let mut b = build(1, &range(NEEDED), 1);
        let c1 = b.input.justification[0].data.target;
        let source = Checkpoint {
            epoch: c1.epoch.checked_add_signed(shift).unwrap(),
            root: [0xee; 32],
        };
        b.input.justification = testkit::votes(&b.chain, &range(NEEDED), source, c1);
        let r = verify(&b.input);
        if ok {
            assert!(r.is_ok(), "source {shift} from C1");
        } else {
            assert_eq!(r, Err(Error::LinksDisagree), "source {shift} from C1");
        }
    }
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
