//! The vault's checkpoint rules, as `XindexVault`'s: a checkpoint is a final Ethereum block both P1 and P2 prove, a week
//! without a new one stalls the vault, and a message that moves coins or loosens a rule runs only from a block the
//! checkpoint covers (VLT-3). Each chain keeps the checkpoint in its own storage and turns a `false` into its own error.

use crate::constants::{CAP_UPDATE, FREEZE, STALL_PERIOD};

/// A final Ethereum block: its number, its timestamp and its state root.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Checkpoint {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: [u8; 32],
}

/// When a vault whose last checkpoint is dated `timestamp` stalls: STALL_PERIOD after it.
pub fn stall_start(timestamp: u64) -> i64 {
    timestamp as i64 + STALL_PERIOD
}

/// A week without a new checkpoint: P1 and P2 may have stopped working.
pub fn stalled(timestamp: u64, now: i64) -> bool {
    now > stall_start(timestamp)
}

/// `c` is after `last`, in blocks and in time, not in the future, and has a state to read.
pub fn is_newer(last: &Checkpoint, c: &Checkpoint, now: i64) -> bool {
    c.block > last.block
        && c.timestamp > last.timestamp
        && c.timestamp as i64 <= now
        && c.state_root != [0u8; 32]
}

/// `c` is within STALL_PERIOD of now: a checkpoint that would not leave the vault stalled.
pub fn is_recent(c: &Checkpoint, now: i64) -> bool {
    c.timestamp as i64 + STALL_PERIOD >= now
}

/// Whether a message of `kind` moves coins or loosens a rule, and so needs both proofs and a checkpoint covering its
/// block, as `XindexVault._needsBoth` decides: every kind but a freeze and a cap update that raises neither the cap nor
/// the floor. `lowers` says whether a cap update lowers both (`cap <= cap in force` and `floor <= floor in force`).
pub fn needs_both(kind: u8, lowers: bool) -> bool {
    match kind {
        FREEZE => false,
        CAP_UPDATE => !lowers,
        _ => true,
    }
}
