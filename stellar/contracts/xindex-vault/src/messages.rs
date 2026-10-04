//! Messages from Ethereum: `deliver`, the twin of the EVM vault's, one entry point for every kind. It runs its checks:
//! after a snapshot, no block past it; the canonical encoding, the route, the emitter (the index the message names, a
//! registered one, or the factory for a governance kind); the proofs; for a message that moves coins or loosens a rule,
//! both proofs and a checkpoint covering its block (VLT-3); and a used mark, so a message runs at most once. Then the
//! kind's effect, and the governance changes that wait on the vault (VLT-2).

use soroban_sdk::{Bytes, BytesN, Env};
use xindex_core::abi::{self, AbiError, Message};
use xindex_core::checkpoint;
use xindex_core::constants::*;

use crate::error::VaultError;
use crate::events::*;
use crate::types::*;
use crate::vault::{self, fail, require, Log};

fn abi_err(env: &Env, e: AbiError) -> ! {
    match e {
        AbiError::BadMessage => fail(env, VaultError::BadMessage),
        AbiError::Overflow => fail(env, VaultError::Overflow),
    }
}

pub fn decode<'a>(env: &Env, p: &'a [u8]) -> Message<'a> {
    abi::decode_message(p).unwrap_or_else(|e| abi_err(env, e))
}

pub fn word<'a>(env: &Env, body: &'a [u8], words: usize, i: usize) -> &'a [u8; 32] {
    abi::body_word(body, words, i).unwrap_or_else(|e| abi_err(env, e))
}

pub fn to_u64(env: &Env, w: &[u8; 32]) -> u64 {
    abi::to_u64(w).unwrap_or_else(|e| abi_err(env, e))
}

pub fn to_address(env: &Env, w: &[u8; 32]) -> [u8; 20] {
    abi::to_address(w).unwrap_or_else(|e| abi_err(env, e))
}

/// A body word that must be zero: Stage B's Stellar vault holds XLM only, `address(0)` on Ethereum.
fn check_native(env: &Env, w: &[u8; 32]) {
    require(env, *w == [0u8; 32], VaultError::NotNative);
}

/// The message is Ethereum's, for this chain and this vault.
pub fn check_route(env: &Env, cfg: &Config, m: &Message) {
    require(
        env,
        m.source_chain_id == cfg.source_chain_id
            && m.dest_chain_id == cfg.chain_id
            && m.vault == vault::vault_id(env),
        VaultError::WrongRoute,
    );
}

/// A cap update's body: XLM's id, which must be zero, then its cap and floor.
pub fn read_cap(env: &Env, body: &[u8]) -> (u64, u64) {
    check_native(env, word(env, body, 3, 0));
    (
        to_u64(env, word(env, body, 3, 1)),
        to_u64(env, word(env, body, 3, 2)),
    )
}

/// Refuses a message already used, then marks it used when `keep`, so it never runs again.
pub fn mark_used(env: &Env, id: &[u8; 32], keep: bool) {
    let key = DataKey::Used(BytesN::from_array(env, id));
    require(
        env,
        !env.storage().persistent().has(&key),
        VaultError::AlreadyDelivered,
    );
    if keep {
        vault::put(env, &key, &true);
    }
}

/// Anyone: runs one `VaultMessage` the factory or an index emitted on Ethereum, which P1, P2 or both prove from
/// `block`. Only a message on both proofs becomes the last message a successor must prove again: one broken proof
/// system could forge a one-proof freeze, which no honest successor could prove (LG-3).
pub fn deliver(
    env: &Env,
    payload: &Bytes,
    block: u64,
    proof1: &Option<Bytes>,
    proof2: &Option<Bytes>,
) {
    let mut cfg = vault::config(env);
    // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
    let snapshot = cfg.snapshot.block;
    require(
        env,
        snapshot == 0 || block <= snapshot,
        VaultError::IssuedAfterSnapshot,
    );
    let p = payload.to_alloc_vec();
    let m = decode(env, &p);
    require(
        env,
        m.kind != 0 && m.kind <= VERIFIER_ROTATION,
        VaultError::UnknownKind,
    );
    check_route(env, &cfg, &m);
    let governance = m.kind >= CAP_UPDATE;
    let index = BytesN::from_array(env, &m.index);
    if governance {
        // Any Ethereum contract can emit a message naming itself; a governance kind is the factory's alone.
        require(
            env,
            m.index == cfg.factory.to_array(),
            VaultError::WrongEmitter,
        );
    } else {
        require(env, vault::is_index(env, &index), VaultError::NotAnIndex);
    }
    let lowers = m.kind == CAP_UPDATE && {
        let (cap, floor) = read_cap(env, m.body);
        cap <= cfg.cap && floor <= cfg.outflow_floor
    };
    let loosening = checkpoint::needs_both(m.kind, lowers);

    require(
        env,
        proof1.is_some() || proof2.is_some(),
        VaultError::NoProof,
    );
    let both = proof1.is_some() && proof2.is_some();
    require(env, both || !loosening, VaultError::BothProofsRequired);
    // A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
    // snapshot at that checkpoint never pays twice what such a message already paid (VLT-3).
    require(
        env,
        !loosening || block <= cfg.checkpoint.block,
        VaultError::NotCheckpointed,
    );
    let log = Log::of(env, &p, m.index, block);
    let id = log.id;
    // A cut taken on one proof moves no mark (VLT-4), so it stays deliverable on both, which moves the mark past an
    // older raise; until then a replay on one proof only applies it again (A3-02). A freeze is used up at once.
    mark_used(env, &id, both || m.kind == FREEZE);
    if let Some(proof) = proof1 {
        vault::verify_event(env, &cfg.p1, &log, proof);
    }
    if let Some(proof) = proof2 {
        vault::verify_event(env, &cfg.p2, &log, proof);
    }
    let id = BytesN::from_array(env, &id);
    if both {
        cfg.last_message = id.clone();
    }
    MessageDelivered {
        id: id.clone(),
        kind: m.kind as u32,
        index: index.clone(),
    }
    .publish(env);

    match m.kind {
        BURN => burn(env, &mut cfg, &index, &id, m.body),
        INTAKE_SETTLED | INTAKE_FAILED => {
            let intake_id = BytesN::from_array(env, word(env, m.body, 1, 0));
            let key = DataKey::Intake(index.clone(), intake_id.clone());
            let mut intake: Intake = vault::get(env, &key).unwrap_or(Intake {
                state: INTAKE_NONE as u32,
                has_native: false,
                total: 0,
            });
            require(
                env,
                intake.state == INTAKE_NONE as u32 || intake.state == INTAKE_OPEN as u32,
                VaultError::IntakeNotOpen,
            );
            resolve(
                env,
                &cfg,
                &index,
                &intake_id,
                &mut intake,
                m.kind == INTAKE_SETTLED,
            );
        }
        MIGRATE => migrate(env, &cfg, &index, &id, m.body),
        _ => governance_message(env, &mut cfg, &m, both),
    }
    vault::set_config(env, &cfg);
}

// ---------------------------------------------------------------------
// BURN
// ---------------------------------------------------------------------

/// A burn from an index, delivered or recorded: pays its recipient what the speed limit allows now and owes the rest.
pub fn burn(env: &Env, cfg: &mut Config, index: &BytesN<20>, id: &BytesN<32>, body: &[u8]) {
    check_native(env, word(env, body, 3, 0));
    let amount = to_u64(env, word(env, body, 3, 1));
    let recipient = BytesN::from_array(env, word(env, body, 3, 2));
    require(env, amount != 0, VaultError::ZeroAmount);
    // A recipient is a Stellar account's key, never the vault or another contract (SOL-9 holds by construction).
    require(
        env,
        recipient != vault::zero32(env),
        VaultError::ZeroAddress,
    );
    let mut owed = Owed {
        to_index: false,
        recipient: recipient.clone(),
        new_index: BytesN::from_array(env, &[0u8; 20]),
        remaining: amount,
    };
    BurnAccepted {
        index: index.clone(),
        id: id.clone(),
        amount,
        recipient,
    }
    .publish(env);
    pay_recipient(env, cfg, index, id, &mut owed, false);
}

/// Pays what the speed limit allows now of `owed`, to its account, and leaves the rest owed. An account that does not
/// exist cannot take XLM yet: its payout waits as owed, and `release` pays it once the account exists (SOL-5).
pub fn pay_recipient(
    env: &Env,
    cfg: &mut Config,
    index: &BytesN<20>,
    id: &BytesN<32>,
    owed: &mut Owed,
    strict: bool,
) {
    let mut s = vault::index_state(env, index);
    let to = vault::account(env, &owed.recipient);
    let pay = vault::pay_owed(env, cfg, index, &mut s, id, owed, strict, to.exists());
    vault::put(env, &DataKey::Owed(index.clone(), id.clone()), owed);
    if pay == 0 {
        return;
    }
    cfg.held -= pay;
    vault::refresh_index(env, cfg, index, &s);
    vault::put_index(env, index, &s);
    vault::send(env, cfg, &to, pay);
}

// ---------------------------------------------------------------------
// INTAKE_SETTLED, INTAKE_FAILED
// ---------------------------------------------------------------------

/// Settles an intake, whose deposits join the index, or fails it, so its depositors can take them back.
pub fn resolve(
    env: &Env,
    cfg: &Config,
    index: &BytesN<20>,
    intake_id: &BytesN<32>,
    intake: &mut Intake,
    settle: bool,
) {
    if settle {
        intake.state = INTAKE_SETTLED_STATE as u32;
        if intake.has_native {
            let mut s = vault::index_state(env, index);
            s.balance += intake.total;
            s.has_native = true;
            vault::refresh_index(env, cfg, index, &s);
            vault::put_index(env, index, &s);
        }
        IntakeSettled {
            index: index.clone(),
            intake_id: intake_id.clone(),
        }
        .publish(env);
    } else {
        intake.state = INTAKE_FAILED_STATE as u32;
        IntakeFailed {
            index: index.clone(),
            intake_id: intake_id.clone(),
        }
        .publish(env);
    }
    vault::refresh_intake(env, cfg, index, intake_id, intake);
    vault::put(
        env,
        &DataKey::Intake(index.clone(), intake_id.clone()),
        intake,
    );
}

// ---------------------------------------------------------------------
// MIGRATE
// ---------------------------------------------------------------------

/// A migration, delivered or recorded: moves coins two index versions share from the old index's balance to the new
/// one's, within the speed limit, as a burn leaves (Stage B spec, section 5.5). The coins never leave the vault.
pub fn migrate(env: &Env, cfg: &Config, index: &BytesN<20>, id: &BytesN<32>, body: &[u8]) {
    let new_index = BytesN::from_array(env, &to_address(env, word(env, body, 3, 0)));
    require(env, new_index != *index, VaultError::NotAnIndex);
    require(
        env,
        vault::is_index(env, &new_index),
        VaultError::NotAnIndex,
    );
    check_native(env, word(env, body, 3, 1));
    let amount = to_u64(env, word(env, body, 3, 2));
    require(env, amount != 0, VaultError::ZeroAmount);
    let mut owed = Owed {
        to_index: true,
        recipient: vault::zero32(env),
        new_index: new_index.clone(),
        remaining: amount,
    };
    MigrationAccepted {
        index: index.clone(),
        id: id.clone(),
        amount,
        new_index,
    }
    .publish(env);
    pay_migration(env, cfg, index, id, &mut owed, false);
}

/// Moves what the speed limit allows now of an owed migration into the new index's balance; `held` stays, since the
/// coins stay in the vault.
pub fn pay_migration(
    env: &Env,
    cfg: &Config,
    index: &BytesN<20>,
    id: &BytesN<32>,
    owed: &mut Owed,
    strict: bool,
) {
    let mut s = vault::index_state(env, index);
    let pay = vault::pay_owed(env, cfg, index, &mut s, id, owed, strict, true);
    vault::put(env, &DataKey::Owed(index.clone(), id.clone()), owed);
    if pay == 0 {
        return;
    }
    let mut new = vault::index_state(env, &owed.new_index);
    new.balance += pay;
    new.has_native = true;
    vault::refresh_index(env, cfg, index, &s);
    vault::refresh_index(env, cfg, &owed.new_index, &new);
    vault::put_index(env, index, &s);
    vault::put_index(env, &owed.new_index, &new);
}

// ---------------------------------------------------------------------
// Governance: CAP_UPDATE, FREEZE, FREEZER_CHANGE, VERIFIER_ROTATION
// ---------------------------------------------------------------------

/// A freeze runs at once, but not after a snapshot (VLT-5). Every other governance message must be newer than the last
/// of its kind taken on both proofs, and only one taken on both proofs moves that mark, so one broken proof system
/// cannot lock the factory out with a forged nonce (VLT-4). A cap update raising neither figure applies at once; a
/// raise, a new freezer and new verifiers wait GOVERNANCE_DELAY here, where the freezer can see them and stop a raise
/// or a rotation, however their proofs were obtained (VLT-2).
fn governance_message(env: &Env, cfg: &mut Config, m: &Message, both: bool) {
    if m.kind == FREEZE {
        require(env, m.body.is_empty(), VaultError::BadMessage);
        vault::check_no_snapshot(env, cfg);
        freeze_until(env, cfg);
        return;
    }
    let last = match m.kind {
        CAP_UPDATE => &mut cfg.cap_nonce,
        FREEZER_CHANGE => &mut cfg.freezer_nonce,
        _ => &mut cfg.rotation_nonce,
    };
    require(env, m.nonce > *last, VaultError::StaleGovernance);
    if both {
        *last = m.nonce;
    }
    let now = vault::now(env);
    let body = Bytes::from_slice(env, m.body);
    match m.kind {
        CAP_UPDATE => {
            let (cap, floor) = read_cap(env, m.body);
            if cap <= cfg.cap && floor <= cfg.outflow_floor {
                // Newer than a waiting raise, which it replaces.
                cfg.pending_cap = none(env);
                set_cap(env, cfg, cap, floor);
            } else {
                cfg.pending_cap = queue(env, m.kind, &body, now);
            }
        }
        FREEZER_CHANGE => {
            word(env, m.body, 1, 0);
            cfg.pending_freezer = queue(env, m.kind, &body, now);
        }
        _ => {
            word(env, m.body, 2, 0);
            cfg.pending_rotation = queue(env, m.kind, &body, now);
        }
    }
}

pub fn none(env: &Env) -> PendingChange {
    PendingChange {
        body_hash: vault::zero32(env),
        ready_at: 0,
    }
}

/// Starts `kind`'s wait, replacing whatever older change of its kind was waiting.
fn queue(env: &Env, kind: u8, body: &Bytes, now: u64) -> PendingChange {
    let ready_at = now + GOVERNANCE_DELAY as u64;
    ChangeQueued {
        kind: kind as u32,
        body: body.clone(),
        ready_at,
    }
    .publish(env);
    PendingChange {
        body_hash: env.crypto().keccak256(body).to_bytes(),
        ready_at,
    }
}

pub fn set_cap(env: &Env, cfg: &mut Config, cap: u64, floor: u64) {
    cfg.cap = cap;
    cfg.outflow_floor = floor;
    CapSet {
        cap,
        outflow_floor: floor,
    }
    .publish(env);
}

/// Freezes the vault for FREEZE_DURATION from now; a later freeze extends it, and none shortens it.
pub fn freeze_until(env: &Env, cfg: &mut Config) {
    let until = vault::now(env) + FREEZE_DURATION as u64;
    if until > cfg.frozen_until {
        cfg.frozen_until = until;
    }
    Frozen {
        until: cfg.frozen_until,
    }
    .publish(env);
}

/// Anyone, from its `ready_at`: applies the waiting change of `kind` whose body `ChangeQueued` announced. A freeze in
/// force holds every change but the freezer's replacement: a freezer that froze again and again must not be able to
/// keep itself in place.
pub fn apply_change(env: &Env, kind: u32, body: &Bytes) {
    let kind = narrow(env, kind);
    let mut cfg = vault::config(env);
    let waiting = pending(env, &mut cfg, kind).clone();
    require(
        env,
        waiting.ready_at != 0 && waiting.body_hash == env.crypto().keccak256(body).to_bytes(),
        VaultError::NoPendingChange,
    );
    require(
        env,
        vault::now(env) >= waiting.ready_at,
        VaultError::ChangeNotReady,
    );
    if kind != FREEZER_CHANGE {
        vault::check_not_frozen(env, &cfg);
    }
    *pending(env, &mut cfg, kind) = none(env);
    let b = body.to_alloc_vec();
    match kind {
        CAP_UPDATE => {
            let (cap, floor) = read_cap(env, &b);
            set_cap(env, &mut cfg, cap, floor);
        }
        FREEZER_CHANGE => {
            let key = BytesN::from_array(env, word(env, &b, 1, 0));
            require(env, key != vault::zero32(env), VaultError::ZeroAddress);
            // The freezer is a Stellar account, whose own signers and thresholds may make it a multisig.
            cfg.freezer = vault::account(env, &key);
            FreezerChanged {
                freezer: cfg.freezer.clone(),
            }
            .publish(env);
        }
        _ => {
            let p1 = vault::contract(env, &BytesN::from_array(env, word(env, &b, 2, 0)));
            let p2 = vault::contract(env, &BytesN::from_array(env, word(env, &b, 2, 1)));
            let (p1, p2) = vault::pin_pair(env, p1, p2);
            VerifiersRotated {
                p1: p1.address.clone(),
                p2: p2.address.clone(),
            }
            .publish(env);
            cfg.p1 = p1;
            cfg.p2 = p2;
        }
    }
    ChangeApplied { kind: kind.into() }.publish(env);
    vault::set_config(env, &cfg);
}

/// The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
pub fn cancel_change(env: &Env, kind: u32) {
    let mut cfg = vault::config(env);
    cfg.freezer.require_auth();
    let kind = narrow(env, kind);
    require(env, kind != FREEZER_CHANGE, VaultError::NotFreezer);
    let waiting = pending(env, &mut cfg, kind);
    require(env, waiting.ready_at != 0, VaultError::NoPendingChange);
    *waiting = none(env);
    ChangeCancelled { kind: kind.into() }.publish(env);
    vault::set_config(env, &cfg);
}

/// A change's kind is one byte. A wider word names no change: narrowing it with `as u8` let `cancel_change(263)` past
/// the freezer's guard and onto its own replacement (B3-01).
fn narrow(env: &Env, kind: u32) -> u8 {
    u8::try_from(kind).unwrap_or_else(|_| fail(env, VaultError::NoPendingChange))
}

fn pending<'a>(env: &Env, cfg: &'a mut Config, kind: u8) -> &'a mut PendingChange {
    match kind {
        CAP_UPDATE => &mut cfg.pending_cap,
        FREEZER_CHANGE => &mut cfg.pending_freezer,
        VERIFIER_ROTATION => &mut cfg.pending_rotation,
        _ => fail(env, VaultError::NoPendingChange),
    }
}
