//! The Stellar vault against the EVM vault's rules (`test/XindexVault.t.sol`), on the real host with its built Wasm,
//! the native asset's own contract and accounts holding real XLM, and mock verifiers standing in for P1 and P2:
//! deployment, registration, deposits, the route and the used mark, burns under the speed limit, refunds, migration,
//! governance and its delay, the freeze, and `attest`, its record pinned byte for byte.

mod common;

use common::*;
use soroban_sdk::testutils::Events as _;
use soroban_sdk::{xdr, Address, Bytes, Event, IntoVal, Symbol};
use xindex_core::constants::*;
use xindex_core::Crypto;
use xindex_vault::error::VaultError;
use xindex_vault::events::Attest;
use xindex_vault::types::*;

fn err(r: Result<(), soroban_sdk::Error>, e: VaultError) {
    assert_eq!(r, Err(code(e)));
}

// ---------------------------------------------------------------------
// deployment
// ---------------------------------------------------------------------

/// The constructor's refusals: no zero factory or template; the freezer a Stellar account, not the zero key; the
/// recovery proposer a contract, and so never the freezer; P1 and P2 two different contracts, whose code the vault pins.
#[test]
fn the_constructor_checks_its_settings() {
    let env = new_env();
    env.mock_all_auths();
    native_asset(&env);
    let p1 = env.register(MockVerifier, (false,));
    let p2 = env.register(MockVerifier, (false,));
    let freezer = funded(&env, "freezer");
    let recovery = env.register(MockMultisig, ());
    let zero = account_of(&env, &[0; 32]);
    let vault = H::vault_address(&env);
    let w = wasm("xindex_vault");
    // The vault's error the constructor failed with, if it did.
    let deploy = |args: InitArgs, a: &Address, b: &Address| -> Option<u32> {
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            env.register_at(&vault, w.as_slice(), (args, a.clone(), b.clone()));
        }));
        let message = r.err()?.downcast::<std::string::String>().unwrap();
        let at = message
            .find("constructor invocation has failed with error\", Error(Contract, #")
            .unwrap();
        let tail = &message[at..];
        let digits: std::string::String = tail[tail.find('#').unwrap() + 1..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        Some(digits.parse().unwrap())
    };
    let init = |f: &Address, r: &Address, factory, hub| H::init_args(&env, f, r, factory, hub);
    let refused = |e: VaultError| Some(e as u32);
    assert_eq!(
        deploy(init(&freezer, &recovery, [0; 20], HUB), &p1, &p2),
        refused(VaultError::ZeroAddress)
    );
    assert_eq!(
        deploy(init(&freezer, &recovery, FACTORY, [0; 20]), &p1, &p2),
        refused(VaultError::ZeroAddress)
    );
    assert_eq!(
        deploy(init(&recovery, &recovery, FACTORY, HUB), &p1, &p2),
        refused(VaultError::NotAnAccount)
    );
    assert_eq!(
        deploy(init(&zero, &recovery, FACTORY, HUB), &p1, &p2),
        refused(VaultError::ZeroAddress)
    );
    assert_eq!(
        deploy(init(&freezer, &freezer, FACTORY, HUB), &p1, &p2),
        refused(VaultError::NotAContract)
    );
    let good = init(&freezer, &recovery, FACTORY, HUB);
    assert_eq!(
        deploy(good.clone(), &p1, &p1),
        refused(VaultError::VerifiersNotDistinct)
    );
    assert_eq!(
        deploy(good.clone(), &p1, &freezer),
        refused(VaultError::NotAContract)
    );
    assert_eq!(deploy(good, &p1, &p2), None);
    let cfg = xindex_vault::XindexVaultClient::new(&env, &vault).config();
    assert_eq!(cfg.p1.address, p1);
    assert_eq!(cfg.p2.address, p2);
    assert_eq!(cfg.checkpoint.timestamp, env.ledger().timestamp());
    assert_eq!(cfg.chain_id, CHAIN_ID);
}

/// The vault's id is its contract id, as the factory registers it and every message names it.
#[test]
fn the_vaults_id_is_its_contract_id() {
    let h = H::deployed();
    assert_eq!(h.v().vault_id().to_array(), VAULT_ID);
}

// ---------------------------------------------------------------------
// registration
// ---------------------------------------------------------------------

/// Only the factory's CREATE2 clone of the hub template registers, once; its digest is the hub's to read at once.
#[test]
fn register_index_by_the_factorys_create2_formula() {
    let h = H::deployed();
    let env = &h.env;
    let (index, salt) = h.index_of(1);
    let wrong = C.keccak256(&[b"another salt"]);
    assert_eq!(
        h.v()
            .try_register_index(&b20(env, &index), &b32(env, &wrong)),
        Err(Ok(code(VaultError::NotAnIndex)))
    );
    h.v().register_index(&b20(env, &index), &b32(env, &salt));
    h.v().register_index(&b20(env, &index), &b32(env, &salt));
    let digest = xindex_core::abi::index_digest(&C, CHAIN_ID, &VAULT_ID, &index, false, 0, 0);
    assert_eq!(h.v().index_digest(&b20(env, &index)).to_array(), digest);
}

// ---------------------------------------------------------------------
// deposits
// ---------------------------------------------------------------------

/// A deposit moves exactly its XLM through the native asset's contract, books it against the cap, and updates the
/// intake's digest; the intake's id fixes its deadline.
#[test]
fn deposit_books_and_moves_xlm() {
    let mut h = H::ready();
    let env = h.env.clone();
    let from = funded(&env, "alice");
    let id = h.intake(h.now() + 3600);
    let (index, intake) = (b20(&env, &h.index), b32(&env, &id));
    let before = h.balance(&from);
    h.v().deposit(&from, &index, &intake, &(10 * XLM as i128));
    h.v().deposit(&from, &index, &intake, &(5 * XLM as i128));
    assert_eq!(before - h.balance(&from), 15 * XLM as i128);
    assert_eq!(h.balance(&h.vault), 15 * XLM as i128);
    assert_eq!(h.config().held, 15 * XLM);
    assert_eq!(h.v().deposited(&index, &intake, &from), 15 * XLM);
    let digest = xindex_core::abi::intake_digest(
        &C,
        CHAIN_ID,
        &VAULT_ID,
        &h.index,
        &id,
        INTAKE_OPEN,
        true,
        15 * XLM,
    );
    assert_eq!(h.v().intake_digest(&index, &intake).to_array(), digest);
}

#[test]
fn deposit_refusals() {
    let mut h = H::ready();
    let env = h.env.clone();
    let from = funded(&env, "alice");
    let index = b20(&env, &h.index);
    let id = h.intake(h.now() + 3600);
    let intake = b32(&env, &id);
    let r = |h: &H, i: &soroban_sdk::BytesN<20>, id: &soroban_sdk::BytesN<32>, a: i128| {
        h.v()
            .try_deposit(&from, i, id, &a)
            .map(|_| ())
            .map_err(|e| e.unwrap())
    };
    err(r(&h, &index, &intake, 0), VaultError::ZeroAmount);
    err(r(&h, &index, &intake, -1), VaultError::ZeroAmount);
    err(
        r(&h, &index, &intake, u64::MAX as i128 + 1),
        VaultError::Overflow,
    );
    let (other, _) = h.index_of(9);
    err(
        r(&h, &b20(&env, &other), &intake, 1),
        VaultError::NotAnIndex,
    );
    err(
        r(&h, &index, &intake, (CAP + 1) as i128),
        VaultError::CapExceeded,
    );
    let late = h.intake(h.now() - 1);
    err(
        r(&h, &index, &b32(&env, &late), 1),
        VaultError::IntakeClosed,
    );
    let far = h.intake(h.now() + MAX_INTAKE_LIFE as u64 + 1);
    err(
        r(&h, &index, &b32(&env, &far), 1),
        VaultError::IntakeTooLong,
    );
    // A freeze, and a stall, stop deposits.
    h.v().freeze();
    err(r(&h, &index, &intake, 1), VaultError::VaultFrozen);
}

/// A week without a checkpoint stalls the vault: it takes no deposit, which it might never be able to settle or
/// refund, until anyone brings a new checkpoint.
#[test]
fn a_stalled_vault_takes_no_deposit() {
    let mut h = H::ready();
    let env = h.env.clone();
    let from = funded(&env, "alice");
    h.warp(STALL_PERIOD as u64 + 1);
    assert!(h.v().stalled());
    let id = h.intake(h.now() + 3600);
    let r = h
        .v()
        .try_deposit(&from, &b20(&env, &h.index), &b32(&env, &id), &1)
        .map(|_| ())
        .map_err(|e| e.unwrap());
    err(r, VaultError::VaultStalled);
    h.fresh();
    h.v()
        .deposit(&from, &b20(&env, &h.index), &b32(&env, &id), &1);
}

// ---------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------

/// An intake settles on both proofs from a checkpointed block: its deposits join the index, and both digests change.
#[test]
fn an_intake_settles_into_the_index() {
    let mut h = H::ready();
    h.fund(100 * XLM);
    let s = h.index_state(&h.index);
    assert_eq!((s.balance, s.has_native), (100 * XLM, true));
    let digest =
        xindex_core::abi::index_digest(&C, CHAIN_ID, &VAULT_ID, &h.index, true, 100 * XLM, 0);
    assert_eq!(
        h.v().index_digest(&b20(&h.env, &h.index)).to_array(),
        digest
    );
}

/// Every check `deliver` makes: the proofs, the kind, the route, the emitter, the used mark.
#[test]
fn deliver_refusals() {
    let mut h = H::ready();
    let id = h.intake(h.now() + 3600);
    let p = h.payload(INTAKE_SETTLED, h.index, &id);
    let env = h.env.clone();
    assert_eq!(
        h.v().try_deliver(&bytes(&env, &p), &1, &None, &None),
        Err(Ok(code(VaultError::NoProof)))
    );
    err(h.try_deliver(&p, By::P1), VaultError::BothProofsRequired);
    // A proof of another log fails in the verifier.
    let bad = Bytes::from_array(&env, &[7u8; 32]);
    assert!(h
        .v()
        .try_deliver(&bytes(&env, &p), &1, &Some(bad.clone()), &Some(bad))
        .is_err());
    // Another source, chain or vault.
    for (source, dest, vault) in [
        (1, CHAIN_ID, VAULT_ID),
        (SOURCE_CHAIN_ID, 1_399_811_150, VAULT_ID),
        (SOURCE_CHAIN_ID, CHAIN_ID, [9u8; 32]),
    ] {
        let q = payload_for(source, INTAKE_SETTLED, dest, vault, h.index, 77, &id);
        err(h.try_deliver(&q, By::Both), VaultError::WrongRoute);
    }
    // An index not registered; a governance kind not from the factory; an unknown kind.
    let (stranger_index, _) = h.index_of(9);
    let q = h.payload(INTAKE_SETTLED, stranger_index, &id);
    err(h.try_deliver(&q, By::Both), VaultError::NotAnIndex);
    let q = h.payload(FREEZE, h.index, &[]);
    err(h.try_deliver(&q, By::Both), VaultError::WrongEmitter);
    let q = h.payload(9, h.index, &[]);
    err(h.try_deliver(&q, By::Both), VaultError::UnknownKind);
    let q = h.payload(0, h.index, &[]);
    err(h.try_deliver(&q, By::Both), VaultError::UnknownKind);
    // A malformed payload.
    let mut q = h.payload(INTAKE_SETTLED, h.index, &id);
    q[0] ^= 1;
    err(h.try_deliver(&q, By::Both), VaultError::BadMessage);
    // Once delivered, never again.
    h.deliver(&p, By::Both);
    err(h.try_deliver(&p, By::Both), VaultError::AlreadyDelivered);
    assert!(h.v().used(&b32(&env, &C.keccak256(&[&p]))));
}

/// VLT-3: a message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
/// snapshot at that checkpoint never pays twice what such a message already paid.
#[test]
fn test_vlt3_a_message_after_the_checkpoint_waits_for_it() {
    let mut h = H::ready();
    h.fund(100 * XLM);
    let p = h.burn_payload(XLM, &key_of("bob"));
    h.block = 1_001;
    err(h.try_deliver(&p, By::Both), VaultError::NotCheckpointed);
    h.warp(1);
    h.advance(1_001);
    h.deliver(&p, By::Both);
}

// ---------------------------------------------------------------------
// burns and the speed limit
// ---------------------------------------------------------------------

/// A burn pays its account within 4% of the index's balance in any 24 hours, or the floor; the rest stays owed and is
/// released as the window moves. An account that does not exist yet cannot take XLM: its payout waits, and is released
/// once it exists (the twin of SOL-5).
#[test]
fn a_burn_pays_within_the_speed_limit() {
    let mut h = H::ready();
    h.fund(1_000 * XLM);
    let bob_key = key_of("bob");
    create_account(&h.env, &bob_key, 0);
    let bob = account_of(&h.env, &bob_key);
    let p = h.burn_payload(100 * XLM, &bob_key);
    h.deliver(&p, By::Both);
    // 4% of 1,000 XLM.
    assert_eq!(h.balance(&bob), 40 * XLM as i128);
    let id = b32(&h.env, &C.keccak256(&[&p]));
    let index = b20(&h.env, &h.index);
    assert_eq!(h.v().owed(&index, &id).unwrap().remaining, 60 * XLM);
    assert_eq!(
        h.v().try_release(&index, &id),
        Err(Ok(code(VaultError::NothingPayable)))
    );
    h.warp(DAY + 3600);
    h.fresh();
    h.v().release(&index, &id);
    assert!(h.balance(&bob) > 40 * XLM as i128);
    let s = h.index_state(&h.index);
    assert_eq!(s.balance + s.paid_total, 1_000 * XLM);
    assert_eq!(h.config().held, s.balance);
}

/// The twin of SOL-5: a burn to an account that does not exist yet, which could not take XLM, is still delivered; its
/// payout waits as owed, in full, and anyone releases it once the account exists.
#[test]
fn test_sol5_a_burn_to_a_new_account_is_still_delivered() {
    let mut h = H::ready();
    h.fund(1_000 * XLM);
    let carol_key = key_of("carol");
    let carol = account_of(&h.env, &carol_key);
    assert!(!carol.exists());
    let q = h.burn_payload(XLM, &carol_key);
    h.deliver(&q, By::Both);
    let (index, qid) = (b20(&h.env, &h.index), b32(&h.env, &C.keccak256(&[&q])));
    assert_eq!(h.v().owed(&index, &qid).unwrap().remaining, XLM);
    assert_eq!(h.index_state(&h.index).balance, 1_000 * XLM);
    assert_eq!(
        h.v().try_release(&index, &qid),
        Err(Ok(code(VaultError::NothingPayable)))
    );
    create_account(&h.env, &carol_key, 0);
    h.v().release(&index, &qid);
    assert_eq!(h.balance(&carol), XLM as i128);
    assert_eq!(h.index_state(&h.index).balance, 999 * XLM);
}

/// The twin of SOL-9: a recipient is a Stellar account by its key, never a contract, so no payout can land in the vault
/// itself, or in the native asset's contract, and strand there outside the book. A burn naming the vault's own id pays
/// the account of that key, which waits as any account that does not exist.
#[test]
fn test_sol9_the_vaults_own_id_is_no_recipient() {
    let mut h = H::ready();
    h.fund(100 * XLM);
    let before = h.balance(&h.vault);
    let native = h.xlm.to_payload().unwrap();
    let xdr_native = match native {
        soroban_sdk::address_payload::AddressPayload::ContractIdHash(id) => id.to_array(),
        _ => unreachable!(),
    };
    for key in [VAULT_ID, xdr_native] {
        let p = h.burn_payload(XLM, &key);
        h.deliver(&p, By::Both);
        let (index, id) = (b20(&h.env, &h.index), b32(&h.env, &C.keccak256(&[&p])));
        let owed = h.v().owed(&index, &id).unwrap();
        assert_eq!((owed.recipient.to_array(), owed.remaining), (key, XLM));
        assert_ne!(account_of(&h.env, &key), h.vault);
    }
    assert_eq!(h.balance(&h.vault), before);
    assert_eq!(h.config().held, 100 * XLM);
}

/// The floor lets a small balance out whole.
#[test]
fn the_floor_lets_a_small_balance_out() {
    let mut h = H::ready();
    h.fund(XLM / 2);
    let bob_key = key_of("bob");
    create_account(&h.env, &bob_key, 0);
    let p = h.burn_payload(XLM / 2, &bob_key);
    h.deliver(&p, By::Both);
    assert_eq!(h.balance(&account_of(&h.env, &bob_key)), (XLM / 2) as i128);
}

#[test]
fn burn_refusals() {
    let mut h = H::ready();
    h.fund(10 * XLM);
    let body = [[1u8; 32], u256(XLM), key_of("bob")].concat();
    let p = h.payload(BURN, h.index, &body);
    err(h.try_deliver(&p, By::Both), VaultError::NotNative);
    let p = h.burn_payload(0, &key_of("bob"));
    err(h.try_deliver(&p, By::Both), VaultError::ZeroAmount);
    let p = h.burn_payload(XLM, &[0u8; 32]);
    err(h.try_deliver(&p, By::Both), VaultError::ZeroAddress);
    let body = [[0u8; 32], [0xff; 32], key_of("bob")].concat();
    let p = h.payload(BURN, h.index, &body);
    err(h.try_deliver(&p, By::Both), VaultError::Overflow);
}

// ---------------------------------------------------------------------
// refunds
// ---------------------------------------------------------------------

/// A failed intake's depositors take their XLM back, each once, and never while frozen.
#[test]
fn a_failed_intake_refunds_its_depositors() {
    let mut h = H::ready();
    let env = h.env.clone();
    let alice = funded(&env, "alice");
    let id = h.intake(h.now() + 3600);
    let (index, intake) = (b20(&env, &h.index), b32(&env, &id));
    h.v().deposit(&alice, &index, &intake, &(3 * XLM as i128));
    assert_eq!(
        h.v().try_refund(&alice, &index, &intake),
        Err(Ok(code(VaultError::IntakeNotOpen)))
    );
    let p = h.payload(INTAKE_FAILED, h.index, &id);
    h.deliver(&p, By::Both);
    let before = h.balance(&alice);
    h.v().refund(&alice, &index, &intake);
    assert_eq!(h.balance(&alice) - before, 3 * XLM as i128);
    assert_eq!(h.config().held, 0);
    assert_eq!(
        h.v().try_refund(&alice, &index, &intake),
        Err(Ok(code(VaultError::NothingToRefund)))
    );
    // A settled intake cannot fail later, nor a failed one settle.
    let q = h.payload(INTAKE_SETTLED, h.index, &id);
    err(h.try_deliver(&q, By::Both), VaultError::IntakeNotOpen);
}

// ---------------------------------------------------------------------
// migration
// ---------------------------------------------------------------------

/// A migration moves XLM from the old index's balance to the new one's, within the speed limit, and never out of the
/// vault: `held` stays.
#[test]
fn a_migration_moves_xlm_between_versions() {
    let mut h = H::ready();
    h.fund(1_000 * XLM);
    let new = h.register(2);
    let body = [address_word(&new), [0u8; 32], u256(100 * XLM)].concat();
    let p = h.payload(MIGRATE, h.index, &body);
    h.deliver(&p, By::Both);
    assert_eq!(h.index_state(&new).balance, 40 * XLM);
    assert_eq!(h.index_state(&h.index).balance, 960 * XLM);
    assert_eq!(h.config().held, 1_000 * XLM);
    h.warp(DAY + 3600);
    h.fresh();
    let id = b32(&h.env, &C.keccak256(&[&p]));
    h.v().release_migration(&b20(&h.env, &h.index), &id);
    assert!(h.index_state(&new).balance > 40 * XLM);
    // Into an index not registered, or itself: refused.
    let (unregistered, _) = h.index_of(7);
    let body = [address_word(&unregistered), [0u8; 32], u256(XLM)].concat();
    let p = h.payload(MIGRATE, h.index, &body);
    err(h.try_deliver(&p, By::Both), VaultError::NotAnIndex);
    let body = [address_word(&h.index), [0u8; 32], u256(XLM)].concat();
    let p = h.payload(MIGRATE, h.index, &body);
    err(h.try_deliver(&p, By::Both), VaultError::NotAnIndex);
}

// ---------------------------------------------------------------------
// governance
// ---------------------------------------------------------------------

fn cap_body(cap: u64, floor: u64) -> std::vec::Vec<u8> {
    [[0u8; 32], u256(cap), u256(floor)].concat()
}

/// A cap update raising neither figure applies at once on one proof; a raise needs both, then waits GOVERNANCE_DELAY
/// on the vault (VLT-2), applied by anyone after it, cancelled by the freezer before it.
#[test]
fn caps_lower_at_once_and_raise_after_a_week() {
    let mut h = H::ready();
    let p = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 2, FLOOR));
    h.deliver(&p, By::P1);
    assert_eq!(h.config().cap, CAP / 2);
    let raise = cap_body(CAP, FLOOR * 2);
    let p = h.payload(CAP_UPDATE, FACTORY, &raise);
    err(h.try_deliver(&p, By::P2), VaultError::BothProofsRequired);
    h.deliver(&p, By::Both);
    assert_eq!(h.config().cap, CAP / 2);
    let body = bytes(&h.env, &raise);
    assert_eq!(
        h.v().try_apply_change(&(CAP_UPDATE as u32), &body),
        Err(Ok(code(VaultError::ChangeNotReady)))
    );
    h.warp(GOVERNANCE_DELAY as u64);
    h.v().apply_change(&(CAP_UPDATE as u32), &body);
    assert_eq!((h.config().cap, h.config().outflow_floor), (CAP, FLOOR * 2));
    // The freezer drops a waiting raise.
    let p = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP * 2, FLOOR * 2));
    h.deliver(&p, By::Both);
    h.v().cancel_change(&(CAP_UPDATE as u32));
    assert_eq!(
        h.v().try_apply_change(
            &(CAP_UPDATE as u32),
            &bytes(&h.env, &cap_body(CAP * 2, FLOOR * 2))
        ),
        Err(Ok(code(VaultError::NoPendingChange)))
    );
}

/// VLT-4 and the twin of SOL-3: a governance message older than the last of its kind taken on both proofs never runs,
/// so an older cap update delivered late cannot undo a newer one; and only a message on both proofs moves the mark,
/// so one broken proof system cannot lock the factory out with a forged nonce.
#[test]
fn test_vlt4_only_both_proofs_move_the_nonce() {
    let mut h = H::ready();
    let older = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 4, FLOOR));
    let newer = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 2, FLOOR));
    h.deliver(&newer, By::Both);
    err(h.try_deliver(&older, By::Both), VaultError::StaleGovernance);
    assert_eq!(h.config().cap_nonce, 2);
    // A forged lowering on one proof under a huge nonce lowers the cap, as a protective message may, but leaves the
    // mark where it was.
    let forged = payload_with(CAP_UPDATE, FACTORY, 1_000_000, &cap_body(CAP / 8, FLOOR));
    h.deliver(&forged, By::P1);
    assert_eq!(h.config().cap, CAP / 8);
    assert_eq!(h.config().cap_nonce, 2);
    // So the factory's next message still runs: a raise from the forged cap, which waits its week.
    let body = cap_body(CAP / 3, FLOOR);
    let next = h.payload(CAP_UPDATE, FACTORY, &body);
    h.deliver(&next, By::Both);
    assert_eq!(h.config().cap_nonce, 3);
    h.warp(GOVERNANCE_DELAY as u64);
    h.v()
        .apply_change(&(CAP_UPDATE as u32), &bytes(&h.env, &body));
    assert_eq!(h.config().cap, CAP / 3);
}

/// VLT-2: a new freezer waits a week too, and the freezer cannot cancel its own replacement; a freeze holds every
/// waiting change but that one.
#[test]
fn test_vlt2_the_freezers_replacement_cannot_be_held() {
    let mut h = H::ready();
    let new_key = key_of("new freezer");
    let body = new_key.to_vec();
    let p = h.payload(FREEZER_CHANGE, FACTORY, &body);
    h.deliver(&p, By::Both);
    assert_eq!(
        h.v().try_cancel_change(&(FREEZER_CHANGE as u32)),
        Err(Ok(code(VaultError::NotFreezer)))
    );
    h.v().freeze();
    h.warp(GOVERNANCE_DELAY as u64);
    h.v()
        .apply_change(&(FREEZER_CHANGE as u32), &bytes(&h.env, &body));
    assert_eq!(h.config().freezer, account_of(&h.env, &new_key));
    // A raise waits out a freeze: the new freezer freezes again just as the raise comes due.
    let raise = bytes(&h.env, &cap_body(CAP * 2, FLOOR));
    h.fresh();
    let q = h.payload(CAP_UPDATE, FACTORY, &raise.to_alloc_vec());
    h.deliver(&q, By::Both);
    h.warp(GOVERNANCE_DELAY as u64);
    h.v().freeze();
    assert!(h.now() < h.config().frozen_until);
    assert_eq!(
        h.v().try_apply_change(&(CAP_UPDATE as u32), &raise),
        Err(Ok(code(VaultError::VaultFrozen)))
    );
    h.set_time(h.config().frozen_until);
    h.fresh();
    h.v().apply_change(&(CAP_UPDATE as u32), &raise);
    assert_eq!(h.config().cap, CAP * 2);
}

/// The twin of SOL-3: an older freezer change delivered after a newer one never runs, so it cannot undo it.
#[test]
fn test_sol3_an_older_freezer_change_cannot_undo_a_newer_one() {
    let mut h = H::ready();
    let older = h.payload(FREEZER_CHANGE, FACTORY, &key_of("older"));
    let newer = h.payload(FREEZER_CHANGE, FACTORY, &key_of("newer"));
    h.deliver(&newer, By::Both);
    err(h.try_deliver(&older, By::Both), VaultError::StaleGovernance);
    h.warp(GOVERNANCE_DELAY as u64);
    let newer_body = bytes(&h.env, &key_of("newer"));
    h.v().apply_change(&(FREEZER_CHANGE as u32), &newer_body);
    assert_eq!(h.config().freezer, account_of(&h.env, &key_of("newer")));
}

/// Each power answers to its holder's signature alone: the depositor's for a deposit and a refund, the freezer's for a
/// freeze and a cancel; and without one, each is refused by the host.
#[test]
fn each_power_needs_its_holders_signature() {
    let mut h = H::ready();
    let signers = |h: &H| {
        h.env
            .auths()
            .iter()
            .map(|(a, _)| a.clone())
            .collect::<std::vec::Vec<_>>()
    };
    let from = funded(&h.env, "depositor");
    let id = h.intake(h.now() + 3600);
    let (index, intake) = (b20(&h.env, &h.index), b32(&h.env, &id));
    h.v().deposit(&from, &index, &intake, &(XLM as i128));
    assert_eq!(signers(&h), std::slice::from_ref(&from));
    let fail = h.payload(INTAKE_FAILED, h.index, &id);
    h.deliver(&fail, By::Both);
    h.v().refund(&from, &index, &intake);
    assert_eq!(signers(&h), std::slice::from_ref(&from));
    let p = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP * 2, FLOOR));
    h.deliver(&p, By::Both);
    h.v().cancel_change(&(CAP_UPDATE as u32));
    assert_eq!(signers(&h), std::slice::from_ref(&h.freezer));
    h.v().freeze();
    assert_eq!(signers(&h), std::slice::from_ref(&h.freezer));

    let mut h = H::ready();
    let from = funded(&h.env, "depositor");
    h.env.set_auths(&[]);
    let id = h.intake(h.now() + 3600);
    let (index, intake) = (b20(&h.env, &h.index), b32(&h.env, &id));
    assert!(unsigned(|| h.v().deposit(
        &from,
        &index,
        &intake,
        &(XLM as i128)
    )));
    let p = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP * 2, FLOOR));
    h.deliver(&p, By::Both);
    assert!(unsigned(|| h.v().cancel_change(&(CAP_UPDATE as u32))));
    assert!(unsigned(|| h.v().freeze()));
}

/// Whether `f` fails for want of a signature: the host's own refusal, not the vault's.
fn unsigned(f: impl FnOnce()) -> bool {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Err(e) => e
            .downcast_ref::<std::string::String>()
            .is_some_and(|m| m.starts_with("HostError: Error(Auth, InvalidAction)")),
        Ok(()) => false,
    }
}

/// A freeze runs on one proof, stops deposits and payouts for 14 days, and a later freeze extends it.
#[test]
fn a_freeze_stops_payouts() {
    let mut h = H::ready();
    h.fund(100 * XLM);
    let p = h.payload(FREEZE, FACTORY, &[]);
    h.deliver(&p, By::P2);
    let until = h.config().frozen_until;
    assert_eq!(until, h.now() + FREEZE_DURATION as u64);
    let bob_key = key_of("bob");
    create_account(&h.env, &bob_key, 0);
    let q = h.burn_payload(XLM, &bob_key);
    h.deliver(&q, By::Both);
    assert_eq!(h.balance(&account_of(&h.env, &bob_key)), 0);
    h.set_time(until);
    h.fresh();
    let id = b32(&h.env, &C.keccak256(&[&q]));
    h.v().release(&b20(&h.env, &h.index), &id);
    assert_eq!(h.balance(&account_of(&h.env, &bob_key)), XLM as i128);
}

/// A rotation names two verifier contracts, waits a week, and pins their code when it applies.
#[test]
fn a_rotation_pins_the_new_verifiers() {
    let mut h = H::ready();
    let n1 = h.env.register(MockVerifier, (false,));
    let n2 = h.env.register(MockVerifier, (false,));
    let id = |a: &Address| match a.to_payload().unwrap() {
        soroban_sdk::address_payload::AddressPayload::ContractIdHash(x) => x.to_array(),
        _ => panic!(),
    };
    let body = [id(&n1), id(&n2)].concat();
    let p = h.payload(VERIFIER_ROTATION, FACTORY, &body);
    h.deliver(&p, By::Both);
    h.warp(GOVERNANCE_DELAY as u64);
    h.v()
        .apply_change(&(VERIFIER_ROTATION as u32), &bytes(&h.env, &body));
    assert_eq!(h.config().p1.address, n1);
    assert_eq!(h.config().p2.address, n2);
    // One verifier twice is refused.
    let same = [id(&n1), id(&n1)].concat();
    h.fresh();
    let q = h.payload(VERIFIER_ROTATION, FACTORY, &same);
    h.deliver(&q, By::Both);
    h.warp(GOVERNANCE_DELAY as u64);
    assert_eq!(
        h.v()
            .try_apply_change(&(VERIFIER_ROTATION as u32), &bytes(&h.env, &same)),
        Err(Ok(code(VaultError::VerifiersNotDistinct)))
    );
}

// ---------------------------------------------------------------------
// attest
// ---------------------------------------------------------------------

/// `attest` succeeds only if each slot holds its value, an absent one zero, and emits exactly one event, topics
/// `[Symbol("attest")]` and data the `Bytes` of `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`, checked
/// byte for byte against Solidity's encoder (the vector below is `cast abi-encode`'s, `tests/fixtures/attest.json`).
#[test]
fn attest_emits_the_record_byte_for_byte() {
    let mut h = H::ready();
    let id = h.fund(100 * XLM);
    let env = h.env.clone();
    let index_key = xindex_vault::vault::index_slot(&env, &h.index);
    let intake_key = xindex_vault::vault::intake_slot(&env, &h.index, &id);
    let absent = [0x5au8; 32];
    let slots = [index_key, intake_key, absent];
    let values = [
        h.v().index_digest(&b20(&env, &h.index)).to_array(),
        h.v()
            .intake_digest(&b20(&env, &h.index), &b32(&env, &id))
            .to_array(),
        [0u8; 32],
    ];
    h.v().attest(&vec32(&env, &slots), &vec32(&env, &values));
    let events = env.events().all();
    let last = events.events().last().unwrap().clone();
    let record = env.as_contract(&h.vault, || {
        xindex_vault::attest_record(&env, CHAIN_ID, &vec32(&env, &slots), &vec32(&env, &values))
    });
    let expected = Attest {
        record: record.clone(),
    }
    .to_xdr(&env, &h.vault);
    assert_eq!(last, expected);
    // The event's own XDR: one topic, the symbol "attest"; data, the record's bytes.
    let xdr::ContractEventBody::V0(body) = &last.body;
    assert_eq!(body.topics.len(), 1);
    assert_eq!(
        body.topics[0],
        xdr::ScVal::Symbol("attest".try_into().unwrap())
    );
    let data: Bytes = Bytes::from_slice(&env, &record.to_alloc_vec());
    assert_eq!(
        body.data,
        xdr::ScVal::Bytes(data.to_alloc_vec().try_into().unwrap())
    );
    // Solidity's encoding of the same, built independently here as `abi.encode` lays it out.
    let mut sol = std::vec::Vec::new();
    for w in [
        xindex_vault::ATTEST_DOMAIN,
        u256(CHAIN_ID),
        VAULT_ID,
        u256(160),
        u256(160 + 32 * 4),
        u256(3),
    ] {
        sol.extend_from_slice(&w);
    }
    slots.iter().for_each(|s| sol.extend_from_slice(s));
    sol.extend_from_slice(&u256(3));
    values.iter().for_each(|v| sol.extend_from_slice(v));
    assert_eq!(record.to_alloc_vec(), sol);
    let fixture = json("stellar/contracts/xindex-vault/tests/fixtures/attest.json");
    let vector = hex(fixture["record"].as_str().unwrap());
    let vslots: std::vec::Vec<[u8; 32]> = fixture["slots"]
        .as_array()
        .unwrap()
        .iter()
        .map(h32)
        .collect();
    let vvalues: std::vec::Vec<[u8; 32]> = fixture["values"]
        .as_array()
        .unwrap()
        .iter()
        .map(h32)
        .collect();
    let from_vault = env.as_contract(&h.vault, || {
        xindex_vault::attest_record(
            &env,
            fixture["chain_id"].as_u64().unwrap(),
            &vec32(&env, &vslots),
            &vec32(&env, &vvalues),
        )
    });
    assert_eq!(
        from_vault.to_alloc_vec(),
        vector,
        "the record is Solidity's abi.encode"
    );
    let _ = Symbol::new(&env, "attest");
    let _: soroban_sdk::Val = record.into_val(&env);
}

/// A slot that does not hold its value, or slots and values that differ in number, attest nothing.
#[test]
fn attest_refuses_what_the_vault_does_not_hold() {
    let mut h = H::ready();
    let id = h.fund(100 * XLM);
    let env = h.env.clone();
    let intake_key = xindex_vault::vault::intake_slot(&env, &h.index, &id);
    let wrong = [1u8; 32];
    assert_eq!(
        h.v()
            .try_attest(&vec32(&env, &[intake_key]), &vec32(&env, &[wrong])),
        Err(Ok(code(VaultError::NotAttested)))
    );
    assert_eq!(
        h.v()
            .try_attest(&vec32(&env, &[intake_key]), &vec32(&env, &[])),
        Err(Ok(code(VaultError::NotAttested)))
    );
}

/// The slot keys the hub computes (`HybridHubStorage._provenIntake`, `reportOutflow`, `recordExit`), checked against
/// `cast`'s (`tests/fixtures/attest.json`).
#[test]
fn the_slot_keys_are_the_hubs() {
    let h = H::deployed();
    let fixture = json("stellar/contracts/xindex-vault/tests/fixtures/attest.json");
    let index = h20(&fixture["index"]);
    let intake = h32(&fixture["intake_id"]);
    assert_eq!(
        xindex_vault::vault::index_slot(&h.env, &index),
        h32(&fixture["index_slot"])
    );
    assert_eq!(
        xindex_vault::vault::intake_slot(&h.env, &index, &intake),
        h32(&fixture["intake_slot"])
    );
    assert_eq!(xindex_vault::vault::snapshot_slot(), u256(25));
}

// ---------------------------------------------------------------------
// costs
// ---------------------------------------------------------------------

/// What the vault's own calls cost, with mock verifiers whose checks are a keccak: a deposit, a burn on both proofs, a
/// release, a checkpoint and an `attest` of three slots, each far inside Stellar's 400M instructions. With the real P1
/// and P2, a delivery adds each verifier's `verify_event` (`tests/verifiers.rs`).
#[test]
fn the_vaults_calls_fit_stellars_limits() {
    let mut h = H::ready();
    let env = h.env.clone();
    let mut costs = std::vec::Vec::new();
    let from = funded(&env, "depositor");
    let id = h.intake(h.now() + 3600);
    let (index, intake) = (b20(&env, &h.index), b32(&env, &id));
    h.v()
        .deposit(&from, &index, &intake, &(1_000 * XLM as i128));
    costs.push(("deposit", instructions(&env)));
    let settle = h.payload(INTAKE_SETTLED, h.index, &id);
    h.deliver(&settle, By::Both);
    costs.push(("deliver INTAKE_SETTLED", instructions(&env)));
    let bob_key = key_of("bob");
    create_account(&env, &bob_key, 0);
    let p = h.burn_payload(100 * XLM, &bob_key);
    h.deliver(&p, By::Both);
    costs.push(("deliver BURN, paid in part", instructions(&env)));
    h.warp(DAY + 3600);
    h.fresh();
    costs.push(("advance_checkpoint", instructions(&env)));
    h.v().release(&index, &b32(&env, &C.keccak256(&[&p])));
    costs.push(("release", instructions(&env)));
    let slots = [
        xindex_vault::vault::index_slot(&env, &h.index),
        xindex_vault::vault::intake_slot(&env, &h.index, &id),
        xindex_vault::vault::index_slot(&env, &[9; 20]),
    ];
    let values = [
        h.v().index_digest(&index).to_array(),
        h.v().intake_digest(&index, &intake).to_array(),
        [0u8; 32],
    ];
    h.v().attest(&vec32(&env, &slots), &vec32(&env, &values));
    costs.push(("attest, 3 slots", instructions(&env)));
    for (call, n) in costs {
        println!("vault: {call}, {n} instructions");
        assert!(n < MAX_INSTRUCTIONS / 10);
    }
}
