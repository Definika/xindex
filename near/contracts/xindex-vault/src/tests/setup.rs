//! Initialization, registration, deposits and refunds, the stall, and `attest`.

use super::*;

/// The constants are the hashes the interfaces doc and the vault's own docs name.
#[test]
fn the_domains_are_their_hashes() {
    at(1, RELAYER, 0);
    assert_eq!(keccak(&[b"xindex.v4.vault-attest"]), ATTEST_DOMAIN);
    assert_eq!(keccak(&[b"xindex.v4.near-verifier"]), VERIFIER_DOMAIN);
}

/// The twin of `DeployVault`'s checks, made on the vault itself: the recovery proposer is a contract account, never an
/// implicit one a single key holds, and not the freezer; P1 and P2 are of two different proof systems; nothing is zero.
#[test]
fn initialization_checks_the_roles_and_the_verifiers() {
    let f = json();
    let now = 1_800_000_000;
    at(now, RELAYER, 0);
    let ok = T::config(&f, now);
    for implicit in [
        "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
        "8a60b13532285ff156d87793f0f288a8a528c68abd5e9c6d6d8422437216db29",
    ] {
        let mut c = ok.clone();
        c.recovery_proposer = implicit.parse().unwrap();
        fails("RecoveryNotMultisig", || Vault::new(c));
    }
    let mut c = ok.clone();
    c.recovery_proposer = c.freezer.clone();
    fails("SameRole", || Vault::new(c));
    let mut c = ok.clone();
    c.p2.system = SP1;
    fails("VerifiersNotDistinct", || Vault::new(c));
    let mut c = ok.clone();
    c.p1.system = 3;
    fails("UnknownSystem", || Vault::new(c));
    let mut c = ok.clone();
    c.p2.key = Hex32::default();
    fails("ZeroAddress", || Vault::new(c));
    let mut c = ok.clone();
    c.factory = Hex20::default();
    fails("ZeroAddress", || Vault::new(c));

    let v = Vault::new(ok.clone());
    let view = v.config();
    assert_eq!(view.vault_id.0, T::vault_id());
    assert_eq!(view.p1.0, verifier_id(&ok.p1));
    assert_eq!(view.p2.0, verifier_id(&ok.p2));
    assert_eq!(view.checkpoint.timestamp, now, "the first week's grace");
    assert_eq!(v.verifier(view.p1).unwrap().key, ok.p1.key);
    assert!(!v.stalled());
}

/// A light client's id is `keccak256(abi.encode(VERIFIER_DOMAIN, system, key, anchor, epoch, genesisTime))`, which the
/// factory computes on Ethereum to name it in a rotation: against `cast abi-encode` and `cast keccak`.
#[test]
fn a_verifier_id_is_its_configurations_hash() {
    at(1, RELAYER, 0);
    let c = verifier_config(RISC_ZERO, 2, 123_456);
    assert_eq!(
        verifier_id(&c),
        h32(&near_sdk::serde_json::json!(
            "0xcf6a6fd6a33753488e2b5e7456c76748258491e517753312a7f3836608e9f8f6"
        ))
    );
}

/// An index is registered once its address is the factory's CREATE2 clone under its salt; its digest and its slot are
/// written then, as the EVM vault refreshes it at registration; a second registration changes nothing.
#[test]
fn an_index_registers_by_create2() {
    let mut t = T::new();
    let index = Hex20(t.index);
    fails("NotAnIndex", || {
        t.call(RELAYER, ONE, |v| v.register_index(index, Hex32([1; 32])))
    });
    let state = t.v.index_state(index).unwrap();
    let digest = xindex_core::abi::index_digest_wide(
        &Near,
        NEAR_TESTNET,
        &T::vault_id(),
        &t.index,
        false,
        0,
        0,
    );
    assert_eq!(state.digest.0, digest);
    assert_eq!(t.v.slot(Hex32(index_slot(&t.index))).0, digest);
    let salt = Hex32(h32(&t.f["salt"]));
    t.call(RELAYER, ONE, |v| v.register_index(index, salt));
}

/// Deposits: only to a registered index, while neither frozen nor stalled, before the intake's deadline and at most
/// MAX_INTAKE_LIFE ahead, within the cap, paying their storage; the intake's digest is the hub's.
#[test]
fn deposits_follow_the_intake_rules() {
    let mut t = T::new();
    let deadline = t.now + 3600;
    let intake = intake_id(deadline, 1);
    let index = Hex20(t.index);
    let other = Hex20([9; 20]);
    fails("NotAnIndex", || {
        t.call(ALICE, 2 * ONE, |v| {
            v.deposit(other, Hex32(intake), U128(ONE))
        })
    });
    fails("ZeroAmount", || {
        t.call(ALICE, ONE, |v| v.deposit(index, Hex32(intake), U128(0)))
    });
    let late = intake_id(t.now - 1, 2);
    fails("IntakeClosed", || {
        t.call(ALICE, 2 * ONE, |v| v.deposit(index, Hex32(late), U128(ONE)))
    });
    let far = intake_id(t.now + MAX_INTAKE_LIFE as u64 + 1, 3);
    fails("IntakeTooLong", || {
        t.call(ALICE, 2 * ONE, |v| v.deposit(index, Hex32(far), U128(ONE)))
    });
    fails("CapExceeded", || {
        t.call(ALICE, 2_000_000 * ONE, |v| {
            v.deposit(index, Hex32(intake), U128(1_000_001 * ONE))
        })
    });
    t.deposit(ALICE, &intake, 25 * ONE);
    t.deposit(ALICE, &intake, 5 * ONE);
    let i = t.v.intake(index, Hex32(intake)).unwrap();
    assert_eq!((i.state, i.total.0), (INTAKE_OPEN, 30 * ONE));
    let digest = xindex_core::abi::intake_digest_wide(
        &Near,
        NEAR_TESTNET,
        &T::vault_id(),
        &t.index,
        &intake,
        INTAKE_OPEN,
        true,
        30 * ONE,
    );
    assert_eq!(i.digest.0, digest);
    assert_eq!(t.v.slot(Hex32(intake_slot(&t.index, &intake))).0, digest);
    assert_eq!(
        t.v.deposited(index, Hex32(intake), ALICE.parse().unwrap())
            .0,
        30 * ONE
    );
    assert_eq!(t.v.config().held.0, 30 * ONE);
    // What the call attached beyond the deposit and its storage goes back to the caller.
    t.deposit(ALICE, &intake, ONE);
    let back = transfers();
    assert_eq!(back.len(), 1);
    assert_eq!(back[0].0.as_str(), ALICE);
    assert!(back[0].1 > ONE / 2 && back[0].1 <= ONE);

    // A deposit into a new intake that attaches the deposit alone pays none of the storage it adds. The check comes
    // last in the call, after it wrote, and the mocked runtime keeps what a failed call wrote, so it comes last here.
    let fresh = Hex32(intake_id(t.now + 3600, 9));
    fails("StorageNotPaid", || {
        t.call(ALICE, ONE, |v| v.deposit(index, fresh, U128(ONE)))
    });

    t.warp(3601);
    fails("IntakeClosed", || {
        t.call(ALICE, 2 * ONE, |v| {
            v.deposit(index, Hex32(intake), U128(ONE))
        })
    });
}

/// A week without a checkpoint stalls the vault: it takes no deposit it might never settle or refund, until anyone
/// brings a new checkpoint.
#[test]
fn test_stall_a_week_without_a_checkpoint() {
    let mut t = T::new();
    t.warp(STALL_PERIOD as u64);
    assert!(!t.stalled());
    t.warp(1);
    assert!(t.stalled());
    let index = Hex20(t.index);
    let intake = Hex32(intake_id(t.now + 3600, 1));
    fails("VaultStalled", || {
        t.call(ALICE, 2 * ONE, |v| v.deposit(index, intake, U128(ONE)))
    });
    t.advance(5_000);
    assert!(!t.stalled());
    t.call(ALICE, 2 * ONE, |v| v.deposit(index, intake, U128(ONE)));
}

/// A failed intake's depositor takes its deposit back, once, not while frozen.
#[test]
fn a_failed_intakes_deposit_is_refunded() {
    let mut t = T::new();
    let intake = intake_id(t.now + 3600, 1);
    let (index, id) = (Hex20(t.index), Hex32(intake));
    t.deposit(ALICE, &intake, 3 * ONE);
    fails("IntakeNotOpen", || {
        t.call(ALICE, 0, |v| v.refund(index, id))
    });
    t.deliver(INTAKE_FAILED, &intake);
    fails("NothingToRefund", || {
        t.call(RELAYER, 0, |v| v.refund(index, id))
    });
    t.call(ALICE, 0, |v| v.refund(index, id));
    assert_eq!(transfers(), vec![(ALICE.parse().unwrap(), 3 * ONE)]);
    assert_eq!(t.v.config().held.0, 0);
    assert_eq!(t.v.intake(index, id).unwrap().total.0, 0);
    fails("NothingToRefund", || {
        t.call(ALICE, 0, |v| v.refund(index, id))
    });
}

/// `attest` succeeds only on the values the vault holds, and its record is `abi.encode(ATTEST_DOMAIN, chainId, vaultId,
/// height, timestampNs, slots, values)` byte for byte, against
/// `cast abi-encode "f(bytes32,uint256,bytes32,uint64,uint64,bytes32[],bytes32[])"`. The sandbox test checks that a run
/// states its own block.
#[test]
fn attest_vouches_only_for_what_the_vault_holds() {
    let mut t = T::new();
    let slot = Hex32(index_slot(&t.index));
    let held = t.v.slot(slot);
    t.call(RELAYER, 0, |v| v.attest(vec![slot], vec![held]));
    fails("NotAttested", || {
        t.call(RELAYER, 0, |v| v.attest(vec![slot], vec![Hex32([1; 32])]))
    });
    fails("NotAttested", || {
        t.call(RELAYER, 0, |v| v.attest(vec![slot], vec![]))
    });
    // An absent slot holds zero.
    t.call(RELAYER, 0, |v| {
        v.attest(vec![Hex32([5; 32])], vec![Hex32::default()])
    });

    let record = attest_record(
        NEAR_TESTNET,
        &h32(&near_sdk::serde_json::json!(
            "0x4eaa69495e9ee6c1516bfbfa5af14200ef184119216685e332487ce645d51daf"
        )),
        123_456_789,
        1_759_500_000_123_456_789,
        &[[0x11; 32], [0x22; 32]],
        &[[0x33; 32], [0x44; 32]],
    );
    assert_eq!(record, hex(ATTEST_VECTOR));
}

/// `cast abi-encode "f(bytes32,uint256,bytes32,uint64,uint64,bytes32[],bytes32[])" ATTEST_DOMAIN 4078699518750379172
/// keccak("vault.test.near") 123456789 1759500000123456789 "[0x11..,0x22..]" "[0x33..,0x44..]"`.
pub const ATTEST_VECTOR: &str = "0xb0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c000000000000000000000000000000000000000000000000389a739a38ac4ca44eaa69495e9ee6c1516bfbfa5af14200ef184119216685e332487ce645d51daf00000000000000000000000000000000000000000000000000000000075bcd15000000000000000000000000000000000000000000000000186affed89a88d1500000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000000211111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000233333333333333333333333333333333333333333333333333333333333333334444444444444444444444444444444444444444444444444444444444444444";

/// B2-02: initialization refuses what `DeployVault` refuses: a floor above the cap, which would leave the speed limit
/// never binding, and Ethereum's own chain as the vault's, under which no message could route. A deterministic account
/// has no later chance to fix either.
#[test]
fn test_b202_initialization_refuses_what_deploy_vault_refuses() {
    let f = json();
    let now = 1_800_000_000;
    at(now, RELAYER, 0);
    let ok = T::config(&f, now);
    let mut c = ok.clone();
    c.native_floor = U128(c.native_cap.0 + 1);
    fails("FloorAboveCap", || Vault::new(c));
    let mut c = ok.clone();
    c.chain_id = c.source_chain_id;
    fails("WrongRoute", || Vault::new(c));
    let mut c = ok.clone();
    c.native_floor = c.native_cap;
    Vault::new(c);
}

/// B2-08: the `config` view and `new`'s settings name the chain ids as strings. NEAR's registry ids pass 2^53, which a
/// JavaScript number cannot hold exactly: read as one, testnet's id became another, and a client building a holder's
/// snapshot claim from it signed for the wrong chain.
#[test]
fn test_b208_the_chain_ids_are_strings_in_json() {
    let f = json();
    let now = 1_800_000_000;
    at(now, RELAYER, 0);
    let config = T::config(&f, now);
    let json = near_sdk::serde_json::to_value(&config).unwrap();
    assert_eq!(json["chain_id"], "4078699518750379172");
    assert_eq!(json["source_chain_id"], "11155111");
    let back: InitConfig = near_sdk::serde_json::from_value(json).unwrap();
    assert_eq!(back.chain_id.0, NEAR_TESTNET);
    let view = near_sdk::serde_json::to_value(Vault::new(config).config()).unwrap();
    assert_eq!(view["chain_id"], "4078699518750379172");
    assert_eq!(view["source_chain_id"], "11155111");
    // Past what a JavaScript number holds: read as one, it is another id.
    assert_ne!(NEAR_TESTNET as f64 as u64, NEAR_TESTNET);
}

/// B2-09: a recovery proposer of nearcore's universal account family (`0u…`) is refused as an implicit one is: its keys
/// are its state init's, which a contract cannot read, so it may be one key's.
#[test]
fn test_b209_a_universal_account_is_no_recovery_proposer() {
    let f = json();
    let now = 1_800_000_000;
    at(now, RELAYER, 0);
    let mut c = T::config(&f, now);
    c.recovery_proposer = "0u7e5f4552091a69125d5dfcb7b8c2659029395bdf"
        .parse()
        .unwrap();
    assert!(is_implicit(&c.recovery_proposer));
    fails("RecoveryNotMultisig", || Vault::new(c));
    for named in ["recovery.test.near", "u0.near", "multisig.0u.near"] {
        assert!(!is_implicit(&named.parse().unwrap()), "{named}");
    }
}

/// B1-04: no deposit before the first checkpoint. No message could settle or fail such an intake, since every one
/// needs a checkpoint covering its block, and no successor or snapshot could follow without one: its NEAR would stay
/// for good.
#[test]
fn test_b104_no_deposit_before_the_first_checkpoint() {
    let mut t = T::bare();
    let index = Hex20(t.index);
    let intake = Hex32(intake_id(t.now + 3600, 1));
    fails("NoCheckpoint", || {
        t.call(ALICE, 2 * ONE, |v| v.deposit(index, intake, U128(ONE)))
    });
    assert_eq!(t.v.config().held.0, 0);
    t.advance(1_000);
    t.deposit(ALICE, &intake.0, ONE);
    assert_eq!(t.v.config().held.0, ONE);
}
