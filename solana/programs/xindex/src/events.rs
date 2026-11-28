// SPDX-License-Identifier: BUSL-1.1
use anchor_lang::prelude::*;

#[event]
pub struct OwnershipTransferStarted {
    pub owner: Pubkey,
    pub pending_owner: Pubkey,
}

#[event]
pub struct OwnershipTransferred {
    pub previous: Pubkey,
    pub owner: Pubkey,
}

#[event]
pub struct GuardianChangeProposed {
    pub guardian: Pubkey,
    pub eta: i64,
}

#[event]
pub struct GuardianChanged {
    pub previous: Pubkey,
    pub guardian: Pubkey,
}

#[event]
pub struct GuardianChangeCancelled {
    pub guardian: Pubkey,
}

#[event]
pub struct ListingProposed {
    pub mint: Pubkey,
    pub decimals: u8,
    pub eta: i64,
}

#[event]
pub struct Listed {
    pub mint: Pubkey,
}

#[event]
pub struct ListingCancelled {
    pub mint: Pubkey,
}

#[event]
pub struct Delisted {
    pub mint: Pubkey,
}

#[event]
pub struct CreatorApproved {
    pub wallet: Pubkey,
    pub approved: bool,
}

#[event]
pub struct IndexCreated {
    pub index: Pubkey,
    pub creator: Pubkey,
    pub share_mint: Pubkey,
    pub legs: u16,
}

#[event]
pub struct Issued {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub recipient: Pubkey,
    pub shares: u64,
}

#[event]
pub struct Redeemed {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub shares: u64,
}

#[event]
pub struct Claimed {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub leg: u16,
    pub amount: u64,
    pub to: Pubkey,
}

#[event]
pub struct FeeSharesMinted {
    pub index: Pubkey,
    pub creator_shares: u64,
    pub platform_shares: u64,
    pub referrer_shares: u64,
}

#[event]
pub struct StreamingFeeAccrued {
    pub index: Pubkey,
    pub fee_shares: u64,
    pub scale: u64,
}

#[event]
pub struct CreatorTransferStarted {
    pub index: Pubkey,
    pub creator: Pubkey,
    pub pending: Pubkey,
}

#[event]
pub struct CreatorTransferred {
    pub index: Pubkey,
    pub previous: Pubkey,
    pub creator: Pubkey,
}

#[event]
pub struct MintingOpened {
    pub index: Pubkey,
}

#[event]
pub struct MinterAllowed {
    pub index: Pubkey,
    pub wallet: Pubkey,
    pub allowed: bool,
}

#[event]
pub struct FeePolicySet {
    pub platform_fee_bps: u16,
    pub platform_streaming_bps: u16,
    pub referral_share_bps: u16,
    pub recipient: Pubkey,
}

/// `index` is the default key when the pause is every index's.
#[event]
pub struct MintingPaused {
    pub index: Pubkey,
    pub paused: bool,
}

#[event]
pub struct PriceFeedProposed {
    pub mint: Pubkey,
    pub feed_id: [u8; 32],
    pub kind: u8,
    pub eta: i64,
}

#[event]
pub struct PriceFeedSet {
    pub mint: Pubkey,
    pub feed_id: [u8; 32],
    pub kind: u8,
}

#[event]
pub struct PriceFeedCancelled {
    pub mint: Pubkey,
}

#[event]
pub struct RebalanceStarted {
    pub index: Pubkey,
    pub proposal_id: u64,
    pub caller: Pubkey,
    pub keep_mask: [u64; 4],
    pub eta: i64,
}

#[event]
pub struct RebalanceQuoted {
    pub index: Pubkey,
    pub proposal_id: u64,
    pub tolerance: u64,
}

#[event]
pub struct RebalanceCancelled {
    pub index: Pubkey,
    pub proposal_id: u64,
    pub caller: Pubkey,
    pub restart_allowed_at: i64,
}

#[event]
pub struct FillOpened {
    pub index: Pubkey,
    pub executor: Pubkey,
    pub proposal_id: u64,
}

#[event]
pub struct Rebalanced {
    pub index: Pubkey,
    pub proposal_id: u64,
    pub rebalance_nonce: u64,
    pub executor: Pubkey,
    pub bar: u64,
    pub gain: i64,
}

#[event]
pub struct FillPaid {
    pub index: Pubkey,
    pub executor: Pubkey,
    pub leg: u16,
    pub amount: u64,
    pub to: Pubkey,
}

#[event]
pub struct WeightsProposed {
    pub index: Pubkey,
    pub weights: Vec<u16>,
    pub eta: i64,
}

#[event]
pub struct WeightsCancelled {
    pub index: Pubkey,
}

#[event]
pub struct WeightsChanged {
    pub index: Pubkey,
    pub weights: Vec<u16>,
}

#[event]
pub struct RequestOpened {
    pub request: Pubkey,
    pub requester: Pubkey,
    pub index: Pubkey,
    pub kind: u8,
    pub escrowed: u64,
    pub min_out: u64,
    pub deadline: i64,
}

#[event]
pub struct RequestFilled {
    pub request: Pubkey,
    pub filler: Pubkey,
    pub paid: u64,
    pub escrowed: u64,
}

#[event]
pub struct RequestClosed {
    pub request: Pubkey,
    pub by: Pubkey,
}
