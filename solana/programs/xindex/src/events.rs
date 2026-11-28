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
