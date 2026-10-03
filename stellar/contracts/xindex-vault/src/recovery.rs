//! Checkpoints, stall recovery and the snapshot exit's start (Stage B spec, section 5.6; design 6.9): the twin of the
//! EVM vault's. Anyone advances the checkpoint to a final Ethereum block P1 and P2 both prove. A week without one is a
//! stall: the vault takes no deposit, and the owner's emergency multisig may propose a successor pair, which must prove
//! the last checkpoint, a recent one and the last message, and waits 30 days with at most two vetoes by the freezer.
//! 180 days into a stall, the last checkpoint becomes the snapshot, for good.

use soroban_sdk::{Address, Bytes, Env};
use xindex_core::abi;
use xindex_core::constants::*;

use crate::error::VaultError;
use crate::events::*;
use crate::types::*;
use crate::vault::{self, require, Log};

/// Anyone, before a snapshot exit: records a final Ethereum block both P1 and P2 prove, newer than the last. One recent
/// enough to end a stall also lapses any successor under review and starts the freezer's count again. A stale one,
/// newer but still a stall's, which the pair in force can still prove up to where it broke, only lets what was sent
/// before the break run (VLT-3): the stall goes on, and so do its successor's review and the count (LG-2).
pub fn advance_checkpoint(env: &Env, c: &Checkpoint, proof1: &Bytes, proof2: &Bytes) {
    let mut cfg = vault::config(env);
    vault::check_no_snapshot(env, &cfg);
    vault::checkpoint_by_both(env, (&cfg.p1, &cfg.p2), c, proof1, proof2);
    vault::check_newer(env, &cfg, c);
    cfg.checkpoint = c.clone();
    CheckpointAdvanced {
        block: c.block,
        timestamp: c.timestamp,
        state_root: c.state_root.clone(),
    }
    .publish(env);
    if !vault::stalled(env, &cfg) {
        // A recent one ends the stall: the pair in force works again.
        cfg.vetoes = 0;
        if vault::drop_successor(env) {
            SuccessorLapsed {}.publish(env);
        }
    }
    vault::set_config(env, &cfg);
}

/// The recovery proposer only, while stalled, before a snapshot exit, with none under review: proposes a successor pair,
/// two different verifier contracts whose code it pins, which must pass the continuity test.
pub fn propose_successor(
    env: &Env,
    new_p1: Address,
    new_p2: Address,
    cont: &Continuity,
    message: &Option<LastMessage>,
) {
    let cfg = vault::config(env);
    cfg.recovery_proposer.require_auth();
    vault::check_no_snapshot(env, &cfg);
    require(env, vault::stalled(env, &cfg), VaultError::NotStalled);
    require(
        env,
        vault::successor(env).is_none(),
        VaultError::SuccessorPending,
    );
    let (p1, p2) = vault::pin_pair(env, new_p1, new_p2);
    // (a) The last checkpoint the pair in force accepted.
    vault::checkpoint_by_both(env, (&p1, &p2), &cfg.checkpoint, &cont.last1, &cont.last2);
    // (b) A recent one, which the successor's proof shows descends from it.
    vault::checkpoint_by_both(env, (&p1, &p2), &cont.recent, &cont.recent1, &cont.recent2);
    vault::check_recent(env, &cfg, &cont.recent);
    // (c) The last message the pair in force delivered on both proofs, if there was one.
    if cfg.last_message != vault::zero32(env) {
        let message = message
            .as_ref()
            .unwrap_or_else(|| vault::fail(env, VaultError::Discontinuous));
        let p = message.payload.to_alloc_vec();
        let log = Log::of(env, &p, abi::index_in(&p), message.block);
        require(
            env,
            log.id == cfg.last_message.to_array(),
            VaultError::Discontinuous,
        );
        vault::verify_event(env, &p1, &log, &message.proof1);
        vault::verify_event(env, &p2, &log, &message.proof2);
    }
    let review_ends = vault::now(env) + RECOVERY_DELAY as u64;
    SuccessorProposed {
        p1: p1.address.clone(),
        p2: p2.address.clone(),
        review_ends,
    }
    .publish(env);
    env.storage().instance().set(
        &DataKey::Successor,
        &Successor {
            p1,
            p2,
            review_ends,
        },
    );
    vault::set_config(env, &cfg);
}

/// The freezer only, at most MAX_RECOVERY_VETOES times a stall: drops the successor under review.
pub fn veto_successor(env: &Env) {
    let mut cfg = vault::config(env);
    cfg.freezer.require_auth();
    require(env, vault::drop_successor(env), VaultError::NoSuccessor);
    require(
        env,
        cfg.vetoes < MAX_RECOVERY_VETOES as u32,
        VaultError::VetoesExhausted,
    );
    cfg.vetoes += 1;
    SuccessorVetoed { vetoes: cfg.vetoes }.publish(env);
    vault::set_config(env, &cfg);
}

/// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2, which ends the
/// stall and the freezer's count.
pub fn adopt_successor(env: &Env, c: &Checkpoint, proof1: &Bytes, proof2: &Bytes) {
    let mut cfg = vault::config(env);
    // A snapshot clears any successor, and a checkpoint that ends the stall lapses it, so a pending one is still in its
    // stall.
    let s = vault::successor(env).unwrap_or_else(|| vault::fail(env, VaultError::NoSuccessor));
    require(
        env,
        vault::now(env) >= s.review_ends,
        VaultError::ReviewNotOver,
    );
    vault::checkpoint_by_both(env, (&s.p1, &s.p2), c, proof1, proof2);
    vault::check_recent(env, &cfg, c);
    SuccessorAdopted {
        p1: s.p1.address.clone(),
        p2: s.p2.address.clone(),
    }
    .publish(env);
    CheckpointAdvanced {
        block: c.block,
        timestamp: c.timestamp,
        state_root: c.state_root.clone(),
    }
    .publish(env);
    vault::drop_successor(env);
    cfg.vetoes = 0;
    cfg.p1 = s.p1;
    cfg.p2 = s.p2;
    cfg.checkpoint = c.clone();
    vault::set_config(env, &cfg);
}

/// Anyone, SNAPSHOT_EXIT_DELAY after the stall began: takes the last checkpoint as the snapshot for good. From then on
/// no message from a later Ethereum block runs, and holders at it claim directly. The snapshot's state root is also
/// the slot the hub reads at `bytes32(25)`, so `attest` shows the exit to Ethereum.
pub fn begin_snapshot(env: &Env) {
    let mut cfg = vault::config(env);
    vault::check_no_snapshot(env, &cfg);
    let due = vault::stall_start(&cfg) + SNAPSHOT_EXIT_DELAY as u64;
    require(env, vault::now(env) >= due, VaultError::SnapshotNotDue);
    let last = cfg.checkpoint.clone();
    // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
    require(
        env,
        last.state_root != vault::zero32(env),
        VaultError::NoCheckpoint,
    );
    vault::set_slot(env, &vault::snapshot_slot(), &last.state_root.to_array());
    SnapshotBegun {
        block: last.block,
        timestamp: last.timestamp,
        state_root: last.state_root.clone(),
    }
    .publish(env);
    cfg.snapshot = last;
    if vault::drop_successor(env) {
        SuccessorLapsed {}.publish(env);
    }
    vault::set_config(env, &cfg);
}
