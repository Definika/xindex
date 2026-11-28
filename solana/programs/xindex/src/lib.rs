// SPDX-License-Identifier: BUSL-1.1
//! Xindex on Solana: index tokens backed in kind (`docs/design/solana.md`). An index's every share is backed by units of
//! each of its legs, held in the index's own vaults. Wallets the owner approves create indexes, on their weights at
//! Pyth's prices; anyone issues and redeems in kind; fees are shares; and an index rebalances toward its weights through
//! an auction judged on units, which Pyth's prices and a quote can only refuse. Paths that touch every leg run over
//! several transactions, through tickets.
#![allow(unexpected_cfgs)]

pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod math;
pub mod pyth;
pub mod settlement;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("9oUHUMboV1WHQunh4zQVV7RwGSNzQqYcFWoSXTfbAjWT");

#[program]
pub mod xindex {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        owner: Pubkey,
        guardian: Pubkey,
        usdc: Pubkey,
        usdt: Pubkey,
    ) -> Result<()> {
        instructions::config::handle_initialize(ctx, owner, guardian, usdc, usdt)
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

    pub fn propose_price_feed(
        ctx: Context<ProposePriceFeed>,
        feed_id: [u8; 32],
        kind: u8,
    ) -> Result<()> {
        instructions::listing::handle_propose_price_feed(ctx, feed_id, kind)
    }

    pub fn execute_price_feed(ctx: Context<ExecutePriceFeed>) -> Result<()> {
        instructions::listing::handle_execute_price_feed(ctx)
    }

    pub fn cancel_price_feed(ctx: Context<GuardListing>) -> Result<()> {
        instructions::listing::handle_cancel_price_feed(ctx)
    }

    pub fn set_fee_policy(
        ctx: Context<SetFeePolicy>,
        platform_fee_bps: u16,
        platform_streaming_bps: u16,
        referral_share_bps: u16,
        recipient: Pubkey,
    ) -> Result<()> {
        instructions::fees::handle_set_fee_policy(
            ctx,
            platform_fee_bps,
            platform_streaming_bps,
            referral_share_bps,
            recipient,
        )
    }

    pub fn set_mint_pause(ctx: Context<PauseIndex>, paused: bool) -> Result<()> {
        instructions::fees::handle_set_mint_pause(ctx, paused)
    }

    pub fn set_mint_pause_all(ctx: Context<PauseAll>, paused: bool) -> Result<()> {
        instructions::fees::handle_set_mint_pause_all(ctx, paused)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn begin_index(
        ctx: Context<BeginIndex>,
        terms_hash: [u8; 32],
        leg_count: u16,
        name: String,
        symbol: String,
        terms: IndexTerms,
        gated: bool,
    ) -> Result<()> {
        instructions::create::handle_begin_index(
            ctx, terms_hash, leg_count, name, symbol, terms, gated,
        )
    }

    pub fn add_legs<'info>(ctx: Context<'info, AddLegs<'info>>, legs: Vec<LegSpec>) -> Result<()> {
        instructions::create::handle_add_legs(ctx, legs)
    }

    pub fn price_legs<'info>(ctx: Context<'info, PriceLegs<'info>>, legs: Vec<u16>) -> Result<()> {
        instructions::create::handle_price_legs(ctx, legs)
    }

    pub fn seal_index(ctx: Context<SealIndex>) -> Result<()> {
        instructions::create::handle_seal_index(ctx)
    }

    pub fn accrue_fees(ctx: Context<AccrueFees>) -> Result<()> {
        instructions::fees::handle_accrue_fees(ctx)
    }

    pub fn transfer_creator(ctx: Context<CreatorOnly>, pending: Pubkey) -> Result<()> {
        instructions::fees::handle_transfer_creator(ctx, pending)
    }

    pub fn accept_creator(ctx: Context<AcceptCreator>) -> Result<()> {
        instructions::fees::handle_accept_creator(ctx)
    }

    pub fn open_minting(ctx: Context<CreatorOnly>) -> Result<()> {
        instructions::fees::handle_open_minting(ctx)
    }

    pub fn allow_minter(ctx: Context<AllowMinter>, wallet: Pubkey) -> Result<()> {
        instructions::fees::handle_allow_minter(ctx, wallet)
    }

    pub fn disallow_minter(ctx: Context<DisallowMinter>) -> Result<()> {
        instructions::fees::handle_disallow_minter(ctx)
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

    pub fn start_rebalance(ctx: Context<StartRebalance>, keep_mask: [u64; 4]) -> Result<()> {
        instructions::rebalance::handle_start_rebalance(ctx, keep_mask)
    }

    pub fn start_quoted_rebalance(
        ctx: Context<StartQuotedRebalance>,
        keep_mask: [u64; 4],
        tolerance: u64,
    ) -> Result<()> {
        instructions::rebalance::handle_start_quoted_rebalance(ctx, keep_mask, tolerance)
    }

    pub fn write_quote(ctx: Context<WriteQuote>, offset: u16, prices: Vec<u128>) -> Result<()> {
        instructions::rebalance::handle_write_quote(ctx, offset, prices)
    }

    pub fn cancel_rebalance(ctx: Context<CancelRebalance>, proposal_id: Option<u64>) -> Result<()> {
        instructions::rebalance::handle_cancel_rebalance(ctx, proposal_id)
    }

    pub fn open_fill(ctx: Context<OpenFill>) -> Result<()> {
        instructions::fill::handle_open_fill(ctx)
    }

    pub fn set_fill_units(ctx: Context<EditFill>, offset: u16, units: Vec<u64>) -> Result<()> {
        instructions::fill::handle_set_fill_units(ctx, offset, units)
    }

    pub fn price_fill<'info>(ctx: Context<'info, EditFill<'info>>, legs: Vec<u16>) -> Result<()> {
        instructions::fill::handle_price_fill(ctx, legs)
    }

    pub fn deposit_fill(ctx: Context<DepositFill>, leg: u16, amount: u64) -> Result<()> {
        instructions::fill::handle_deposit_fill(ctx, leg, amount)
    }

    pub fn withdraw_fill(ctx: Context<WithdrawFill>, leg: u16) -> Result<()> {
        instructions::fill::handle_withdraw_fill(ctx, leg)
    }

    pub fn commit_fill(ctx: Context<CommitFill>) -> Result<()> {
        instructions::fill::handle_commit_fill(ctx)
    }

    pub fn close_fill(ctx: Context<CloseFill>) -> Result<()> {
        instructions::fill::handle_close_fill(ctx)
    }

    pub fn propose_weights(ctx: Context<ProposeWeights>, weights: Vec<u16>) -> Result<()> {
        instructions::weights::handle_propose_weights(ctx, weights)
    }

    pub fn cancel_weights(ctx: Context<CancelWeights>) -> Result<()> {
        instructions::weights::handle_cancel_weights(ctx)
    }

    pub fn execute_weights(ctx: Context<ExecuteWeights>) -> Result<()> {
        instructions::weights::handle_execute_weights(ctx)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_request(
        ctx: Context<OpenRequest>,
        id: u64,
        kind: u8,
        amount: u64,
        min_out: u64,
        deadline: i64,
        expected_nonce: Option<u64>,
    ) -> Result<()> {
        instructions::requests::handle_open_request(
            ctx,
            id,
            kind,
            amount,
            min_out,
            deadline,
            expected_nonce,
        )
    }

    pub fn fill_request(
        ctx: Context<FillRequest>,
        amount: u64,
        expected: Option<[u8; 32]>,
    ) -> Result<()> {
        instructions::requests::handle_fill_request(ctx, amount, expected)
    }

    pub fn close_request(ctx: Context<CloseRequest>) -> Result<()> {
        instructions::requests::handle_close_request(ctx)
    }
}
