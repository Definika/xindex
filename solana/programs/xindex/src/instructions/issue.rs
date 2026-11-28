// SPDX-License-Identifier: BUSL-1.1
//! Issue in kind through a ticket. `open_issue` records what each leg needs for the shares asked, rounded up; `deposit`
//! moves one leg into the index's vault, several in a transaction; `finalize_issue` mints the shares once every leg is
//! in. Until then `withdraw_deposit` returns a leg and `cancel_issue` closes an empty ticket.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{self, Mint as ShareMint, MintTo, Token, TokenAccount as ShareAccount},
    token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::*,
    error::XindexError,
    events::Issued,
    math::{amount_up, required},
    state::{split, split_mut, Index, IndexSeeds, IssueTicket, Leg},
};

/// The token program a leg's mint belongs to.
pub fn leg_program(leg: &Leg) -> Pubkey {
    if leg.token_2022 == 1 {
        anchor_spl::token_2022::ID
    } else {
        anchor_spl::token::ID
    }
}

/// What a leg instruction needs of its index, copied out of the account so no borrow is held across a call.
pub struct LegView {
    pub leg: Leg,
    pub rebalance_nonce: u64,
    pub seeds: IndexSeeds,
}

/// Leg `leg` of the sealed index `index`, after checking that `mint` and `token_program` are its own.
pub fn leg_of(
    index: &AccountLoader<Index>,
    leg: u16,
    mint: &Pubkey,
    token_program: &Pubkey,
) -> Result<LegView> {
    let info = index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, legs) = split(&data)?;
    require!(header.sealed == 1, XindexError::NotSealed);
    let found = *legs
        .get(leg as usize)
        .ok_or_else(|| error!(XindexError::BadLeg))?;
    require_keys_eq!(*mint, found.mint, XindexError::WrongLegAccount);
    require_keys_eq!(
        *token_program,
        leg_program(&found),
        XindexError::WrongLegAccount
    );
    Ok(LegView {
        leg: found,
        rebalance_nonce: header.rebalance_nonce,
        seeds: header.seeds(),
    })
}

/// Applies `change` to leg `leg` of `index`'s data.
pub fn update_leg(
    index: &AccountLoader<Index>,
    leg: u16,
    change: impl FnOnce(&mut Leg) -> Result<()>,
) -> Result<()> {
    let info = index.to_account_info();
    let mut data = info.try_borrow_mut_data()?;
    let (_, slots) = split_mut(&mut data)?;
    change(&mut slots[leg as usize])
}

/// Sends `amount` of a leg from the index's vault to `to`, signed by the index's address.
pub fn pay_out<'info>(
    index: &AccountLoader<'info, Index>,
    view: &LegView,
    vault: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    to: &InterfaceAccount<'info, TokenAccount>,
    token_program: &Interface<'info, TokenInterface>,
    amount: u64,
) -> Result<()> {
    let seeds = view.seeds.seeds();
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            token_program.key(),
            TransferChecked {
                from: vault.to_account_info(),
                mint: mint.to_account_info(),
                to: to.to_account_info(),
                authority: index.to_account_info(),
            },
            &[&seeds],
        ),
        amount,
        view.leg.decimals,
    )
}

#[derive(Accounts)]
pub struct OpenIssue<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        init,
        payer = owner,
        space = IssueTicket::space(index.load()?.legs_len as usize),
        seeds = [ISSUE_SEED, index.key().as_ref(), owner.key().as_ref()],
        bump
    )]
    pub ticket: Account<'info, IssueTicket>,
    pub system_program: Program<'info, System>,
}

pub fn handle_open_issue(ctx: Context<OpenIssue>, shares: u64) -> Result<()> {
    require!(shares != 0, XindexError::ZeroShares);
    let (need, nonce) = {
        let info = ctx.accounts.index.to_account_info();
        let data = info.try_borrow_data()?;
        let (header, legs) = split(&data)?;
        require!(header.sealed == 1, XindexError::NotSealed);
        let need = legs
            .iter()
            .map(|leg| amount_up(shares, leg.units))
            .collect::<Result<Vec<u64>>>()?;
        (need, header.rebalance_nonce)
    };
    let ticket = &mut ctx.accounts.ticket;
    ticket.index = ctx.accounts.index.key();
    ticket.owner = ctx.accounts.owner.key();
    ticket.shares = shares;
    ticket.rebalance_nonce = nonce;
    ticket.bump = ctx.bumps.ticket;
    ticket.deposited = vec![0; need.len()];
    ticket.need = need;
    Ok(())
}

#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(mut, seeds = [ISSUE_SEED, index.key().as_ref(), owner.key().as_ref()], bump = ticket.bump)]
    pub ticket: Account<'info, IssueTicket>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = mint, token::authority = owner, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(
        init_if_needed,
        payer = owner,
        associated_token::mint = mint,
        associated_token::authority = index,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/// Moves what the ticket still needs of leg `leg` into the index's vault. A vault below what it owes is refused before
/// anything moves (`Underbacked`), so a newcomer's deposit never pays what an issuer left short; and the vault must
/// receive exactly what was sent (`ShortDeposit`).
pub fn handle_deposit(ctx: Context<Deposit>, leg: u16) -> Result<()> {
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    let i = leg as usize;
    let ticket = &ctx.accounts.ticket;
    require!(
        ticket.rebalance_nonce == view.rebalance_nonce,
        XindexError::StaleRebalanceNonce
    );
    let amount = ticket.need[i] - ticket.deposited[i];
    require!(amount != 0, XindexError::NothingToDeposit);
    let before = ctx.accounts.vault.amount;
    require!(
        before as u128 >= required(ctx.accounts.share_mint.supply, &view.leg),
        XindexError::Underbacked
    );

    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            TransferChecked {
                from: ctx.accounts.from.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.vault.to_account_info(),
                authority: ctx.accounts.owner.to_account_info(),
            },
        ),
        amount,
        view.leg.decimals,
    )?;
    ctx.accounts.vault.reload()?;
    let received = ctx
        .accounts
        .vault
        .amount
        .checked_sub(before)
        .ok_or_else(|| error!(XindexError::ShortDeposit))?;
    require!(received == amount, XindexError::ShortDeposit);

    ctx.accounts.ticket.deposited[i] += amount;
    update_leg(&ctx.accounts.index, leg, |slot| {
        slot.pending = slot
            .pending
            .checked_add(amount)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
        Ok(())
    })
}

#[derive(Accounts)]
pub struct WithdrawDeposit<'info> {
    pub owner: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [ISSUE_SEED, index.key().as_ref(), owner.key().as_ref()], bump = ticket.bump)]
    pub ticket: Account<'info, IssueTicket>,
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

/// Returns what the ticket deposited of leg `leg` to `to`, an account the owner names.
pub fn handle_withdraw_deposit(ctx: Context<WithdrawDeposit>, leg: u16) -> Result<()> {
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    let i = leg as usize;
    let amount = ctx.accounts.ticket.deposited[i];
    require!(amount != 0, XindexError::NothingDeposited);
    ctx.accounts.ticket.deposited[i] = 0;
    update_leg(&ctx.accounts.index, leg, |slot| {
        slot.pending -= amount;
        Ok(())
    })?;
    pay_out(
        &ctx.accounts.index,
        &view,
        &ctx.accounts.vault,
        &ctx.accounts.mint,
        &ctx.accounts.to,
        &ctx.accounts.token_program,
        amount,
    )
}

#[derive(Accounts)]
pub struct FinalizeIssue<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(
        mut,
        close = owner,
        seeds = [ISSUE_SEED, index.key().as_ref(), owner.key().as_ref()],
        bump = ticket.bump
    )]
    pub ticket: Account<'info, IssueTicket>,
    #[account(mut, address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(mut, token::mint = share_mint)]
    pub recipient: Account<'info, ShareAccount>,
    pub token_program: Program<'info, Token>,
}

/// Mints the ticket's shares to `recipient` once every leg is deposited, at the rebalance nonce the ticket was opened
/// at. What the ticket deposited becomes the new shares' backing.
pub fn handle_finalize_issue(ctx: Context<FinalizeIssue>) -> Result<()> {
    let ticket = &ctx.accounts.ticket;
    let shares = ticket.shares;
    let seeds = {
        let info = ctx.accounts.index.to_account_info();
        let mut data = info.try_borrow_mut_data()?;
        let (header, slots) = split_mut(&mut data)?;
        require!(header.sealed == 1, XindexError::NotSealed);
        require!(
            ticket.rebalance_nonce == header.rebalance_nonce,
            XindexError::StaleRebalanceNonce
        );
        require!(
            ticket.deposited == ticket.need,
            XindexError::IssueIncomplete
        );
        for (slot, need) in slots[..header.legs_len as usize]
            .iter_mut()
            .zip(ticket.need.iter())
        {
            slot.pending -= need;
        }
        header.seeds()
    };
    let signer = seeds.seeds();
    token::mint_to(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            MintTo {
                mint: ctx.accounts.share_mint.to_account_info(),
                to: ctx.accounts.recipient.to_account_info(),
                authority: ctx.accounts.index.to_account_info(),
            },
            &[&signer],
        ),
        shares,
    )?;
    emit!(Issued {
        index: ctx.accounts.index.key(),
        owner: ctx.accounts.owner.key(),
        recipient: ctx.accounts.recipient.key(),
        shares,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CancelIssue<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        mut,
        close = owner,
        seeds = [ISSUE_SEED, index.key().as_ref(), owner.key().as_ref()],
        bump = ticket.bump
    )]
    pub ticket: Account<'info, IssueTicket>,
}

/// Closes a ticket with nothing deposited, its rent back to the owner.
pub fn handle_cancel_issue(ctx: Context<CancelIssue>) -> Result<()> {
    require!(
        ctx.accounts.ticket.deposited.iter().all(|d| *d == 0),
        XindexError::DepositsOutstanding
    );
    Ok(())
}
