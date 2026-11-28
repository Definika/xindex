// SPDX-License-Identifier: BUSL-1.1
//! Xindex on Solana: index tokens backed in kind (`docs/design/solana.md`). An index's every share is backed by fixed
//! units of each of its legs, held in the index's own vaults. Wallets the owner approves create indexes; anyone issues
//! and redeems in kind. Paths that touch every leg run over several transactions, through tickets.
#![allow(unexpected_cfgs)]

pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod math;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("9oUHUMboV1WHQunh4zQVV7RwGSNzQqYcFWoSXTfbAjWT");

#[program]
pub mod xindex {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, owner: Pubkey, guardian: Pubkey) -> Result<()> {
        instructions::config::handle_initialize(ctx, owner, guardian)
    }

    pub fn transfer_ownership(ctx: Context<OwnerOnly>, pending_owner: Pubkey) -> Result<()> {
        instructions::config::handle_transfer_ownership(ctx, pending_owner)
    }

    pub fn accept_ownership(ctx: Context<AcceptOwnership>) -> Result<()> {
        instructions::config::handle_accept_ownership(ctx)
    }

    pub fn propose_guardian(ctx: Context<OwnerOnly>, guardian: Pubkey) -> Result<()> {
        instructions::config::handle_propose_guardian(ctx, guardian)
    }

    pub fn execute_guardian(ctx: Context<ExecuteGuardian>) -> Result<()> {
        instructions::config::handle_execute_guardian(ctx)
    }

    pub fn cancel_guardian(ctx: Context<CancelGuardian>) -> Result<()> {
        instructions::config::handle_cancel_guardian(ctx)
    }

    pub fn propose_listing(ctx: Context<ProposeListing>) -> Result<()> {
        instructions::listing::handle_propose_listing(ctx)
    }

    pub fn execute_listing(ctx: Context<ExecuteListing>) -> Result<()> {
        instructions::listing::handle_execute_listing(ctx)
    }

    pub fn cancel_listing(ctx: Context<GuardListing>) -> Result<()> {
        instructions::listing::handle_cancel_listing(ctx)
    }

    pub fn delist(ctx: Context<GuardListing>) -> Result<()> {
        instructions::listing::handle_delist(ctx)
    }

    pub fn approve_creator(ctx: Context<ApproveCreator>, wallet: Pubkey) -> Result<()> {
        instructions::listing::handle_approve_creator(ctx, wallet)
    }

    pub fn revoke_creator(ctx: Context<RevokeCreator>) -> Result<()> {
        instructions::listing::handle_revoke_creator(ctx)
    }

    pub fn begin_index(
        ctx: Context<BeginIndex>,
        terms_hash: [u8; 32],
        leg_count: u16,
        name: String,
        symbol: String,
    ) -> Result<()> {
        instructions::create::handle_begin_index(ctx, terms_hash, leg_count, name, symbol)
    }

    pub fn add_legs<'info>(ctx: Context<'info, AddLegs<'info>>, legs: Vec<LegSpec>) -> Result<()> {
        instructions::create::handle_add_legs(ctx, legs)
    }

    pub fn seal_index(ctx: Context<SealIndex>) -> Result<()> {
        instructions::create::handle_seal_index(ctx)
    }

    pub fn open_issue(ctx: Context<OpenIssue>, shares: u64) -> Result<()> {
        instructions::issue::handle_open_issue(ctx, shares)
    }

    pub fn deposit(ctx: Context<Deposit>, leg: u16) -> Result<()> {
        instructions::issue::handle_deposit(ctx, leg)
    }

    pub fn withdraw_deposit(ctx: Context<WithdrawDeposit>, leg: u16) -> Result<()> {
        instructions::issue::handle_withdraw_deposit(ctx, leg)
    }

    pub fn finalize_issue(ctx: Context<FinalizeIssue>) -> Result<()> {
        instructions::issue::handle_finalize_issue(ctx)
    }

    pub fn cancel_issue(ctx: Context<CancelIssue>) -> Result<()> {
        instructions::issue::handle_cancel_issue(ctx)
    }

    pub fn redeem(ctx: Context<Redeem>, shares: u64) -> Result<()> {
        instructions::redeem::handle_redeem(ctx, shares)
    }

    pub fn claim(ctx: Context<Claim>, leg: u16, amount: u64) -> Result<()> {
        instructions::redeem::handle_claim(ctx, leg, amount)
    }

    pub fn close_redeem(ctx: Context<CloseRedeem>) -> Result<()> {
        instructions::redeem::handle_close_redeem(ctx)
    }
}
