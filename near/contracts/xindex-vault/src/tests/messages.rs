//! Messages from Ethereum: their proofs, route and emitter; the checkpoint they wait for (VLT-3); burns under the speed
//! limit, to implicit recipients, never to the vault itself (SOL-9); migrations; and payouts that come back.

use near_sdk::PromiseResult;
use near_sdk::{test_vm_config, RuntimeFeesConfig};

use super::*;

/// A message runs only on a log P1 or P2 proves in a block a recorded proof covered, of the index it names, routed to
/// this chain and this vault, once. One proof never moves coins.
#[test]
fn a_message_needs_its_proofs_its_route_and_one_delivery() {
    let mut t = T::new();
    let index = t.index;
    let intake = intake_id(t.now + 3600, 1);
    let settle = t.payload(INTAKE_SETTLED, &index, &intake);
    let block = t.next_block();

    fails("NoProof", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(Base64VecU8(settle.clone()), block, None, None)
        })
    });
    // On one proof only: it would move coins.
    let proof = Base64VecU8(t.event_proof(&index, &settle, block));
    fails("BothProofsRequired", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                Some(proof.clone()),
                None,
            )
        })
    });
    fails("BothProofsRequired", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                None,
                Some(proof.clone()),
            )
        })
    });
    // A proof of another payload's log is not this log's.
    let other = t.payload(INTAKE_SETTLED, &index, &intake);
    let other_proof = Base64VecU8(t.event_proof(&index, &other, block));
    fails("NotTheLog", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                Some(other_proof.clone()),
                Some(other_proof.clone()),
            )
        })
    });
    // A log in a block no proof recorded.
    let unrecorded = {
        let mut p = proof.0.clone();
        p[0] ^= 1;
        Base64VecU8(p)
    };
    fails("UnknownHeaders", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                Some(unrecorded.clone()),
                Some(proof.clone()),
            )
        })
    });
    // Routed elsewhere, from another emitter, of an unknown kind, or from an index not registered here.
    let wrong_dest = T::payload_with(INTAKE_SETTLED, &index, &intake, 50, NEAR_TESTNET + 1);
    let p = Base64VecU8(t.event_proof(&index, &wrong_dest, block));
    fails("WrongRoute", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(wrong_dest.clone()),
                block,
                Some(p.clone()),
                Some(p.clone()),
            )
        })
    });
    let freeze_from_index = t.payload(FREEZE, &index, &[]);
    let p = Base64VecU8(t.event_proof(&index, &freeze_from_index, block));
    fails("WrongEmitter", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(freeze_from_index.clone()),
                block,
                Some(p.clone()),
                Some(p.clone()),
            )
        })
    });
    let unknown = t.payload(9, &index, &intake);
    let p = Base64VecU8(t.event_proof(&index, &unknown, block));
    fails("UnknownKind", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(unknown.clone()),
                block,
                Some(p.clone()),
                Some(p.clone()),
            )
        })
    });
    let stranger = [0x77; 20];
    let from_stranger = t.payload(INTAKE_SETTLED, &stranger, &intake);
    let p = Base64VecU8(t.event_proof(&stranger, &from_stranger, block));
    fails("NotAnIndex", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(from_stranger.clone()),
                block,
                Some(p.clone()),
                Some(p.clone()),
            )
        })
    });

    t.call(RELAYER, ONE, |v| {
        v.deliver(
            Base64VecU8(settle.clone()),
            block,
            Some(proof.clone()),
            Some(proof.clone()),
        )
    });
    let id = keccak(&[&settle]);
    assert!(t.v.used(Hex32(id)));
    assert_eq!(t.v.config().last_message.0, id);
    fails("AlreadyDelivered", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                Some(proof.clone()),
                Some(proof.clone()),
            )
        })
    });
}

/// A message claimed in a real receipt: P1's proof walks block 26,092,387's real receipts trie
/// (`test/fixtures/ethereum/receipts.json`) to each case's receipt through the chain's keccak, a one-byte key, a
/// two-byte key and a legacy receipt, and finds its log is not the message. The sandbox runs the same on Wasm.
#[test]
fn a_real_receipt_holds_no_message_of_ours() {
    let mut t = T::new();
    let real: near_sdk::serde_json::Value = near_sdk::serde_json::from_str(
        &crate::fixtures::repo_file("test/fixtures/ethereum/receipts.json"),
    )
    .unwrap();
    let number = real["number"].as_u64().unwrap();
    t.advance(number + 10);
    let (head, root, range) = five_blocks(
        number,
        real["timestamp"].as_u64().unwrap(),
        &h32(&real["stateRoot"]),
        &h32(&real["receiptsRoot"]),
    );
    let (p1, p2) = (t.v.p1, t.v.p2);
    t.v.ranges.insert((p1, root), range);
    t.v.ranges.insert((p2, root), range);
    let index = t.index;
    let burn = t.payload(BURN, &index, &burn_body(ONE, &[0x42; 32]));
    for case in real["cases"].as_array().unwrap() {
        let nodes: Vec<Vec<u8>> = case["proof"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| hex(n.as_str().unwrap()))
            .collect();
        let tx = case["txIndex"].as_u64().unwrap();
        let proof = Base64VecU8(
            [
                head.clone(),
                receipt_part(&nodes, tx, case["logIndex"].as_u64().unwrap()),
            ]
            .concat(),
        );
        fails("NotTheLog", || {
            t.call(RELAYER, ONE, |v| {
                v.deliver(
                    Base64VecU8(burn.clone()),
                    number,
                    Some(proof.clone()),
                    Some(proof.clone()),
                )
            })
        });
    }
}

/// VLT-3: a message that moves coins runs only from a block the vault's checkpoint covers, so the snapshot, which is the
/// last checkpoint, never pays a holder whose burn the vault also paid. Once the checkpoint covers the block, it runs.
#[test]
fn test_vlt3_a_message_after_the_checkpoint_waits_for_it() {
    let mut t = T::new();
    t.advance(1_000);
    let index = t.index;
    let intake = intake_id(t.now + 3600, 1);
    t.deposit(ALICE, &intake, 4 * ONE);
    let settle = t.payload(INTAKE_SETTLED, &index, &intake);
    let block = 1_001;
    let proof = Base64VecU8(t.event_proof(&index, &settle, block));
    fails("NotCheckpointed", || {
        t.call(RELAYER, ONE, |v| {
            v.deliver(
                Base64VecU8(settle.clone()),
                block,
                Some(proof.clone()),
                Some(proof.clone()),
            )
        })
    });
    t.advance(1_001);
    t.call(RELAYER, ONE, |v| {
        v.deliver(
            Base64VecU8(settle.clone()),
            block,
            Some(proof.clone()),
            Some(proof.clone()),
        )
    });
    assert_eq!(t.balance(), 4 * ONE);
}

/// A burn pays its recipient what the speed limit allows now, 4% of the index's balance in any 24 hours, and owes the
/// rest, which anyone releases as the limit allows; a frozen vault pays nothing, and an explicit release that can pay
/// nothing fails. Amounts past 2^64 yocto, and an implicit recipient, which the transfer creates.
#[test]
fn a_burn_pays_within_the_speed_limit_and_owes_the_rest() {
    let mut t = T::new();
    t.fund(1_000 * ONE);
    let recipient = keccak(&[b"burn recipient"]);
    let to: AccountId = crate::fixtures::hex_str(&recipient).parse().unwrap();
    let burn = t.deliver(BURN, &burn_body(100 * ONE, &recipient));
    assert_eq!(
        transfers(),
        vec![(to.clone(), 40 * ONE)],
        "4% of 1,000 NEAR"
    );
    let id = Hex32(keccak(&[&burn]));
    let index = Hex20(t.index);
    assert_eq!(t.v.owed(index, id).unwrap().remaining.0, 60 * ONE);
    assert_eq!(t.balance(), 960 * ONE);
    assert_eq!(t.v.config().held.0, 960 * ONE);
    fails("NothingPayable", || {
        t.call(RELAYER, 0, |v| v.release(index, id))
    });
    t.warp(25 * 3600);
    t.call(RELAYER, 0, |v| v.release(index, id));
    assert_eq!(
        transfers(),
        vec![(to.clone(), 960 * ONE / 25)],
        "4% of what is left"
    );
    let state = t.v.index_state(index).unwrap();
    assert_eq!(state.paid_total.0, 40 * ONE + 960 * ONE / 25);
    // The index's digest carries the 128-bit amounts.
    assert_eq!(
        state.digest.0,
        xindex_core::abi::index_digest_wide(
            &Near,
            NEAR_TESTNET,
            &T::vault_id(),
            &t.index,
            true,
            state.balance.0,
            state.paid_total.0
        )
    );
    // Frozen: nothing is paid, and an explicit release fails.
    t.call(FREEZER, 0, |v| v.freeze());
    t.warp(25 * 3600);
    fails("NothingPayable", || {
        t.call(RELAYER, 0, |v| v.release(index, id))
    });
    t.warp(14 * 24 * 3600);
    t.call(RELAYER, 0, |v| v.release(index, id));
    assert_eq!(transfers().len(), 1);
}

/// A recipient whose top 12 bytes are zero is the ETH-implicit account of its low 20 bytes (NEP-518); a zero one is
/// refused; a burn of something other than NEAR is refused.
#[test]
fn burn_recipients_are_implicit_accounts() {
    let mut t = T::new();
    t.fund(100 * ONE);
    let mut eth = [0u8; 32];
    eth[12..].copy_from_slice(&hex("7E5F4552091A69125d5DfCb7b8C2659029395Bdf"));
    t.deliver(BURN, &burn_body(ONE, &eth));
    assert_eq!(
        transfers(),
        vec![(
            "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
                .parse()
                .unwrap(),
            ONE
        )]
    );
    let index = t.index;
    let zero = t.payload(BURN, &index, &burn_body(ONE, &[0u8; 32]));
    fails("ZeroAddress", || t.deliver_by(&index, &zero, true, true));
    let mut not_native = burn_body(ONE, &eth);
    not_native[31] = 1;
    let other = t.payload(BURN, &index, &not_native);
    fails("NotNative", || t.deliver_by(&index, &other, true, true));
}

/// SOL-9's NEAR twin: a burn to the vault's own account would strand the payout. Only an implicit account can be a
/// recipient, so the case arises only for a vault at an implicit account: one is set up here, and its own key refused.
#[test]
fn test_sol9_the_vault_is_no_recipient() {
    let own = [0x5a; 32];
    let account = crate::fixtures::hex_str(&own);
    let mut t = T::new();
    t.fund(100 * ONE);
    // The same vault, run as if it lived at the implicit account of `own`: every message's route names that account's id.
    let index = t.index;
    let body = burn_body(ONE, &own);
    let vault_id = keccak(&[account.as_bytes()]);
    let mut payload = t.payload(BURN, &index, &body);
    payload[4 * 32..5 * 32].copy_from_slice(&vault_id);
    let block = t.next_block();
    let proof = Base64VecU8(t.event_proof(&index, &payload, block));
    testing_env!(VMContextBuilder::new()
        .current_account_id(account.parse().unwrap())
        .predecessor_account_id(RELAYER.parse().unwrap())
        .block_timestamp(t.now * 1_000_000_000)
        .attached_deposit(NearToken::from_yoctonear(ONE))
        .prepaid_gas(Gas::from_tgas(1000))
        .build());
    fails("WrongRecipient", || {
        t.v.deliver(
            Base64VecU8(payload.clone()),
            block,
            Some(proof.clone()),
            Some(proof.clone()),
        )
    });
}

/// A migration moves coins two versions share from the old index's balance into the new one's, within the speed limit;
/// the coins never leave the vault, so `held` stays. Only to another registered index.
#[test]
fn a_migration_moves_coins_between_indexes_within_the_limit() {
    let mut t = T::new();
    t.fund(500 * ONE);
    let v2 = h20(&t.f["migrate"]["new_index"]);
    let v2_salt = Hex32(h32(&t.f["migrate"]["new_salt"]));
    let body = |to: &[u8; 20], amount: u128| {
        [&address_word(to)[..], &[0u8; 32], &u256_wide(amount)].concat()
    };
    let index = t.index;
    let unregistered = t.payload(MIGRATE, &index, &body(&v2, 10 * ONE));
    fails("NotAnIndex", || {
        t.deliver_by(&index, &unregistered, true, true)
    });
    t.call(RELAYER, ONE, |v| v.register_index(Hex20(v2), v2_salt));
    let to_itself = t.payload(MIGRATE, &index, &body(&index, 10 * ONE));
    fails("NotAnIndex", || {
        t.deliver_by(&index, &to_itself, true, true)
    });
    t.deliver(MIGRATE, &body(&v2, 50 * ONE));
    assert!(transfers().is_empty(), "nothing leaves the vault");
    assert_eq!(t.balance(), 480 * ONE, "4% of 500");
    assert_eq!(t.v.index_state(Hex20(v2)).unwrap().balance.0, 20 * ONE);
    assert_eq!(t.v.config().held.0, 500 * ONE);
}

/// A payout's transfer that fails puts its amount back: owed again, in the index's balance and in `held`, as the EVM
/// vault's burn to a refusing recipient stays owed. That only the vault itself runs the callback, the Wasm entry point
/// checks (`#[private]`), which the sandbox tests exercise.
#[test]
fn a_payout_that_fails_is_owed_again() {
    let mut t = T::new();
    t.fund(1_000 * ONE);
    let recipient = keccak(&[b"burn recipient"]);
    let burn = t.deliver(BURN, &burn_body(100 * ONE, &recipient));
    let (index, id) = (Hex20(t.index), Hex32(keccak(&[&burn])));
    let paid = 40 * ONE;
    let context = VMContextBuilder::new()
        .current_account_id(VAULT.parse().unwrap())
        .predecessor_account_id(VAULT.parse().unwrap())
        .block_timestamp(t.now * 1_000_000_000)
        .build();
    testing_env!(
        context.clone(),
        test_vm_config(),
        RuntimeFeesConfig::test(),
        Default::default(),
        vec![PromiseResult::Successful(vec![])]
    );
    t.v.on_payout(index, id, U128(paid));
    assert_eq!(
        t.v.owed(index, id).unwrap().remaining.0,
        60 * ONE,
        "a payout that arrived stays paid"
    );
    testing_env!(
        context,
        test_vm_config(),
        RuntimeFeesConfig::test(),
        Default::default(),
        vec![PromiseResult::Failed]
    );
    t.v.on_payout(index, id, U128(paid));
    assert_eq!(t.v.owed(index, id).unwrap().remaining.0, 100 * ONE);
    assert_eq!(t.balance(), 1_000 * ONE);
    assert_eq!(t.v.index_state(index).unwrap().paid_total.0, 0);
    assert_eq!(t.v.config().held.0, 1_000 * ONE);
    assert_eq!(events(), vec!["payout_returned"]);
}
