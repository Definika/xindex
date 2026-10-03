//! The statement on mainnet's own chain (`fixtures/mainnet.json`, which `fixtures/generate.py` rebuilds and checks
//! with a separate implementation): epoch E-1's producers, E-1's last final block naming E's, and the head, in E,
//! naming E+1's. Every check is then broken one at a time, on the real blocks and on a small set of generated keys.

use ed25519_dalek::{Signer, SigningKey};
use serde_json::Value;
use xindex_near_finality::*;

fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn h32(v: &Value) -> Hash {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../fixtures/mainnet.json")).unwrap()
}

fn producers(v: &Value) -> Vec<Producer> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| Producer {
            account_id: p["account_id"].as_str().unwrap().to_string(),
            public_key: h32(&p["public_key"]),
            stake: p["stake"].as_str().unwrap().parse().unwrap(),
        })
        .collect()
}

fn inner_lite(v: &Value) -> InnerLite {
    InnerLite {
        height: v["height"].as_u64().unwrap(),
        epoch_id: h32(&v["epoch_id"]),
        next_epoch_id: h32(&v["next_epoch_id"]),
        prev_state_root: h32(&v["prev_state_root"]),
        outcome_root: h32(&v["outcome_root"]),
        timestamp: v["timestamp"].as_u64().unwrap(),
        next_bp_hash: h32(&v["next_bp_hash"]),
        block_merkle_root: h32(&v["block_merkle_root"]),
    }
}

fn block(v: &Value) -> LightClientBlock {
    LightClientBlock {
        prev_block_hash: h32(&v["prev_block_hash"]),
        next_block_inner_hash: h32(&v["next_block_inner_hash"]),
        inner_lite: inner_lite(&v["inner_lite"]),
        inner_rest_hash: h32(&v["inner_rest_hash"]),
        next_bps: v["next_bps"].as_array().map(|_| producers(&v["next_bps"])),
        approvals_after_next: v["approvals_after_next"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().map(|s| Sig(hex(s).try_into().unwrap())))
            .collect(),
    }
}

fn real() -> (Input, Value) {
    let f = fixture();
    let input = Input {
        epoch_id: h32(&f["anchor"]["epoch_id"]),
        producers: producers(&f["anchor"]["producers"]),
        blocks: f["blocks"].as_array().unwrap().iter().map(block).collect(),
    };
    (input, f)
}

/// Mainnet's chain verifies, and commits what the separate implementation computed: E-1's producers in, E+1's out,
/// named by the head, and the head's height, time and block Merkle root.
#[test]
fn mainnet_verifies() {
    let (input, f) = real();
    let out = verify(&input).expect("mainnet's own chain");
    assert_eq!(out.abi_encode(), hex(f["public_values"].as_str().unwrap()));
    assert_eq!(out.producers_in, h32(&f["anchor"]["producers_hash"]));
    let head = &input.blocks[1];
    assert_eq!(out.epoch_out, head.inner_lite.next_epoch_id);
    assert_eq!(out.named_at, head.inner_lite.timestamp);
    assert_eq!(
        block_hash(
            &head.inner_lite,
            &head.inner_rest_hash,
            &head.prev_block_hash
        )
        .to_vec(),
        hex(f["head_hash"].as_str().unwrap())
    );
    // Both blocks clear two thirds by a margin, as the generator measured: 70% and 84% of stake.
    let (a, t) = approved_stake(&input.blocks[0], &input.producers).unwrap();
    assert!(a * 100 / t >= 70);
}

/// One epoch at a time: the head, in E, cannot be checked from E-1 without E-1's block naming E's producers, and a
/// block cannot repeat or go back.
#[test]
fn epochs_are_followed_one_at_a_time() {
    let (input, _) = real();
    let mut skip = input.clone();
    skip.blocks.remove(0);
    let height = skip.blocks[0].inner_lite.height;
    assert_eq!(verify(&skip), Err(Error::WrongEpoch { height }));

    let mut unnamed = input.clone();
    unnamed.blocks[0].next_bps = None;
    assert_eq!(verify(&unnamed), Err(Error::WrongEpoch { height }));

    let mut twice = input.clone();
    twice.blocks.insert(1, input.blocks[0].clone());
    let h0 = input.blocks[0].inner_lite.height;
    assert_eq!(
        verify(&twice),
        Err(Error::NotAfterTheLast {
            height: h0,
            last: h0
        })
    );

    let mut back = input.clone();
    back.blocks.reverse();
    assert!(verify(&back).is_err());

    let mut other = input.clone();
    other.epoch_id[0] ^= 1;
    assert_eq!(
        verify(&other),
        Err(Error::WrongEpoch {
            height: input.blocks[0].inner_lite.height
        })
    );
    assert_eq!(
        verify(&Input {
            blocks: vec![],
            ..input
        }),
        Err(Error::NoBlocks)
    );
}

/// The next producers must be exactly those the header commits to.
#[test]
fn the_next_producers_are_the_committed_ones() {
    let (input, _) = real();
    let height = input.blocks[0].inner_lite.height;
    for change in 0..4 {
        let mut bad = input.clone();
        let next = bad.blocks[0].next_bps.as_mut().unwrap();
        match change {
            0 => next[3].stake += 1,
            1 => next[3].public_key[5] ^= 1,
            2 => next[3].account_id.push('x'),
            _ => {
                next.pop();
            }
        }
        assert_eq!(verify(&bad), Err(Error::WrongNextProducers { height }));
    }
}

/// Every present approval must verify, over exactly the light client's message, under its own producer's key.
#[test]
fn every_approval_must_verify() {
    let (input, _) = real();
    let b0 = &input.blocks[0];
    let height = b0.inner_lite.height;
    let signer = b0
        .approvals_after_next
        .iter()
        .position(|a| a.is_some())
        .unwrap();

    let mut forged = input.clone();
    forged.blocks[0].approvals_after_next[signer]
        .as_mut()
        .unwrap()
        .0[7] ^= 1;
    assert_eq!(
        verify(&forged),
        Err(Error::BadSignature {
            height,
            producer: signer
        })
    );

    // Any change to what was signed: the next block's inner hash, the header, the rest of it, the parent.
    let edits: [fn(&mut LightClientBlock); 5] = [
        |b| b.next_block_inner_hash[0] ^= 1,
        |b| b.inner_lite.timestamp += 1,
        |b| b.inner_lite.block_merkle_root[0] ^= 1,
        |b| b.inner_rest_hash[0] ^= 1,
        |b| b.prev_block_hash[0] ^= 1,
    ];
    for edit in edits {
        let mut bad = input.clone();
        edit(&mut bad.blocks[0]);
        assert_eq!(
            verify(&bad),
            Err(Error::BadSignature {
                height,
                producer: signer
            })
        );
    }

    // Another producer's key in its place: the anchor's hash changes, and the signature fails under it.
    let mut swapped = input.clone();
    swapped.producers.swap(signer, signer + 1);
    assert!(matches!(verify(&swapped), Err(Error::BadSignature { .. })));

    // A key that does not decompress fails the block, as nearcore's `Signature::verify` returns false.
    let mut bad_key = input.clone();
    bad_key.producers[signer].public_key = (0u8..=255)
        .map(|y| {
            let mut k = [0u8; 32];
            k[0] = y;
            k
        })
        .find(|k| ed25519_dalek::VerifyingKey::from_bytes(k).is_err())
        .expect("a y-coordinate off the curve");
    assert_eq!(
        verify(&bad_key),
        Err(Error::BadKey {
            height,
            producer: signer
        })
    );
}

/// Strictly more than two thirds of the whole set's stake: dropping approvals until it is no more fails the block.
#[test]
fn more_than_two_thirds_of_the_stake() {
    let (mut input, _) = real();
    let (approved, total) = approved_stake(&input.blocks[0], &input.producers).unwrap();
    assert!(approved > total * 2 / 3);
    let mut a = approved;
    for i in 0..input.producers.len() {
        if a <= total * 2 / 3 {
            break;
        }
        if input.blocks[0].approvals_after_next[i].take().is_some() {
            a -= input.producers[i].stake;
        }
    }
    let height = input.blocks[0].inner_lite.height;
    assert_eq!(
        verify(&input),
        Err(Error::NotEnoughStake {
            height,
            approved: a,
            total
        })
    );
}

// ---------------------------------------------------------------------
// a small set of generated keys, for the boundaries
// ---------------------------------------------------------------------

fn keys(n: usize) -> Vec<SigningKey> {
    (0..n)
        .map(|i| SigningKey::from_bytes(&sha256(&[b"key", &[i as u8]])))
        .collect()
}

fn set(keys: &[SigningKey], stakes: &[u128]) -> Vec<Producer> {
    keys.iter()
        .zip(stakes)
        .enumerate()
        .map(|(i, (k, s))| Producer {
            account_id: format!("p{i}.near"),
            public_key: k.verifying_key().to_bytes(),
            stake: *s,
        })
        .collect()
}

/// A block of epoch `epoch` at `height`, approved by the keys `by` signs for.
fn signed(
    epoch: Hash,
    height: u64,
    keys: &[SigningKey],
    by: &[bool],
    next: Option<Vec<Producer>>,
) -> LightClientBlock {
    let mut b = LightClientBlock {
        prev_block_hash: sha256(&[b"prev", &height.to_le_bytes()]),
        next_block_inner_hash: sha256(&[b"next", &height.to_le_bytes()]),
        inner_lite: InnerLite {
            height,
            epoch_id: epoch,
            next_epoch_id: sha256(&[b"epoch after", &epoch]),
            prev_state_root: [1; 32],
            outcome_root: [2; 32],
            timestamp: 1_791_000_000_000_000_000 + height,
            next_bp_hash: next.as_ref().map(|n| producers_hash(n)).unwrap_or([3; 32]),
            block_merkle_root: sha256(&[b"blocks", &height.to_le_bytes()]),
        },
        inner_rest_hash: [4; 32],
        next_bps: next,
        approvals_after_next: vec![],
    };
    let message = approval_message(&b);
    b.approvals_after_next = keys
        .iter()
        .zip(by)
        .map(|(k, yes)| yes.then(|| Sig(k.sign(&message).to_bytes())))
        .collect();
    b
}

/// Exactly two thirds is not enough; one more yoctoNEAR is. Approvals past the set are ignored, and a producer with
/// no slot counts as not approving.
#[test]
fn the_threshold_is_strict() {
    let ks = keys(4);
    let stakes = [1_000, 1_000, 1_000, 3_000u128];
    let epoch = [9; 32];
    let ps = set(&ks, &stakes);
    // 4,000 of 6,000: exactly two thirds.
    let b = signed(epoch, 10, &ks, &[true, false, false, true], None);
    let input = Input {
        epoch_id: epoch,
        producers: ps.clone(),
        blocks: vec![b],
    };
    assert_eq!(
        verify(&input),
        Err(Error::NotEnoughStake {
            height: 10,
            approved: 4_000,
            total: 6_000
        })
    );
    let mut more = ps.clone();
    more[3].stake += 1;
    let b = signed(epoch, 10, &ks, &[true, false, false, true], None);
    assert!(verify(&Input {
        epoch_id: epoch,
        producers: more,
        blocks: vec![b]
    })
    .is_ok());

    // An approval beyond the set changes nothing; one slot short means that producer did not approve.
    let mut extra = signed(epoch, 11, &ks, &[true, true, true, true], None);
    extra.approvals_after_next.push(Some(Sig([0; 64])));
    assert!(verify(&Input {
        epoch_id: epoch,
        producers: ps.clone(),
        blocks: vec![extra]
    })
    .is_ok());
    let mut short = signed(epoch, 12, &ks, &[true, true, true, true], None);
    short.approvals_after_next.truncate(3);
    assert_eq!(
        verify(&Input {
            epoch_id: epoch,
            producers: ps,
            blocks: vec![short]
        }),
        Err(Error::NotEnoughStake {
            height: 12,
            approved: 3_000,
            total: 6_000
        })
    );
}

/// Three epochs in one proof: each block is checked by the set the block before named, and the proof ends at the last
/// set named, at the time its block named it.
#[test]
fn several_epochs_in_one_proof() {
    let (a, b, c) = (keys(3), keys(5)[2..].to_vec(), keys(7)[4..].to_vec());
    let (sa, sb, sc) = (
        set(&a, &[5, 5, 5]),
        set(&b, &[10, 10, 1]),
        set(&c, &[1, 1, 1]),
    );
    let e0 = [7; 32];
    let b1 = signed(e0, 100, &a, &[true, true, true], Some(sb.clone()));
    let e1 = b1.inner_lite.next_epoch_id;
    let b2 = signed(e1, 200, &b, &[true, true, false], None);
    let b3 = signed(e1, 300, &b, &[true, true, true], Some(sc.clone()));
    let out = verify(&Input {
        epoch_id: e0,
        producers: sa.clone(),
        blocks: vec![b1.clone(), b2.clone(), b3.clone()],
    })
    .unwrap();
    assert_eq!(out.epoch_out, b3.inner_lite.next_epoch_id);
    assert_eq!(out.producers_out, producers_hash(&sc));
    assert_eq!(out.named_at, b3.inner_lite.timestamp);
    assert_eq!((out.height, out.timestamp), (300, b3.inner_lite.timestamp));

    // A proof that names no set keeps the set it started from, and says so with a zero time.
    let same = verify(&Input {
        epoch_id: e1,
        producers: sb.clone(),
        blocks: vec![b2.clone()],
    })
    .unwrap();
    assert_eq!(
        (same.epoch_out, same.producers_out, same.named_at),
        (e1, producers_hash(&sb), 0)
    );

    // Signed by the old set where the new one rules: refused.
    let stale = signed(e1, 250, &a, &[true, true, true], None);
    assert!(matches!(
        verify(&Input {
            epoch_id: e0,
            producers: sa,
            blocks: vec![b1, stale]
        }),
        Err(Error::BadSignature { .. })
    ));
}
