// SPDX-License-Identifier: BUSL-1.1
//! An index is created in four steps, since two hundred legs fit no one transaction: `begin_index` fixes its address
//! from the hash of its terms, `add_legs` adds the legs a few at a time, `price_legs` records Pyth's value of each in
//! the creator's price sheet, and `seal_index` checks the whole against the hash and the weights against the values,
//! and opens it. Only a wallet the owner approved begins and seals one.

use anchor_lang::{prelude::*, system_program};
use anchor_spl::token::{Mint, Token};
use ethnum::U256;

use crate::{
    constants::*,
    error::XindexError,
    events::IndexCreated,
    math::{max_units, terms_hash_of},
    pyth::price_leg,
    settlement::{mul_div, WAD},
    state::{
        split, split_mut, split_sheet, Config, Index, IndexTerms, Leg, LegSpec, Listing, PriceSheet,
    },
};

/// Requires `approval` to be the program's record of `creator`'s approval (its address is checked by seeds).
fn require_approved(approval: &UncheckedAccount) -> Result<()> {
    require!(
        approval.owner == &crate::ID && !approval.data_is_empty(),
        XindexError::CreatorNotApproved
    );
    Ok(())
}

#[derive(Accounts)]
#[instruction(terms_hash: [u8; 32], leg_count: u16)]
pub struct BeginIndex<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,
    /// CHECK: the creator's approval, read by `require_approved`; its address is fixed by the seeds.
    #[account(seeds = [CREATOR_SEED, creator.key().as_ref()], bump)]
    pub approval: UncheckedAccount<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = creator,
        space = Index::space(0),
        seeds = [INDEX_SEED, creator.key().as_ref(), terms_hash.as_ref()],
        bump
    )]
    pub index: AccountLoader<'info, Index>,
    #[account(
        init,
        payer = creator,
        seeds = [SHARES_SEED, index.key().as_ref()],
        bump,
        mint::decimals = SHARE_DECIMALS,
        mint::authority = index,
        mint::token_program = token_program
    )]
    pub share_mint: Account<'info, Mint>,
    /// The creator's price sheet for the seal's check on weights, closed to it at the seal.
    #[account(
        init,
        payer = creator,
        space = PriceSheet::space(leg_count as usize),
        seeds = [SHEET_SEED, index.key().as_ref()],
        bump
    )]
    pub sheet: AccountLoader<'info, PriceSheet>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

/// Begins an index of `leg_count` legs at the address `terms_hash` names. The terms are the creator's rates and the
/// interval, within their bounds, and the platform's rates and referral share as the policy has them now
/// (`PolicyChanged` otherwise): the creator signs for exactly what its index will charge.
#[allow(clippy::too_many_arguments)]
pub fn handle_begin_index(
    ctx: Context<BeginIndex>,
    terms_hash: [u8; 32],
    leg_count: u16,
    name: String,
    symbol: String,
    terms: IndexTerms,
    gated: bool,
) -> Result<()> {
    require_approved(&ctx.accounts.approval)?;
    require!(
        (MIN_COMPONENTS..=MAX_COMPONENTS).contains(&(leg_count as usize)),
        XindexError::BadLegCount
    );
    require!(
        name.len() <= MAX_NAME_LEN && symbol.len() <= MAX_SYMBOL_LEN,
        XindexError::NameTooLong
    );
    require!(
        terms.creator_fee_bps <= MAX_CREATOR_FEE_BPS
            && terms.creator_streaming_bps <= MAX_CREATOR_STREAMING_BPS,
        XindexError::FeeTooHigh
    );
    require!(
        (MIN_REBALANCE_INTERVAL..=MAX_REBALANCE_INTERVAL).contains(&terms.rebalance_interval),
        XindexError::IntervalOutOfRange
    );
    let config = &ctx.accounts.config;
    require!(
        terms.platform_fee_bps == config.platform_fee_bps
            && terms.platform_streaming_bps == config.platform_streaming_bps
            && terms.referral_share_bps == config.referral_share_bps,
        XindexError::PolicyChanged
    );
    let mut index = ctx.accounts.index.load_init()?;
    index.creator = ctx.accounts.creator.key();
    index.creator_role = ctx.accounts.creator.key();
    index.terms_hash = terms_hash;
    index.share_mint = ctx.accounts.share_mint.key();
    index.rebalance_nonce = 0;
    index.scale = SCALE_ONE;
    index.rebalance_interval = terms.rebalance_interval;
    index.creator_fee_bps = terms.creator_fee_bps;
    index.platform_fee_bps = terms.platform_fee_bps;
    index.referral_share_bps = terms.referral_share_bps;
    index.creator_streaming_bps = terms.creator_streaming_bps;
    index.platform_streaming_bps = terms.platform_streaming_bps;
    index.gated = gated as u8;
    index.leg_count = leg_count;
    index.legs_len = 0;
    index.sealed = 0;
    index.bump = ctx.bumps.index;
    index.shares_bump = ctx.bumps.share_mint;
    index.name[..name.len()].copy_from_slice(name.as_bytes());
    index.name_len = name.len() as u8;
    index.symbol[..symbol.len()].copy_from_slice(symbol.as_bytes());
    index.symbol_len = symbol.len() as u8;
    let mut sheet = ctx.accounts.sheet.load_init()?;
    sheet.index = ctx.accounts.index.key();
    sheet.legs = leg_count;
    sheet.bump = ctx.bumps.sheet;
    Ok(())
}

#[derive(Accounts)]
#[instruction(legs: Vec<LegSpec>)]
pub struct AddLegs<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,
    /// Grown by the handler to hold `legs` more, the creator paying its rent.
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    pub system_program: Program<'info, System>,
}

/// Adds `legs`, each with its mint's listing passed in `remaining_accounts` in the same order. A leg must be listed,
/// start within its units' bounds, weigh something, and name a mint no other leg names.
pub fn handle_add_legs<'info>(
    ctx: Context<'info, AddLegs<'info>>,
    legs: Vec<LegSpec>,
) -> Result<()> {
    let (creator, held) = {
        let index = ctx.accounts.index.load()?;
        (index.creator, index.legs_len as usize)
    };
    require_keys_eq!(creator, ctx.accounts.creator.key(), XindexError::NotCreator);
    let info = ctx.accounts.index.to_account_info();
    let space = Index::space(held + legs.len());
    let short = Rent::get()?
        .minimum_balance(space)
        .saturating_sub(info.lamports());
    if short != 0 {
        system_program::transfer(
            CpiContext::new(
                system_program::ID,
                system_program::Transfer {
                    from: ctx.accounts.creator.to_account_info(),
                    to: info.clone(),
                },
            ),
            short,
        )?;
    }
    info.resize(space)?;
    let mut data = info.try_borrow_mut_data()?;
    let (index, slots) = split_mut(&mut data)?;
    require!(index.sealed == 0, XindexError::AlreadySealed);
    require!(
        held + legs.len() <= index.leg_count as usize,
        XindexError::TooManyLegs
    );
    require!(
        ctx.remaining_accounts.len() == legs.len(),
        XindexError::ListingMismatch
    );
    for (k, (spec, listing_info)) in legs.iter().zip(ctx.remaining_accounts.iter()).enumerate() {
        let listing: Account<Listing> =
            Account::try_from(listing_info).map_err(|_| error!(XindexError::ListingMismatch))?;
        let expected = Pubkey::create_program_address(
            &[LISTING_SEED, spec.mint.as_ref(), &[listing.bump]],
            &crate::ID,
        )
        .map_err(|_| error!(XindexError::ListingMismatch))?;
        require_keys_eq!(listing_info.key(), expected, XindexError::ListingMismatch);
        require_keys_eq!(listing.mint, spec.mint, XindexError::ListingMismatch);
        require!(listing.listed, XindexError::NotListed);
        require!(
            spec.units >= MIN_RAW_UNITS && spec.units <= max_units(listing.decimals),
            XindexError::UnitsOutOfBounds
        );
        require!(spec.weight != 0, XindexError::ZeroWeight);
        require!(
            slots[..held + k].iter().all(|leg| leg.mint != spec.mint),
            XindexError::DuplicateLeg
        );
        slots[held + k] = Leg {
            mint: spec.mint,
            units: spec.units,
            owed: 0,
            pending: 0,
            weight: spec.weight,
            token_2022: (listing.token_program == anchor_spl::token_2022::ID) as u8,
            decimals: listing.decimals,
            _reserved: [0; 4],
        };
    }
    index.legs_len = (held + legs.len()) as u16;
    Ok(())
}

#[derive(Accounts)]
pub struct PriceLegs<'info> {
    pub creator: Signer<'info>,
    #[account(has_one = creator)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, seeds = [SHEET_SEED, index.key().as_ref()], bump)]
    pub sheet: AccountLoader<'info, PriceSheet>,
}

/// Records Pyth's value of each leg named, as arriving, in the price sheet; `remaining_accounts` carries, for each in
/// order, its listing, Pyth's price and, for a `Multiplier` feed, its mint (`pyth::price_leg`).
pub fn handle_price_legs<'info>(
    ctx: Context<'info, PriceLegs<'info>>,
    legs: Vec<u16>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let info = ctx.accounts.index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, held) = split(&data)?;
    require!(header.sealed == 0, XindexError::AlreadySealed);
    let sheet_info = ctx.accounts.sheet.to_account_info();
    let mut sheet_data = sheet_info.try_borrow_mut_data()?;
    let (_, prices) = split_sheet(&mut sheet_data)?;
    let mut at = 0;
    for leg in legs {
        let found = held
            .get(leg as usize)
            .ok_or_else(|| error!(XindexError::BadLeg))?;
        let (value, publish_time) = price_leg(ctx.remaining_accounts, &mut at, found, false, now)?;
        prices[leg as usize].set(value, publish_time);
    }
    require!(
        at == ctx.remaining_accounts.len(),
        XindexError::ListingMismatch
    );
    Ok(())
}

#[derive(Accounts)]
pub struct SealIndex<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,
    /// CHECK: the creator's approval, read again: it is read while the index is created, and creation ends here.
    #[account(seeds = [CREATOR_SEED, creator.key().as_ref()], bump)]
    pub approval: UncheckedAccount<'info>,
    #[account(mut, has_one = creator)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, close = creator, seeds = [SHEET_SEED, index.key().as_ref()], bump)]
    pub sheet: AccountLoader<'info, PriceSheet>,
}

/// Opens the index once every leg is in, the weights make 10,000, the legs hash to the terms its address commits to,
/// and, at Pyth's prices of the last `MAX_CREATION_PRICE_AGE` seconds, every leg's share of the index's value lies
/// within `MAX_WEIGHT_DEVIATION` of its weight, relative to the weight (`OffWeights`): an index starts on its weights.
pub fn handle_seal_index(ctx: Context<SealIndex>) -> Result<()> {
    require_approved(&ctx.accounts.approval)?;
    let now = Clock::get()?.unix_timestamp;
    let key = ctx.accounts.index.key();
    let info = ctx.accounts.index.to_account_info();
    let mut data = info.try_borrow_mut_data()?;
    let (index, slots) = split_mut(&mut data)?;
    require!(index.sealed == 0, XindexError::AlreadySealed);
    require!(index.legs_len == index.leg_count, XindexError::LegsMissing);
    let legs = &slots[..index.legs_len as usize];
    let weights: u32 = legs.iter().map(|leg| leg.weight as u32).sum();
    require!(weights == TOTAL_WEIGHT, XindexError::WeightsNotWhole);
    require!(
        terms_hash_of(index.leg_count, &index.terms(), legs) == index.terms_hash,
        XindexError::TermsMismatch
    );
    let sheet_info = ctx.accounts.sheet.to_account_info();
    let mut sheet_data = sheet_info.try_borrow_mut_data()?;
    let (_, prices) = split_sheet(&mut sheet_data)?;
    check_on_weights(legs, prices, now)?;
    index.sealed = 1;
    index.last_rebalance = now;
    index.last_accrual = now;
    emit!(IndexCreated {
        index: key,
        creator: index.creator,
        share_mint: index.share_mint,
        legs: index.leg_count
    });
    Ok(())
}

/// Each leg's share of the index's value at its recorded price lies within `MAX_WEIGHT_DEVIATION` of its weight,
/// relative to the weight, every price no older than `MAX_CREATION_PRICE_AGE`. Exact in integers: a value is under
/// 2^128 and units under 2^60, so the sums and products fit 256 bits; the allowance rounds down, against the creator.
pub fn check_on_weights(legs: &[Leg], prices: &[crate::state::PricedLeg], now: i64) -> Result<()> {
    let worth = |k: usize| U256::from(prices[k].value()) * U256::from(legs[k].units);
    let mut total = U256::ZERO;
    for (k, price) in prices.iter().enumerate().take(legs.len()) {
        require!(price.publish_time != 0, XindexError::PriceMissing);
        require!(
            price.publish_time >= now - MAX_CREATION_PRICE_AGE,
            XindexError::StalePrice
        );
        total += worth(k);
    }
    for (k, leg) in legs.iter().enumerate() {
        let share = worth(k) * U256::from(TOTAL_WEIGHT);
        let target = U256::from(leg.weight) * total;
        let gap = if share > target {
            share - target
        } else {
            target - share
        };
        let allowance = mul_div(target, MAX_WEIGHT_DEVIATION, WAD, false)
            .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
        if gap > allowance {
            msg!("leg {} is off its weight of {}", k, leg.weight);
            return err!(XindexError::OffWeights);
        }
    }
    Ok(())
}
