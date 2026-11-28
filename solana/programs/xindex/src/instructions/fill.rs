// SPDX-License-Identifier: BUSL-1.1
//! A fill of a rebalance, over several transactions, through a ticket: the executor names the units, prices the legs
//! that move, deposits what the growing legs will need, and only then commits, after which it claims what the index
//! sold it (`docs/design/solana.md`, section 8.3).
//!
//! - The commit touches no leg and reads no balance. Before it, a fill's deposits are `pending` in their legs, as an
//!   issue's are; at it, what a growing leg needs leaves `pending` for the backing, and what a shrinking leg gives
//!   leaves the backing for `owed`. So the invariant holds with the new units at every step.
//! - The units are judged first, on units alone (`settlement`): every leg inside its caps as it is named, and the gain
//!   at or above the bar at the commit. The quote, if the proposal has one, and Pyth's prices can then only refuse.
//! - Two hundred legs' arithmetic fits no one instruction, so each step keeps the commit's sums exact as it goes:
//!   naming a leg's units moves the ticket's weighted score by that leg's change in score, and pricing a leg adds its
//!   value to the value in or out. The commit sums nothing; it reads the sums, the bar and the prices' ages.
//! - An executor is untrusted: what it is paid it is paid only after the commit, and only from what it is owed.

use anchor_lang::prelude::*;
use anchor_spl::{
    token::{Mint as ShareMint, Token, TokenAccount as ShareAccount},
    token_interface::{Mint, TokenAccount, TokenInterface},
};
use ethnum::U256;

use crate::{
    constants::*,
    error::XindexError,
    events::{FillOpened, FillPaid, Rebalanced},
    instructions::{
        fees::{accrue, check_recipients, fee_view, Recipients},
        issue::{deposit_into, leg_of, pay_out, update_leg},
    },
    math::backing_wide,
    pyth::price_leg,
    settlement::{
        bar_at, floor_div, floor_of, leg_score, leg_value, oracle_tolerance_at, value_floor,
        LegMove, Refusal, TOTAL_WEIGHT,
    },
    state::{
        split, split_fill, split_mut, wide, words, Config, FillLeg, FillTicket, Index, Leg, Quote,
    },
};

/// What leg `i` adds to the ticket's weighted score at `next` units, refused outside its caps.
fn score_at(index: &Index, i: usize, leg: &Leg, next: u64) -> Result<i128> {
    let m = LegMove {
        current: U256::from(leg.units),
        next: U256::from(next),
        weight: leg.weight,
        kept: index.keeps(i),
    };
    leg_score(i, m, U256::from(u64::MAX)).map_err(refused)
}

/// Takes the value a priced leg adds to the ticket's sums back out of them, and forgets its price.
fn unprice(ticket: &mut FillTicket, leg: &Leg, slot: &mut FillLeg) {
    if slot.price.publish_time == 0 {
        return;
    }
    let (worth, leaving) = leg_value(
        U256::from(leg.units),
        U256::from(slot.new_units),
        slot.price.value(),
    );
    if leaving {
        ticket.value_out = words(wide(&ticket.value_out) - worth);
    } else {
        ticket.value_in = words(wide(&ticket.value_in) - worth);
    }
    slot.price = Default::default();
}

#[derive(Accounts)]
pub struct OpenFill<'info> {
    #[account(mut)]
    pub executor: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        init,
        payer = executor,
        space = FillTicket::space(index.load()?.legs_len as usize),
        seeds = [FILL_SEED, index.key().as_ref(), executor.key().as_ref()],
        bump
    )]
    pub ticket: AccountLoader<'info, FillTicket>,
    pub system_program: Program<'info, System>,
}

/// Opens a ticket for the pending proposal, during its notice or its auction, with every leg at its units.
pub fn handle_open_fill(ctx: Context<OpenFill>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let key = ctx.accounts.index.key();
    let executor = ctx.accounts.executor.key();
    let info = ctx.accounts.index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, legs) = split(&data)?;
    require!(header.sealed == 1, XindexError::NotSealed);
    require!(header.eta != 0, XindexError::NoPendingRebalance);
    require!(
        now <= header.eta + AUCTION_DURATION,
        XindexError::RebalanceExpired
    );
    {
        let mut ticket = ctx.accounts.ticket.load_init()?;
        ticket.index = key;
        ticket.executor = executor;
        ticket.proposal_id = header.proposal_count;
        ticket.rebalance_nonce = header.rebalance_nonce;
        ticket.legs = header.legs_len;
        ticket.bump = ctx.bumps.ticket;
    }
    let ticket_info = ctx.accounts.ticket.to_account_info();
    let mut ticket_data = ticket_info.try_borrow_mut_data()?;
    let (_, fill) = split_fill(&mut ticket_data)?;
    for (slot, leg) in fill.iter_mut().zip(legs) {
        slot.new_units = leg.units;
    }
    emit!(FillOpened {
        index: key,
        executor,
        proposal_id: header.proposal_count,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct EditFill<'info> {
    pub executor: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [FILL_SEED, index.key().as_ref(), executor.key().as_ref()], bump)]
    pub ticket: AccountLoader<'info, FillTicket>,
}

/// Requires the ticket to be open for the index's pending proposal at its current nonce.
fn require_live(ticket: &FillTicket, index: &Index) -> Result<()> {
    require!(ticket.committed == 0, XindexError::FillCommitted);
    require!(
        index.eta != 0
            && ticket.proposal_id == index.proposal_count
            && ticket.rebalance_nonce == index.rebalance_nonce,
        XindexError::StaleFill
    );
    Ok(())
}

/// Names new units from leg `offset` on, each refused outside its caps (`LegOutOfBounds`, `UnitsOverflow`). A leg whose
/// units change loses the price recorded for it, since a price leans by the leg's direction.
pub fn handle_set_fill_units(ctx: Context<EditFill>, offset: u16, units: Vec<u64>) -> Result<()> {
    let info = ctx.accounts.index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, legs) = split(&data)?;
    let ticket_info = ctx.accounts.ticket.to_account_info();
    let mut ticket_data = ticket_info.try_borrow_mut_data()?;
    let (ticket, fill) = split_fill(&mut ticket_data)?;
    require_live(ticket, header)?;
    let start = offset as usize;
    require!(
        start + units.len() <= fill.len(),
        XindexError::LengthMismatch
    );
    let mut score = ticket.score();
    for (k, next) in units.into_iter().enumerate() {
        let i = start + k;
        let (leg, slot) = (&legs[i], &mut fill[i]);
        if slot.new_units == next {
            continue;
        }
        let added = score_at(header, i, leg, next)?;
        score += added - score_at(header, i, leg, slot.new_units)?;
        unprice(ticket, leg, slot);
        slot.new_units = next;
    }
    ticket.set_score(score);
    Ok(())
}

/// Records Pyth's value of each leg named that moves, leaning against the executor by the leg's direction, and adds it
/// to the ticket's value in or out; `remaining_accounts` carries, for each in order, its listing, Pyth's price and, for
/// a `Multiplier` feed, its mint.
pub fn handle_price_fill<'info>(
    ctx: Context<'info, EditFill<'info>>,
    legs: Vec<u16>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let info = ctx.accounts.index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, held) = split(&data)?;
    let ticket_info = ctx.accounts.ticket.to_account_info();
    let mut ticket_data = ticket_info.try_borrow_mut_data()?;
    let (ticket, fill) = split_fill(&mut ticket_data)?;
    require_live(ticket, header)?;
    let mut at = 0;
    for leg in legs {
        let i = leg as usize;
        let current = held.get(i).ok_or_else(|| error!(XindexError::BadLeg))?;
        let slot = &mut fill[i];
        let next = slot.new_units;
        if next == current.units {
            continue;
        }
        let (value, publish_time) = price_leg(
            ctx.remaining_accounts,
            &mut at,
            current,
            next < current.units,
            now,
        )?;
        unprice(ticket, current, slot);
        slot.price.set(value, publish_time);
        let (worth, leaving) = leg_value(U256::from(current.units), U256::from(next), value);
        if leaving {
            ticket.value_out = words(wide(&ticket.value_out) + worth);
        } else {
            ticket.value_in = words(wide(&ticket.value_in) + worth);
        }
    }
    require!(
        at == ctx.remaining_accounts.len(),
        XindexError::ListingMismatch
    );
    Ok(())
}

#[derive(Accounts)]
pub struct DepositFill<'info> {
    pub executor: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(mut, seeds = [FILL_SEED, index.key().as_ref(), executor.key().as_ref()], bump)]
    pub ticket: AccountLoader<'info, FillTicket>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = mint, token::authority = executor, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = index,
        associated_token::token_program = token_program
    )]
    pub vault: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

/// Deposits `amount` of leg `leg` toward what the commit will need of it, as an issue's deposit: refused into a vault
/// below what it owes (`Underbacked`), and only what the vault received counts (`ShortDeposit`).
pub fn handle_deposit_fill(ctx: Context<DepositFill>, leg: u16, amount: u64) -> Result<()> {
    require!(amount != 0, XindexError::NothingToDeposit);
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    {
        let info = ctx.accounts.index.to_account_info();
        let data = info.try_borrow_data()?;
        let (header, _) = split(&data)?;
        let ticket = ctx.accounts.ticket.load()?;
        require_live(&ticket, header)?;
    }
    deposit_into(
        &view,
        ctx.accounts.share_mint.supply,
        &ctx.accounts.from,
        &mut ctx.accounts.vault,
        &ctx.accounts.mint,
        &ctx.accounts.executor,
        &ctx.accounts.token_program,
        amount,
    )?;
    {
        let ticket_info = ctx.accounts.ticket.to_account_info();
        let mut ticket_data = ticket_info.try_borrow_mut_data()?;
        let (_, fill) = split_fill(&mut ticket_data)?;
        let slot = &mut fill[leg as usize];
        slot.deposited = slot
            .deposited
            .checked_add(amount)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
    }
    update_leg(&ctx.accounts.index, leg, |slot| {
        slot.pending = slot
            .pending
            .checked_add(amount)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
        Ok(())
    })
}

#[derive(Accounts)]
pub struct WithdrawFill<'info> {
    pub executor: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [FILL_SEED, index.key().as_ref(), executor.key().as_ref()], bump)]
    pub ticket: AccountLoader<'info, FillTicket>,
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

/// Pays the executor what leg `leg` holds for it: its deposit, whole before the commit and what the commit did not
/// need after it, and, after the commit, what the leg gave out. Open at any time, so no deposit is ever stranded.
pub fn handle_withdraw_fill(ctx: Context<WithdrawFill>, leg: u16) -> Result<()> {
    let view = leg_of(
        &ctx.accounts.index,
        leg,
        &ctx.accounts.mint.key(),
        &ctx.accounts.token_program.key(),
    )?;
    let (refund, bought) = {
        let ticket_info = ctx.accounts.ticket.to_account_info();
        let mut ticket_data = ticket_info.try_borrow_mut_data()?;
        let (_, fill) = split_fill(&mut ticket_data)?;
        let slot = fill
            .get_mut(leg as usize)
            .ok_or_else(|| error!(XindexError::BadLeg))?;
        let owed = (slot.deposited, slot.settled);
        slot.deposited = 0;
        slot.settled = 0;
        owed
    };
    let amount = refund + bought;
    require!(amount != 0, XindexError::NothingOwed);
    update_leg(&ctx.accounts.index, leg, |slot| {
        slot.pending -= refund;
        slot.owed -= bought;
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
    )?;
    emit!(FillPaid {
        index: ctx.accounts.index.key(),
        executor: ctx.accounts.executor.key(),
        leg,
        amount,
        to: ctx.accounts.to.key(),
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CommitFill<'info> {
    pub executor: Signer<'info>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [FILL_SEED, index.key().as_ref(), executor.key().as_ref()], bump)]
    pub ticket: AccountLoader<'info, FillTicket>,
    #[account(mut, address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub creator_shares: Account<'info, ShareAccount>,
    #[account(mut)]
    pub platform_shares: Option<Account<'info, ShareAccount>>,
    /// The index's quote, required when it binds this proposal.
    #[account(seeds = [QUOTE_SEED, index.key().as_ref()], bump = quote.bump)]
    pub quote: Option<Account<'info, Quote>>,
    pub token_program: Program<'info, Token>,
}

/// Maps the arithmetic's refusal to the program's error, with its fields in the log.
fn refused(refusal: Refusal) -> Error {
    msg!("{:?}", refusal);
    match refusal {
        Refusal::AuctionOver => error!(XindexError::RebalanceExpired),
        Refusal::LengthMismatch => error!(XindexError::LengthMismatch),
        Refusal::NothingToRebalance => error!(XindexError::NothingToRebalance),
        Refusal::LegOutOfBounds { .. } => error!(XindexError::LegOutOfBounds),
        Refusal::UnitsOverflow { .. } => error!(XindexError::UnitsOverflow),
        Refusal::GainBelowBar { .. } => error!(XindexError::GainBelowBar),
    }
}

/// Settles the fill: accrues the streaming fee, judges the units against the caps and the bar, checks the quote that
/// binds the proposal and Pyth's prices of the last `MAX_PRICE_AGE` seconds, requires every growing leg's deposit to
/// cover its amount at the supply now (`RebalanceMovedOn`), and writes the new units, booking what each shrinking leg
/// gives out as owed to the executor.
pub fn handle_commit_fill(ctx: Context<CommitFill>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let key = ctx.accounts.index.key();
    let (view, _) = fee_view(&ctx.accounts.index)?;
    let recipients = Recipients {
        creator: &ctx.accounts.creator_shares,
        platform: ctx.accounts.platform_shares.as_ref(),
    };
    check_recipients(&view, &ctx.accounts.config, &recipients)?;
    {
        let index = ctx.accounts.index.load()?;
        let ticket = ctx.accounts.ticket.load()?;
        require_live(&ticket, &index)?;
        require!(now >= index.eta, XindexError::RebalanceNotReady);
        require!(
            now <= index.eta + AUCTION_DURATION,
            XindexError::RebalanceExpired
        );
    }
    accrue(
        &ctx.accounts.index,
        &mut ctx.accounts.share_mint,
        &recipients,
        &ctx.accounts.token_program,
        now,
    )?;
    let supply = ctx.accounts.share_mint.supply;
    let info = ctx.accounts.index.to_account_info();
    let mut data = info.try_borrow_mut_data()?;
    let (index, slots) = split_mut(&mut data)?;
    let n = index.legs_len as usize;
    let legs = &mut slots[..n];
    let ticket_info = ctx.accounts.ticket.to_account_info();
    let mut ticket_data = ticket_info.try_borrow_mut_data()?;
    let (ticket, fill) = split_fill(&mut ticket_data)?;
    let elapsed = (now - index.eta) as u64;

    // the units, on units alone: each leg was held to its caps as it was named, and the gain is the sum of their scores
    require!(
        supply as u128 >= SHARE_UNIT,
        XindexError::NothingToRebalance
    );
    let bar = bar_at(elapsed).ok_or_else(|| refused(Refusal::AuctionOver))?;
    let gain = floor_div(ticket.score(), TOTAL_WEIGHT);
    if gain < bar as i128 {
        return Err(refused(Refusal::GainBelowBar { gain, bar }));
    }

    // the quote, which can only refuse
    if index.quote_proposal == ticket.proposal_id {
        let quote = ctx
            .accounts
            .quote
            .as_ref()
            .ok_or_else(|| error!(XindexError::InvalidQuote))?;
        require!(
            quote.proposal == ticket.proposal_id && quote.prices.len() == n,
            XindexError::InvalidQuote
        );
        let moves = (0..n).map(|i| {
            (
                U256::from(legs[i].units),
                U256::from(fill[i].new_units),
                quote.prices[i],
            )
        });
        let (value_in, floor) = value_floor(moves, index.quote_tolerance as u128);
        if value_in < floor {
            msg!("value in {}, floor {}", value_in, floor);
            return err!(XindexError::BelowQuote);
        }
    }

    // Pyth's prices, which can only refuse: every moving leg priced in the last MAX_PRICE_AGE seconds
    for (leg, slot) in legs.iter().zip(fill.iter()) {
        if slot.new_units == leg.units {
            continue;
        }
        require!(slot.price.publish_time != 0, XindexError::PriceMissing);
        require!(
            slot.price.publish_time >= now - MAX_PRICE_AGE,
            XindexError::StalePrice
        );
    }
    let tolerance = oracle_tolerance_at(elapsed).ok_or_else(|| refused(Refusal::AuctionOver))?;
    let (value_in, floor) = (
        wide(&ticket.value_in),
        floor_of(wide(&ticket.value_out), tolerance),
    );
    if value_in < floor {
        msg!("value in {}, floor {}", value_in, floor);
        return err!(XindexError::BelowOracleValue);
    }

    // the amounts, at the supply now, and the new units
    let scale = index.scale;
    for (leg, slot) in legs.iter_mut().zip(fill.iter_mut()) {
        let next = slot.new_units;
        if next == leg.units {
            continue;
        }
        let amount = |delta: u64, up: bool| {
            backing_wide(supply, delta, scale, up)
                .and_then(|a| u64::try_from(a).ok())
                .ok_or_else(|| error!(XindexError::AmountTooLarge))
        };
        if next > leg.units {
            let need = amount(next - leg.units, true)?;
            require!(slot.deposited >= need, XindexError::RebalanceMovedOn);
            slot.deposited -= need;
            leg.pending -= need;
        } else {
            let out = amount(leg.units - next, false)?;
            slot.settled = out;
            leg.owed = leg
                .owed
                .checked_add(out)
                .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
        }
        leg.units = next;
    }
    index.masked_fill = index.keep_mask.iter().any(|word| *word != 0) as u8;
    index.rebalance_nonce += 1;
    index.last_rebalance = now;
    index.eta = 0;
    index.keep_mask = [0; MASK_WORDS];
    ticket.committed = 1;
    emit!(Rebalanced {
        index: key,
        proposal_id: ticket.proposal_id,
        rebalance_nonce: index.rebalance_nonce,
        executor: ctx.accounts.executor.key(),
        bar: bar as u64,
        gain: gain as i64,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CloseFill<'info> {
    #[account(mut)]
    pub executor: Signer<'info>,
    #[account(
        mut,
        close = executor,
        seeds = [FILL_SEED, ticket.load()?.index.as_ref(), executor.key().as_ref()],
        bump
    )]
    pub ticket: AccountLoader<'info, FillTicket>,
}

/// Closes a ticket that holds nothing for the executor, its rent back to it.
pub fn handle_close_fill(ctx: Context<CloseFill>) -> Result<()> {
    let ticket_info = ctx.accounts.ticket.to_account_info();
    let mut ticket_data = ticket_info.try_borrow_mut_data()?;
    let (_, fill) = split_fill(&mut ticket_data)?;
    require!(
        fill.iter()
            .all(|slot| slot.deposited == 0 && slot.settled == 0),
        XindexError::FillOutstanding
    );
    Ok(())
}
