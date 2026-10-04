//! The snapshot exit (Stage B spec, section 5.6; design 6.9, layer 4), after `begin_snapshot`: every read of the hub's
//! storage is under the snapshot's state root, proven with `eth_getProof`'s nodes (`xindex_core::state_reader`), the
//! proof inline, since a Soroban transaction holds 132 KB. Holders at the snapshot claim their share directly, within
//! the speed limit; an intake still open is settled or failed from the hub's mark of the settle message it sent; a burn
//! or migration the hub marked sent is paid as a delivered one would be.
//!
//! What Stellar changes from the EVM vault, as Solana's vault does: the chain is named by the registry's id; a recovery
//! address is a whole 32-byte key, so only zero counts as none; and a signed claim names a 32-byte recipient, under a
//! domain whose salt is the vault's 32-byte id.

use soroban_sdk::{Bytes, BytesN, Env};
use xindex_core::constants::*;
use xindex_core::snapshot::{self, SnapshotError};
use xindex_core::state_reader;
use xindex_soroban::Soroban;

use crate::error::VaultError;
use crate::events::*;
use crate::messages;
use crate::types::*;
use crate::vault::{self, fail, require};

fn snapshot_err(env: &Env, e: SnapshotError) -> ! {
    match e {
        SnapshotError::BadStateProof => fail(env, VaultError::BadStateProof),
        SnapshotError::WrongComponent => fail(env, VaultError::WrongComponent),
        SnapshotError::Overflow => fail(env, VaultError::Overflow),
        SnapshotError::ZeroAmount => fail(env, VaultError::ZeroAmount),
        SnapshotError::BadSignature => fail(env, VaultError::BadSignature),
    }
}

/// Slots of `index`'s storage at the snapshot.
fn read_hub(
    env: &Env,
    cfg: &Config,
    index: &[u8; 20],
    slots: &[[u8; 32]],
    proof: &Bytes,
) -> alloc::vec::Vec<[u8; 32]> {
    let root = vault::snapshot_root(env, cfg);
    state_reader::read_slots(&Soroban(env), &root, index, slots, &proof.to_alloc_vec())
        .unwrap_or_else(|_| fail(env, VaultError::BadStateProof))
}

/// Anyone, after the snapshot: pays `holder`'s share of XLM in `index` at the snapshot, read from the hub's storage
/// there (`snapshot::share`), to the account `recipient`: the recovery key the holder registered in the hub for this
/// chain, if any, which a contract holder must register; otherwise the recipient it signed for with its Ethereum key
/// (EIP-712). Paid within the speed limit, as any payout: a snapshot of a forged checkpoint takes no more than a forged
/// burn. One claim per holder and index.
pub fn claim_snapshot(
    env: &Env,
    index: &BytesN<20>,
    holder: &BytesN<20>,
    component: u64,
    recipient: &BytesN<32>,
    signature: &Bytes,
    proof: &Bytes,
) {
    let mut cfg = vault::config(env);
    require(env, vault::is_index(env, index), VaultError::NotAnIndex);
    require(
        env,
        *recipient != vault::zero32(env),
        VaultError::ZeroAddress,
    );
    let c = Soroban(env);
    let (index_a, holder_a) = (index.to_array(), holder.to_array());
    let id = BytesN::from_array(env, &snapshot::claim_id(&c, &index_a, &holder_a));
    let key = DataKey::Owed(index.clone(), id.clone());
    require(
        env,
        !env.storage().persistent().has(&key),
        VaultError::AlreadyClaimed,
    );
    let slots = snapshot::claim_slots(&c, &holder_a, component, cfg.chain_id);
    let values = read_hub(env, &cfg, &index_a, &slots, proof);
    let (amount, registered) = snapshot::share(&c, &values, component, cfg.chain_id)
        .unwrap_or_else(|e| snapshot_err(env, e));
    match registered {
        // A holder that registered a recovery key, such as a contract, is paid there and nowhere else.
        Some(key) => require(env, recipient.to_array() == key, VaultError::WrongRecipient),
        None => {
            // Under Ethereum's chain id, where the holder's wallet is (B1-06).
            let digest = snapshot::claim_digest(
                &c,
                &vault::vault_id(env),
                cfg.source_chain_id,
                &index_a,
                &holder_a,
                &recipient.to_array(),
            );
            snapshot::check_signature(&c, &digest, &signature.to_alloc_vec(), &holder_a)
                .unwrap_or_else(|e| snapshot_err(env, e));
        }
    }
    let mut owed = Owed {
        to_index: false,
        recipient: recipient.clone(),
        new_index: BytesN::from_array(env, &[0u8; 20]),
        remaining: amount,
    };
    SnapshotClaimed {
        index: index.clone(),
        holder: holder.clone(),
        recipient: recipient.clone(),
        amount,
        id: id.clone(),
    }
    .publish(env);
    messages::pay_recipient(env, &mut cfg, index, &id, &mut owed, false);
    vault::set_config(env, &cfg);
}

/// Anyone, after the snapshot: settles an intake still open if the hub had sent its settle message by the snapshot, and
/// otherwise fails it, so its depositors take their coins back. The hub marks an intake settled in the transaction that
/// sends its settle message (`_settledIntakes`), so its mark at the snapshot says whether that message was sent by then:
/// nothing sent later will ever run here.
pub fn resolve_intake(env: &Env, index: &BytesN<20>, intake_id: &BytesN<32>, proof: &Bytes) {
    let cfg = vault::config(env);
    let key = DataKey::Intake(index.clone(), intake_id.clone());
    let mut intake: Intake = vault::get(env, &key)
        .filter(|i: &Intake| i.state == INTAKE_OPEN as u32)
        .unwrap_or_else(|| fail(env, VaultError::IntakeNotOpen));
    let slot = snapshot::settled_slot(&Soroban(env), &intake_id.to_array());
    let mark = read_hub(env, &cfg, &index.to_array(), &[slot], proof)[0];
    let settled = mark != [0u8; 32];
    IntakeResolved {
        index: index.clone(),
        intake_id: intake_id.clone(),
        settled,
    }
    .publish(env);
    messages::resolve(env, &cfg, index, intake_id, &mut intake, settled);
}

/// Anyone, after the snapshot: a burn or a migration the index sent before it and that never arrived runs on the
/// index's own record of it (`_sentMessages`), once, within the speed limit, as a delivered one would. The index marks
/// each in the transaction that sends it, and only it writes its storage, so its mark at the snapshot shows the index
/// sent this message by then. Every other kind in flight at the snapshot resolves without one: an intake's through
/// `resolve_intake`, and governance not at all.
pub fn deliver_recorded(env: &Env, payload: &Bytes, proof: &Bytes) {
    let mut cfg = vault::config(env);
    let p = payload.to_alloc_vec();
    let c = Soroban(env);
    let id = xindex_core::abi::message_id(&c, &p);
    let m = messages::decode(env, &p);
    require(
        env,
        m.kind == BURN || m.kind == MIGRATE,
        VaultError::UnknownKind,
    );
    messages::check_route(env, &cfg, &m);
    let index = BytesN::from_array(env, &m.index);
    require(env, vault::is_index(env, &index), VaultError::NotAnIndex);
    let slot = snapshot::sent_slot(&c, &id);
    let mark = read_hub(env, &cfg, &m.index, &[slot], proof)[0];
    require(env, mark != [0u8; 32], VaultError::NotRecorded);
    messages::mark_used(env, &id, true);
    let id = BytesN::from_array(env, &id);
    MessageDelivered {
        id: id.clone(),
        kind: m.kind as u32,
        index: index.clone(),
    }
    .publish(env);
    if m.kind == BURN {
        messages::burn(env, &mut cfg, &index, &id, m.body);
    } else {
        messages::migrate(env, &cfg, &index, &id, m.body);
    }
    vault::set_config(env, &cfg);
}
