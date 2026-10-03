//! Checkpoints, the stall and stall recovery (LG-2, LG-3), and the snapshot's start (VLT-5), against the EVM vault's
//! rules (Stage B spec, section 5.6).

use super::*;

impl T {
    /// Registers a successor pair, SP1's and RISC Zero's light clients under seeds of their own.
    fn new_pair(&mut self, seed: u8) -> ([u8; 32], [u8; 32]) {
        let (a, b) = (
            verifier_config(SP1, seed, epoch_at(self.now)),
            verifier_config(RISC_ZERO, seed + 1, epoch_at(self.now)),
        );
        let ida = self.call(RELAYER, ONE, |v| v.register_verifier(a));
        let idb = self.call(RELAYER, ONE, |v| v.register_verifier(b));
        (ida.0, idb.0)
    }

    /// The continuity test `pair` passes: the vault's last checkpoint, a recent one at `recent_block`, and, if one was
    /// delivered, the last message, `payload` in `block`, each proven by both.
    fn continuity(
        &mut self,
        pair: ([u8; 32], [u8; 32]),
        recent_block: u64,
        last: Option<(&[u8], u64)>,
    ) -> Continuity {
        let checkpoint = self.v.checkpoint;
        let last_proofs = self.checkpoint_proofs(&checkpoint, Some(pair));
        let recent = Checkpoint {
            block: recent_block,
            timestamp: self.now,
            state_root: Hex32(keccak(&[b"recent", &recent_block.to_le_bytes()])),
        };
        let recent_proofs = self.checkpoint_proofs(&recent, Some(pair));
        let message = last.map(|(payload, block)| {
            let index = self.index;
            let id = keccak(&[payload]);
            let leaf = receipt_leaf(&receipt(&index, &id, payload));
            let (head, root) = header(block, self.now, &[7u8; 32], &keccak(&[&leaf]));
            self.record_for(&pair.0, root, block);
            self.record_for(&pair.1, root, block);
            let proof = [
                head,
                vec![1u8],
                (leaf.len() as u32).to_le_bytes().to_vec(),
                leaf,
                0u32.to_le_bytes().to_vec(),
                0u32.to_le_bytes().to_vec(),
            ]
            .concat();
            LastMessage {
                payload: Base64VecU8(payload.to_vec()),
                block,
                proofs: PairProofs {
                    proof1: Base64VecU8(proof.clone()),
                    proof2: Base64VecU8(proof),
                },
            }
        });
        Continuity {
            last: last_proofs,
            recent,
            recent_proofs,
            message,
        }
    }

    fn propose(&mut self, pair: ([u8; 32], [u8; 32]), c: Continuity) {
        self.call(RECOVERY, 0, |v| {
            v.propose_successor(Hex32(pair.0), Hex32(pair.1), c)
        });
    }
}

/// A checkpoint needs both P1 and P2, each proving the same block, time and state root, newer than the last.
#[test]
fn a_checkpoint_needs_both_and_is_newer() {
    let mut t = T::new();
    t.advance(1_000);
    t.warp(60);
    let c = Checkpoint {
        block: 1_010,
        timestamp: t.now,
        state_root: Hex32([7; 32]),
    };
    let mut proofs = t.checkpoint_proofs(&c, None);
    let honest = proofs.clone();
    // P2's proof of another root.
    let (wrong, root) = header(1_010, t.now, &[8; 32], &[9; 32]);
    let p2 = t.v.p2;
    t.record_for(&p2, root, 1_010);
    proofs.proof2 = Base64VecU8(wrong);
    fails("NotTheCheckpoint", || {
        t.call(RELAYER, 0, |v| v.advance_checkpoint(c, proofs.clone()))
    });
    let stale = Checkpoint { block: 999, ..c };
    let stale_proofs = t.checkpoint_proofs(&stale, None);
    fails("NotNewer", || {
        t.call(RELAYER, 0, |v| {
            v.advance_checkpoint(stale, stale_proofs.clone())
        })
    });
    let ahead = Checkpoint {
        timestamp: t.now + 1,
        ..c
    };
    let ahead_proofs = t.checkpoint_proofs(&ahead, None);
    fails("NotNewer", || {
        t.call(RELAYER, 0, |v| {
            v.advance_checkpoint(ahead, ahead_proofs.clone())
        })
    });
    t.call(RELAYER, 0, |v| v.advance_checkpoint(c, honest));
    assert_eq!(t.v.config().checkpoint, c);
}

/// A stall, a successor proposed by the recovery proposer, 30 days of review, adoption on a fresh checkpoint: the vault
/// runs on the new pair and no longer stalls. Only the proposer proposes, only in a stall, one at a time.
#[test]
fn recovery_propose_review_adopt() {
    let mut t = T::new();
    t.advance(1_000);
    let pair = t.new_pair(30);
    let c = t.continuity(pair, 2_000, None);
    fails("NotStalled", || t.propose(pair, c.clone()));
    t.warp(STALL_PERIOD as u64 + 1);
    let c = t.continuity(pair, 2_000, None);
    fails("NotRecoveryProposer", || {
        t.call(ALICE, 0, |v| {
            v.propose_successor(Hex32(pair.0), Hex32(pair.1), c.clone())
        })
    });
    t.propose(pair, c.clone());
    let review_ends = t.v.config().successor.review_ends;
    assert_eq!(review_ends, t.now + RECOVERY_DELAY as u64);
    fails("SuccessorPending", || t.propose(pair, c.clone()));

    let fresh = |t: &mut T, block: u64| {
        let c = Checkpoint {
            block,
            timestamp: t.now,
            state_root: Hex32([block as u8; 32]),
        };
        let proofs = t.checkpoint_proofs(&c, Some(pair));
        (c, proofs)
    };
    let (c1, p1) = fresh(&mut t, 2_500);
    fails("ReviewNotOver", || {
        t.call(RELAYER, 0, |v| v.adopt_successor(c1, p1.clone()))
    });
    t.warp(RECOVERY_DELAY as u64);
    let (c2, p2) = fresh(&mut t, 3_000);
    t.call(RELAYER, 0, |v| v.adopt_successor(c2, p2));
    let cfg = t.v.config();
    assert_eq!((cfg.p1.0, cfg.p2.0), pair);
    assert_eq!(cfg.checkpoint, c2);
    assert_eq!(cfg.successor.review_ends, 0);
    assert!(!t.stalled());
}

/// The continuity test: the successor must prove the vault's last checkpoint, a recent one newer than it, and the last
/// message delivered on both proofs; two clients of one proof system are no pair.
#[test]
fn the_continuity_test() {
    let mut t = T::new();
    let intake = t.fund(10 * ONE);
    let index = t.index;
    let last = t.v.config().last_message.0;
    let block = t.block;
    // The last message: the settle `fund` delivered.
    let settle = T::payload_with(INTAKE_SETTLED, &index, &intake, t.nonce, NEAR_TESTNET);
    assert_eq!(keccak(&[&settle]), last);
    t.warp(STALL_PERIOD as u64 + 100);
    let pair = t.new_pair(40);
    // (c) missing, then another message.
    let c = t.continuity(pair, 9_000, None);
    fails("Discontinuous", || t.propose(pair, c));
    let other = T::payload_with(INTAKE_SETTLED, &index, &[1; 32], 3, NEAR_TESTNET);
    let c = t.continuity(pair, 9_000, Some((&other, block)));
    fails("Discontinuous", || t.propose(pair, c));
    // (b) not recent.
    let mut c = t.continuity(pair, 9_000, Some((&settle, block)));
    let old = Checkpoint {
        timestamp: t.now - STALL_PERIOD as u64 - 1,
        ..c.recent
    };
    c.recent_proofs = t.checkpoint_proofs(&old, Some(pair));
    c.recent = old;
    fails("NotRecent", || t.propose(pair, c));
    // (a) another last checkpoint.
    let mut c = t.continuity(pair, 9_000, Some((&settle, block)));
    let other_last = Checkpoint {
        state_root: Hex32([0x5e; 32]),
        ..t.v.checkpoint
    };
    c.last = t.checkpoint_proofs(&other_last, Some(pair));
    fails("NotTheCheckpoint", || t.propose(pair, c));
    // One proof system twice.
    let same = verifier_config(SP1, 50, epoch_at(t.now));
    let same_id = t.call(RELAYER, ONE, |v| v.register_verifier(same)).0;
    let c = t.continuity((pair.0, same_id), 9_000, Some((&settle, block)));
    fails("VerifiersNotDistinct", || t.propose((pair.0, same_id), c));

    let c = t.continuity(pair, 9_000, Some((&settle, block)));
    t.propose(pair, c);
}

/// The freezer vetoes at most twice a stall; a checkpoint from the pair in force that ends the stall lapses a successor
/// and begins a new count.
#[test]
fn vetoes_and_lapse() {
    let mut t = T::new();
    t.advance(1_000);
    t.warp(STALL_PERIOD as u64 + 1);
    let pair = t.new_pair(60);
    fails("NoSuccessor", || t.call(FREEZER, 0, |v| v.veto_successor()));
    for i in 0..2 {
        let c = t.continuity(pair, 2_000 + i, None);
        t.propose(pair, c);
        fails("NotFreezer", || t.call(ALICE, 0, |v| v.veto_successor()));
        t.call(FREEZER, 0, |v| v.veto_successor());
    }
    let c = t.continuity(pair, 2_010, None);
    t.propose(pair, c);
    fails("VetoesExhausted", || {
        t.call(FREEZER, 0, |v| v.veto_successor())
    });
    // The pair in force proves a recent checkpoint: the stall is over, and so is the successor.
    t.advance(2_020);
    let cfg = t.v.config();
    assert_eq!((cfg.successor.review_ends, cfg.vetoes), (0, 0));
    assert!(events().contains(&"successor_lapsed".to_string()));
    // A new stall, a new count.
    t.warp(STALL_PERIOD as u64 + 1);
    let c = t.continuity(pair, 2_030, None);
    t.propose(pair, c);
    t.call(FREEZER, 0, |v| v.veto_successor());
    assert_eq!(t.v.config().vetoes, 1);
}

/// LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the checkpoint but
/// stale. Such an advance lets messages sent before the break run (VLT-3), and leaves the stall as it was: the successor
/// under review stays, and so does the freezer's count, so nobody can lapse the review or win the freezer new vetoes one
/// stale block at a time. Adoption ends the stall and the count.
#[test]
fn test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes() {
    let mut t = T::new();
    t.advance(1_000);
    let last = t.v.checkpoint;
    t.warp(STALL_PERIOD as u64 + 1);
    let pair = t.new_pair(70);
    let c = t.continuity(pair, 9_000, None);
    t.propose(pair, c);
    t.call(FREEZER, 0, |v| v.veto_successor());
    let c = t.continuity(pair, 9_001, None);
    t.propose(pair, c);
    let review_ends = t.v.config().successor.review_ends;

    // A day before the review ends, a stranger advances by one stale block.
    t.now = review_ends - 24 * 3600;
    t.advance_to(1_001, last.timestamp + 12, [0x51; 32]);
    assert!(t.stalled());
    let cfg = t.v.config();
    assert_eq!(cfg.successor.review_ends, review_ends, "the review goes on");
    assert_eq!(cfg.vetoes, 1, "the count goes on");
    assert!(!events().contains(&"successor_lapsed".to_string()));

    // The freezer's second veto is its last in this stall, stale advances or not.
    t.call(FREEZER, 0, |v| v.veto_successor());
    t.advance_to(1_002, last.timestamp + 24, [0x52; 32]);
    let c = t.continuity(pair, 9_002, None);
    t.propose(pair, c);
    t.advance_to(1_003, last.timestamp + 36, [0x53; 32]);
    fails("VetoesExhausted", || {
        t.call(FREEZER, 0, |v| v.veto_successor())
    });

    // The review runs its course and the successor is adopted, which ends the stall and the count.
    t.now = t.v.config().successor.review_ends;
    let fresh = Checkpoint {
        block: 9_100,
        timestamp: t.now,
        state_root: Hex32([0x5f; 32]),
    };
    let proofs = t.checkpoint_proofs(&fresh, Some(pair));
    t.call(RELAYER, 0, |v| v.adopt_successor(fresh, proofs));
    let cfg = t.v.config();
    assert_eq!(cfg.p1.0, pair.0);
    assert_eq!(cfg.vetoes, 0);
    assert!(!t.stalled());
}

/// LG-3: only a message on both proofs becomes the last message a successor must prove again. With one proof system
/// broken, a forged one-proof freeze still freezes, but it cannot keep an honest successor out.
#[test]
fn test_lg3_a_one_proof_message_is_not_the_last_message() {
    let mut t = T::new();
    let intake = t.fund(10 * ONE);
    let real = t.v.config().last_message.0;
    assert_ne!(real, [0u8; 32]);
    let real_block = t.block;
    let index = t.index;
    let real_payload = T::payload_with(INTAKE_SETTLED, &index, &intake, t.nonce, NEAR_TESTNET);
    assert_eq!(keccak(&[&real_payload]), real);

    let factory = h20(&t.f["factory"]);
    let forged = t.payload(FREEZE, &factory, &[]);
    t.deliver_by(&factory, &forged, true, false);
    assert!(
        t.v.used(Hex32(keccak(&[&forged]))),
        "delivered: the vault is frozen"
    );
    let forged2 = t.payload(FREEZE, &factory, &[]);
    t.deliver_by(&factory, &forged2, false, true);
    assert_eq!(
        t.v.config().last_message.0,
        real,
        "neither one-proof message counts"
    );

    t.warp(15 * 24 * 3600);
    assert!(t.stalled());
    let pair = t.new_pair(80);
    let c = t.continuity(pair, 9_000, Some((&real_payload, real_block)));
    t.propose(pair, c);
    assert_eq!(t.v.config().successor.p1.0, pair.0);
}

/// 180 days into a stall the last checkpoint becomes the snapshot, for good: a successor under review lapses, no
/// checkpoint or proposal follows, and the snapshot's root is in the slot the hub reads (25).
#[test]
fn the_snapshot_begins_after_180_days_of_stall() {
    let mut t = T::new();
    fails("SnapshotNotDue", || {
        t.call(RELAYER, 0, |v| v.begin_snapshot())
    });
    t.warp(t.v.stall_start() - t.now + SNAPSHOT_EXIT_DELAY as u64);
    fails("NoCheckpoint", || {
        t.call(RELAYER, 0, |v| v.begin_snapshot())
    });
    t.advance(1_000);
    let last = t.v.checkpoint;
    let due = last.timestamp + STALL_PERIOD as u64 + SNAPSHOT_EXIT_DELAY as u64;
    t.now = due - 1;
    let pair = t.new_pair(90);
    let c = t.continuity(pair, 2_000, None);
    t.propose(pair, c.clone());
    fails("SnapshotNotDue", || {
        t.call(RELAYER, 0, |v| v.begin_snapshot())
    });
    t.now = due;
    t.call(RELAYER, 0, |v| v.begin_snapshot());
    let cfg = t.v.config();
    assert_eq!(cfg.snapshot, last);
    assert_eq!(
        cfg.successor.review_ends, 0,
        "a successor under review lapses"
    );
    assert_eq!(t.v.slot(Hex32(u256(SNAPSHOT_ROOT_SLOT))), last.state_root);
    fails("SnapshotTaken", || {
        t.call(RELAYER, 0, |v| v.begin_snapshot())
    });
    let later = Checkpoint {
        block: 5_000,
        timestamp: t.now,
        state_root: Hex32([1; 32]),
    };
    let proofs = t.checkpoint_proofs(&later, None);
    fails("SnapshotTaken", || {
        t.call(RELAYER, 0, |v| v.advance_checkpoint(later, proofs.clone()))
    });
    fails("SnapshotTaken", || t.propose(pair, c));
}

/// VLT-5: nothing freezes the vault after its snapshot, neither the freezer nor the factory's message: nothing could
/// replace the freezer then, and nothing may hold the exit off. A message from a block after the snapshot never runs.
#[test]
fn test_vlt5_no_freeze_after_the_snapshot() {
    let mut t = T::new();
    t.advance(1_000);
    let factory = h20(&t.f["factory"]);
    let freeze = t.payload(FREEZE, &factory, &[]);
    let proof = Base64VecU8(t.event_proof(&factory, &freeze, 900));
    t.now = t.v.stall_start() + SNAPSHOT_EXIT_DELAY as u64;
    t.call(RELAYER, 0, |v| v.begin_snapshot());
    fails("SnapshotTaken", || t.call(FREEZER, 0, |v| v.freeze()));
    fails("SnapshotTaken", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(freeze.clone()),
                900,
                Some(proof.clone()),
                Some(proof.clone()),
            )
        })
    });
    let later = t.payload(FREEZE, &factory, &[]);
    let proof = Base64VecU8(t.event_proof(&factory, &later, 1_001));
    fails("IssuedAfterSnapshot", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(later.clone()),
                1_001,
                Some(proof.clone()),
                Some(proof.clone()),
            )
        })
    });
}
