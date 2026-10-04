//! The snapshot exit against a real hub's storage: `fixtures/hub.json`, which `fixtures/generate.py` builds by running
//! the repository's own HybridIndexFactory and HybridHub on anvil, with this vault's `config` address registered as
//! Solana's vault, and proving every slot the vault reads with `eth_getProof`. The vault reads them under the state root
//! of its last checkpoint: holders' shares, units and claims, a recovery key, the settled mark of an intake and the sent
//! mark of a burn, and their absence.

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use serde_json::Value;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex_vault::{
    constants::*, error::VaultError, snapshot, state::Checkpoint, state_reader, vault,
};

fn fixture() -> Value {
    serde_json::from_str(include_str!("fixtures/hub.json")).unwrap()
}

fn bytes(v: &Value) -> Vec<u8> {
    let s = v.as_str().unwrap().trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn h20(v: &Value) -> [u8; 20] {
    bytes(v).try_into().unwrap()
}

fn h32(v: &Value) -> [u8; 32] {
    bytes(v).try_into().unwrap()
}

fn key(v: &Value) -> Pubkey {
    Pubkey::new_from_array(h32(v))
}

/// The vault as it stands at the hub's last block: the index registered, the settled order's SOL and an open order's
/// deposited before their deadlines, and its checkpoint at that block, whose state root the reads are under.
struct Exit {
    h: Harness,
    f: Value,
    index: [u8; 20],
    settled: [u8; 32],
    open: [u8; 32],
    settled_depositor: Keypair,
    open_depositor: Keypair,
}

fn exit() -> Exit {
    let f = fixture();
    let mut h = Harness::new();
    assert_eq!(
        h.config.to_bytes(),
        h32(&f["vault"]),
        "the hub's chain registry names this vault"
    );
    assert_eq!(f["source_chain_id"].as_u64().unwrap(), SOURCE_CHAIN_ID);
    assert_eq!(f["chain_id"].as_u64().unwrap(), CHAIN_ID);
    let settled = h32(&f["settled_intake"]["id"]);
    let open = h32(&f["open_intake"]["id"]);
    h.set_time(f["settled_intake"]["deadline"].as_i64().unwrap() - 600);
    let mut args = h.init_args();
    args.factory = h20(&f["factory"]);
    args.hub_implementation = h20(&f["hub_implementation"]);
    let authority = h.authority.insecure_clone();
    let ix = h.initialize_ix(&authority.pubkey(), args, h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_ok();
    let index = h20(&f["index"]);
    h.register(index, h32(&f["salt"])).expect_ok();
    // A first checkpoint, before any deposit (B1-04).
    h.warp(1);
    h.advance(1).expect_ok();

    let (settled_depositor, open_depositor) = (Keypair::new(), Keypair::new());
    let amount = |name: &str| f[name]["amount"].as_u64().unwrap();
    h.svm
        .airdrop(&settled_depositor.pubkey(), amount("settled_intake") + SOL)
        .unwrap();
    h.svm
        .airdrop(&open_depositor.pubkey(), amount("open_intake") + SOL)
        .unwrap();
    h.deposit(&settled_depositor, index, settled, amount("settled_intake"))
        .expect_ok();
    let timestamp = f["timestamp"].as_i64().unwrap();
    h.set_time(timestamp + 60);
    h.deposit(&open_depositor, index, open, amount("open_intake"))
        .expect_ok();
    h.advance_to(Checkpoint {
        block: f["block"].as_u64().unwrap(),
        timestamp: timestamp as u64,
        state_root: h32(&f["state_root"]),
    })
    .expect_ok();
    Exit {
        h,
        f,
        index,
        settled,
        open,
        settled_depositor,
        open_depositor,
    }
}

impl Exit {
    fn snapshot(&mut self) {
        let due = vault::stall_start(&self.h.config()) + SNAPSHOT_EXIT_DELAY;
        self.h.set_time(due);
        self.h.begin_snapshot().expect_ok();
    }

    fn proof(&self, path: &[&str]) -> Vec<u8> {
        let mut v = &self.f;
        for p in path {
            v = &v[*p];
        }
        bytes(&v["proof"])
    }

    fn claim_proof(&self, holder: &str, component: usize) -> Vec<u8> {
        bytes(&self.f[holder]["claims"][component]["proof"])
    }

    fn holder(&self, holder: &str) -> [u8; 20] {
        h20(&self.f[holder]["address"])
    }

    fn recipient(&self, holder: &str) -> Pubkey {
        key(&self.f[holder]["recipient"])
    }

    fn signature(&self) -> Vec<u8> {
        bytes(&self.f["holder_a"]["signature"])
    }

    fn claim_a(&mut self, recipient: Pubkey, component: usize, signature: Vec<u8>) -> Outcome {
        let (index, holder) = (self.index, self.holder("holder_a"));
        let proof = self.claim_proof("holder_a", component);
        self.h.claim_snapshot(
            index,
            holder,
            recipient,
            component as u64,
            signature,
            &proof,
        )
    }

    fn claim_b(&mut self, recipient: Pubkey) -> Outcome {
        let (index, holder) = (self.index, self.holder("holder_b"));
        let proof = self.claim_proof("holder_b", 1);
        self.h
            .claim_snapshot(index, holder, recipient, 1, Vec::new(), &proof)
    }

    fn burn(&mut self) -> Outcome {
        let payload = bytes(&self.f["burn"]["payload"]);
        let recipient = key(&self.f["burn"]["recipient"]);
        let proof = self.proof(&["burn", "proof"]);
        self.h
            .deliver_recorded_burn(self.index, payload, recipient, &proof)
    }
}

/// The whole exit, on a real hub's storage: each open intake settled or failed from the hub's mark at the snapshot, a
/// burn in flight paid from the hub's record, and holders paid their shares at the snapshot's units plus their claims,
/// within the speed limit, by signature or to their recovery key, once.
#[test]
fn the_snapshot_exit_reads_a_real_hub() {
    let mut e = exit();
    let (index, settled, open) = (e.index, e.settled, e.open);
    let settled_proof = e.proof(&["settled_intake", "proof"]);
    let open_proof = e.proof(&["open_intake", "proof"]);
    e.h.resolve_intake(index, settled, &settled_proof)
        .expect_code(VaultError::NoSnapshot);
    e.burn().expect_code(VaultError::NoSnapshot);
    let (recipient_a, signature) = (e.recipient("holder_a"), e.signature());
    e.claim_a(recipient_a, 1, signature.clone())
        .expect_code(VaultError::NoSnapshot);
    e.snapshot();

    // The settled order's intake joins the index; the open one fails, and its depositor takes its SOL back.
    let out = e.h.resolve_intake(index, settled, &settled_proof);
    out.expect_ok();
    println!("resolve_intake: {} compute units", out.cu);
    let settled_amount = e.f["settled_intake"]["amount"].as_u64().unwrap();
    assert_eq!(e.h.intake(&index, &settled).state, INTAKE_SETTLED_STATE);
    assert_eq!(e.h.index(&index).balance, settled_amount);
    e.h.resolve_intake(index, settled, &settled_proof)
        .expect_code(VaultError::IntakeNotOpen);
    e.h.resolve_intake(index, open, &open_proof).expect_ok();
    assert_eq!(e.h.intake(&index, &open).state, INTAKE_FAILED_STATE);
    let depositor = e.open_depositor.insecure_clone();
    let before = e.h.lamports(&depositor.pubkey());
    e.h.refund(&depositor, index, open).expect_ok();
    let open_amount = e.f["open_intake"]["amount"].as_u64().unwrap();
    assert!(e.h.lamports(&depositor.pubkey()) > before + open_amount - SOL / 100);
    let _ = &e.settled_depositor;

    // The burn in flight: 1.5 SOL, of which the floor lets 1 SOL out today.
    let out = e.burn();
    out.expect_ok();
    println!("deliver_recorded_burn: {} compute units", out.cu);
    let burn_recipient = key(&e.f["burn"]["recipient"]);
    assert_eq!(e.h.lamports(&burn_recipient), FLOOR);
    let burn_id = h32(&e.f["burn"]["id"]);
    assert_eq!(e.h.owed(&index, &burn_id).remaining, 1_500_000_000 - FLOOR);
    e.burn().expect_error("Custom(0)"); // its used mark exists: it runs once

    // Holder A: 4 shares at 1.5 SOL, plus a claim of 1.5 SOL, to the recipient it signed for. Today's limit is spent.
    let out = e.claim_a(recipient_a, 1, signature.clone());
    out.expect_ok();
    println!("claim_snapshot (signature): {} compute units", out.cu);
    let id_a = snapshot::claim_id(&index, &e.holder("holder_a"));
    assert_eq!(e.h.owed(&index, &id_a).remaining, 7_500_000_000);
    assert_eq!(e.h.owed(&index, &id_a).recipient, recipient_a);
    e.claim_a(recipient_a, 1, signature)
        .expect_error("Custom(0)"); // once a holder
                                    // Holder B: 3 shares, to the recovery key it registered in the hub, with no signature.
    let recipient_b = e.recipient("holder_b");
    let out = e.claim_b(recipient_b);
    out.expect_ok();
    println!("claim_snapshot (recovery key): {} compute units", out.cu);
    let id_b = snapshot::claim_id(&index, &e.holder("holder_b"));
    assert_eq!(e.h.owed(&index, &id_b).remaining, 4_500_000_000);

    // A day on, the speed limit pays the next part.
    e.h.warp(25 * 3600);
    e.h.release(index, id_a, recipient_a).expect_ok();
    assert_eq!(e.h.lamports(&recipient_a), FLOOR);
}

/// VLT-1: a claim reads a component only inside the hub's components array, and only this chain's coin there. WETH,
/// the first component, is refused; so is the empty slot just past the array's end, and storage further past it that
/// holds SOL at a far larger unit count, as storage a holder could fill.
#[test]
fn test_vlt1_the_component_must_lie_inside_the_array() {
    let mut e = exit();
    e.snapshot();
    e.h.resolve_intake(e.index, e.settled, &e.proof(&["settled_intake", "proof"]))
        .expect_ok();
    let (recipient, signature) = (e.recipient("holder_a"), e.signature());
    e.claim_a(recipient, 0, signature.clone())
        .expect_code(VaultError::WrongComponent);
    e.claim_a(recipient, 2, signature.clone())
        .expect_code(VaultError::WrongComponent);
    let (index, holder) = (e.index, e.holder("holder_a"));
    let past = bytes(&e.f["holder_a"]["past_the_end"]["proof"]);
    e.h.claim_snapshot(index, holder, recipient, 7, signature.clone(), &past)
        .expect_code(VaultError::WrongComponent);
    e.claim_a(recipient, 1, signature).expect_ok();
}

/// A holder's share goes where the holder says: to the recipient its Ethereum key signed for, under OpenZeppelin's rules
/// for a signature, or to the recovery key it registered, and nowhere else.
#[test]
fn a_claim_is_paid_only_where_its_holder_says() {
    let mut e = exit();
    e.snapshot();
    e.h.resolve_intake(e.index, e.settled, &e.proof(&["settled_intake", "proof"]))
        .expect_ok();
    let (recipient, signature) = (e.recipient("holder_a"), e.signature());
    e.claim_a(Pubkey::new_unique(), 1, signature.clone())
        .expect_code(VaultError::BadSignature);
    e.claim_a(recipient, 1, Vec::new())
        .expect_code(VaultError::BadSignature);
    e.claim_a(recipient, 1, signature[..64].to_vec())
        .expect_code(VaultError::BadSignature);
    let mut v29 = signature.clone();
    v29[64] = 29;
    e.claim_a(recipient, 1, v29)
        .expect_code(VaultError::BadSignature);
    // v as the raw recovery id, 0 or 1, which recovers the same key elsewhere: OpenZeppelin takes only 27 and 28.
    let mut raw = signature.clone();
    raw[64] -= 27;
    e.claim_a(recipient, 1, raw)
        .expect_code(VaultError::BadSignature);
    // The same signature with s in the upper half and v flipped recovers the same key; OpenZeppelin refuses it.
    e.claim_a(recipient, 1, malleable(&signature))
        .expect_code(VaultError::BadSignature);
    let treasury = e.h.treasury;
    e.claim_a(treasury, 1, signature.clone())
        .expect_code(VaultError::WrongRecipient);
    e.claim_a(recipient, 1, signature).expect_ok();

    // Holder B registered a recovery key: paid there and only there, signature or not.
    e.claim_b(Pubkey::new_unique())
        .expect_code(VaultError::WrongRecipient);
    let recipient_b = e.recipient("holder_b");
    e.claim_b(recipient_b).expect_ok();
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
    let mut e = exit();
    e.snapshot();
    e.h.resolve_intake(e.index, e.settled, &e.proof(&["settled_intake", "proof"]))
        .expect_ok();
    let index = e.index;
    let unsent = bytes(&e.f["unsent_burn"]["payload"]);
    let unsent_proof = e.proof(&["unsent_burn", "proof"]);
    let recipient = key(&e.f["burn"]["recipient"]);
    e.h.deliver_recorded_burn(index, unsent, recipient, &unsent_proof)
        .expect_code(VaultError::NotRecorded);
    // A message of another kind resolves another way: refused before anything is read.
    let mut settle = bytes(&e.f["burn"]["payload"]);
    settle[2 * 32 + 31] = INTAKE_SETTLED;
    e.h.deliver_recorded_burn(index, settle, recipient, &unsent_proof)
        .expect_code(VaultError::UnknownKind);
    let migrate = bytes(&e.f["migrate"]["payload"]);
    let migrate_proof = e.proof(&["migrate", "proof"]);
    let v2 = h20(&e.f["migrate"]["new_index"]);
    e.h.register(v2, h32(&e.f["migrate"]["new_salt"]))
        .expect_ok();
    e.h.deliver_recorded_burn(index, migrate.clone(), recipient, &migrate_proof)
        .expect_code(VaultError::UnknownKind);
    let out =
        e.h.deliver_recorded_migrate(index, v2, migrate, &migrate_proof);
    out.expect_ok();
    println!("deliver_recorded_migrate: {} compute units", out.cu);
    assert_eq!(
        e.h.index(&v2).balance,
        FLOOR,
        "one share's SOL, 1.5, the floor's worth today"
    );
    let id = h32(&e.f["migrate"]["id"]);
    assert_eq!(e.h.owed(&index, &id).remaining, 1_500_000_000 - FLOOR);
    e.burn().expect_ok();
}

/// Every node is checked against the snapshot's root: a proof tampered with, cut short or followed by anything does not
/// prove the hub's storage.
#[test]
fn a_state_proof_must_prove_the_storage() {
    let mut e = exit();
    e.snapshot();
    let (index, settled) = (e.index, e.settled);
    let proof = e.proof(&["settled_intake", "proof"]);
    let mut tampered = proof.clone();
    let middle = tampered.len() / 2;
    tampered[middle] ^= 1;
    e.h.resolve_intake(index, settled, &tampered)
        .expect_code(VaultError::BadStateProof);
    e.h.resolve_intake(index, settled, &proof[..proof.len() - 1])
        .expect_code(VaultError::BadStateProof);
    let mut longer = proof.clone();
    longer.push(0);
    e.h.resolve_intake(index, settled, &longer)
        .expect_code(VaultError::BadStateProof);
    e.h.resolve_intake(index, settled, &proof).expect_ok();
}

/// What the vault computes of Ethereum's encodings, against what Solidity's encoder and `cast` computed for the same
/// hub: every slot a claim, a resolution and a recorded delivery read, SOL's token id, and the EIP-712 digest a holder
/// signs, whose signature recovers to the holder.
#[test]
fn the_reads_and_the_digest_are_solidity_s() {
    let f = fixture();
    let holder = h20(&f["holder_a"]["address"]);
    for c in 0..3 {
        let want: Vec<[u8; 32]> = f["holder_a"]["claims"][c]["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(h32)
            .collect();
        assert_eq!(
            snapshot::claim_slots(&holder, c as u64, CHAIN_ID).to_vec(),
            want
        );
    }
    let settled = h32(&f["settled_intake"]["id"]);
    assert_eq!(
        snapshot::settled_slot(&settled),
        h32(&f["settled_intake"]["proof"]["slots"][0])
    );
    let burn = h32(&f["burn"]["id"]);
    assert_eq!(
        snapshot::sent_slot(&burn),
        h32(&f["burn"]["proof"]["slots"][0])
    );
    assert_eq!(snapshot::vault_token(CHAIN_ID), h20(&f["sol_token"]));

    let index = h20(&f["index"]);
    let recipient = key(&f["holder_a"]["recipient"]);
    let digest = snapshot::claim_digest(
        &h32(&f["vault"]),
        SOURCE_CHAIN_ID,
        &index,
        &holder,
        &recipient,
    );
    assert_eq!(digest, h32(&f["holder_a"]["digest"]));
    let signature = bytes(&f["holder_a"]["signature"]);
    snapshot::check_signature(&digest, &signature, &holder).unwrap();
    assert!(snapshot::check_signature(&digest, &signature, &[1u8; 20]).is_err());
}

/// The state reader on the fixture's proofs: the values `eth_getProof` reported, zero for a slot proven absent, and zero
/// for every slot of an account the state does not hold.
#[test]
fn the_state_reader_reads_what_eth_get_proof_reported() {
    let f = fixture();
    let root = h32(&f["state_root"]);
    let index = h20(&f["index"]);
    for case in [
        &f["holder_a"]["claims"][1],
        &f["holder_b"]["claims"][2],
        &f["open_intake"]["proof"],
        &f["unsent_burn"]["proof"],
    ] {
        let slots: Vec<[u8; 32]> = case["slots"].as_array().unwrap().iter().map(h32).collect();
        let want: Vec<[u8; 32]> = case["values"].as_array().unwrap().iter().map(h32).collect();
        let got = state_reader::read_slots(&root, &index, &slots, &bytes(&case["proof"])).unwrap();
        assert_eq!(got, want);
    }
    let absent = &f["absent_account"];
    let got = state_reader::read_slots(
        &root,
        &h20(&absent["address"]),
        &[[0u8; 32]],
        &bytes(&absent["proof"]["proof"]),
    )
    .unwrap();
    assert_eq!(got, vec![[0u8; 32]]);
    // Under another root, nothing is proven.
    let hub_proof = bytes(&f["settled_intake"]["proof"]["proof"]);
    assert!(state_reader::read_slots(&[0x22; 32], &index, &[[0u8; 32]], &hub_proof).is_err());
}

/// B1-06: the claim's EIP-712 domain names Ethereum's chain id, where the holder's wallet is, not the registry's id for
/// Solana, which no EVM network carries and wallets refuse to sign for. Holder A's signature under Sepolia's id pays;
/// the one it gave under the registry's id, the domain the claim had before, is refused.
#[test]
fn test_b106_the_claim_domain_names_ethereum() {
    let mut e = exit();
    e.snapshot();
    e.h.resolve_intake(e.index, e.settled, &e.proof(&["settled_intake", "proof"]))
        .expect_ok();
    let recipient = e.recipient("holder_a");
    let registry = bytes(&Value::from(
        "0xb71f8db60b38425c7bdd2d7d5eca6c0c1edb7cfc4685e0f597c810a9cc618492308d5a67e6affd495a176e6b207dc6ccbc3a8fa016d3f3f0a50da7b3166c3a6e1b",
    ));
    e.claim_a(recipient, 1, registry)
        .expect_code(VaultError::BadSignature);
    let signature = e.signature();
    e.claim_a(recipient, 1, signature).expect_ok();
    let id = snapshot::claim_id(&e.index, &e.holder("holder_a"));
    assert_eq!(e.h.owed(&e.index, &id).recipient, recipient);
}
