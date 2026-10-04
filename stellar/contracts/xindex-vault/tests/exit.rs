//! The snapshot exit on a real hub's storage (`tests/fixtures/hub.json`, `generate.py`): the repository's own factory and
//! hub on anvil, registered under Stellar testnet's registry id with the tests' vault id, read under the state root of
//! its last block through `eth_getProof`'s nodes, as the vault reads it at its snapshot. The twin of Solana's
//! `tests/exit.rs`.

mod common;

use common::*;
use serde_json::Value;
use soroban_sdk::{Bytes, BytesN};
use xindex_core::constants::*;
use xindex_core::snapshot;
use xindex_vault::error::VaultError;
use xindex_vault::types::*;

fn fixture() -> Value {
    json("stellar/contracts/xindex-vault/tests/fixtures/hub.json")
}

fn hexb(v: &Value) -> std::vec::Vec<u8> {
    hex(v.as_str().unwrap())
}

fn err<T: core::fmt::Debug + PartialEq>(
    r: Result<
        Result<T, soroban_sdk::ConversionError>,
        Result<soroban_sdk::Error, soroban_sdk::InvokeError>,
    >,
    e: VaultError,
) {
    match r {
        Err(Ok(got)) => assert_eq!(got, code(e)),
        other => panic!("expected {e:?}, got {other:?}"),
    }
}

/// The vault as it stands at the hub's last block: the index registered, the settled order's XLM and an open order's
/// deposited before their deadlines, and its checkpoint at that block, whose state root the reads are under.
struct Exit {
    h: H,
    f: Value,
    index: [u8; 20],
    settled: [u8; 32],
    open: [u8; 32],
    open_depositor: soroban_sdk::Address,
}

fn exit() -> Exit {
    let f = fixture();
    assert_eq!(
        h32(&f["vault"]),
        VAULT_ID,
        "the hub's chain registry names this vault"
    );
    assert_eq!(f["source_chain_id"].as_u64().unwrap(), SOURCE_CHAIN_ID);
    assert_eq!(f["chain_id"].as_u64().unwrap(), CHAIN_ID);
    let settled = h32(&f["settled_intake"]["id"]);
    let open = h32(&f["open_intake"]["id"]);
    let mut h = H::deployed_with(
        h20(&f["factory"]),
        h20(&f["hub_implementation"]),
        f["settled_intake"]["deadline"].as_u64().unwrap() - 600,
    );
    let env = h.env.clone();
    let index = h20(&f["index"]);
    h.index = index;
    h.salt = h32(&f["salt"]);
    h.v()
        .register_index(&b20(&env, &index), &b32(&env, &h.salt));
    // A first checkpoint, before any deposit (B1-04).
    h.warp(1);
    h.advance(1);
    let amount = |name: &str| f[name]["amount"].as_u64().unwrap() as i128;
    let settled_depositor = funded(&env, "settled depositor");
    let open_depositor = funded(&env, "open depositor");
    h.v().deposit(
        &settled_depositor,
        &b20(&env, &index),
        &b32(&env, &settled),
        &amount("settled_intake"),
    );
    let timestamp = f["timestamp"].as_u64().unwrap();
    h.set_time(timestamp + 60);
    h.v().deposit(
        &open_depositor,
        &b20(&env, &index),
        &b32(&env, &open),
        &amount("open_intake"),
    );
    let c = Checkpoint {
        block: f["block"].as_u64().unwrap(),
        timestamp,
        state_root: b32(&env, &h32(&f["state_root"])),
    };
    h.advance_to(&c);
    Exit {
        h,
        f,
        index,
        settled,
        open,
        open_depositor,
    }
}

impl Exit {
    fn snapshot(&self) {
        self.h
            .set_time(self.h.v().stall_start() + SNAPSHOT_EXIT_DELAY as u64);
        self.h.v().begin_snapshot();
    }

    fn proof(&self, path: &[&str]) -> Bytes {
        let mut v = &self.f;
        for p in path {
            v = &v[*p];
        }
        bytes(&self.h.env, &hexb(&v["proof"]))
    }

    fn holder(&self, holder: &str) -> BytesN<20> {
        b20(&self.h.env, &h20(&self.f[holder]["address"]))
    }

    fn recipient(&self, holder: &str) -> [u8; 32] {
        h32(&self.f[holder]["recipient"])
    }

    fn signature(&self) -> std::vec::Vec<u8> {
        hexb(&self.f["holder_a"]["signature"])
    }

    fn claim_a(
        &self,
        recipient: [u8; 32],
        component: usize,
        signature: &[u8],
    ) -> Result<
        Result<(), soroban_sdk::ConversionError>,
        Result<soroban_sdk::Error, soroban_sdk::InvokeError>,
    > {
        let env = &self.h.env;
        let proof = bytes(
            env,
            &hexb(&self.f["holder_a"]["claims"][component]["proof"]),
        );
        self.h.v().try_claim_snapshot(
            &b20(env, &self.index),
            &self.holder("holder_a"),
            &(component as u64),
            &b32(env, &recipient),
            &bytes(env, signature),
            &proof,
        )
    }

    fn claim_b(
        &self,
        recipient: [u8; 32],
    ) -> Result<
        Result<(), soroban_sdk::ConversionError>,
        Result<soroban_sdk::Error, soroban_sdk::InvokeError>,
    > {
        let env = &self.h.env;
        let proof = bytes(env, &hexb(&self.f["holder_b"]["claims"][1]["proof"]));
        self.h.v().try_claim_snapshot(
            &b20(env, &self.index),
            &self.holder("holder_b"),
            &1,
            &b32(env, &recipient),
            &Bytes::new(env),
            &proof,
        )
    }

    fn recorded(
        &self,
        name: &str,
    ) -> Result<
        Result<(), soroban_sdk::ConversionError>,
        Result<soroban_sdk::Error, soroban_sdk::InvokeError>,
    > {
        let env = &self.h.env;
        self.h.v().try_deliver_recorded(
            &bytes(env, &hexb(&self.f[name]["payload"])),
            &self.proof(&[name, "proof"]),
        )
    }

    fn owed(&self, id: &[u8; 32]) -> Owed {
        let env = &self.h.env;
        self.h
            .v()
            .owed(&b20(env, &self.index), &b32(env, id))
            .unwrap()
    }

    fn resolve(&self, which: &str, id: [u8; 32]) {
        let env = &self.h.env;
        self.h.v().resolve_intake(
            &b20(env, &self.index),
            &b32(env, &id),
            &self.proof(&[which, "proof"]),
        );
    }
}

/// The whole exit, on a real hub's storage: each open intake settled or failed from the hub's mark at the snapshot, a
/// burn in flight paid from the hub's record, and holders paid their shares at the snapshot's units plus their claims,
/// within the speed limit, by signature or to their recovery key, once.
#[test]
fn the_snapshot_exit_reads_a_real_hub() {
    let e = exit();
    let env = e.h.env.clone();
    let index = b20(&env, &e.index);
    err(
        e.h.v().try_resolve_intake(
            &index,
            &b32(&env, &e.settled),
            &e.proof(&["settled_intake", "proof"]),
        ),
        VaultError::NoSnapshot,
    );
    err(e.recorded("burn"), VaultError::NoSnapshot);
    let signature = e.signature();
    err(
        e.claim_a(e.recipient("holder_a"), 1, &signature),
        VaultError::NoSnapshot,
    );
    e.snapshot();

    // The settled order's intake joins the index; the open one fails, and its depositor takes its XLM back.
    e.resolve("settled_intake", e.settled);
    let settled_amount = e.f["settled_intake"]["amount"].as_u64().unwrap();
    assert_eq!(
        e.h.v()
            .intake(&index, &b32(&env, &e.settled))
            .unwrap()
            .state,
        INTAKE_SETTLED_STATE as u32
    );
    assert_eq!(e.h.index_state(&e.index).balance, settled_amount);
    err(
        e.h.v().try_resolve_intake(
            &index,
            &b32(&env, &e.settled),
            &e.proof(&["settled_intake", "proof"]),
        ),
        VaultError::IntakeNotOpen,
    );
    e.resolve("open_intake", e.open);
    assert_eq!(
        e.h.v().intake(&index, &b32(&env, &e.open)).unwrap().state,
        INTAKE_FAILED_STATE as u32
    );
    let before = e.h.balance(&e.open_depositor);
    e.h.v()
        .refund(&e.open_depositor, &index, &b32(&env, &e.open));
    let open_amount = e.f["open_intake"]["amount"].as_u64().unwrap() as i128;
    assert_eq!(e.h.balance(&e.open_depositor) - before, open_amount);

    // The burn in flight, to an account that exists: paid what the speed limit allows today, the rest owed.
    let burn_recipient = e.f["burn"]["recipient"]
        .as_str()
        .map(|_| h32(&e.f["burn"]["recipient"]))
        .unwrap();
    create_account(&env, &burn_recipient, 0);
    let limit = e.h.v().available(&index);
    e.recorded("burn").unwrap().unwrap();
    let burn_id = h32(&e.f["burn"]["id"]);
    let paid = e.h.balance(&account_of(&env, &burn_recipient)) as u64;
    assert!(paid > 0 && paid <= limit);
    assert_eq!(
        paid + e.owed(&burn_id).remaining,
        125 * XLM,
        "one share's XLM"
    );
    err(e.recorded("burn"), VaultError::AlreadyDelivered);

    // Holder A: 4 shares and a claim of one share's XLM, to the recipient it signed for: owed, as today's limit is spent.
    let recipient_a = e.recipient("holder_a");
    create_account(&env, &recipient_a, 0);
    e.claim_a(recipient_a, 1, &signature).unwrap().unwrap();
    let id_a = snapshot::claim_id(&C, &e.index, &h20(&e.f["holder_a"]["address"]));
    let owed_a = e.owed(&id_a);
    assert_eq!(
        owed_a.remaining + e.h.balance(&account_of(&env, &recipient_a)) as u64,
        625 * XLM
    );
    assert_eq!(owed_a.recipient.to_array(), recipient_a);
    err(
        e.claim_a(recipient_a, 1, &signature),
        VaultError::AlreadyClaimed,
    );
    // Holder B: 3 shares, to the recovery key it registered in the hub, with no signature.
    let recipient_b = e.recipient("holder_b");
    e.claim_b(recipient_b).unwrap().unwrap();
    let id_b = snapshot::claim_id(&C, &e.index, &h20(&e.f["holder_b"]["address"]));
    assert_eq!(e.owed(&id_b).remaining, 375 * XLM);

    // A day on, the speed limit pays the next part.
    e.h.warp(25 * 3600);
    let before = e.h.balance(&account_of(&env, &recipient_a));
    e.h.v().release(&index, &b32(&env, &id_a));
    assert!(e.h.balance(&account_of(&env, &recipient_a)) > before);
}

/// VLT-1: a claim reads a component only inside the hub's components array, and only this chain's coin there. WETH,
/// the first component, is refused; so is the empty slot just past the array's end, and storage further past it that
/// holds XLM at a far larger unit count, as storage a holder could fill.
#[test]
fn test_vlt1_the_component_must_lie_inside_the_array() {
    let e = exit();
    e.snapshot();
    e.resolve("settled_intake", e.settled);
    let env = e.h.env.clone();
    let (recipient, signature) = (e.recipient("holder_a"), e.signature());
    err(
        e.claim_a(recipient, 0, &signature),
        VaultError::WrongComponent,
    );
    err(
        e.claim_a(recipient, 2, &signature),
        VaultError::WrongComponent,
    );
    let past = bytes(&env, &hexb(&e.f["holder_a"]["past_the_end"]["proof"]));
    err(
        e.h.v().try_claim_snapshot(
            &b20(&env, &e.index),
            &e.holder("holder_a"),
            &7,
            &b32(&env, &recipient),
            &bytes(&env, &signature),
            &past,
        ),
        VaultError::WrongComponent,
    );
    e.claim_a(recipient, 1, &signature).unwrap().unwrap();
}

/// `n - s` and `v` flipped: the other signature of the same key over the same digest.
fn malleable(signature: &[u8]) -> std::vec::Vec<u8> {
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

/// A holder's share goes where the holder says: to the account its Ethereum key signed for, under OpenZeppelin's rules
/// for a signature, or to the recovery key it registered, and nowhere else.
#[test]
fn a_claim_is_paid_only_where_its_holder_says() {
    let e = exit();
    e.snapshot();
    e.resolve("settled_intake", e.settled);
    let (recipient, signature) = (e.recipient("holder_a"), e.signature());
    // Each of these fails, in the vault's check or in the host's recovery, and pays nothing.
    for bad in [
        e.claim_a(key_of("someone else"), 1, &signature),
        e.claim_a(recipient, 1, &[]),
        e.claim_a(recipient, 1, &signature[..64]),
        e.claim_a(recipient, 1, &{
            let mut v = signature.clone();
            v[64] = 29;
            v
        }),
        e.claim_a(recipient, 1, &{
            let mut v = signature.clone();
            v[64] -= 27;
            v
        }),
        e.claim_a(recipient, 1, &malleable(&signature)),
    ] {
        assert!(bad.is_err());
    }
    err(
        e.claim_a(recipient, 1, &malleable(&signature)),
        VaultError::BadSignature,
    );
    err(e.claim_a(recipient, 1, &[]), VaultError::BadSignature);
    e.claim_a(recipient, 1, &signature).unwrap().unwrap();
    err(
        e.claim_b(key_of("someone else")),
        VaultError::WrongRecipient,
    );
    e.claim_b(e.recipient("holder_b")).unwrap().unwrap();
}

/// A burn or migration runs after the snapshot only on the index's own mark of it, and only a burn or a migration: a
/// real migration into the index's second version is paid into that version's balance within the speed limit.
#[test]
fn a_recorded_message_runs_only_on_the_hubs_mark() {
    let e = exit();
    e.snapshot();
    e.resolve("settled_intake", e.settled);
    let env = e.h.env.clone();
    err(e.recorded("unsent_burn"), VaultError::NotRecorded);
    let mut settle = hexb(&e.f["burn"]["payload"]);
    settle[2 * 32 + 31] = INTAKE_SETTLED;
    err(
        e.h.v()
            .try_deliver_recorded(&bytes(&env, &settle), &e.proof(&["unsent_burn", "proof"])),
        VaultError::UnknownKind,
    );
    let v2 = h20(&e.f["migrate"]["new_index"]);
    err(e.recorded("migrate"), VaultError::NotAnIndex);
    e.h.v().register_index(
        &b20(&env, &v2),
        &b32(&env, &h32(&e.f["migrate"]["new_salt"])),
    );
    e.recorded("migrate").unwrap().unwrap();
    let moved = e.h.index_state(&v2).balance;
    let id = h32(&e.f["migrate"]["id"]);
    assert!(moved > 0);
    assert_eq!(moved + e.owed(&id).remaining, 125 * XLM, "one share's XLM");
}

/// Every node is checked against the snapshot's root: a proof tampered with, cut short or followed by anything does not
/// prove the hub's storage.
#[test]
fn a_state_proof_must_prove_the_storage() {
    let e = exit();
    e.snapshot();
    let env = e.h.env.clone();
    let index = b20(&env, &e.index);
    let settled = b32(&env, &e.settled);
    let proof = hexb(&e.f["settled_intake"]["proof"]["proof"]);
    let mut tampered = proof.clone();
    let middle = tampered.len() / 2;
    tampered[middle] ^= 1;
    for bad in [
        tampered,
        proof[..proof.len() - 1].to_vec(),
        [proof.clone(), vec![0]].concat(),
    ] {
        err(
            e.h.v()
                .try_resolve_intake(&index, &settled, &bytes(&env, &bad)),
            VaultError::BadStateProof,
        );
    }
    e.h.v()
        .resolve_intake(&index, &settled, &bytes(&env, &proof));
}

/// What the vault computes of Ethereum's encodings, against what Solidity's encoder and `cast` computed for the same
/// hub: every slot a claim, a resolution and a recorded delivery read, XLM's token id, and the EIP-712 digest a holder
/// signs, under the domain whose salt is this vault's id and whose chain id is Ethereum's (B1-06).
#[test]
fn the_reads_and_the_digest_are_solidity_s() {
    let f = fixture();
    let holder = h20(&f["holder_a"]["address"]);
    for c in 0..3 {
        let want: std::vec::Vec<[u8; 32]> = f["holder_a"]["claims"][c]["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(h32)
            .collect();
        assert_eq!(
            snapshot::claim_slots(&C, &holder, c as u64, CHAIN_ID).to_vec(),
            want
        );
    }
    assert_eq!(snapshot::vault_token(&C, CHAIN_ID), h20(&f["xlm_token"]));
    let digest = snapshot::claim_digest(
        &C,
        &VAULT_ID,
        SOURCE_CHAIN_ID,
        &h20(&f["index"]),
        &holder,
        &h32(&f["holder_a"]["recipient"]),
    );
    assert_eq!(digest, h32(&f["holder_a"]["digest"]));
}

/// After the exit, `attest` shows it to Ethereum: the snapshot's state root at the slot the hub's `recordExit` and every
/// evidence proof read (LG-5).
#[test]
fn attest_shows_the_exit() {
    let e = exit();
    let env = e.h.env.clone();
    let key = vec32(&env, &[u256(25)]);
    e.h.v().attest(&key, &vec32(&env, &[[0u8; 32]]));
    e.snapshot();
    let root = h32(&e.f["state_root"]);
    e.h.v().attest(&key, &vec32(&env, &[root]));
    err(
        e.h.v().try_attest(&key, &vec32(&env, &[[0u8; 32]])),
        VaultError::NotAttested,
    );
}

/// What the snapshot exit costs on the real hub's proofs, and how large they are: a claim by signature (five storage
/// slots and a secp256k1 recovery), a claim to a recovery key, an intake resolved and a recorded burn, each far inside
/// Stellar's 400M instructions and its 132 KB transaction.
#[test]
fn the_exits_calls_fit_stellars_limits() {
    let e = exit();
    let env = e.h.env.clone();
    e.snapshot();
    let mut costs = std::vec::Vec::new();
    let size = |path: &[&str]| e.proof(path).len() as usize;
    e.resolve("settled_intake", e.settled);
    costs.push((
        "resolve_intake",
        instructions(&env),
        size(&["settled_intake", "proof"]),
    ));
    let recipient_a = e.recipient("holder_a");
    create_account(&env, &recipient_a, 0);
    e.claim_a(recipient_a, 1, &e.signature()).unwrap().unwrap();
    let claim = hexb(&e.f["holder_a"]["claims"][1]["proof"]).len();
    costs.push(("claim_snapshot by signature", instructions(&env), claim));
    e.claim_b(e.recipient("holder_b")).unwrap().unwrap();
    let claim = hexb(&e.f["holder_b"]["claims"][1]["proof"]).len();
    costs.push((
        "claim_snapshot to a recovery key",
        instructions(&env),
        claim,
    ));
    create_account(&env, &h32(&e.f["burn"]["recipient"]), 0);
    e.recorded("burn").unwrap().unwrap();
    costs.push((
        "deliver_recorded BURN",
        instructions(&env),
        size(&["burn", "proof"]),
    ));
    for (call, n, bytes) in costs {
        println!("vault: {call}, {n} instructions, a {bytes}-byte proof");
        assert!(n < MAX_INSTRUCTIONS / 10);
        assert!(bytes < MAX_TX_BYTES / 4);
    }
}

/// B1-06: the claim's EIP-712 domain names Ethereum's chain id, where the holder's wallet is, not the registry's id for
/// Stellar, which no EVM network carries and wallets refuse to sign for. Holder A's signature under Sepolia's id pays;
/// the one it gave under the registry's id, the domain the claim had before, is refused.
#[test]
fn test_b106_the_claim_domain_names_ethereum() {
    let e = exit();
    e.snapshot();
    e.resolve("settled_intake", e.settled);
    let recipient = e.recipient("holder_a");
    let registry = hex("0x5943aa1bbb86d6e9d4fac7ea67a0ab051624efa27264cbaa61b1c155b819b8275b528a50da8fa1732388249044d6d7734b5ebae34f1f4247bb1f022ae837800b1c");
    err(e.claim_a(recipient, 1, &registry), VaultError::BadSignature);
    e.claim_a(recipient, 1, &e.signature()).unwrap().unwrap();
    let id = snapshot::claim_id(&C, &e.index, &h20(&e.f["holder_a"]["address"]));
    assert_eq!(e.owed(&id).recipient, b32(&e.h.env, &recipient));
}
