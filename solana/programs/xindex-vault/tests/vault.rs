//! The Solana vault against the EVM vault's rules (Stage B spec, sections 4 and 7), in LiteSVM with the stub verifier as
//! P1 and P2: initialization, registration, deposits, messages, burns within the speed limit, refunds, migration,
//! governance and the freeze, and the digests Ethereum proves.

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex_vault::{abi, constants::*, error::VaultError, vault};

// ---------------------------------------------------------------------
// initialization and registration
// ---------------------------------------------------------------------

#[test]
fn only_the_deployer_initializes_once() {
    let mut h = Harness::new();
    let stranger = Keypair::new();
    h.svm.airdrop(&stranger.pubkey(), 10 * SOL).unwrap();
    let ix = h.initialize_ix(&stranger.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&stranger])
        .expect_code(VaultError::NotDeployer);

    let authority = h.authority.insecure_clone();
    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p1);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::VerifiersNotDistinct);
    let mut args = h.init_args();
    args.factory = [0u8; 20];
    let ix = h.initialize_ix(&authority.pubkey(), args, h.p1, h.p2);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::ZeroAddress);
    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, authority.pubkey());
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::NotAContract);

    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_ok();
    let c = h.config();
    assert_eq!(
        (
            c.source_chain_id,
            c.chain_id,
            c.factory,
            c.hub_implementation
        ),
        (SOURCE_CHAIN_ID, CHAIN_ID, FACTORY, HUB)
    );
    assert_eq!((c.p1, c.p2, c.freezer), (h.p1, h.p2, h.freezer.pubkey()));
    assert_eq!(
        (c.cap, c.outflow_floor, c.held, c.frozen_until),
        (CAP, FLOOR, 0, 0)
    );
    assert_eq!(
        h.treasury_balance(),
        0,
        "the treasury holds its rent reserve only"
    );

    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_error("Custom(0)");
}

/// An index is legitimate when its address is the factory's CREATE2 clone of the hub template under some salt.
#[test]
fn only_the_factorys_clones_register() {
    let (mut h, index) = Harness::ready();
    let s = h.index(&index);
    assert_eq!(s.index, index);
    let vault_id = vault::vault_id(&h.config);
    assert_eq!(
        s.digest,
        abi::index_digest(CHAIN_ID, &vault_id, &index, false, 0, 0)
    );
    h.register(index, [1u8; 32]).expect_ok(); // again: nothing changes
    let (other, _) = index_of(2);
    h.register(other, [3u8; 32])
        .expect_code(VaultError::NotAnIndex);
}

// ---------------------------------------------------------------------
// deposits
// ---------------------------------------------------------------------

#[test]
fn a_deposit_opens_an_intake_within_its_rules() {
    let (mut h, index) = Harness::ready();
    let alice = Keypair::new();
    h.svm.airdrop(&alice.pubkey(), 100 * SOL).unwrap();
    let intake = intake_id(h.now() + 3600, 1);
    h.deposit(&alice, index, intake, 0)
        .expect_code(VaultError::ZeroAmount);
    h.deposit(&alice, index, intake, 3 * SOL).expect_ok();
    h.deposit(&alice, index, intake, 2 * SOL).expect_ok();
    let i = h.intake(&index, &intake);
    assert_eq!(
        (i.state, i.total, i.has_native),
        (INTAKE_OPEN, 5 * SOL, true)
    );
    let vault_id = vault::vault_id(&h.config);
    assert_eq!(
        i.digest,
        abi::intake_digest(
            CHAIN_ID,
            &vault_id,
            &index,
            &intake,
            INTAKE_OPEN,
            true,
            5 * SOL
        )
    );
    assert_eq!(h.config().held, 5 * SOL);
    assert_eq!(h.treasury_balance(), 5 * SOL);

    let far = intake_id(h.now() + 7 * 24 * 3600 + 1, 2);
    h.deposit(&alice, index, far, SOL)
        .expect_code(VaultError::IntakeTooLong);
    h.deposit(&alice, index, intake_id(h.now() + 7 * 24 * 3600, 3), SOL)
        .expect_ok();
    h.warp(3601);
    h.deposit(&alice, index, intake, SOL)
        .expect_code(VaultError::IntakeClosed);
    let (unregistered, _) = index_of(9);
    // An unregistered index has no state account: AccountNotInitialized.
    h.deposit(&alice, unregistered, intake_id(h.now() + 60, 4), SOL)
        .expect_error("Custom(3012)");
}

#[test]
fn deposits_stay_within_the_cap() {
    let (mut h, index) = Harness::ready();
    let lower = h.payload(CAP_UPDATE, FACTORY, &cap_body(100 * SOL, FLOOR));
    h.deliver_governance(lower, By::Both).expect_ok();
    let whale = Keypair::new();
    h.svm.airdrop(&whale.pubkey(), 200 * SOL).unwrap();
    let intake = intake_id(h.now() + 3600, 1);
    h.deposit(&whale, index, intake, 100 * SOL).expect_ok();
    h.deposit(&whale, index, intake, 1)
        .expect_code(VaultError::CapExceeded);
}

// ---------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------

#[test]
fn a_settled_intake_joins_the_index_once() {
    let (mut h, index) = Harness::ready();
    let intake = h.fund(index, 10 * SOL);
    let s = h.index(&index);
    assert_eq!((s.balance, s.has_native), (10 * SOL, true));
    let vault_id = vault::vault_id(&h.config);
    assert_eq!(
        s.digest,
        abi::index_digest(CHAIN_ID, &vault_id, &index, true, 10 * SOL, 0)
    );
    let i = h.intake(&index, &intake);
    assert_eq!(i.state, INTAKE_SETTLED_STATE);
    assert_eq!(
        i.digest,
        abi::intake_digest(CHAIN_ID, &vault_id, &index, &intake, 2, true, 10 * SOL)
    );
    // Settled for good: another settle or a fail of it is refused.
    h.deliver_intake(index, intake, INTAKE_FAILED, By::Both)
        .expect_code(VaultError::IntakeNotOpen);
}

#[test]
fn a_message_runs_once() {
    let (mut h, index) = Harness::ready();
    let intake = intake_id(h.now() + 3600, 1);
    let payload = h.payload(INTAKE_SETTLED, index, &intake);
    h.deliver_intake_payload(index, intake, payload.clone(), By::Both)
        .expect_ok();
    h.deliver_intake_payload(index, intake, payload, By::Both)
        .expect_error("Custom(0)");
}

#[test]
fn coin_moving_messages_need_both_proofs() {
    let (mut h, index) = Harness::ready();
    let intake = intake_id(h.now() + 3600, 1);
    for by in [By::P1, By::P2] {
        h.deliver_intake(index, intake, INTAKE_SETTLED, by)
            .expect_code(VaultError::BothProofsRequired);
    }
    let bob = Pubkey::new_unique();
    let p = h.payload(BURN, index, &burn_body(SOL, &bob));
    h.deliver_burn(index, p, bob, By::P1)
        .expect_code(VaultError::BothProofsRequired);
}

#[test]
fn the_stub_accepts_only_its_relayers_signature() {
    let (mut h, index) = Harness::ready();
    let intake = intake_id(h.now() + 3600, 1);
    // The relayers swapped: each stub refuses the other's key.
    std::mem::swap(&mut h.relayer1, &mut h.relayer2);
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_error("MissingRequiredSignature");
}

/// Only the vault's own P1 and P2 count: a program an attacker deployed, verifying on its own key, is refused in either
/// place.
#[test]
fn the_verifiers_must_be_p1_and_p2() {
    let (mut h, index) = Harness::ready();
    let stub = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../target/deploy/stub_verifier.so"
    ));
    let rogue = Pubkey::new_unique();
    h.svm.add_program(rogue, stub).unwrap();
    let rogue_relayer = Keypair::new();
    h.svm.airdrop(&rogue_relayer.pubkey(), SOL).unwrap();
    h.init_stub(rogue, &rogue_relayer.pubkey()).expect_ok();
    let intake = intake_id(h.now() + 3600, 1);

    let (p1, relayer1) = (h.p1, h.relayer1.insecure_clone());
    h.p1 = rogue;
    h.relayer1 = rogue_relayer.insecure_clone();
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_code(VaultError::WrongVerifier);
    (h.p1, h.relayer1) = (p1, relayer1);

    let (p2, relayer2) = (h.p2, h.relayer2.insecure_clone());
    h.p2 = rogue;
    h.relayer2 = rogue_relayer;
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_code(VaultError::WrongVerifier);
    (h.p2, h.relayer2) = (p2, relayer2);
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_ok();
}

#[test]
fn the_route_and_the_emitter_must_be_this_vaults() {
    let (mut h, index) = Harness::ready();
    let intake = intake_id(h.now() + 3600, 1);
    let good = h.payload(INTAKE_SETTLED, index, &intake);

    // Another destination chain.
    let mut other_chain = good.clone();
    other_chain[3 * 32 + 31] ^= 1;
    h.deliver_intake_payload(index, intake, other_chain, By::Both)
        .expect_code(VaultError::WrongRoute);
    // Another source chain.
    let mut other_source = good.clone();
    other_source[32 + 31] ^= 1;
    h.deliver_intake_payload(index, intake, other_source, By::Both)
        .expect_code(VaultError::WrongRoute);
    // Another vault.
    let mut other_vault = good.clone();
    other_vault[4 * 32] ^= 1;
    h.deliver_intake_payload(index, intake, other_vault, By::Both)
        .expect_code(VaultError::WrongRoute);
    // A governance kind on an index's instruction (its empty body names intake zero).
    let p = h.payload(FREEZE, index, &[]);
    h.deliver_intake_payload(index, [0u8; 32], p, By::Both)
        .expect_code(VaultError::UnknownKind);
    // Kind zero, and one past the last.
    for kind in [0u8, 9] {
        let p = h.payload(kind, index, &intake);
        h.deliver_intake_payload(index, intake, p, By::Both)
            .expect_code(VaultError::UnknownKind);
    }
    h.deliver_intake_payload(index, intake, good, By::Both)
        .expect_ok();
}

#[test]
fn a_message_is_known_by_its_hash() {
    let (mut h, index) = Harness::ready();
    let intake = intake_id(h.now() + 3600, 1);
    let payload = h.payload(INTAKE_SETTLED, index, &intake);
    // A used mark anywhere but where the payload's hash derives: ConstraintSeeds.
    h.deliver_intake_with_id(index, intake, payload.clone(), [7u8; 32], By::Both)
        .expect_error("Custom(2006)");
    // A payload with a trailing byte is not the canonical encoding of any message.
    let mut longer = payload;
    longer.push(0);
    h.deliver_intake_payload(index, intake, longer, By::Both)
        .expect_code(VaultError::BadMessage);
}

// ---------------------------------------------------------------------
// burns and the speed limit
// ---------------------------------------------------------------------

/// A burn pays what 4% of the balance allows now, and owes the rest until the window moves on.
#[test]
fn a_burn_pays_within_the_speed_limit_and_owes_the_rest() {
    let (mut h, index) = Harness::ready();
    h.fund(index, 100 * SOL);
    let bob = Keypair::new().pubkey();
    h.svm.airdrop(&bob, SOL).unwrap();
    let p = h.payload(BURN, index, &burn_body(10 * SOL, &bob));
    let id = abi::keccak(&[&p]);
    h.deliver_burn(index, p, bob, By::Both).expect_ok();
    assert_eq!(h.lamports(&bob), SOL + 4 * SOL, "4% of the 100 today");
    let o = h.owed(&index, &id);
    assert_eq!(
        (o.remaining, o.to_index, o.recipient),
        (6 * SOL, false, bob)
    );
    let s = h.index(&index);
    assert_eq!((s.balance, s.paid_total), (96 * SOL, 4 * SOL));
    assert_eq!(h.config().held, 96 * SOL);

    h.release(index, id, bob)
        .expect_code(VaultError::NothingPayable);
    h.warp(24 * 3600);
    h.release(index, id, bob)
        .expect_code(VaultError::NothingPayable); // the 25th hour still counts
    h.warp(3600);
    h.release(index, id, bob).expect_ok();
    assert_eq!(
        h.lamports(&bob),
        SOL + 4 * SOL + 3_840_000_000,
        "4% of the 96 left"
    );
    let vault_id = vault::vault_id(&h.config);
    let s = h.index(&index);
    assert_eq!(
        s.digest,
        abi::index_digest(CHAIN_ID, &vault_id, &index, true, s.balance, s.paid_total)
    );
    assert_eq!(h.config().held, s.balance);
    assert_eq!(
        h.treasury_balance(),
        s.balance,
        "the treasury holds exactly what it accounts for"
    );
}

#[test]
fn a_burn_never_pays_more_than_the_balance_and_the_floor_lets_the_last_coins_out() {
    let (mut h, index) = Harness::ready();
    h.fund(index, SOL / 2);
    let bob = Keypair::new().pubkey();
    h.svm.airdrop(&bob, SOL).unwrap();
    let p = h.payload(BURN, index, &burn_body(2 * SOL, &bob));
    let id = abi::keccak(&[&p]);
    h.deliver_burn(index, p, bob, By::Both).expect_ok();
    assert_eq!(
        h.lamports(&bob),
        SOL + SOL / 2,
        "all of it, within the 1 SOL floor"
    );
    assert_eq!(h.owed(&index, &id).remaining, 2 * SOL - SOL / 2);
    assert_eq!(h.index(&index).balance, 0);
}

#[test]
fn a_burn_refusals() {
    let (mut h, index) = Harness::ready();
    h.fund(index, 10 * SOL);
    let bob = Keypair::new().pubkey();
    let p = h.payload(BURN, index, &burn_body(SOL, &bob));
    h.deliver_burn(index, p, Pubkey::new_unique(), By::Both)
        .expect_code(VaultError::WrongRecipient);
    let p = h.payload(BURN, index, &burn_body(0, &bob));
    h.deliver_burn(index, p, bob, By::Both)
        .expect_code(VaultError::ZeroAmount);
    // The zero key is the system program's, which no transaction can pass as writable: a burn to it never runs
    // (ConstraintMut). The hub never sends one: a zero recipient books a claim instead.
    let p = h.payload(BURN, index, &burn_body(SOL, &Pubkey::default()));
    h.deliver_burn(index, p, Pubkey::default(), By::Both)
        .expect_error("Custom(2000)");
    let mut body = burn_body(SOL, &bob);
    body[31] = 1; // an ERC-20, not SOL
    let p = h.payload(BURN, index, &body);
    h.deliver_burn(index, p, bob, By::Both)
        .expect_code(VaultError::NotNative);
    let mut body = burn_body(SOL, &bob);
    body[32 + 23] = 1; // an amount above 64 bits
    let p = h.payload(BURN, index, &body);
    h.deliver_burn(index, p, bob, By::Both)
        .expect_code(VaultError::Overflow);
}

/// A burn fits one Solana transaction, both proofs' accounts and the relayers' signatures included.
#[test]
fn a_burn_fits_a_transaction() {
    let (mut h, index) = Harness::ready();
    let bob = Pubkey::new_unique();
    let p = h.payload(BURN, index, &burn_body(SOL, &bob));
    let id = abi::keccak(&[&p]);
    let data = anchor_lang::InstructionData::data(&xindex_vault::instruction::DeliverBurn {
        payload: p,
        proofs: h.proofs(By::Both),
    });
    let mut metas = anchor_lang::ToAccountMetas::to_account_metas(
        &xindex_vault::accounts::DeliverBurn {
            payer: h.payer.pubkey(),
            config: h.config,
            used: pda(&[USED_SEED, &id]),
            index_state: pda(&[INDEX_SEED, &index]),
            owed: pda(&[OWED_SEED, &index, &id]),
            recipient: bob,
            treasury: h.treasury,
            system_program: anchor_lang::solana_program::system_program::ID,
        },
        None,
    );
    let (verifiers, relayers) = h.verifier_accounts(By::Both);
    metas.extend(verifiers);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: xindex_vault::id(),
        accounts: metas,
        data,
    };
    let payer = h.payer.insecure_clone();
    let size = h.size(&[ix], &[&payer, &relayers[0], &relayers[1]]);
    assert!(size <= 1232, "{size} bytes");
    println!("a burn with both stub proofs: {size} of 1,232 bytes");
}

// ---------------------------------------------------------------------
// intakes failed, refunds
// ---------------------------------------------------------------------

#[test]
fn a_failed_intake_refunds_each_depositor() {
    let (mut h, index) = Harness::ready();
    let (alice, bob) = (Keypair::new(), Keypair::new());
    for k in [&alice, &bob] {
        h.svm.airdrop(&k.pubkey(), 10 * SOL).unwrap();
    }
    let intake = intake_id(h.now() + 3600, 1);
    h.deposit(&alice, index, intake, 3 * SOL).expect_ok();
    h.deposit(&bob, index, intake, 2 * SOL).expect_ok();
    h.refund(&alice, index, intake)
        .expect_code(VaultError::IntakeNotOpen);
    h.deliver_intake(index, intake, INTAKE_FAILED, By::Both)
        .expect_ok();
    let before = h.lamports(&alice.pubkey());
    h.refund(&alice, index, intake).expect_ok();
    assert_eq!(
        h.lamports(&alice.pubkey()) - before,
        3 * SOL - 5000,
        "less the fee alice paid"
    );
    h.refund(&alice, index, intake)
        .expect_code(VaultError::NothingToRefund);
    h.refund(&bob, index, intake).expect_ok();
    let i = h.intake(&index, &intake);
    assert_eq!((i.state, i.total), (INTAKE_FAILED_STATE, 0));
    assert_eq!(h.config().held, 0);
    // A failed intake takes no deposit.
    h.deposit(&alice, index, intake, SOL)
        .expect_code(VaultError::IntakeClosed);
}

// ---------------------------------------------------------------------
// migration
// ---------------------------------------------------------------------

#[test]
fn a_migration_moves_within_the_speed_limit() {
    let (mut h, index) = Harness::ready();
    let (next, salt) = index_of(2);
    h.register(next, salt).expect_ok();
    h.fund(index, 100 * SOL);
    let p = h.payload(MIGRATE, index, &migrate_body(&next, 10 * SOL));
    let id = abi::keccak(&[&p]);
    h.deliver_migrate(index, next, p, By::Both).expect_ok();
    assert_eq!(h.index(&next).balance, 4 * SOL);
    assert_eq!(
        h.index(&index).paid_total,
        4 * SOL,
        "a migration counts as paid out"
    );
    assert_eq!(h.config().held, 100 * SOL, "nothing left the vault");
    let o = h.owed(&index, &id);
    assert_eq!(
        (o.remaining, o.to_index, o.new_index),
        (6 * SOL, true, next)
    );
    h.release_migration(index, id, next)
        .expect_code(VaultError::NothingPayable);
    h.warp(25 * 3600);
    h.release_migration(index, id, next).expect_ok();
    assert_eq!(h.index(&next).balance, 4 * SOL + 3_840_000_000);
    let vault_id = vault::vault_id(&h.config);
    let n = h.index(&next);
    assert_eq!(
        n.digest,
        abi::index_digest(CHAIN_ID, &vault_id, &next, true, n.balance, 0)
    );

    // To itself: the new index's account is the old one's, which the instruction may not take mutably twice
    // (ConstraintDuplicateMutableAccount), before the program's own check of the same.
    let p = h.payload(MIGRATE, index, &migrate_body(&index, SOL));
    h.deliver_migrate(index, index, p, By::Both)
        .expect_error("Custom(2040)");
    let (unregistered, _) = index_of(7);
    let p = h.payload(MIGRATE, index, &migrate_body(&unregistered, SOL));
    h.deliver_migrate(index, unregistered, p, By::Both)
        .expect_error("Custom(3012)"); // AccountNotInitialized
}

// ---------------------------------------------------------------------
// governance and the freeze
// ---------------------------------------------------------------------

#[test]
fn a_cap_raise_needs_both_proofs_and_a_lowering_one() {
    let (mut h, _) = Harness::ready();
    let raise = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP + 1, FLOOR));
    h.deliver_governance(raise.clone(), By::P1)
        .expect_code(VaultError::BothProofsRequired);
    h.deliver_governance(raise, By::Both).expect_ok();
    assert_eq!(h.config().cap, CAP, "a raise waits");
    h.warp(GOVERNANCE_DELAY);
    h.apply_change(CAP_UPDATE, &cap_body(CAP + 1, FLOOR), None)
        .expect_ok();
    assert_eq!(h.config().cap, CAP + 1);
    let lower = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP, FLOOR / 2));
    h.deliver_governance(lower, By::P2).expect_ok();
    assert_eq!((h.config().cap, h.config().outflow_floor), (CAP, FLOOR / 2));
    let floor = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP, FLOOR));
    h.deliver_governance(floor, By::P1)
        .expect_code(VaultError::BothProofsRequired);
}

#[test]
fn only_the_factory_governs() {
    let (mut h, index) = Harness::ready();
    // An index's FREEZE: its emitter is not the factory.
    let p = h.payload(FREEZE, index, &[]);
    h.deliver_governance(p, By::Both)
        .expect_code(VaultError::WrongEmitter);
    // An index's kind from the factory, on the governance instruction.
    let p = h.payload(BURN, FACTORY, &burn_body(SOL, &Pubkey::new_unique()));
    h.deliver_governance(p, By::Both)
        .expect_code(VaultError::UnknownKind);
}

/// A freeze stops deposits, payouts and refunds; accepted burns wait; it ends by itself and never shortens.
#[test]
fn a_freeze_stops_coins_moving_and_expires() {
    let (mut h, index) = Harness::ready();
    h.fund(index, 100 * SOL);
    let stranger = Keypair::new();
    h.freeze(&stranger).expect_code(VaultError::NotFreezer);
    let freezer = h.freezer.insecure_clone();
    h.freeze(&freezer).expect_ok();
    let until = h.now() + FREEZE_DURATION;
    assert_eq!(h.config().frozen_until, until);

    let bob = Keypair::new().pubkey();
    h.svm.airdrop(&bob, SOL).unwrap();
    let p = h.payload(BURN, index, &burn_body(SOL, &bob));
    let id = abi::keccak(&[&p]);
    h.deliver_burn(index, p, bob, By::Both).expect_ok();
    assert_eq!(h.lamports(&bob), SOL, "accepted, not paid");
    h.release(index, id, bob)
        .expect_code(VaultError::NothingPayable);
    let alice = Keypair::new();
    h.svm.airdrop(&alice.pubkey(), 10 * SOL).unwrap();
    h.deposit(&alice, index, intake_id(h.now() + 60, 99), SOL)
        .expect_code(VaultError::VaultFrozen);

    // The factory's FREEZE rests on either proof, and never shortens a freeze.
    h.warp(24 * 3600);
    let p = h.payload(FREEZE, FACTORY, &[]);
    h.deliver_governance(p, By::P2).expect_ok();
    assert_eq!(h.config().frozen_until, h.now() + FREEZE_DURATION);
    let later = h.config().frozen_until;
    h.set_time(later);
    h.release(index, id, bob).expect_ok();
    assert_eq!(h.lamports(&bob), 2 * SOL, "paid once the freeze ended");
}

#[test]
fn the_freezer_and_the_verifiers_rotate_on_both_proofs() {
    let (mut h, index) = Harness::ready();
    let next = Keypair::new();
    let p = h.payload(FREEZER_CHANGE, FACTORY, &next.pubkey().to_bytes());
    h.deliver_governance(p, By::P1)
        .expect_code(VaultError::BothProofsRequired);
    h.govern(FREEZER_CHANGE, &next.pubkey().to_bytes(), None)
        .expect_ok();
    assert_eq!(h.config().freezer, next.pubkey());
    h.govern(FREEZER_CHANGE, &[0u8; 32], None)
        .expect_code(VaultError::ZeroAddress);

    // New stubs, under new relayers.
    let stub = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../target/deploy/stub_verifier.so"
    ));
    let (n1, n2) = (Pubkey::new_unique(), Pubkey::new_unique());
    h.svm.add_program(n1, stub).unwrap();
    h.svm.add_program(n2, stub).unwrap();
    let (r1, r2) = (Keypair::new(), Keypair::new());
    h.init_stub(n1, &r1.pubkey()).expect_ok();
    h.init_stub(n2, &r2.pubkey()).expect_ok();
    let body = [n1.to_bytes(), n1.to_bytes()].concat();
    h.govern(VERIFIER_ROTATION, &body, Some((n1, n1)))
        .expect_code(VaultError::VerifiersNotDistinct);
    let not_a_program = h.relayer1.pubkey();
    let body = [n1.to_bytes(), not_a_program.to_bytes()].concat();
    h.govern(VERIFIER_ROTATION, &body, Some((n1, not_a_program)))
        .expect_code(VaultError::NotAContract);
    let body = [n1.to_bytes(), n2.to_bytes()].concat();
    h.govern(VERIFIER_ROTATION, &body, Some((n1, n2)))
        .expect_ok();
    assert_eq!((h.config().p1, h.config().p2), (n1, n2));

    // The old verifiers are refused now; the new ones, with their relayers, are not.
    let intake = intake_id(h.now() + 3600, 1);
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_code(VaultError::WrongVerifier);
    h.p1 = n1;
    h.p2 = n2;
    h.relayer1 = r1;
    h.relayer2 = r2;
    for k in [&h.relayer1, &h.relayer2] {
        h.svm.airdrop(&k.pubkey(), SOL).unwrap();
    }
    h.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
        .expect_ok();
}

// ---------------------------------------------------------------------
// the internal red team of 30 September (SOL-1 to SOL-9)
// ---------------------------------------------------------------------

fn fresh_stub(h: &mut Harness) -> Pubkey {
    let stub = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../target/deploy/stub_verifier.so"
    ));
    let fresh = Pubkey::new_unique();
    h.svm.add_program(fresh, stub).unwrap();
    fresh
}

/// SOL-1: only a stub's upgrade authority sets its relayer key, so nobody can take it in front of the deployer.
#[test]
fn test_sol1_only_the_deployer_initializes_a_stub() {
    let mut h = Harness::new();
    let fresh = fresh_stub(&mut h);
    let (deployer, attacker) = (Keypair::new(), Keypair::new());
    for k in [&deployer, &attacker] {
        h.svm.airdrop(&k.pubkey(), 10 * SOL).unwrap();
    }
    h.set_upgrade_authority(fresh, Some(deployer.pubkey()));
    h.init_stub_by(fresh, &attacker.pubkey(), &attacker)
        .expect_error("MissingRequiredSignature");
    h.init_stub_by(fresh, &Keypair::new().pubkey(), &deployer)
        .expect_ok();
    h.init_stub_by(fresh, &attacker.pubkey(), &deployer)
        .expect_error("AccountAlreadyInitialized");
}

/// SOL-4: lamports sent to a stub's state address in advance do not block its initialization.
#[test]
fn test_sol4_lamports_at_a_stubs_state_do_not_block_it() {
    let mut h = Harness::new();
    let fresh = fresh_stub(&mut h);
    let state = Pubkey::find_program_address(&[b"verifier"], &fresh).0;
    let rent = h.svm.minimum_balance_for_rent_exemption(0);
    h.svm.airdrop(&state, rent).unwrap();
    h.init_stub(fresh, &Keypair::new().pubkey()).expect_ok();
}

/// SOL-2: a verifier whose code its upgrade authority could rewrite is refused as P1 or P2, at initialization and at a
/// rotation, since it would bypass the 30-day rotation.
#[test]
fn test_sol2_an_upgradeable_verifier_is_refused() {
    let mut h = Harness::new();
    let authority = h.authority.insecure_clone();
    h.set_upgrade_authority(h.p1, Some(Keypair::new().pubkey()));
    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority])
        .expect_code(VaultError::VerifierUpgradeable);
    h.set_upgrade_authority(h.p1, None);
    let ix = h.initialize_ix(&authority.pubkey(), h.init_args(), h.p1, h.p2);
    h.send(&[ix], &[&authority]).expect_ok();
    h.warp(1);
    h.advance(1_000).expect_ok();

    let (n1, n2) = (fresh_stub(&mut h), fresh_stub(&mut h));
    let (r1, r2) = (Keypair::new(), Keypair::new());
    h.init_stub(n1, &r1.pubkey()).expect_ok();
    h.init_stub(n2, &r2.pubkey()).expect_ok();
    h.set_upgrade_authority(n2, Some(Keypair::new().pubkey()));
    let body = [n1.to_bytes(), n2.to_bytes()].concat();
    h.govern(VERIFIER_ROTATION, &body, Some((n1, n2)))
        .expect_code(VaultError::VerifierUpgradeable);
}

/// SOL-3: an older governance message of a kind, delivered after a newer one, is refused; a freeze always runs.
#[test]
fn test_sol3_an_older_freezer_change_cannot_undo_a_newer_one() {
    let (mut h, _) = Harness::ready();
    let (old, new) = (Keypair::new(), Keypair::new());
    let first = h.payload(FREEZER_CHANGE, FACTORY, &old.pubkey().to_bytes());
    let second = h.payload(FREEZER_CHANGE, FACTORY, &new.pubkey().to_bytes());
    h.deliver_governance(second, By::Both).expect_ok();
    h.deliver_governance(first, By::Both)
        .expect_code(VaultError::StaleGovernance);
    h.warp(GOVERNANCE_DELAY);
    h.apply_change(FREEZER_CHANGE, &old.pubkey().to_bytes(), None)
        .expect_code(VaultError::NoPendingChange);
    h.apply_change(FREEZER_CHANGE, &new.pubkey().to_bytes(), None)
        .expect_ok();
    assert_eq!(h.config().freezer, new.pubkey());

    let lower = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 2, FLOOR));
    let raise = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP * 2, FLOOR));
    h.deliver_governance(raise, By::Both).expect_ok();
    h.deliver_governance(lower, By::Both)
        .expect_code(VaultError::StaleGovernance);
    // An older freeze still runs: it only protects.
    let freeze = h.payload(FREEZE, FACTORY, &[]);
    let later = h.payload(FREEZE, FACTORY, &[]);
    h.deliver_governance(later, By::P1).expect_ok();
    h.deliver_governance(freeze, By::P2).expect_ok();
}

/// SOL-5: a payout below rent to an empty account waits as owed instead of failing the delivery; once someone funds the
/// recipient, it is released.
#[test]
fn test_sol5_a_small_burn_to_a_new_account_is_still_delivered() {
    let (mut h, index) = Harness::ready();
    h.fund(index, 10 * SOL);
    let bob = Pubkey::new_unique();
    let small = h.svm.minimum_balance_for_rent_exemption(0) / 2;
    let p = h.payload(BURN, index, &burn_body(small, &bob));
    let id = abi::keccak(&[&p]);
    h.deliver_burn(index, p, bob, By::Both).expect_ok();
    assert_eq!(h.owed(&index, &id).remaining, small);
    h.release(index, id, bob)
        .expect_code(VaultError::NothingPayable);
    h.svm.airdrop(&bob, SOL).unwrap();
    h.release(index, id, bob).expect_ok();
    assert_eq!(h.lamports(&bob), SOL + small);
}

/// SOL-9: a burn cannot name the treasury or one of the vault's own accounts, where its payout would be stranded.
#[test]
fn test_sol9_the_vaults_own_accounts_are_no_recipients() {
    let (mut h, index) = Harness::ready();
    h.fund(index, 10 * SOL);
    let treasury = h.treasury;
    let p = h.payload(BURN, index, &burn_body(SOL, &treasury));
    h.deliver_burn(index, p, treasury, By::Both)
        .expect_code(VaultError::WrongRecipient);
    let index_account = pda(&[INDEX_SEED, &index]);
    let p = h.payload(BURN, index, &burn_body(SOL, &index_account));
    h.deliver_burn(index, p, index_account, By::Both)
        .expect_code(VaultError::WrongRecipient);
}

// ---------------------------------------------------------------------
// the Stage B red team of 30 September, on the EVM vault's twin (VLT-2, VLT-4)
// ---------------------------------------------------------------------

/// VLT-2: a raised cap or floor, a new freezer and new verifiers wait a week on the vault, however their proofs were
/// obtained. The freezer may drop a raise or a rotation, never its own replacement; a freeze holds every change but
/// that one; a newer lowering drops a waiting raise.
#[test]
fn test_vlt2_a_loosening_waits_and_the_freezer_can_stop_it() {
    let (mut h, _) = Harness::ready();
    let raise = cap_body(CAP, 100 * SOL);
    let p = h.payload(CAP_UPDATE, FACTORY, &raise);
    h.deliver_governance(p, By::Both).expect_ok();
    assert_eq!(h.config().outflow_floor, FLOOR, "the floor has not moved");
    assert_eq!(h.config().pending_cap.ready_at, h.now() + GOVERNANCE_DELAY);
    h.apply_change(CAP_UPDATE, &raise, None)
        .expect_code(VaultError::ChangeNotReady);
    let stranger = Keypair::new();
    h.cancel_change(&stranger, CAP_UPDATE)
        .expect_code(VaultError::NotFreezer);
    let freezer = h.freezer.insecure_clone();
    h.cancel_change(&freezer, CAP_UPDATE).expect_ok();
    h.cancel_change(&freezer, CAP_UPDATE)
        .expect_code(VaultError::NoPendingChange);
    h.warp(GOVERNANCE_DELAY);
    h.apply_change(CAP_UPDATE, &raise, None)
        .expect_code(VaultError::NoPendingChange);

    // Sent again, it waits again, and a freeze holds it; the freezer's replacement it neither holds nor may drop.
    let p = h.payload(CAP_UPDATE, FACTORY, &raise);
    h.deliver_governance(p, By::Both).expect_ok();
    let next = Keypair::new();
    let p = h.payload(FREEZER_CHANGE, FACTORY, &next.pubkey().to_bytes());
    h.deliver_governance(p, By::Both).expect_ok();
    h.cancel_change(&freezer, FREEZER_CHANGE)
        .expect_code(VaultError::NotFreezer);
    h.warp(GOVERNANCE_DELAY - 24 * 3600);
    h.freeze(&freezer).expect_ok();
    h.warp(24 * 3600);
    h.apply_change(CAP_UPDATE, &raise, None)
        .expect_code(VaultError::VaultFrozen);
    h.apply_change(FREEZER_CHANGE, &next.pubkey().to_bytes(), None)
        .expect_ok();
    assert_eq!(h.config().freezer, next.pubkey());
    let until = h.config().frozen_until;
    h.set_time(until);
    h.apply_change(CAP_UPDATE, &raise, None).expect_ok();
    assert_eq!(h.config().outflow_floor, 100 * SOL);
    assert_eq!(h.config().pending_cap.ready_at, 0);

    // A newer lowering drops a waiting raise.
    let again = cap_body(CAP, 200 * SOL);
    let p = h.payload(CAP_UPDATE, FACTORY, &again);
    h.deliver_governance(p, By::Both).expect_ok();
    let p = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 2, 50 * SOL));
    h.deliver_governance(p, By::P1).expect_ok();
    h.warp(GOVERNANCE_DELAY);
    h.apply_change(CAP_UPDATE, &again, None)
        .expect_code(VaultError::NoPendingChange);
    assert_eq!(h.config().outflow_floor, 50 * SOL);
}

/// VLT-4: only a message on both proofs moves the mark. One proof, even with a nonce far ahead, may lower the cap but
/// cannot lock the factory's later messages out.
#[test]
fn test_vlt4_one_proof_moves_no_mark() {
    let (mut h, _) = Harness::ready();
    let mark = h.config().cap_nonce;
    let honest = h.nonce;
    h.nonce = u64::MAX - 1;
    let forged = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP / 8, FLOOR));
    h.nonce = honest;
    h.deliver_governance(forged, By::P1).expect_ok();
    assert_eq!(h.config().cap, CAP / 8);
    assert_eq!(h.config().cap_nonce, mark, "one proof moves no mark");
    h.govern(CAP_UPDATE, &cap_body(CAP, FLOOR), None)
        .expect_ok();
    assert_eq!(h.config().cap, CAP, "the factory's next message still runs");
    assert_eq!(h.config().cap_nonce, h.nonce);
}
