// SPDX-License-Identifier: BUSL-1.1
use anchor_lang::prelude::*;

#[error_code]
pub enum XindexError {
    #[msg("only the program's upgrade authority initializes the configuration")]
    NotUpgradeAuthority,
    #[msg("only the owner may do this")]
    NotOwner,
    #[msg("only the owner or the guardian may do this")]
    NotOwnerOrGuardian,
    #[msg("only the pending owner may accept the role")]
    NotPendingOwner,
    #[msg("no proposal is pending")]
    NothingPending,
    #[msg("the proposal's delay has not passed")]
    TooEarly,
    #[msg("the proposal's window has closed")]
    ProposalExpired,
    #[msg("a proposal for this mint is still live")]
    ListingPending,
    #[msg("the mint's accounting cannot be held in kind")]
    UnlistableMint,
    #[msg("the mint has more decimals than a listing allows")]
    TooManyDecimals,
    #[msg("the token program is not the mint's")]
    WrongTokenProgram,
    #[msg("the wallet is not approved to create an index")]
    CreatorNotApproved,
    #[msg("an index holds two to two hundred legs")]
    BadLegCount,
    #[msg("the name or the symbol is too long")]
    NameTooLong,
    #[msg("the index is sealed")]
    AlreadySealed,
    #[msg("the index is not sealed")]
    NotSealed,
    #[msg("more legs than the index was begun with")]
    TooManyLegs,
    #[msg("a listing account does not match its leg")]
    ListingMismatch,
    #[msg("the mint is not listed")]
    NotListed,
    #[msg("a leg's units are outside their bounds")]
    UnitsOutOfBounds,
    #[msg("a leg's weight is zero")]
    ZeroWeight,
    #[msg("a mint appears twice")]
    DuplicateLeg,
    #[msg("the index has fewer legs than it was begun with")]
    LegsMissing,
    #[msg("the weights do not sum to 10,000")]
    WeightsNotWhole,
    #[msg("the legs are not the terms the index's address commits to")]
    TermsMismatch,
    #[msg("no shares")]
    ZeroShares,
    #[msg("an amount does not fit a token amount")]
    AmountTooLarge,
    #[msg("no such leg")]
    BadLeg,
    #[msg("the account does not belong to this leg")]
    WrongLegAccount,
    #[msg("the leg is already deposited")]
    NothingToDeposit,
    #[msg("nothing of this leg is deposited")]
    NothingDeposited,
    #[msg("the vault holds less than it owes")]
    Underbacked,
    #[msg("the vault received less than was sent")]
    ShortDeposit,
    #[msg("the index rebalanced since the ticket was opened")]
    StaleRebalanceNonce,
    #[msg("a leg is not yet deposited")]
    IssueIncomplete,
    #[msg("deposits are still in the ticket")]
    DepositsOutstanding,
    #[msg("nothing of this leg is owed")]
    NothingOwed,
    #[msg("claims are still in the ticket")]
    ClaimsOutstanding,
    #[msg("the ticket belongs to another index or owner")]
    WrongTicket,
    #[msg("only the index's creator may do this")]
    NotCreator,
}
