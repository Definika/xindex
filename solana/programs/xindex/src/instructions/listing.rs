// SPDX-License-Identifier: BUSL-1.1
//! Listings and approvals. The owner proposes a mint behind `LISTING_DELAY`, anyone executes it within
//! `PROPOSAL_WINDOW`, and the owner or the guardian cancels or delists. A listing reaches only indexes created after it.

use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::spl_token_2022::{
        extension::{
            default_account_state::DefaultAccountState, transfer_hook::TransferHook,
            BaseStateWithExtensions, ExtensionType, StateWithExtensions,
        },
        state::{AccountState, Mint as MintState},
    },
    token_interface::{Mint, TokenInterface},
};

use crate::{
    constants::*,
    error::XindexError,
    events::*,
    pyth::{FEED_MULTIPLIER, FEED_NONE, FEED_TOKEN},
    state::{Config, Creator, Listing},
};

/// Refuses a mint whose accounting an index in kind cannot hold, and returns its decimals:
/// - a transfer fee, which delivers less than is sent;
/// - a permanent delegate, which can move or burn any balance, the vault's included (the WBT rule's power);
/// - a non-transferable mint;
/// - accounts frozen by default, so a new vault could never receive;
/// - a transfer hook with a program set, whose accounts no transfer here passes;
/// - more than `MAX_DECIMALS` decimals.
///
/// A scaled-UI multiplier, an interest-bearing rate, a pause, metadata and confidential transfers pass: none moves a
/// raw balance the vault holds, and the vault never configures a confidential balance.
pub fn check_mint(mint: &AccountInfo, token_program: &Pubkey) -> Result<u8> {
    require_keys_eq!(*mint.owner, *token_program, XindexError::WrongTokenProgram);
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<MintState>::unpack(&data)
        .map_err(|_| error!(XindexError::UnlistableMint))?;
    if *token_program == anchor_spl::token_2022::ID {
        for extension in state
            .get_extension_types()
            .map_err(|_| error!(XindexError::UnlistableMint))?
        {
            match extension {
                ExtensionType::TransferFeeConfig
                | ExtensionType::ConfidentialTransferFeeConfig
                | ExtensionType::PermanentDelegate
                | ExtensionType::NonTransferable => return err!(XindexError::UnlistableMint),
                ExtensionType::TransferHook => {
                    let hook = state
                        .get_extension::<TransferHook>()
                        .map_err(|_| error!(XindexError::UnlistableMint))?;
                    require!(
                        hook.program_id.0.to_bytes() == [0u8; 32],
                        XindexError::UnlistableMint
                    );
                }
                ExtensionType::DefaultAccountState => {
                    let default = state
                        .get_extension::<DefaultAccountState>()
                        .map_err(|_| error!(XindexError::UnlistableMint))?;
                    require!(
                        default.state != AccountState::Frozen as u8,
                        XindexError::UnlistableMint
                    );
                }
                _ => {}
            }
        }
    }
    require!(
        state.base.decimals <= MAX_DECIMALS,
        XindexError::TooManyDecimals
    );
    Ok(state.base.decimals)
}

#[derive(Accounts)]
pub struct ProposeListing<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        init_if_needed,
        payer = owner,
        space = 8 + Listing::INIT_SPACE,
        seeds = [LISTING_SEED, mint.key().as_ref()],
        bump
    )]
    pub listing: Account<'info, Listing>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handle_propose_listing(ctx: Context<ProposeListing>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let listing = &mut ctx.accounts.listing;
    require!(
        listing.eta == 0 || now > listing.eta + PROPOSAL_WINDOW,
        XindexError::ListingPending
    );
    let decimals = check_mint(
        &ctx.accounts.mint.to_account_info(),
        &ctx.accounts.token_program.key(),
    )?;
    listing.mint = ctx.accounts.mint.key();
    listing.token_program = ctx.accounts.token_program.key();
    listing.decimals = decimals;
    listing.eta = now + LISTING_DELAY;
    listing.bump = ctx.bumps.listing;
    emit!(ListingProposed {
        mint: listing.mint,
        decimals,
        eta: listing.eta
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ExecuteListing<'info> {
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(mut, seeds = [LISTING_SEED, mint.key().as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

/// Anyone executes a listing within its window. The mint is checked again, since its authority may have set a
/// transfer hook since the proposal.
pub fn handle_execute_listing(ctx: Context<ExecuteListing>) -> Result<()> {
    let listing = &mut ctx.accounts.listing;
    require!(listing.eta != 0, XindexError::NothingPending);
    let now = Clock::get()?.unix_timestamp;
    require!(now >= listing.eta, XindexError::TooEarly);
    require!(
        now <= listing.eta + PROPOSAL_WINDOW,
        XindexError::ProposalExpired
    );
    check_mint(&ctx.accounts.mint.to_account_info(), &listing.token_program)?;
    listing.listed = true;
    listing.eta = 0;
    emit!(Listed { mint: listing.mint });
    Ok(())
}

#[derive(Accounts)]
pub struct GuardListing<'info> {
    pub signer: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = signer.key() == config.owner || signer.key() == config.guardian @ XindexError::NotOwnerOrGuardian
    )]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [LISTING_SEED, listing.mint.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

pub fn handle_cancel_listing(ctx: Context<GuardListing>) -> Result<()> {
    let listing = &mut ctx.accounts.listing;
    require!(listing.eta != 0, XindexError::NothingPending);
    listing.eta = 0;
    emit!(ListingCancelled { mint: listing.mint });
    Ok(())
}

pub fn handle_delist(ctx: Context<GuardListing>) -> Result<()> {
    let listing = &mut ctx.accounts.listing;
    require!(listing.listed, XindexError::NotListed);
    listing.listed = false;
    emit!(Delisted { mint: listing.mint });
    Ok(())
}

#[derive(Accounts)]
#[instruction(wallet: Pubkey)]
pub struct ApproveCreator<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
    #[account(
        init_if_needed,
        payer = owner,
        space = 8 + Creator::INIT_SPACE,
        seeds = [CREATOR_SEED, wallet.as_ref()],
        bump
    )]
    pub approval: Account<'info, Creator>,
    pub system_program: Program<'info, System>,
}

pub fn handle_approve_creator(ctx: Context<ApproveCreator>, wallet: Pubkey) -> Result<()> {
    let approval = &mut ctx.accounts.approval;
    approval.wallet = wallet;
    approval.bump = ctx.bumps.approval;
    emit!(CreatorApproved {
        wallet,
        approved: true
    });
    Ok(())
}

#[derive(Accounts)]
pub struct RevokeCreator<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
    #[account(mut, close = owner, seeds = [CREATOR_SEED, approval.wallet.as_ref()], bump = approval.bump)]
    pub approval: Account<'info, Creator>,
}

/// Withdraws an approval. It reaches no index that exists: the approval is read only while an index is created.
pub fn handle_revoke_creator(ctx: Context<RevokeCreator>) -> Result<()> {
    emit!(CreatorApproved {
        wallet: ctx.accounts.approval.wallet,
        approved: false
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ProposePriceFeed<'info> {
    pub owner: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [LISTING_SEED, listing.mint.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

/// Proposes Pyth's feed for a listed or proposed mint, executable from `LISTING_DELAY` for `PROPOSAL_WINDOW`. The kind
/// says what the feed prices (`pyth::FEED_*`); `FEED_NONE` with a zero id removes the feed. The id is not asked of
/// anyone: Pyth's receiver knows a feed only once an update of it is posted, and a wrong id can only refuse.
pub fn handle_propose_price_feed(
    ctx: Context<ProposePriceFeed>,
    feed_id: [u8; 32],
    kind: u8,
) -> Result<()> {
    require!(
        matches!(kind, FEED_NONE | FEED_TOKEN | FEED_MULTIPLIER)
            && (kind == FEED_NONE) == (feed_id == [0; 32]),
        XindexError::InvalidPriceFeed
    );
    let now = Clock::get()?.unix_timestamp;
    let listing = &mut ctx.accounts.listing;
    require!(
        listing.feed_eta == 0 || now > listing.feed_eta + PROPOSAL_WINDOW,
        XindexError::PriceFeedPending
    );
    listing.pending_feed_id = feed_id;
    listing.pending_feed_kind = kind;
    listing.feed_eta = now + LISTING_DELAY;
    emit!(PriceFeedProposed {
        mint: listing.mint,
        feed_id,
        kind,
        eta: listing.feed_eta
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ExecutePriceFeed<'info> {
    #[account(mut, seeds = [LISTING_SEED, listing.mint.as_ref()], bump = listing.bump)]
    pub listing: Account<'info, Listing>,
}

/// Anyone sets a proposed feed within its window. It reaches every index's next check, as the EVM factory's record does.
pub fn handle_execute_price_feed(ctx: Context<ExecutePriceFeed>) -> Result<()> {
    let listing = &mut ctx.accounts.listing;
    require!(listing.feed_eta != 0, XindexError::NothingPending);
    let now = Clock::get()?.unix_timestamp;
    require!(now >= listing.feed_eta, XindexError::TooEarly);
    require!(
        now <= listing.feed_eta + PROPOSAL_WINDOW,
        XindexError::ProposalExpired
    );
    listing.feed_id = listing.pending_feed_id;
    listing.feed_kind = listing.pending_feed_kind;
    listing.pending_feed_id = [0; 32];
    listing.pending_feed_kind = FEED_NONE;
    listing.feed_eta = 0;
    emit!(PriceFeedSet {
        mint: listing.mint,
        feed_id: listing.feed_id,
        kind: listing.feed_kind
    });
    Ok(())
}

/// The owner or the guardian cancels a proposed feed.
pub fn handle_cancel_price_feed(ctx: Context<GuardListing>) -> Result<()> {
    let listing = &mut ctx.accounts.listing;
    require!(listing.feed_eta != 0, XindexError::NothingPending);
    listing.feed_eta = 0;
    listing.pending_feed_id = [0; 32];
    listing.pending_feed_kind = FEED_NONE;
    emit!(PriceFeedCancelled { mint: listing.mint });
    Ok(())
}
