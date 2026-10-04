use anchor_lang::prelude::*;

/// The EVM vault's errors, and the few Solana adds.
#[error_code]
pub enum VaultError {
    #[msg("only the program's upgrade authority initializes the vault")]
    NotDeployer,
    ZeroAddress,
    ZeroAmount,
    NotAnIndex,
    VaultFrozen,
    IntakeClosed,
    IntakeTooLong,
    CapExceeded,
    NoProof,
    #[msg("a message must be the canonical encoding of VaultMessages")]
    BadMessage,
    WrongRoute,
    WrongEmitter,
    BothProofsRequired,
    UnknownKind,
    #[msg("a 256-bit amount or id from Ethereum does not fit where Solana keeps it")]
    Overflow,
    #[msg("Stage B's Solana vault holds only SOL")]
    NotNative,
    IntakeNotOpen,
    NothingOwed,
    NothingPayable,
    NothingToRefund,
    NotFreezer,
    NotAContract,
    VerifiersNotDistinct,
    #[msg("the verifier accounts do not match P1 and P2")]
    WrongVerifier,
    WrongRecipient,
    #[msg("a verifier must be a program nobody can upgrade")]
    VerifierUpgradeable,
    #[msg("an older governance message of this kind than the last delivered")]
    StaleGovernance,
    #[msg("no change of this kind with this body waits")]
    NoPendingChange,
    ChangeNotReady,
    #[msg("a stalled vault takes no deposit")]
    VaultStalled,
    #[msg("a checkpoint must be newer than the last, in blocks and in time, not in the future, with a state")]
    NotNewer,
    #[msg("a successor's checkpoint must be recent: within STALL_PERIOD of now")]
    NotRecent,
    NotStalled,
    NotRecoveryProposer,
    SuccessorPending,
    NoSuccessor,
    #[msg("the successor does not prove the last checkpoint and the last message")]
    Discontinuous,
    VetoesExhausted,
    ReviewNotOver,
    SnapshotTaken,
    NoSnapshot,
    SnapshotNotDue,
    NoCheckpoint,
    #[msg("after the snapshot, a message from a later Ethereum block never runs")]
    IssuedAfterSnapshot,
    #[msg(
        "a message that moves coins or loosens a rule waits for a checkpoint covering its block"
    )]
    NotCheckpointed,
    #[msg("the index's storage at the snapshot does not mark this message sent")]
    NotRecorded,
    #[msg("the component must lie inside the hub's components array and be this chain's coin")]
    WrongComponent,
    BadSignature,
    #[msg("a state proof that does not prove the hub's storage under the root")]
    BadStateProof,
    #[msg(
        "the recovery proposer must be a multisig: an address off the ed25519 curve, never a key"
    )]
    RecoveryNotMultisig,
    #[msg("the freezer and the recovery proposer must be two accounts")]
    SameRole,
    #[msg(
        "the message already ran: only a cut taken on one proof may come again, on both (A3-02)"
    )]
    AlreadyDelivered,
}
