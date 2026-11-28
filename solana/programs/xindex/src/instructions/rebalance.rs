// SPDX-License-Identifier: BUSL-1.1
//! Starting and cancelling a rebalance, and the quote the owner or the guardian may post with a start: the EVM hub's
//! clock, rule for rule (`docs/design/solana.md`, section 8.3).
//!
//! - Anyone starts once the index's interval has passed since the last fill; a fill under a keep mask restarts only
//!   `MIN_REBALANCE_INTERVAL` (XS-3), and the owner or the guardian may start `MIN_REBALANCE_INTERVAL` after any fill,
//!   never before the first (RW-3).
//! - A keep mask, and a start before strangers may after a cancel or an expiry, are the owner's or the guardian's.
//! - A cancel holds strangers off for `REBALANCE_DELAY`, so the owner and the guardian get the first restart.

use anchor_lang::prelude::*;

use crate::{
    constants::*,
    error::XindexError,
    events::{RebalanceCancelled, RebalanceQuoted, RebalanceStarted},
    settlement::WAD,
    state::{mask_bit, split, Config, Index, Quote},
};

/// Whether `signer` is the owner or the guardian.
pub fn is_owner_or_guardian(config: &Config, signer: &Pubkey) -> bool {
    *signer == config.owner || (*signer == config.guardian && *signer != Pubkey::default())
}

/// The earliest time anyone, not only the owner or the guardian, may start: after a cancel, `restart_allowed_at`; after
/// an auction that expired unfilled, its end plus `REBALANCE_DELAY`.
fn permissionless_at(index: &Index) -> i64 {
    let after_expiry = if index.eta == 0 {
        0
    } else {
        index.eta + AUCTION_DURATION + REBALANCE_DELAY
    };
    index.restart_allowed_at.max(after_expiry)
}

/// Starts a rebalance for `caller` under the clock and the keep mask's rules, and returns its id.
fn start(
    index: &mut Index,
    config: &Config,
    caller: &Pubkey,
    keep_mask: [u64; MASK_WORDS],
    now: i64,
) -> Result<u64> {
    require!(index.sealed == 1, XindexError::NotSealed);
    let privileged = is_owner_or_guardian(config, caller);
    let mut earliest = index.last_rebalance
        + if index.masked_fill == 1 {
            MIN_REBALANCE_INTERVAL
        } else {
            index.rebalance_interval
        };
    if now < earliest && index.rebalance_nonce != 0 && privileged {
        earliest = index.last_rebalance + MIN_REBALANCE_INTERVAL;
    }
    require!(now >= earliest, XindexError::RebalanceTooSoon);
    require!(
        index.eta == 0 || now > index.eta + AUCTION_DURATION,
        XindexError::RebalancePending
    );
    let n = index.legs_len as usize;
    let kept = (0..64 * MASK_WORDS)
        .filter(|leg| mask_bit(&keep_mask, *leg))
        .count();
    let beyond = (n..64 * MASK_WORDS).any(|leg| mask_bit(&keep_mask, leg));
    require!(
        !beyond && n - kept >= MIN_COMPONENTS,
        XindexError::InvalidKeepMask
    );
    let masked = keep_mask.iter().any(|word| *word != 0);
    require!(
        !(masked || now < permissionless_at(index)) || privileged,
        XindexError::Unauthorized
    );
    index.eta = now + REBALANCE_DELAY;
    index.keep_mask = keep_mask;
    index.proposal_count += 1;
    Ok(index.proposal_count)
}

#[derive(Accounts)]
pub struct StartRebalance<'info> {
    pub caller: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
}

/// Starts a rebalance; the auction opens `REBALANCE_DELAY` later and runs `AUCTION_DURATION`.
pub fn handle_start_rebalance(
    ctx: Context<StartRebalance>,
    keep_mask: [u64; MASK_WORDS],
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let mut index = ctx.accounts.index.load_mut()?;
    let caller = ctx.accounts.caller.key();
    let id = start(&mut index, &ctx.accounts.config, &caller, keep_mask, now)?;
    emit!(RebalanceStarted {
        index: ctx.accounts.index.key(),
        proposal_id: id,
        caller,
        keep_mask,
        eta: index.eta,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct StartQuotedRebalance<'info> {
    pub caller: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [QUOTE_SEED, index.key().as_ref()], bump = quote.bump)]
    pub quote: Account<'info, Quote>,
}

/// The owner or the guardian starts a rebalance with the quote it wrote: a fill of this proposal must then also bring
/// in, at the quote's prices, at least `1 − tolerance` of what it takes out. Every leg not kept needs a price; a kept
/// one's is ignored. The quote binds this proposal alone.
pub fn handle_start_quoted_rebalance(
    ctx: Context<StartQuotedRebalance>,
    keep_mask: [u64; MASK_WORDS],
    tolerance: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    let caller = ctx.accounts.caller.key();
    require!(
        is_owner_or_guardian(config, &caller),
        XindexError::Unauthorized
    );
    require!((tolerance as u128) < WAD, XindexError::InvalidQuote);
    let now = Clock::get()?.unix_timestamp;
    let mut index = ctx.accounts.index.load_mut()?;
    let quote = &mut ctx.accounts.quote;
    let n = index.legs_len as usize;
    require!(quote.prices.len() == n, XindexError::InvalidQuote);
    for (leg, price) in quote.prices.iter_mut().enumerate() {
        if mask_bit(&keep_mask, leg) {
            *price = 0;
        } else {
            require!(*price != 0, XindexError::InvalidQuote);
        }
    }
    let id = start(&mut index, config, &caller, keep_mask, now)?;
    quote.proposal = id;
    index.quote_proposal = id;
    index.quote_tolerance = tolerance;
    let key = ctx.accounts.index.key();
    emit!(RebalanceStarted {
        index: key,
        proposal_id: id,
        caller,
        keep_mask,
        eta: index.eta,
    });
    emit!(RebalanceQuoted {
        index: key,
        proposal_id: id,
        tolerance,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct WriteQuote<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        init_if_needed,
        payer = caller,
        space = Quote::space(index.load()?.legs_len as usize),
        seeds = [QUOTE_SEED, index.key().as_ref()],
        bump
    )]
    pub quote: Account<'info, Quote>,
    pub system_program: Program<'info, System>,
}

/// The owner or the guardian writes the quote's prices from leg `offset` on. A quote that binds a live proposal is
/// never written (`QuoteBound`), so no quote changes under the fills it judges.
pub fn handle_write_quote(ctx: Context<WriteQuote>, offset: u16, prices: Vec<u128>) -> Result<()> {
    require!(
        is_owner_or_guardian(&ctx.accounts.config, &ctx.accounts.caller.key()),
        XindexError::Unauthorized
    );
    let now = Clock::get()?.unix_timestamp;
    let (n, live) = {
        let info = ctx.accounts.index.to_account_info();
        let data = info.try_borrow_data()?;
        let (header, _) = split(&data)?;
        require!(header.sealed == 1, XindexError::NotSealed);
        let live = header.eta != 0
            && now <= header.eta + AUCTION_DURATION
            && ctx.accounts.quote.proposal == header.proposal_count
            && header.quote_proposal == header.proposal_count;
        (header.legs_len as usize, live)
    };
    require!(!live, XindexError::QuoteBound);
    let quote = &mut ctx.accounts.quote;
    if quote.index == Pubkey::default() {
        quote.index = ctx.accounts.index.key();
        quote.bump = ctx.bumps.quote;
        quote.prices = vec![0; n];
    }
    let start = offset as usize;
    require!(
        start + prices.len() <= quote.prices.len(),
        XindexError::LengthMismatch
    );
    quote.prices[start..start + prices.len()].copy_from_slice(&prices);
    Ok(())
}

#[derive(Accounts)]
pub struct CancelRebalance<'info> {
    pub caller: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
}

/// The owner or the guardian cancels the pending rebalance: `proposal_id` names the one its signers read, and the
/// cancel refuses another (`StaleProposal`, CA-S02); None cancels whichever is pending. Strangers may start again
/// `REBALANCE_DELAY` later; an auction that already expired keeps the hold its expiry set (VR-04).
pub fn handle_cancel_rebalance(
    ctx: Context<CancelRebalance>,
    proposal_id: Option<u64>,
) -> Result<()> {
    let caller = ctx.accounts.caller.key();
    require!(
        is_owner_or_guardian(&ctx.accounts.config, &caller),
        XindexError::Unauthorized
    );
    let now = Clock::get()?.unix_timestamp;
    let mut index = ctx.accounts.index.load_mut()?;
    require!(index.eta != 0, XindexError::NoPendingRebalance);
    if let Some(id) = proposal_id {
        require!(id == index.proposal_count, XindexError::StaleProposal);
    }
    let restart_at = if now <= index.eta + AUCTION_DURATION {
        now + REBALANCE_DELAY
    } else {
        permissionless_at(&index)
    };
    index.eta = 0;
    index.keep_mask = [0; MASK_WORDS];
    index.restart_allowed_at = restart_at;
    emit!(RebalanceCancelled {
        index: ctx.accounts.index.key(),
        proposal_id: index.proposal_count,
        caller,
        restart_allowed_at: restart_at,
    });
    Ok(())
}
