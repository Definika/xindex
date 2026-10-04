//! Throwaway review probes (not for commit): adversarial inputs the statement must count correctly, and the corners
//! the margin's assumptions do not cover.

use bls12_381::Scalar;
use xindex_finality::beacon::{Checkpoint, FAR_FUTURE_EPOCH};
use xindex_finality::testkit::{self, Chain};
use xindex_finality::{verify, Error, Input};

const N: usize = 300;
const BALANCE: u64 = 2_048_000_000_000;
const E0: u64 = 411_400;
const NEEDED: u32 = 203;

fn range(n: u32) -> Vec<u32> {
    (0..n).collect()
}

fn secret_of(chain: &Chain, signers: &[u32]) -> Scalar {
    signers
        .iter()
        .fold(Scalar::zero(), |acc, &i| acc + chain.secrets[i as usize])
}

/// Re-signs every aggregate of both links with the secrets of its registry signers plus `extra`.
fn resign(chain: &Chain, input: &mut Input, extra: Scalar) {
    for a in input
        .justification
        .iter_mut()
        .chain(input.finalization.iter_mut())
    {
        let registry_signers: Vec<u32> = a
            .signers
            .iter()
            .copied()
            .filter(|&i| (i as usize) < N)
            .collect();
        let s = secret_of(chain, &registry_signers) + extra;
        a.signature = testkit::sign_with(s, &a.data);
    }
}

/// A signer listed twice, with the signature doubled to match: the aggregate verifies, the stake counts once.
#[test]
fn probe_duplicate_signer_with_matching_signature_counts_once() {
    let chain = testkit::chain(N, BALANCE);
    let mut input = testkit::build(&chain, E0, 1, &range(NEEDED - 1), 1);
    for a in input
        .justification
        .iter_mut()
        .chain(input.finalization.iter_mut())
    {
        // Every signer listed twice: the key doubles, and so does the signature.
        let doubled: Vec<u32> = a.signers.iter().flat_map(|&i| [i, i]).collect();
        let s = secret_of(&chain, &doubled);
        a.signers = doubled;
        a.signature = testkit::sign_with(s, &a.data);
    }
    let r = verify(&input);
    println!("duplicate signers, one short: {r:?}");
    assert!(matches!(r, Err(Error::BelowThreshold { .. })));
}

/// A registry validator's own key presented again as a "new key" with its real deposit signature, and listed both
/// ways: the key is legitimately possessed, but it adds no stake.
#[test]
fn probe_registry_key_reused_as_new_key_adds_no_stake() {
    let chain = testkit::chain(N, BALANCE);
    let mut input = testkit::build(&chain, E0, 1, &range(NEEDED - 1), 1);
    // Validator 0's key, with a deposit signed by validator 0's secret.
    input.new_keys = vec![testkit::new_key(chain.secrets[0], 32_000_000_000)];
    for a in input
        .justification
        .iter_mut()
        .chain(input.finalization.iter_mut())
    {
        a.signers.push(N as u32);
    }
    resign(&chain, &mut input, chain.secrets[0]);
    let r = verify(&input);
    println!("registry key as new key, one short: {r:?}");
    assert!(matches!(r, Err(Error::BelowThreshold { .. })));
}

/// A validator whose record at the anchor shows no activation yet (activation_epoch FAR_FUTURE) but which the real
/// chain activates before C1: the statement counts it in neither the total nor the signed stake.
#[test]
fn probe_validator_pending_at_the_anchor_counts_nowhere() {
    let mut chain = testkit::chain(N, BALANCE);
    for v in chain.validators[200..].iter_mut() {
        v.activation_epoch = FAR_FUTURE_EPOCH;
    }
    // Two thirds of the 200 active, plus three validators of margin: 137 suffice, though 300 are active in reality.
    let input = testkit::build(&chain, E0, 1, &range(137), 1);
    let r = verify(&input);
    println!("100 of 300 pending at the anchor, 137 sign: {r:?}");
    assert!(r.is_ok());
}

/// The justification link's source is not constrained at all: a source at or after C1's own epoch is accepted.
#[test]
fn probe_justification_source_is_unconstrained() {
    let chain = testkit::chain(N, BALANCE);
    let mut input = testkit::build(&chain, E0, 1, &range(NEEDED), 1);
    let c1 = input.justification[0].data.target;
    for a in input.justification.iter_mut() {
        a.data.source = Checkpoint {
            epoch: c1.epoch + 7,
            root: [0xee; 32],
        };
    }
    resign(&chain, &mut input, Scalar::zero());
    let r = verify(&input);
    println!("source after the target: {:?}", r.as_ref().map(|o| o.epoch));
    assert!(r.is_ok());
}

/// C1's block ten epochs older than C1's epoch (ten empty epochs): accepted, and the new anchor claims epoch e1 for a
/// registry taken ten epochs earlier, while the next proof's margin assumes it is at most one epoch older.
#[test]
fn probe_checkpoint_block_older_than_its_epoch() {
    let chain = testkit::chain(N, BALANCE);
    let mut input = testkit::build(&chain, E0, 12, &range(N as u32), 1);
    let e1 = input.justification[0].data.target.epoch;
    input.header.slot = (e1 - 10) * 32;
    let c1 = Checkpoint {
        epoch: e1,
        root: input.header.hash_tree_root(),
    };
    for a in input.justification.iter_mut() {
        a.data.target = c1;
    }
    for a in input.finalization.iter_mut() {
        a.data.source = c1;
    }
    resign(&chain, &mut input, Scalar::zero());
    let out = verify(&input).expect("accepted");
    println!(
        "header slot epoch {} (C1 epoch {}), committed epoch {}",
        input.header.slot / 32,
        e1,
        out.epoch
    );
    assert_eq!(out.epoch, e1);
}
