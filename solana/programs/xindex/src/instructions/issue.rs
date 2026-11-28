// SPDX-License-Identifier: BUSL-1.1
//! Issue in kind through a ticket. `open_issue` records what each leg needs for the shares asked and the fee's shares
//! on top, rounded up; `deposit` moves one leg into the index's vault, several in a transaction; `finalize_issue` mints
//! the shares to the recipient and the fee's to its recipients once every leg is in. Until then `withdraw_deposit`
//! returns a leg and `cancel_issue` closes an empty ticket. The three steps that let new shares in read the mint pause;
//! the two that return a deposit never do.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{Mint as ShareMint, Token, TokenAccount as ShareAccount},
    token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::*,
    error::XindexError,
    events::{FeeSharesMinted, Issued},
    instructions::fees::{
        accrue, check_recipients, fee_view, may_receive, mint_fee_shares, mint_shares,
        require_minting, Recipients,
    },
    math::{backing, gross_shares, part_of, pending_accrual, required},
    state::{split, split_mut, Config, Index, IndexSeeds, IssueTicket, Leg, Minter},
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
    pub scale: u64,
    pub mint_paused: bool,
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
        scale: header.scale,
        mint_paused: header.mint_paused == 1,
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

/// Moves `amount` of a leg from `from`, which `authority` owns, into the index's vault, after checking the vault holds
/// what it owes (`Underbacked`, so a newcomer's deposit never pays what an issuer left short), and requires the vault to
/// receive exactly that (`ShortDeposit`). Shared by an issue's deposit and a fill's.
#[allow(clippy::too_many_arguments)]
pub fn deposit_into<'info>(
    view: &LegView,
    supply: u64,
    from: &InterfaceAccount<'info, TokenAccount>,
    vault: &mut InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    authority: &Signer<'info>,
    token_program: &Interface<'info, TokenInterface>,
    amount: u64,
) -> Result<()> {
    let before = vault.amount;
    require!(
        before as u128 >= required(supply, &view.leg, view.scale),
        XindexError::Underbacked
    );
    token_interface::transfer_checked(
        CpiContext::new(
            token_program.key(),
            TransferChecked {
                from: from.to_account_info(),
                mint: mint.to_account_info(),
                to: vault.to_account_info(),
                authority: authority.to_account_info(),
            },
        ),
        amount,
        view.leg.decimals,
    )?;
    vault.reload()?;
    let received = vault
        .amount
        .checked_sub(before)
        .ok_or_else(|| error!(XindexError::ShortDeposit))?;
    require!(received == amount, XindexError::ShortDeposit);
    Ok(())
}

#[derive(Accounts)]
pub struct OpenIssue<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
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

/// Opens a ticket for `shares` to the recipient the finalize names, sized for those and the fee's shares at the scale
/// an accrual now would leave, which is at least the one the finalize meets: the few seconds' difference over-backs,
/// and stays with the holders.
pub fn handle_open_issue(ctx: Context<OpenIssue>, shares: u64) -> Result<()> {
    require!(shares != 0, XindexError::ZeroShares);
    let now = Clock::get()?.unix_timestamp;
    let (gross, need, nonce) = {
        let info = ctx.accounts.index.to_account_info();
        let data = info.try_borrow_data()?;
        let (header, legs) = split(&data)?;
        require!(header.sealed == 1, XindexError::NotSealed);
        require_minting(&ctx.accounts.config, header)?;
        let gross = gross_shares(shares, header.fee_bps())?;
        let (scale, _) = pending_accrual(
            header.streaming_bps(),
            header.scale,
            ctx.accounts.share_mint.supply,
            header.last_accrual,
            now,
        );
        let need = legs
            .iter()
            .map(|leg| backing(gross, leg.units, scale, true))
            .collect::<Result<Vec<u64>>>()?;
        (gross, need, header.rebalance_nonce)
    };
    let ticket = &mut ctx.accounts.ticket;
    ticket.index = ctx.accounts.index.key();
    ticket.owner = ctx.accounts.owner.key();
    ticket.shares = shares;
    ticket.gross = gross;
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
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
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

/// Moves what the ticket still needs of leg `leg` into the index's vault.
pub fn handle_deposit(ctx: Context<Deposit>, leg: u16) -> Result<()> {
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    require!(
        !ctx.accounts.config.mint_paused_all && !view.mint_paused,
        XindexError::MintingPaused
    );
    let i = leg as usize;
    let ticket = &ctx.accounts.ticket;
    require!(
        ticket.rebalance_nonce == view.rebalance_nonce,
        XindexError::StaleRebalanceNonce
    );
    let amount = ticket.need[i] - ticket.deposited[i];
    require!(amount != 0, XindexError::NothingToDeposit);
    deposit_into(
        &view,
        ctx.accounts.share_mint.supply,
        &ctx.accounts.from,
        &mut ctx.accounts.vault,
        &ctx.accounts.mint,
        &ctx.accounts.owner,
        &ctx.accounts.token_program,
        amount,
    )?;
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
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub creator_shares: Account<'info, ShareAccount>,
    #[account(mut)]
    pub platform_shares: Option<Account<'info, ShareAccount>>,
    /// A referrer's share account: the referrer is its owner, named nobody if a gate would refuse it (AU-1).
    #[account(mut, token::mint = share_mint)]
    pub referrer_shares: Option<Account<'info, ShareAccount>>,
    /// The gate's record that the recipient's owner may receive, for a gated index.
    pub recipient_allowance: Option<Account<'info, Minter>>,
    /// The gate's record for the referrer.
    pub referrer_allowance: Option<Account<'info, Minter>>,
    pub token_program: Program<'info, Token>,
}

/// Mints the ticket's shares to `recipient` and the fee's shares to its recipients, once every leg is deposited, at
/// the rebalance nonce the ticket was opened at. What the ticket deposited becomes the new shares' backing. The
/// streaming fee is accrued first.
pub fn handle_finalize_issue(ctx: Context<FinalizeIssue>) -> Result<()> {
    let key = ctx.accounts.index.key();
    let (view, seeds) = fee_view(&ctx.accounts.index)?;
    let recipients = Recipients {
        creator: &ctx.accounts.creator_shares,
        platform: ctx.accounts.platform_shares.as_ref(),
    };
    check_recipients(&view, &ctx.accounts.config, &recipients)?;
    let to = ctx.accounts.recipient.owner;
    require!(
        may_receive(&key, &view, &to, ctx.accounts.recipient_allowance.as_ref()),
        XindexError::NotAllowedMinter
    );
    let referrer = ctx.accounts.referrer_shares.as_ref().filter(|account| {
        may_receive(
            &key,
            &view,
            &account.owner,
            ctx.accounts.referrer_allowance.as_ref(),
        )
    });
    let now = Clock::get()?.unix_timestamp;
    accrue(
        &ctx.accounts.index,
        &mut ctx.accounts.share_mint,
        &recipients,
        &ctx.accounts.token_program,
        now,
    )?;
    let ticket = &ctx.accounts.ticket;
    let (shares, gross) = (ticket.shares, ticket.gross);
    {
        let info = ctx.accounts.index.to_account_info();
        let mut data = info.try_borrow_mut_data()?;
        let (header, slots) = split_mut(&mut data)?;
        require_minting(&ctx.accounts.config, header)?;
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
    }
    let index_info = ctx.accounts.index.to_account_info();
    mint_shares(
        &ctx.accounts.token_program,
        &ctx.accounts.share_mint,
        &index_info,
        &seeds,
        &ctx.accounts.recipient.to_account_info(),
        shares,
    )?;
    let fee = gross - shares;
    let (creator_shares, platform_shares, referrer_shares) = mint_fee_shares(
        &ctx.accounts.token_program,
        &ctx.accounts.share_mint,
        &index_info,
        &seeds,
        &recipients,
        referrer,
        view.referral_share_bps,
        fee,
        part_of(fee, view.platform_fee_bps, view.creator_fee_bps),
    )?;
    emit!(Issued {
        index: key,
        owner: ctx.accounts.owner.key(),
        recipient: ctx.accounts.recipient.key(),
        shares,
    });
    if fee != 0 {
        emit!(FeeSharesMinted {
            index: key,
            creator_shares,
            platform_shares,
            referrer_shares,
        });
    }
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
