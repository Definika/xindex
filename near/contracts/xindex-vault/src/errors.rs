//! The vault's errors: the EVM vault's names, and the few NEAR adds. A failed call panics with
//! `XindexVault: <name>`, which tests and relayers match on.

use near_sdk::env;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    ZeroAddress,
    ZeroAmount,
    NotAnIndex,
    VaultFrozen,
    VaultStalled,
    IntakeClosed,
    IntakeTooLong,
    IntakeNotOpen,
    CapExceeded,
    NoProof,
    BadMessage,
    Overflow,
    NotNative,
    WrongRoute,
    WrongEmitter,
    UnknownKind,
    BothProofsRequired,
    NotCheckpointed,
    IssuedAfterSnapshot,
    AlreadyDelivered,
    NothingOwed,
    NothingPayable,
    NothingToRefund,
    NotFreezer,
    WrongRecipient,
    StaleGovernance,
    NoPendingChange,
    ChangeNotReady,
    NotNewer,
    NotRecent,
    NotStalled,
    NotRecoveryProposer,
    RecoveryNotMultisig,
    SameRole,
    SuccessorPending,
    NoSuccessor,
    Discontinuous,
    VetoesExhausted,
    ReviewNotOver,
    SnapshotTaken,
    NoSnapshot,
    SnapshotNotDue,
    NoCheckpoint,
    NotRecorded,
    WrongComponent,
    BadSignature,
    BadStateProof,
    AlreadyClaimed,
    NotAttested,
    UnknownVerifier,
    UnknownSystem,
    VerifiersNotDistinct,
    InvalidProof,
    StorageNotPaid,
    /// The outflow floor above the cap: the speed limit would never bind (B2-02).
    FloorAboveCap,
    /// A light client's refusal, by the core's name for it.
    Verifier(xindex_core::light_client::Error),
}

/// Fails the call with `XindexVault: <error>`.
pub fn fail(e: Error) -> ! {
    let name = match e {
        Error::Verifier(v) => format!("{v:?}"),
        other => format!("{other:?}"),
    };
    env::panic_str(&format!("XindexVault: {name}"))
}

/// Fails the call with `e` unless `cond` holds.
pub fn check(cond: bool, e: Error) {
    if !cond {
        fail(e)
    }
}
