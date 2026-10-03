//! The snapshot exit on a real hub's storage (`tests/fixtures/hub.json`, written by `tests/fixtures/generate.py` from a
//! hub on anvil with NEAR testnet's registry id and this vault's id): open intakes resolved from the hub's settled mark,
//! a burn or migration in flight paid from the hub's sent mark, and holders paid their shares at the snapshot (VLT-1,
//! SOL-9), each read through a storage proof under the snapshot's state root.

use super::*;

const BOB: &str = "bob.test.near";

/// The vault as it stands at the hub's last block: the index registered, the settled order's NEAR and an open order's
/// deposited before their deadlines, and its checkpoint at that block, whose state root the reads are under.
fn exit() -> T {
    let mut t = T::new();
    let f = t.f.clone();
    t.deposit(
        ALICE,
        &h32(&f["settled_intake"]["id"]),
        amount(&f, "settled_intake"),
    );
    let timestamp = f["timestamp"].as_u64().unwrap();
    t.now = timestamp + 60;
    t.deposit(
        BOB,
        &h32(&f["open_intake"]["id"]),
        amount(&f, "open_intake"),
    );
    t.advance_to(
        f["block"].as_u64().unwrap(),
        timestamp,
        h32(&f["state_root"]),
    );
    t
}

/// An intake's amount in yoctoNEAR, which the fixture writes as a decimal string.
fn amount(f: &near_sdk::serde_json::Value, name: &str) -> u128 {
    f[name]["amount"].as_str().unwrap().parse().unwrap()
}

fn bytes(v: &near_sdk::serde_json::Value) -> Base64VecU8 {
    Base64VecU8(hex(v.as_str().unwrap()))
}

impl T {
    fn snapshot(&mut self) {
        self.now = self.v.stall_start() + SNAPSHOT_EXIT_DELAY as u64;
        self.call(RELAYER, 0, |v| v.begin_snapshot());
    }

    fn proof(&self, name: &str) -> Base64VecU8 {
        bytes(&self.f[name]["proof"]["proof"])
    }

    fn resolve(&mut self, name: &str, proof: Base64VecU8) {
        let (index, id) = (Hex20(self.index), Hex32(h32(&self.f[name]["id"])));
        self.call(RELAYER, 0, |v| v.resolve_intake(index, id, proof));
    }

    fn claim_a(&mut self, recipient: [u8; 32], component: u64, signature: Vec<u8>) {
        let index = Hex20(self.index);
        let holder = Hex20(h20(&self.f["holder_a"]["address"]));
        let proof = bytes(&self.f["holder_a"]["claims"][component as usize]["proof"]);
        self.call(RELAYER, ONE, |v| {
            v.claim_snapshot(
                index,
                holder,
                component,
                Hex32(recipient),
                Base64VecU8(signature),
                proof,
            )
        });
    }

    fn claim_b(&mut self, recipient: [u8; 32]) {
        let index = Hex20(self.index);
        let holder = Hex20(h20(&self.f["holder_b"]["address"]));
        let proof = bytes(&self.f["holder_b"]["claims"][1]["proof"]);
        self.call(RELAYER, ONE, |v| {
            v.claim_snapshot(
                index,
                holder,
                1,
                Hex32(recipient),
                Base64VecU8(vec![]),
                proof,
            )
        });
    }

    fn recorded(&mut self, name: &str) {
        let payload = bytes(&self.f[name]["payload"]);
        let proof = self.proof(name);
        self.call(RELAYER, ONE, |v| v.deliver_recorded(payload, proof));
    }

    fn signature(&self) -> Vec<u8> {
        hex(self.f["holder_a"]["signature"].as_str().unwrap())
    }

    fn recipient(&self, holder: &str) -> [u8; 32] {
        h32(&self.f[holder]["recipient"])
    }

    fn owed_by(&self, id: [u8; 32]) -> u128 {
        let index = Hex20(self.index);
        self.v.owed(index, Hex32(id)).unwrap().remaining.0
    }
}

fn implicit(word: &[u8; 32]) -> AccountId {
    crate::fixtures::hex_str(word).parse().unwrap()
}

/// The whole exit, on a real hub's storage: each open intake settled or failed from the hub's mark at the snapshot, a
/// burn in flight paid from the hub's record, and holders paid their shares at the snapshot's units plus their claims,
/// within the speed limit, by signature or to their recovery address, once.
#[test]
fn the_snapshot_exit_reads_a_real_hub() {
    let mut t = exit();
    let settled_proof = t.proof("settled_intake");
    fails("NoSnapshot", || {
        t.resolve("settled_intake", settled_proof.clone())
    });
    fails("NoSnapshot", || t.recorded("burn"));
    let (recipient_a, signature) = (t.recipient("holder_a"), t.signature());
    fails("NoSnapshot", || {
        t.claim_a(recipient_a, 1, signature.clone())
    });
    t.snapshot();

    // The settled order joins the index; the open one failed, and its depositor takes its NEAR back.
    t.resolve("settled_intake", settled_proof.clone());
    let index = Hex20(t.index);
    let settled = Hex32(h32(&t.f["settled_intake"]["id"]));
    assert_eq!(
        t.v.intake(index, settled).unwrap().state,
        INTAKE_SETTLED_STATE
    );
    assert_eq!(t.balance(), 30 * ONE);
    fails("IntakeNotOpen", || {
        t.resolve("settled_intake", settled_proof.clone())
    });
    let open_proof = t.proof("open_intake");
    t.resolve("open_intake", open_proof);
    let open = Hex32(h32(&t.f["open_intake"]["id"]));
    assert_eq!(t.v.intake(index, open).unwrap().state, INTAKE_FAILED_STATE);
    t.call(BOB, 0, |v| v.refund(index, open));
    assert_eq!(transfers(), vec![(BOB.parse().unwrap(), 3 * ONE)]);

    // The burn in flight: 3 NEAR, one share's, of which the speed limit lets 4% of 30 NEAR out today.
    t.recorded("burn");
    let burn_recipient = implicit(&h32(&t.f["burn"]["recipient"]));
    let today = 30 * ONE * 4 / 100;
    assert_eq!(transfers(), vec![(burn_recipient, today)]);
    let burn_id = h32(&t.f["burn"]["id"]);
    assert_eq!(t.owed_by(burn_id), 3 * ONE - today);
    fails("AlreadyDelivered", || t.recorded("burn"));

    // Holder A: 4 shares at 3 NEAR, plus a claim of 3 NEAR, to the recipient it signed for. Today's limit is spent.
    t.claim_a(recipient_a, 1, signature.clone());
    assert_eq!(transfers(), vec![]);
    let holder_a = h20(&t.f["holder_a"]["address"]);
    let id_a = snapshot::claim_id(&Near, &t.index, &holder_a);
    assert_eq!(t.owed_by(id_a), 15 * ONE);
    assert_eq!(
        t.v.owed(index, Hex32(id_a)).unwrap().recipient,
        Some(implicit(&recipient_a))
    );
    fails("AlreadyClaimed", || {
        t.claim_a(recipient_a, 1, signature.clone())
    });
    // Holder B: 3 shares, to the recovery address it registered in the hub, with no signature.
    let recipient_b = t.recipient("holder_b");
    t.claim_b(recipient_b);
    let holder_b = h20(&t.f["holder_b"]["address"]);
    let id_b = snapshot::claim_id(&Near, &t.index, &holder_b);
    assert_eq!(t.owed_by(id_b), 9 * ONE);

    // A day on, the speed limit pays the next part: 4% of the 30 NEAR less today's.
    t.warp(25 * 3600);
    t.call(ALICE, 0, |v| v.release(index, Hex32(id_a)));
    let next = (30 * ONE - today) * 4 / 100;
    assert_eq!(transfers(), vec![(implicit(&recipient_a), next)]);
    assert_eq!(t.owed_by(id_a), 15 * ONE - next);
}

/// VLT-1: a claim reads a component only inside the hub's components array, and only this chain's coin there. WETH,
/// the first component, is refused; so is the empty slot just past the array's end, and storage further past it that
/// holds NEAR at a far larger unit count, as storage a holder could fill.
#[test]
fn test_vlt1_the_component_must_lie_inside_the_array() {
    let mut t = exit();
    t.snapshot();
    let proof = t.proof("settled_intake");
    t.resolve("settled_intake", proof);
    let (recipient, signature) = (t.recipient("holder_a"), t.signature());
    fails("WrongComponent", || {
        t.claim_a(recipient, 0, signature.clone())
    });
    fails("WrongComponent", || {
        t.claim_a(recipient, 2, signature.clone())
    });
    let index = Hex20(t.index);
    let holder = Hex20(h20(&t.f["holder_a"]["address"]));
    let past = bytes(&t.f["holder_a"]["past_the_end"]["proof"]);
    fails("WrongComponent", || {
        t.call(RELAYER, ONE, |v| {
            v.claim_snapshot(
                index,
                holder,
                7,
                Hex32(recipient),
                Base64VecU8(signature.clone()),
                past.clone(),
            )
        })
    });
    t.claim_a(recipient, 1, signature);
}

/// A holder's share goes where the holder says: to the recipient its Ethereum key signed for, under OpenZeppelin's rules
/// for a signature, or to the recovery address it registered, and nowhere else.
#[test]
fn a_claim_is_paid_only_where_its_holder_says() {
    let mut t = exit();
    t.snapshot();
    let proof = t.proof("settled_intake");
    t.resolve("settled_intake", proof);
    let (recipient, signature) = (t.recipient("holder_a"), t.signature());
    fails("BadSignature", || {
        t.claim_a([0x77; 32], 1, signature.clone())
    });
    fails("BadSignature", || t.claim_a(recipient, 1, vec![]));
    fails("BadSignature", || {
        t.claim_a(recipient, 1, signature[..64].to_vec())
    });
    let mut v29 = signature.clone();
    v29[64] = 29;
    fails("BadSignature", || t.claim_a(recipient, 1, v29));
    // v as the raw recovery id, 0 or 1, which recovers the same key: OpenZeppelin takes only 27 and 28.
    let mut raw = signature.clone();
    raw[64] -= 27;
    fails("BadSignature", || t.claim_a(recipient, 1, raw));
    // The same signature with s in the upper half and v flipped recovers the same key; OpenZeppelin refuses it.
    fails("BadSignature", || {
        t.claim_a(recipient, 1, malleable(&signature))
    });
    fails("ZeroAddress", || t.claim_a([0; 32], 1, signature.clone()));
    t.claim_a(recipient, 1, signature);

    // Holder B registered a recovery address: paid there and only there, signature or not.
    fails("WrongRecipient", || t.claim_b([0x77; 32]));
    let recipient_b = t.recipient("holder_b");
    t.claim_b(recipient_b);
}

/// SOL-9's twin for claims: a claim never pays the vault's own account, where the NEAR would stay, booked as paid. Only
/// an implicit account can be named, so the case arises only for a vault at one: here the vault runs at the implicit
/// account of holder B's registered recovery address, which the hub's storage names.
#[test]
fn test_sol9_a_claim_never_pays_the_vault() {
    let mut t = exit();
    t.snapshot();
    let proof = t.proof("settled_intake");
    t.resolve("settled_intake", proof);
    let recipient_b = t.recipient("holder_b");
    let (index, holder) = (Hex20(t.index), Hex20(h20(&t.f["holder_b"]["address"])));
    let proof = bytes(&t.f["holder_b"]["claims"][1]["proof"]);
    testing_env!(VMContextBuilder::new()
        .current_account_id(implicit(&recipient_b))
        .predecessor_account_id(RELAYER.parse().unwrap())
        .block_timestamp(t.now * 1_000_000_000)
        .attached_deposit(NearToken::from_yoctonear(ONE))
        .prepaid_gas(Gas::from_tgas(1000))
        .build());
    fails("WrongRecipient", || {
        t.v.claim_snapshot(
            index,
            holder,
            1,
            Hex32(recipient_b),
            Base64VecU8(vec![]),
            proof.clone(),
        )
    });
    t.claim_b(recipient_b);
}

/// `n - s` and `v` flipped: the other signature of the same key over the same digest.
fn malleable(signature: &[u8]) -> Vec<u8> {
    const N: [u8; 32] = [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xfe, 0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36,
        0x41, 0x41,
    ];
    let mut out = signature.to_vec();
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = N[i] as i16 - signature[32 + i] as i16 - borrow;
        out[32 + i] = d.rem_euclid(256) as u8;
        borrow = i16::from(d < 0);
    }
    out[64] = if signature[64] == 27 { 28 } else { 27 };
    out
}

/// A burn or migration runs after the snapshot only on the index's own mark of it, and only a burn or a migration: a
/// real migration into the index's second version, which its creator seeded with its last share, is paid into that
/// version's balance within the speed limit.
#[test]
fn a_recorded_message_runs_only_on_the_hubs_mark() {
    let mut t = exit();
    t.snapshot();
    let proof = t.proof("settled_intake");
    t.resolve("settled_intake", proof);
    fails("NotRecorded", || t.recorded("unsent_burn"));
    // A message of another kind resolves another way: refused before anything is read.
    let mut settle = hex(t.f["burn"]["payload"].as_str().unwrap());
    settle[2 * 32 + 31] = INTAKE_SETTLED;
    let unsent_proof = t.proof("unsent_burn");
    fails("UnknownKind", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver_recorded(Base64VecU8(settle.clone()), unsent_proof.clone())
        })
    });
    // The migration names the index's second version, registered here first. (Refused before that, NotAnIndex; the
    // mocked runtime would keep the refused call's used mark, so the sandbox tests that case.)
    let v2 = h20(&t.f["migrate"]["new_index"]);
    let salt = Hex32(h32(&t.f["migrate"]["new_salt"]));
    t.call(RELAYER, ONE, |v| v.register_index(Hex20(v2), salt));
    t.recorded("migrate");
    let today = 30 * ONE * 4 / 100;
    assert_eq!(
        t.call(RELAYER, 0, |v| v.index_state(Hex20(v2)).unwrap().balance.0),
        today,
        "one share's NEAR, 3, of which 4% of 30 NEAR moves today"
    );
    assert_eq!(transfers(), vec![], "the NEAR stays in the vault");
    let id = h32(&t.f["migrate"]["id"]);
    assert_eq!(t.owed_by(id), 3 * ONE - today);
    t.recorded("burn");
    let burn_id = h32(&t.f["burn"]["id"]);
    assert_eq!(t.owed_by(burn_id), 3 * ONE, "today's limit is spent");
}

/// Every node is checked against the snapshot's root: a proof tampered with, cut short or followed by anything does not
/// prove the hub's storage.
#[test]
fn a_state_proof_must_prove_the_storage() {
    let mut t = exit();
    t.snapshot();
    let proof = t.proof("settled_intake").0;
    let mut tampered = proof.clone();
    let middle = tampered.len() / 2;
    tampered[middle] ^= 1;
    fails("BadStateProof", || {
        t.resolve("settled_intake", Base64VecU8(tampered.clone()))
    });
    fails("BadStateProof", || {
        t.resolve(
            "settled_intake",
            Base64VecU8(proof[..proof.len() - 1].to_vec()),
        )
    });
    let mut longer = proof.clone();
    longer.push(0);
    fails("BadStateProof", || {
        t.resolve("settled_intake", Base64VecU8(longer.clone()))
    });
    t.resolve("settled_intake", Base64VecU8(proof));
}

/// What the vault computes of Ethereum's encodings, against what Solidity's encoder and `cast` computed for the same
/// hub: every slot a claim, a resolution and a recorded delivery read, and the EIP-712 digest a holder signs, under the
/// NEAR domain (salt the vault's id, chain id the registry's), whose signature recovers to the holder.
#[test]
fn the_reads_and_the_digest_are_soliditys() {
    let t = T::new();
    let f = &t.f;
    assert_eq!(f["chain_id"].as_u64().unwrap(), NEAR_TESTNET);
    assert_eq!(
        h32(&f["vault"]),
        T::vault_id(),
        "the hub's chain registry names this vault"
    );
    let holder = h20(&f["holder_a"]["address"]);
    for c in 0..3 {
        let want: Vec<[u8; 32]> = f["holder_a"]["claims"][c]["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(h32)
            .collect();
        assert_eq!(
            snapshot::claim_slots(&Near, &holder, c as u64, NEAR_TESTNET).to_vec(),
            want
        );
    }
    let settled = h32(&f["settled_intake"]["id"]);
    assert_eq!(
        snapshot::settled_slot(&Near, &settled),
        h32(&f["settled_intake"]["proof"]["slots"][0])
    );
    assert_eq!(
        snapshot::sent_slot(&Near, &h32(&f["burn"]["id"])),
        h32(&f["burn"]["proof"]["slots"][0])
    );
    let digest = snapshot::claim_digest(
        &Near,
        &T::vault_id(),
        NEAR_TESTNET,
        &t.index,
        &holder,
        &h32(&f["holder_a"]["recipient"]),
    );
    assert_eq!(digest, h32(&f["holder_a"]["digest"]));
    let signature = hex(f["holder_a"]["signature"].as_str().unwrap());
    snapshot::check_signature(&Near, &digest, &signature, &holder).unwrap();
}
