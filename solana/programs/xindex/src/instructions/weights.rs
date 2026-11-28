// SPDX-License-Identifier: BUSL-1.1
//! A change of an index's weights behind a notice: the creator role proposes new weights for the coins the index holds,
//! anyone applies them from `WEIGHTS_DELAY` within `PROPOSAL_WINDOW`, never during a live rebalance, and the creator
//! role, the owner or the guardian cancels. Nothing moves at the change: the next rebalance moves the units, under the
//! bar, the caps and Pyth's check, which bounds what the change's distance from the units can yield per fill.

use anchor_lang::prelude::*;

use crate::{
    constants::*,
    error::XindexError,
    events::{WeightsCancelled, WeightsChanged, WeightsProposed},
    instructions::rebalance::is_owner_or_guardian,
    state::{split_mut, Config, Index, PendingWeights},
};

#[derive(Accounts)]
pub struct ProposeWeights<'info> {
    #[account(mut)]
    pub creator_role: Signer<'info>,
    #[account(has_one = creator_role @ XindexError::NotCreator)]
    pub index: AccountLoader<'info, Index>,
    #[account(
        init_if_needed,
        payer = creator_role,
        space = PendingWeights::space(index.load()?.legs_len as usize),
        seeds = [WEIGHTS_SEED, index.key().as_ref()],
        bump
    )]
    pub weights: Account<'info, PendingWeights>,
    pub system_program: Program<'info, System>,
}

/// Proposes `weights`, one per leg in order, each at least one basis point and 10,000 in all. A proposal replaces the
/// one pending. A weight of zero is refused: such a leg would earn nothing in the units' check, so only a price would
/// guard it.
pub fn handle_propose_weights(ctx: Context<ProposeWeights>, weights: Vec<u16>) -> Result<()> {
    let index = ctx.accounts.index.load()?;
    require!(index.sealed == 1, XindexError::NotSealed);
    require!(
        weights.len() == index.legs_len as usize
            && weights.iter().all(|w| *w != 0 && *w as u32 <= TOTAL_WEIGHT)
            && weights.iter().map(|w| *w as u32).sum::<u32>() == TOTAL_WEIGHT,
        XindexError::InvalidWeights
    );
    let eta = Clock::get()?.unix_timestamp + WEIGHTS_DELAY;
    let pending = &mut ctx.accounts.weights;
    pending.index = ctx.accounts.index.key();
    pending.eta = eta;
    pending.bump = ctx.bumps.weights;
    pending.weights = weights.clone();
    emit!(WeightsProposed {
        index: pending.index,
        weights,
        eta,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CancelWeights<'info> {
    pub signer: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [WEIGHTS_SEED, index.key().as_ref()], bump = weights.bump)]
    pub weights: Account<'info, PendingWeights>,
}

/// The creator role, the owner or the guardian cancels a pending change.
pub fn handle_cancel_weights(ctx: Context<CancelWeights>) -> Result<()> {
    let signer = ctx.accounts.signer.key();
    let creator_role = ctx.accounts.index.load()?.creator_role;
    require!(
        signer == creator_role || is_owner_or_guardian(&ctx.accounts.config, &signer),
        XindexError::Unauthorized
    );
    require!(ctx.accounts.weights.eta != 0, XindexError::NoPendingWeights);
    ctx.accounts.weights.eta = 0;
    emit!(WeightsCancelled {
        index: ctx.accounts.index.key()
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ExecuteWeights<'info> {
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [WEIGHTS_SEED, index.key().as_ref()], bump = weights.bump)]
    pub weights: Account<'info, PendingWeights>,
}

/// Anyone applies a pending change within its window, unless a rebalance is pending and not expired
/// (`RebalancePending`): no proposal is judged against weights its start did not see.
pub fn handle_execute_weights(ctx: Context<ExecuteWeights>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let pending = &mut ctx.accounts.weights;
    require!(pending.eta != 0, XindexError::NoPendingWeights);
    require!(now >= pending.eta, XindexError::WeightsNotReady);
    require!(
        now <= pending.eta + PROPOSAL_WINDOW,
        XindexError::WeightsExpired
    );
    let info = ctx.accounts.index.to_account_info();
    let mut data = info.try_borrow_mut_data()?;
    let (index, slots) = split_mut(&mut data)?;
    require!(
        index.eta == 0 || now > index.eta + AUCTION_DURATION,
        XindexError::RebalancePending
    );
    let legs = &mut slots[..index.legs_len as usize];
    require!(
        pending.weights.len() == legs.len(),
        XindexError::InvalidWeights
    );
    for (leg, weight) in legs.iter_mut().zip(pending.weights.iter()) {
        leg.weight = *weight;
    }
    pending.eta = 0;
    emit!(WeightsChanged {
        index: ctx.accounts.index.key(),
        weights: pending.weights.clone(),
    });
    Ok(())
}
