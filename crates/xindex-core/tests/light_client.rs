//! The light client's rules on real data: block 26,092,387's receipts trie (`test/fixtures/ethereum/receipts.json`,
//! rebuilt and checked against its header by `test/fixtures/ethereum/generate.py`), under a headers root a proof would
//! have recorded; and the anchor's step and lag, as `EthereumFinalityVerifier.t.sol` checks them on the EVM.

mod common;

use common::*;
use serde_json::Value;
use xindex_core::crypto::Crypto;
use xindex_core::event::word;
use xindex_core::light_client::*;

/// The real block, and what a proof over blocks `first..=last` around it records.
struct Block {
    f: Value,
    number: u64,
    timestamp: u64,
    state_root: [u8; 32],
    receipts_root: [u8; 32],
}

fn block() -> Block {
    let f = json("test/fixtures/ethereum/receipts.json");
    Block {
        number: f["number"].as_u64().unwrap(),
        timestamp: f["timestamp"].as_u64().unwrap(),
        state_root: h32(&f["stateRoot"]),
        receipts_root: h32(&f["receiptsRoot"]),
        f,
    }
}

fn leaf(n: u64, t: u64, s: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    C.keccak256(&[&word(n), &word(t), s, r])
}

/// The headers tree over `leaves`, layer by layer, a zero for an odd layer's missing sibling: its root, and the path of
/// leaf `index`.
fn tree(leaves: &[[u8; 32]], index: usize) -> ([u8; 32], Vec<[u8; 32]>) {
    let mut layer = leaves.to_vec();
    let mut path = Vec::new();
    let mut i = index;
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            layer.push([0u8; 32]);
        }
        path.push(layer[i ^ 1]);
        layer = layer
            .chunks(2)
            .map(|p| C.keccak256(&[&p[0], &p[1]]))
            .collect();
        i /= 2;
    }
    (layer[0], path)
}

/// A proof over five blocks, the real one second: the headers root, the range and the real block's path.
fn five(b: &Block) -> ([u8; 32], (u64, u64), Vec<[u8; 32]>) {
    let first = b.number - 1;
    let leaves: Vec<[u8; 32]> = (0..5)
        .map(|i| {
            if i == 1 {
                leaf(b.number, b.timestamp, &b.state_root, &b.receipts_root)
            } else {
                leaf(first + i, b.timestamp, &[i as u8; 32], &[i as u8; 32])
            }
        })
        .collect();
    let (root, path) = tree(&leaves, 1);
    (root, (first, first + 4), path)
}

fn header(root: &[u8; 32], b: &Block, receipts_root: &[u8; 32], path: &[[u8; 32]]) -> Vec<u8> {
    let mut out = [
        &root[..],
        &b.number.to_le_bytes(),
        &b.timestamp.to_le_bytes(),
        &b.state_root,
        receipts_root,
    ]
    .concat();
    out.push(path.len() as u8);
    path.iter().for_each(|p| out.extend_from_slice(p));
    out
}

fn event_proof(head: Vec<u8>, nodes: &Value, tx: u64, log: u64) -> Vec<u8> {
    let nodes: Vec<Vec<u8>> = nodes.as_array().unwrap().iter().map(bytes).collect();
    let mut out = head;
    out.push(nodes.len() as u8);
    for n in &nodes {
        out.extend_from_slice(&(n.len() as u32).to_le_bytes());
        out.extend_from_slice(n);
    }
    out.extend_from_slice(&(tx as u32).to_le_bytes());
    out.extend_from_slice(&(log as u32).to_le_bytes());
    out
}

fn claim_of(b: &Block, case: &Value) -> LogClaim {
    LogClaim {
        block: b.number,
        emitter: h20(&case["emitter"]),
        topic0: h32(&case["topic0"]),
        topic1: h32(&case["topic1"]),
        data_hash: C.keccak256(&[&bytes(&case["data"])]),
    }
}

/// Every real log verifies: a one-byte key, a two-byte key (index 130), and a legacy receipt with no type byte; each
/// claim it does not hold is refused, and so is a headers root no proof recorded.
#[test]
fn real_receipts_verify() {
    let b = block();
    let (root, range, path) = five(&b);
    let lookup = |r: &[u8; 32]| {
        if *r == root {
            Ok(range)
        } else {
            Err(Error::UnknownHeaders)
        }
    };
    for case in b.f["cases"].as_array().unwrap() {
        let proof = event_proof(
            header(&root, &b, &b.receipts_root, &path),
            &case["proof"],
            case["txIndex"].as_u64().unwrap(),
            case["logIndex"].as_u64().unwrap(),
        );
        let claim = claim_of(&b, case);
        assert_eq!(verify_event(&C, &proof, &claim, lookup), Ok(()));
        for wrong in [
            LogClaim {
                block: b.number + 1,
                ..claim_of(&b, case)
            },
            LogClaim {
                emitter: [9; 20],
                ..claim_of(&b, case)
            },
            LogClaim {
                topic1: [9; 32],
                ..claim_of(&b, case)
            },
            LogClaim {
                data_hash: [9; 32],
                ..claim_of(&b, case)
            },
        ] {
            assert_eq!(
                verify_event(&C, &proof, &wrong, lookup),
                Err(Error::NotTheLog)
            );
        }
        let mut trailing = proof.clone();
        trailing.push(0);
        assert_eq!(
            verify_event(&C, &trailing, &claim, lookup),
            Err(Error::BadEventProof)
        );
        let unknown = event_proof(
            header(&[7; 32], &b, &b.receipts_root, &path),
            &case["proof"],
            case["txIndex"].as_u64().unwrap(),
            case["logIndex"].as_u64().unwrap(),
        );
        assert_eq!(
            verify_event(&C, &unknown, &claim, lookup),
            Err(Error::UnknownHeaders)
        );
    }
}

/// A failed transaction, an absent receipt, a log of one topic, and a malformed receipt, each refused by name.
#[test]
fn what_is_not_a_message_is_refused() {
    let b = block();
    let (root, range, path) = five(&b);
    let any = claim_of(&b, &b.f["cases"][0]);
    let run = |receipts_root: &[u8; 32], case: &Value, log: u64| {
        // The real block under the five-block root; or, for the malformed receipt's own receipts root, a block of its
        // own, recorded alone.
        let (head, recorded) = if *receipts_root == b.receipts_root {
            (header(&root, &b, receipts_root, &path), range)
        } else {
            let own = leaf(b.number, b.timestamp, &b.state_root, receipts_root);
            (header(&own, &b, receipts_root, &[]), (b.number, b.number))
        };
        let tx = case["txIndex"].as_u64().unwrap_or(0);
        let proof = event_proof(head, &case["proof"], tx, log);
        verify_event(&C, &proof, &any, |_| Ok(recorded))
    };
    assert_eq!(
        run(&b.receipts_root, &b.f["failed"], 0),
        Err(Error::FailedTransaction)
    );
    assert_eq!(
        run(&b.receipts_root, &b.f["absent"], 0),
        Err(Error::NoReceipt)
    );
    assert_eq!(
        run(&b.receipts_root, &b.f["oneTopic"], 2),
        Err(Error::NoLog)
    );
    assert_eq!(
        run(&b.receipts_root, &b.f["cases"][0], 99),
        Err(Error::NoLog),
        "past the receipt's last log"
    );
    let malformed = h32(&b.f["malformed"]["receiptsRoot"]);
    assert_eq!(
        run(&malformed, &b.f["malformed"], 0),
        Err(Error::BadReceiptProof)
    );
}

/// A checkpoint is the very block: its number, timestamp and state root at their place under a recorded root.
#[test]
fn a_checkpoint_is_the_very_block() {
    let b = block();
    let (root, range, path) = five(&b);
    let proof = header(&root, &b, &b.receipts_root, &path);
    let good = || CheckpointClaim {
        block: b.number,
        timestamp: b.timestamp,
        state_root: b.state_root,
    };
    let lookup = |_: &[u8; 32]| Ok(range);
    assert_eq!(verify_checkpoint(&C, &proof, &good(), lookup), Ok(()));
    for wrong in [
        CheckpointClaim {
            block: b.number + 1,
            ..good()
        },
        CheckpointClaim {
            timestamp: b.timestamp + 1,
            ..good()
        },
        CheckpointClaim {
            state_root: [1; 32],
            ..good()
        },
    ] {
        assert_eq!(
            verify_checkpoint(&C, &proof, &wrong, lookup),
            Err(Error::NotTheCheckpoint)
        );
    }
    // Placed elsewhere in the tree, outside its range, or under a path of the wrong depth.
    assert_eq!(
        verify_checkpoint(&C, &proof, &good(), |_| Ok((b.number + 1, b.number + 5))),
        Err(Error::NotInRange)
    );
    assert_eq!(
        verify_checkpoint(&C, &proof, &good(), |_| Ok((b.number - 2, b.number + 2))),
        Err(Error::BadHeaderPath)
    );
    let shallow = header(&root, &b, &b.receipts_root, &path[..2]);
    assert_eq!(
        verify_checkpoint(&C, &shallow, &good(), lookup),
        Err(Error::BadHeaderPath)
    );
}

fn values(anchor_in: u8, anchor_out: u8, epoch: u64, first: u64, last: u64) -> Vec<u8> {
    [
        [anchor_in; 32],
        [anchor_out; 32],
        word(epoch),
        [0x77; 32],
        word(first),
        word(last),
    ]
    .concat()
}

/// Each proof starts from the stored anchor and moves it one step: as `EthereumFinalityVerifier.update`.
#[test]
fn an_update_follows_the_anchor() {
    let (mut anchor, mut epoch) = ([0xaa; 32], 5u64);
    let v = advance(
        &mut anchor,
        &mut epoch,
        &values(0xaa, 0xbb, 6, 100, 163),
        0,
        0,
    )
    .unwrap();
    assert_eq!((anchor, epoch), ([0xbb; 32], 6));
    assert_eq!((v.headers_root, v.first, v.last), ([0x77; 32], 100, 163));
    assert!(matches!(
        advance(
            &mut anchor,
            &mut epoch,
            &values(0xaa, 0xbb, 6, 100, 163),
            0,
            0
        ),
        Err(Error::WrongAnchor)
    ));
    assert!(advance(
        &mut anchor,
        &mut epoch,
        &values(0xbb, 0xcc, 7, 164, 200),
        0,
        0
    )
    .is_ok());
}

/// B5-01: an update must end at a checkpoint whose epoch began at most MAX_UPDATE_AGE before now, as
/// `FinalityVerifier.update`: a stale one-epoch step would void the honest proofs in flight while aging the anchor.
#[test]
fn test_b501_an_update_must_land_a_recent_checkpoint() {
    assert_eq!(MAX_UPDATE_AGE, 6 * 3_600);
    let (genesis, next) = (1_606_824_023u64, 400_001u64);
    let fresh_until = (genesis + next * 384 + MAX_UPDATE_AGE) as i64;
    let v = values(0xaa, 0xbb, next, 100, 163);
    let (mut anchor, mut epoch) = ([0xaa; 32], next - 1);
    assert!(matches!(
        advance(&mut anchor, &mut epoch, &v, genesis, fresh_until + 1),
        Err(Error::Stale)
    ));
    assert_eq!(
        (anchor, epoch),
        ([0xaa; 32], next - 1),
        "a refused step moves nothing"
    );
    assert!(advance(&mut anchor, &mut epoch, &v, genesis, fresh_until).is_ok());
    assert_eq!((anchor, epoch), ([0xbb; 32], next));
    assert_eq!(
        check_fresh(next, genesis, fresh_until + 1),
        Err(Error::Stale)
    );
    assert_eq!(
        check_fresh(u64::MAX, genesis, i64::MAX),
        Ok(()),
        "saturates, never wraps"
    );
}

/// LG-4: an update is taken until exactly a day after the anchor's epoch began, and refused a second later.
#[test]
fn test_lg4_an_update_comes_at_most_a_day_after_its_anchor() {
    let (genesis, epoch) = (1_606_824_023u64, 400_000u64);
    let bound = (genesis + epoch * 384 + 86_400) as i64;
    assert_eq!(lag_ends(epoch, genesis), bound as u64);
    assert_eq!(check_lag(epoch, genesis, bound), Ok(()));
    assert_eq!(check_lag(epoch, genesis, bound + 1), Err(Error::Lagging));
    assert_eq!(check_lag(epoch, genesis, 0), Ok(()));
    assert_eq!(
        check_lag(epoch, genesis, bound + 365 * 86_400),
        Err(Error::Lagging)
    );
    assert_eq!(
        check_lag(u64::MAX, genesis, i64::MAX),
        Ok(()),
        "saturates, never wraps"
    );
}

#[test]
fn public_values_are_six_words_of_the_right_widths() {
    let (mut anchor, mut epoch) = ([0xaa; 32], 5u64);
    let mut v = values(0xaa, 0xbb, 6, 100, 163);
    v[2 * 32] = 1;
    assert!(matches!(
        advance(&mut anchor, &mut epoch, &v, 0, 0),
        Err(Error::BadPublicValues)
    ));
    let mut v = values(0xaa, 0xbb, 6, 100, 163);
    v[5 * 32 + 23] = 1;
    assert!(matches!(
        advance(&mut anchor, &mut epoch, &v, 0, 0),
        Err(Error::BadPublicValues)
    ));
    let v = values(0xaa, 0xbb, 6, 100, 163);
    assert!(matches!(
        advance(&mut anchor, &mut epoch, &v[..191], 0, 0),
        Err(Error::BadPublicValues)
    ));
    assert_eq!((anchor, epoch), ([0xaa; 32], 5), "nothing moved");
}
