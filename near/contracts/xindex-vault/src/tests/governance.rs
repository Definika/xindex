//! The factory's governance messages (VLT-2, VLT-4, SOL-3, VLT-5's freeze) and P1's and P2's light clients (LG-4, and
//! SP1's and RISC Zero's real proofs through `update_verifier`).

use super::*;

impl T {
    fn govern(&mut self, kind: u8, body: &[u8], p1: bool, p2: bool) -> Vec<u8> {
        let factory = h20(&self.f["factory"]);
        let payload = self.payload(kind, &factory, body);
        self.deliver_by(&factory, &payload, p1, p2);
        payload
    }
}

/// A freeze, and a cap update that raises neither figure, apply at once on either proof alone; a frozen vault takes no
/// deposit and pays nothing.
#[test]
fn a_freeze_and_a_lower_cap_need_one_proof() {
    let mut t = T::new();
    t.govern(CAP_UPDATE, &cap_body(500 * ONE, ONE / 2), false, true);
    let c = t.v.config();
    assert_eq!((c.cap.0, c.outflow_floor.0), (500 * ONE, ONE / 2));
    t.govern(FREEZE, &t.freeze_body(), true, false);
    assert_eq!(t.v.config().frozen_until, t.now + FREEZE_DURATION as u64);
    let index = Hex20(t.index);
    let intake = Hex32(intake_id(t.now + 3600, 1));
    fails("VaultFrozen", || {
        t.call(ALICE, 2 * ONE, |v| v.deposit(index, intake, U128(ONE)))
    });
    // A freeze extends, never shortens; the freezer's key freezes too, and no one else's.
    t.warp(100);
    t.call(FREEZER, 0, |v| v.freeze());
    assert_eq!(t.v.config().frozen_until, t.now + FREEZE_DURATION as u64);
    fails("NotFreezer", || t.call(ALICE, 0, |v| v.freeze()));
}

/// VLT-2: a raised cap, a new freezer and new verifiers need both proofs, then wait GOVERNANCE_DELAY on the vault, where
/// the freezer can drop a raise or a rotation, never its own replacement. A freeze holds every change but that one.
#[test]
fn test_vlt2_a_loosening_change_waits_and_the_freezer_may_drop_it() {
    let mut t = T::new();
    let raise = cap_body(2_000_000 * ONE, 2 * ONE);
    let factory = h20(&t.f["factory"]);
    let one_proof = t.payload(CAP_UPDATE, &factory, &raise);
    fails("BothProofsRequired", || {
        t.deliver_by(&factory, &one_proof, true, false)
    });
    t.govern(CAP_UPDATE, &raise, true, true);
    assert_eq!(t.v.config().cap.0, 1_000_000 * ONE, "not yet");
    let body = Base64VecU8(raise.clone());
    fails("ChangeNotReady", || {
        t.call(RELAYER, 0, |v| v.apply_change(CAP_UPDATE, body.clone()))
    });
    fails("NoPendingChange", || {
        t.call(RELAYER, 0, |v| {
            v.apply_change(CAP_UPDATE, Base64VecU8(cap_body(1, 1)))
        })
    });
    t.warp(GOVERNANCE_DELAY as u64);
    t.call(RELAYER, 0, |v| v.apply_change(CAP_UPDATE, body.clone()));
    assert_eq!(t.v.config().cap.0, 2_000_000 * ONE);
    fails("NoPendingChange", || {
        t.call(RELAYER, 0, |v| v.apply_change(CAP_UPDATE, body.clone()))
    });

    // A second raise, dropped by the freezer.
    let raise2 = cap_body(3_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, &raise2, true, true);
    fails("NotFreezer", || {
        t.call(ALICE, 0, |v| v.cancel_change(CAP_UPDATE))
    });
    t.call(FREEZER, 0, |v| v.cancel_change(CAP_UPDATE));
    t.warp(GOVERNANCE_DELAY as u64);
    fails("NoPendingChange", || {
        t.call(RELAYER, 0, |v| {
            v.apply_change(CAP_UPDATE, Base64VecU8(raise2.clone()))
        })
    });

    // A new freezer, an implicit account, which the freezer can neither drop nor hold off with a freeze.
    let new_key = [0x4b; 32];
    t.govern(FREEZER_CHANGE, &new_key, true, true);
    fails("NotFreezer", || {
        t.call(FREEZER, 0, |v| v.cancel_change(FREEZER_CHANGE))
    });
    t.call(FREEZER, 0, |v| v.freeze());
    t.warp(GOVERNANCE_DELAY as u64);
    t.call(RELAYER, 0, |v| {
        v.apply_change(FREEZER_CHANGE, Base64VecU8(new_key.to_vec()))
    });
    let new_freezer = crate::fixtures::hex_str(&new_key);
    assert_eq!(t.v.config().freezer.as_str(), new_freezer);
    fails("NotFreezer", || t.call(FREEZER, 0, |v| v.freeze()));
    // While frozen, by the new freezer, a raise waits even once ready.
    t.call(&new_freezer, 0, |v| v.freeze());
    let raise3 = cap_body(4_000_000 * ONE, 2 * ONE);
    t.govern(CAP_UPDATE, &raise3, true, true);
    t.warp(GOVERNANCE_DELAY as u64);
    fails("VaultFrozen", || {
        t.call(RELAYER, 0, |v| {
            v.apply_change(CAP_UPDATE, Base64VecU8(raise3.clone()))
        })
    });
}

/// A3-02, A4-03: a cut taken first on one proof moves no mark, so it stays deliverable on both, which moves the mark
/// and drops an older raise waiting under its key. Before, the one-proof delivery used up the id, and the older raise,
/// queued behind it, undid the newer cut a week later. Once on both proofs the cut is used up; a freeze, at once.
#[test]
fn test_a302_a403_a_cut_on_one_proof_still_moves_the_mark_on_both() {
    let mut t = T::new();
    let factory = h20(&t.f["factory"]);
    let older_raise = T::payload_with(
        CAP_UPDATE,
        &factory,
        &cap_body(2_000_000 * ONE, 10 * ONE),
        10,
        NEAR_TESTNET,
    );
    let newer_cut = T::payload_with(
        CAP_UPDATE,
        &factory,
        &cap_body(500_000 * ONE, ONE),
        11,
        NEAR_TESTNET,
    );
    t.deliver_by(&factory, &newer_cut, true, false);
    assert_eq!(t.v.config().nonces, [0, 0, 0], "one proof moves no mark");
    t.deliver_by(&factory, &older_raise, true, true);
    assert_ne!(
        t.v.config().pending_cap.ready_at,
        0,
        "the older raise waits"
    );
    t.deliver_by(&factory, &newer_cut, true, true);
    let c = t.v.config();
    assert_eq!(c.nonces[0], 11);
    assert_eq!(c.pending_cap.ready_at, 0, "and is dropped");
    assert_eq!(c.cap.0, 500_000 * ONE);
    fails("AlreadyDelivered", || {
        t.deliver_by(&factory, &newer_cut, true, true)
    });
    fails("AlreadyDelivered", || {
        t.deliver_by(&factory, &newer_cut, true, false)
    });
    let freeze = t.govern(FREEZE, &t.freeze_body(), true, false);
    fails("AlreadyDelivered", || {
        t.deliver_by(&factory, &freeze, true, false)
    });
}

/// VLT-4 and SOL-3: a governance message must be newer than the last of its kind taken on both proofs, so an older
/// message delivered late cannot undo a newer one; and only one on both proofs moves that mark, so one broken proof
/// system cannot lock the factory out with a forged nonce.
#[test]
fn test_vlt4_one_proof_moves_no_mark() {
    let mut t = T::new();
    let factory = h20(&t.f["factory"]);
    // A forged lower cap at a huge nonce, on one proof: it applies (it only protects), but moves no mark.
    let forged = T::payload_with(
        CAP_UPDATE,
        &factory,
        &cap_body(10 * ONE, ONE),
        1_000_000,
        NEAR_TESTNET,
    );
    t.deliver_by(&factory, &forged, true, false);
    assert_eq!(t.v.config().nonces, [0, 0, 0]);
    // The factory's honest raise, at its next nonce, still runs.
    let honest = t.govern(CAP_UPDATE, &cap_body(20 * ONE, ONE), true, true);
    let nonce = t.nonce;
    assert_eq!(t.v.config().nonces[0], nonce);
    // An older message of the kind, delivered last, is refused.
    let stale = T::payload_with(
        CAP_UPDATE,
        &factory,
        &cap_body(5 * ONE, ONE),
        nonce - 1,
        NEAR_TESTNET,
    );
    fails("StaleGovernance", || {
        t.deliver_by(&factory, &stale, true, true)
    });
    assert_ne!(honest, stale);
}

/// A rotation names two light clients registered here, of two different proof systems, which become P1 and P2 once it
/// applies: the factory's `proposeRotation` carries their ids.
#[test]
fn a_rotation_installs_two_registered_light_clients() {
    let mut t = T::new();
    let new_p1 = verifier_config(SP1, 11, epoch_at(t.now));
    let new_p2 = verifier_config(RISC_ZERO, 12, epoch_at(t.now));
    let same = verifier_config(SP1, 13, epoch_at(t.now));
    let (id1, id2, id3) = (
        verifier_id(&new_p1),
        verifier_id(&new_p2),
        verifier_id(&same),
    );
    let body = [&id1[..], &id2[..]].concat();
    t.govern(VERIFIER_ROTATION, &body, true, true);
    t.warp(GOVERNANCE_DELAY as u64);
    for c in [new_p1, new_p2, same] {
        let id = t.call(RELAYER, ONE, |v| v.register_verifier(c));
        assert_eq!(t.v.verifier(id).unwrap().key, c.key);
    }
    t.call(RELAYER, 0, |v| {
        v.apply_change(VERIFIER_ROTATION, Base64VecU8(body.clone()))
    });
    let c = t.v.config();
    assert_eq!((c.p1.0, c.p2.0), (id1, id2));

    // Two clients of one proof system are no pair. (The mocked runtime keeps a failed call's writes, which clear the
    // waiting change, so each refusal waits on a rotation of its own.)
    let body = [&id1[..], &id3[..]].concat();
    t.govern(VERIFIER_ROTATION, &body, true, true);
    t.warp(GOVERNANCE_DELAY as u64);
    fails("VerifiersNotDistinct", || {
        t.call(RELAYER, 0, |v| {
            v.apply_change(VERIFIER_ROTATION, Base64VecU8(body.clone()))
        })
    });
    // A client nobody registered is none.
    let body = [&id1[..], &[0x99; 32][..]].concat();
    t.govern(VERIFIER_ROTATION, &body, true, true);
    t.warp(GOVERNANCE_DELAY as u64);
    fails("UnknownVerifier", || {
        t.call(RELAYER, 0, |v| {
            v.apply_change(VERIFIER_ROTATION, Base64VecU8(body.clone()))
        })
    });
}

/// LG-4: a light client takes a proof only until a day after its anchor's epoch began, by the clock: past that it stops
/// for good, checked before the proof. Up to it, the proof is checked: SP1's own Groth16 proof passes P1's check on the
/// chain's host functions and is then refused as no statement of ours; RISC Zero's own receipt likewise on P2; a
/// changed proof fails the check itself.
#[test]
fn test_lg4_a_verifier_takes_a_proof_only_within_a_day_of_its_anchor() {
    let mut t = T::new();
    let (key, values, proof) = sp1_fixture();
    let p1 = VerifierConfig {
        system: SP1,
        key: Hex32(key),
        anchor: Hex32([3; 32]),
        epoch: epoch_at(t.now),
        genesis_time: SEPOLIA_GENESIS,
    };
    let id = t.call(RELAYER, ONE, |v| v.register_verifier(p1));
    let lag_ends = SEPOLIA_GENESIS + p1.epoch * 384 + 86_400;
    let (pv, pr) = (Base64VecU8(values.clone()), Base64VecU8(proof.clone()));
    t.now = lag_ends;
    fails("BadPublicValues", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(id, pv.clone(), pr.clone())
        })
    });
    // Other values under the same proof fail the pairing; a proof whose point is off the curve is refused by NEAR's host
    // function itself, which aborts the call.
    let mut other = values.clone();
    other[0] ^= 1;
    fails("InvalidProof", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(id, Base64VecU8(other.clone()), pr.clone())
        })
    });
    let mut changed = proof.clone();
    changed[proof.len() - 1] ^= 1;
    host_fails("AltBn128InvalidInput", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(id, pv.clone(), Base64VecU8(changed.clone()))
        })
    });
    t.now = lag_ends + 1;
    fails("Lagging", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(id, pv.clone(), pr.clone())
        })
    });

    let (image, journal, seal) = risc0_receipt();
    let p2 = VerifierConfig {
        system: RISC_ZERO,
        key: Hex32(image),
        anchor: Hex32([4; 32]),
        epoch: epoch_at(t.now),
        genesis_time: SEPOLIA_GENESIS,
    };
    let id = t.call(RELAYER, ONE, |v| v.register_verifier(p2));
    fails("BadPublicValues", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(id, Base64VecU8(journal.clone()), Base64VecU8(seal.clone()))
        })
    });
    fails("UnknownVerifier", || {
        t.call(RELAYER, ONE, |v| {
            v.update_verifier(Hex32([1; 32]), pv.clone(), pr.clone())
        })
    });
}

const DAY: u64 = 24 * 3600;

/// A3-03: a FREEZE carries the end of the factory's own freeze. Delivered after that end, it freezes nothing, so an
/// undelivered FREEZE is no 14-day pause a stranger may fire months later; delivered mid-freeze, it freezes only to
/// that end. Either way it is used up.
#[test]
fn test_a303_a_late_freeze_ends_with_the_factorys() {
    let mut t = T::new();
    let factory = h20(&t.f["factory"]);
    let late = t.payload(FREEZE, &factory, &t.freeze_body());
    t.warp(300 * DAY);
    t.deliver_by(&factory, &late, true, false);
    assert_eq!(
        t.v.config().frozen_until,
        0,
        "the factory's freeze is long over"
    );
    assert!(t.v.used(Hex32(keccak(&[&late]))), "used up");
    fails("AlreadyDelivered", || {
        t.deliver_by(&factory, &late, true, true)
    });

    let until = t.now + FREEZE_DURATION as u64;
    let mid = t.payload(FREEZE, &factory, &t.freeze_body());
    t.warp(10 * DAY);
    t.deliver_by(&factory, &mid, false, true);
    assert_eq!(
        t.v.config().frozen_until,
        until,
        "only to the factory's end"
    );
    // The freezer's own freeze still runs its whole FREEZE_DURATION, and a FREEZE never shortens one.
    t.call(FREEZER, 0, |v| v.freeze());
    let longer = t.now + FREEZE_DURATION as u64;
    assert_eq!(t.v.config().frozen_until, longer);
    let short = t.payload(FREEZE, &factory, &freeze_body(t.now + DAY));
    t.deliver_by(&factory, &short, true, false);
    assert_eq!(t.v.config().frozen_until, longer);
    // An end far past FREEZE_DURATION, or past 64 bits, freezes FREEZE_DURATION from now.
    t.now = longer;
    let mut far = [0xffu8; 32];
    far[0] = 0;
    let p = t.payload(FREEZE, &factory, &far);
    t.deliver_by(&factory, &p, true, false);
    assert_eq!(t.v.config().frozen_until, t.now + FREEZE_DURATION as u64);
}

/// B4-04: a FREEZE's body is exactly one word, `abi.encode(until)`. (The mocked runtime keeps the used mark a refused
/// delivery wrote, which nothing reads again.)
#[test]
fn test_b404_a_freeze_body_is_one_word() {
    let mut t = T::new();
    let factory = h20(&t.f["factory"]);
    let two = [t.freeze_body(), vec![0u8; 32]].concat();
    for body in [vec![], vec![0u8; 31], two] {
        let p = t.payload(FREEZE, &factory, &body);
        fails("BadMessage", || t.deliver_by(&factory, &p, true, false));
    }
    assert_eq!(t.v.config().frozen_until, 0);
}

/// B1-05: a CAP_UPDATE figure past u128, which an EVM vault takes, means u128::MAX here: no yoctoNEAR amount is
/// larger. Refused, it could never be delivered, and a lowered floor beside it never applied either.
#[test]
fn test_b105_a_cap_wider_than_the_native_type_saturates() {
    let mut t = T::new();
    let factory = h20(&t.f["factory"]);
    let mut past = [0u8; 32];
    past[15] = 1; // 2^128
    let body = [&[0u8; 32][..], &past, &u256_wide(ONE / 2)].concat();
    let raise = t.payload(CAP_UPDATE, &factory, &body);
    fails("BothProofsRequired", || {
        t.deliver_by(&factory, &raise, true, false)
    });
    t.deliver_by(&factory, &raise, true, true);
    assert_eq!(t.v.config().cap.0, 1_000_000 * ONE, "a raise waits");
    t.warp(GOVERNANCE_DELAY as u64);
    let b = Base64VecU8(body);
    t.call(RELAYER, 0, |v| v.apply_change(CAP_UPDATE, b));
    let c = t.v.config();
    assert_eq!((c.cap.0, c.outflow_floor.0), (u128::MAX, ONE / 2));
    // `type(uint256).max` as "no cap" is the same, and then lowers nothing: it applies at once on one proof.
    let body = [&[0u8; 32][..], &[0xff; 32], &u256_wide(ONE / 2)].concat();
    t.govern(CAP_UPDATE, &body, true, false);
    assert_eq!(t.v.config().cap.0, u128::MAX);
}
