use soroban_sdk::contracterror;

/// The EVM vault's errors, and the few Stellar adds.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum VaultError {
    ZeroAddress = 1,
    ZeroAmount = 2,
    NotAnIndex = 3,
    VaultFrozen = 4,
    IntakeClosed = 5,
    IntakeTooLong = 6,
    CapExceeded = 7,
    NoProof = 8,
    /// A message must be the canonical encoding of `VaultMessages`.
    BadMessage = 9,
    WrongRoute = 10,
    WrongEmitter = 11,
    BothProofsRequired = 12,
    UnknownKind = 13,
    /// A 256-bit amount from Ethereum, or one given here, does not fit where the vault keeps it.
    Overflow = 14,
    /// Stage B's Stellar vault holds only XLM.
    NotNative = 15,
    IntakeNotOpen = 16,
    NothingOwed = 17,
    NothingPayable = 18,
    NothingToRefund = 19,
    NotFreezer = 20,
    /// A verifier, or the recovery proposer, must be a Wasm contract.
    NotAContract = 21,
    VerifiersNotDistinct = 22,
    /// A verifier no longer runs the code the vault pinned when it took it.
    VerifierChanged = 23,
    WrongRecipient = 24,
    AlreadyDelivered = 25,
    /// An older governance message of this kind than the last taken on both proofs.
    StaleGovernance = 26,
    NoPendingChange = 27,
    ChangeNotReady = 28,
    /// A stalled vault takes no deposit.
    VaultStalled = 29,
    NotNewer = 30,
    NotRecent = 31,
    NotStalled = 32,
    SuccessorPending = 33,
    NoSuccessor = 34,
    Discontinuous = 35,
    VetoesExhausted = 36,
    ReviewNotOver = 37,
    SnapshotTaken = 38,
    NoSnapshot = 39,
    SnapshotNotDue = 40,
    NoCheckpoint = 41,
    /// After the snapshot, a message from a later Ethereum block never runs.
    IssuedAfterSnapshot = 42,
    /// A message that moves coins or loosens a rule waits for a checkpoint covering its block (VLT-3).
    NotCheckpointed = 43,
    /// The index's storage at the snapshot does not mark this message sent.
    NotRecorded = 44,
    /// The component must lie inside the hub's components array and be this chain's coin (VLT-1).
    WrongComponent = 45,
    BadSignature = 46,
    /// A state proof that does not prove the hub's storage under the root.
    BadStateProof = 47,
    /// The freezer must be a Stellar account.
    NotAnAccount = 48,
    AlreadyClaimed = 49,
    /// `attest`'s slots and values differ in number, or a slot does not hold its value.
    NotAttested = 50,
    /// The native asset's contract is not deployed where the network puts it.
    NoNativeAsset = 51,
}
