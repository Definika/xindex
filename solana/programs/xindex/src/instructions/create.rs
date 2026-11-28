// SPDX-License-Identifier: BUSL-1.1
//! An index is created in three steps, since two hundred legs fit no one transaction: `begin_index` fixes its address
//! from the hash of its terms, `add_legs` adds the legs a few at a time, and `seal_index` checks the whole against the
//! hash and opens it. Only a wallet the owner approved begins and seals one.

use anchor_lang::{prelude::*, system_program};
use anchor_spl::token::{Mint, Token};

use crate::{
    constants::*,
    error::XindexError,
    events::IndexCreated,
    math::{max_units, terms_hash_of},
    state::{split_mut, Index, Leg, LegSpec, Listing},
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
#[instruction(terms_hash: [u8; 32])]
pub struct BeginIndex<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,
    /// CHECK: the creator's approval, read by `require_approved`; its address is fixed by the seeds.
    #[account(seeds = [CREATOR_SEED, creator.key().as_ref()], bump)]
    pub approval: UncheckedAccount<'info>,
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
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn handle_begin_index(
    ctx: Context<BeginIndex>,
    terms_hash: [u8; 32],
    leg_count: u16,
    name: String,
    symbol: String,
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
    let mut index = ctx.accounts.index.load_init()?;
    index.creator = ctx.accounts.creator.key();
    index.terms_hash = terms_hash;
    index.share_mint = ctx.accounts.share_mint.key();
    index.rebalance_nonce = 0;
    index.leg_count = leg_count;
    index.legs_len = 0;
    index.sealed = 0;
    index.bump = ctx.bumps.index;
    index.shares_bump = ctx.bumps.share_mint;
    index.name[..name.len()].copy_from_slice(name.as_bytes());
    index.name_len = name.len() as u8;
    index.symbol[..symbol.len()].copy_from_slice(symbol.as_bytes());
    index.symbol_len = symbol.len() as u8;
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
pub struct SealIndex<'info> {
    pub creator: Signer<'info>,
    /// CHECK: the creator's approval, read again: it is read while the index is created, and creation ends here.
    #[account(seeds = [CREATOR_SEED, creator.key().as_ref()], bump)]
    pub approval: UncheckedAccount<'info>,
    #[account(mut, has_one = creator)]
    pub index: AccountLoader<'info, Index>,
}

/// Opens the index once every leg is in, the weights make 10,000, and the legs hash to the terms its address commits
/// to.
pub fn handle_seal_index(ctx: Context<SealIndex>) -> Result<()> {
    require_approved(&ctx.accounts.approval)?;
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
        terms_hash_of(index.leg_count, legs) == index.terms_hash,
        XindexError::TermsMismatch
    );
    index.sealed = 1;
    emit!(IndexCreated {
        index: key,
        creator: index.creator,
        share_mint: index.share_mint,
        legs: index.leg_count
    });
    Ok(())
}
