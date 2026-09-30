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
    h.send(&[ix], &[&authority]).expect_error("Custom(2007)"); // ConstraintExecutable

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
    let vault_address = vault::vault_address(&h.config);
    assert_eq!(
        s.digest,
        abi::index_digest(CHAIN_ID, &vault_address, &index, false, 0, 0)
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
    let vault_address = vault::vault_address(&h.config);
    assert_eq!(
        i.digest,
        abi::intake_digest(
            CHAIN_ID,
            &vault_address,
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
    h.deliver_governance(lower, By::Both, None).expect_ok();
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
    let vault_address = vault::vault_address(&h.config);
    assert_eq!(
        s.digest,
        abi::index_digest(CHAIN_ID, &vault_address, &index, true, 10 * SOL, 0)
    );
    let i = h.intake(&index, &intake);
    assert_eq!(i.state, INTAKE_SETTLED_STATE);
    assert_eq!(
        i.digest,
        abi::intake_digest(CHAIN_ID, &vault_address, &index, &intake, 2, true, 10 * SOL)
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
    let vault_address = vault::vault_address(&h.config);
    let s = h.index(&index);
    assert_eq!(
        s.digest,
        abi::index_digest(
            CHAIN_ID,
            &vault_address,
            &index,
            true,
            s.balance,
            s.paid_total
        )
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
    let vault_address = vault::vault_address(&h.config);
    let n = h.index(&next);
    assert_eq!(
        n.digest,
        abi::index_digest(CHAIN_ID, &vault_address, &next, true, n.balance, 0)
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
    h.deliver_governance(raise.clone(), By::P1, None)
        .expect_code(VaultError::BothProofsRequired);
    h.deliver_governance(raise, By::Both, None).expect_ok();
    assert_eq!(h.config().cap, CAP + 1);
    let lower = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP, FLOOR / 2));
    h.deliver_governance(lower, By::P2, None).expect_ok();
    assert_eq!((h.config().cap, h.config().outflow_floor), (CAP, FLOOR / 2));
    let floor = h.payload(CAP_UPDATE, FACTORY, &cap_body(CAP, FLOOR));
    h.deliver_governance(floor, By::P1, None)
        .expect_code(VaultError::BothProofsRequired);
}

#[test]
fn only_the_factory_governs() {
    let (mut h, index) = Harness::ready();
    // An index's FREEZE: its emitter is not the factory.
    let p = h.payload(FREEZE, index, &[]);
    h.deliver_governance(p, By::Both, None)
        .expect_code(VaultError::WrongEmitter);
    // An index's kind from the factory, on the governance instruction.
    let p = h.payload(BURN, FACTORY, &burn_body(SOL, &Pubkey::new_unique()));
    h.deliver_governance(p, By::Both, None)
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
    h.deliver_governance(p, By::P2, None).expect_ok();
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
    h.deliver_governance(p.clone(), By::P1, None)
        .expect_code(VaultError::BothProofsRequired);
    h.deliver_governance(p, By::Both, None).expect_ok();
    assert_eq!(h.config().freezer, next.pubkey());
    let p = h.payload(FREEZER_CHANGE, FACTORY, &[0u8; 32]);
    h.deliver_governance(p, By::Both, None)
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
    let p = h.payload(VERIFIER_ROTATION, FACTORY, &body);
    h.deliver_governance(p, By::Both, Some((n1, n1)))
        .expect_code(VaultError::VerifiersNotDistinct);
    let body = [n1.to_bytes(), h.relayer1.pubkey().to_bytes()].concat();
    let p = h.payload(VERIFIER_ROTATION, FACTORY, &body);
    let not_a_program = h.relayer1.pubkey();
    h.deliver_governance(p, By::Both, Some((n1, not_a_program)))
        .expect_code(VaultError::NotAContract);
    let body = [n1.to_bytes(), n2.to_bytes()].concat();
    let p = h.payload(VERIFIER_ROTATION, FACTORY, &body);
    h.deliver_governance(p, By::Both, Some((n1, n2)))
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
