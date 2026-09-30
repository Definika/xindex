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
}
