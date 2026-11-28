// SPDX-License-Identifier: BUSL-1.1
//! Redeem in kind through a ticket. `redeem` burns the shares and books what each leg owes, rounded down, in one
//! instruction that touches no leg: no frozen, paused or hooked leg can stand between a holder and the exit. `claim` pays
//! a leg out, whole or in part, and `close_redeem` returns the ticket's rent once nothing is owed.

use anchor_lang::prelude::*;
use anchor_spl::{
    token::{self, Burn, Mint as ShareMint, Token, TokenAccount as ShareAccount},
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    constants::*,
    error::XindexError,
    events::{Claimed, Redeemed},
    instructions::issue::{leg_of, pay_out, update_leg},
    math::amount_down,
    state::{split_mut, Index, RedeemTicket},
};

#[derive(Accounts)]
pub struct Redeem<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(mut, token::mint = share_mint, token::authority = owner)]
    pub owner_shares: Account<'info, ShareAccount>,
    #[account(
        init_if_needed,
        payer = owner,
        space = RedeemTicket::space(index.load()?.legs_len as usize),
        seeds = [REDEEM_SEED, index.key().as_ref(), owner.key().as_ref()],
        bump
    )]
    pub ticket: Account<'info, RedeemTicket>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

/// Burns `shares` and books what each leg owes the owner. A second redeem adds to an open ticket.
pub fn handle_redeem(ctx: Context<Redeem>, shares: u64) -> Result<()> {
    require!(shares != 0, XindexError::ZeroShares);
    let info = ctx.accounts.index.to_account_info();
    let mut data = info.try_borrow_mut_data()?;
    let (header, slots) = split_mut(&mut data)?;
    require!(header.sealed == 1, XindexError::NotSealed);
    let legs = &mut slots[..header.legs_len as usize];
    let ticket = &mut ctx.accounts.ticket;
    if ticket.owner == Pubkey::default() {
        ticket.index = ctx.accounts.index.key();
        ticket.owner = ctx.accounts.owner.key();
        ticket.bump = ctx.bumps.ticket;
        ticket.owed = vec![0; legs.len()];
    }
    for (i, leg) in legs.iter_mut().enumerate() {
        let due = amount_down(shares, leg.units)?;
        ticket.owed[i] = ticket.owed[i]
            .checked_add(due)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
        leg.owed = leg
            .owed
            .checked_add(due)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
    }
    drop(data);
    token::burn(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Burn {
                mint: ctx.accounts.share_mint.to_account_info(),
                from: ctx.accounts.owner_shares.to_account_info(),
                authority: ctx.accounts.owner.to_account_info(),
            },
        ),
        shares,
    )?;
    emit!(Redeemed {
        index: ctx.accounts.index.key(),
        owner: ctx.accounts.owner.key(),
        shares
    });
    Ok(())
}

#[derive(Accounts)]
pub struct Claim<'info> {
    pub owner: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [REDEEM_SEED, index.key().as_ref(), owner.key().as_ref()], bump = ticket.bump)]
    pub ticket: Account<'info, RedeemTicket>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = index,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

/// Pays up to `amount` of what leg `leg` owes the owner to `to`, an account the owner names. A part is enough when the
/// vault holds less than is owed, as after an issuer's freeze is lifted on part of it.
pub fn handle_claim(ctx: Context<Claim>, leg: u16, amount: u64) -> Result<()> {
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    let i = leg as usize;
    let pay = amount.min(ctx.accounts.ticket.owed[i]);
    require!(pay != 0, XindexError::NothingOwed);
    ctx.accounts.ticket.owed[i] -= pay;
    update_leg(&ctx.accounts.index, leg, |slot| {
        slot.owed -= pay;
        Ok(())
    })?;
    pay_out(
        &ctx.accounts.index,
        &view,
        &ctx.accounts.vault,
        &ctx.accounts.mint,
        &ctx.accounts.to,
        &ctx.accounts.token_program,
        pay,
    )?;
    emit!(Claimed {
        index: ctx.accounts.index.key(),
        owner: ctx.accounts.owner.key(),
        leg,
        amount: pay,
        to: ctx.accounts.to.key(),
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CloseRedeem<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        mut,
        close = owner,
        seeds = [REDEEM_SEED, index.key().as_ref(), owner.key().as_ref()],
        bump = ticket.bump
    )]
    pub ticket: Account<'info, RedeemTicket>,
}

pub fn handle_close_redeem(ctx: Context<CloseRedeem>) -> Result<()> {
    require!(
        ctx.accounts.ticket.owed.iter().all(|o| *o == 0),
        XindexError::ClaimsOutstanding
    );
    Ok(())
}
