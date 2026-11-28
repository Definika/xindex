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
    #[msg("the account is not a price of Pyth's receiver")]
    NotAPythPrice,
    #[msg("the price is not fully verified")]
    PriceNotVerified,
    #[msg("the price is not the listing's feed")]
    WrongPriceFeed,
    #[msg("the price cannot value the leg")]
    UnusablePrice,
    #[msg("the mint's multiplier is scheduled to change or changed too recently")]
    MultiplierUnsettled,
    #[msg("the price is older than the check allows")]
    StalePrice,
    #[msg("the mint has no price feed")]
    NoPriceFeed,
    #[msg("a price feed proposal for this mint is still live")]
    PriceFeedPending,
    #[msg("a feed's kind and id disagree")]
    InvalidPriceFeed,
    #[msg("a leg's share of value lies too far from its weight")]
    OffWeights,
    #[msg("a leg has no price recorded")]
    PriceMissing,
    #[msg("the platform's rates are not the policy's")]
    PolicyChanged,
    #[msg("a fee rate is above its bound")]
    FeeTooHigh,
    #[msg("the rebalance interval is outside 7 to 91 days")]
    IntervalOutOfRange,
    #[msg("the fee policy is outside its bounds")]
    InvalidFeePolicy,
    #[msg("the recipient may not receive this index's new shares")]
    NotAllowedMinter,
    #[msg("minting is paused")]
    MintingPaused,
    #[msg("only the pending creator may accept the role")]
    NotPendingCreator,
    #[msg("a fee account is not its recipient's")]
    WrongFeeAccount,
    #[msg("the index is not gated")]
    NotGated,
    #[msg("too soon to start a rebalance")]
    RebalanceTooSoon,
    #[msg("a rebalance is pending")]
    RebalancePending,
    #[msg("the keep mask names a leg the index lacks or leaves fewer than two moving")]
    InvalidKeepMask,
    #[msg("only the owner or the guardian may do this now")]
    Unauthorized,
    #[msg("no rebalance is pending")]
    NoPendingRebalance,
    #[msg("the proposal is not the latest")]
    StaleProposal,
    #[msg("the auction has not opened")]
    RebalanceNotReady,
    #[msg("the auction is over")]
    RebalanceExpired,
    #[msg("an index under one whole share does not rebalance")]
    NothingToRebalance,
    #[msg("a leg's new units are outside its caps")]
    LegOutOfBounds,
    #[msg("a leg's new units do not fit")]
    UnitsOverflow,
    #[msg("the gain is under the bar")]
    GainBelowBar,
    #[msg("a growing leg's deposit is short of what the settlement needs")]
    RebalanceMovedOn,
    #[msg("the fill brings in less than the quote allows")]
    BelowQuote,
    #[msg("the fill brings in less than Pyth's prices allow")]
    BelowOracleValue,
    #[msg("the quote is incomplete or out of its bounds")]
    InvalidQuote,
    #[msg("the quote binds a live proposal")]
    QuoteBound,
    #[msg("the fill is committed")]
    FillCommitted,
    #[msg("the fill's proposal or nonce is gone")]
    StaleFill,
    #[msg("the fill is not committed")]
    NotCommitted,
    #[msg("the fill still holds deposits or what it is owed")]
    FillOutstanding,
    #[msg("a list of another length")]
    LengthMismatch,
    #[msg("the weights are not one to 10,000 each and 10,000 in all")]
    InvalidWeights,
    #[msg("no weights are pending")]
    NoPendingWeights,
    #[msg("the weights' delay has not passed")]
    WeightsNotReady,
    #[msg("the weights' window has closed")]
    WeightsExpired,
    #[msg("only the configuration's USDC and USDT are a limit order's currency")]
    NotAStable,
    #[msg("a limit order's deadline must lie within thirty days")]
    BadDeadline,
    #[msg("no such kind of limit order")]
    BadRequest,
    #[msg("the limit order's deadline has passed")]
    RequestExpired,
    #[msg("the limit order is not the one the filler priced")]
    RequestChanged,
    #[msg("the fill delivers less than the requester's limit")]
    BelowLimit,
    #[msg("only the requester closes a limit order before its deadline")]
    RequestOpen,
}
