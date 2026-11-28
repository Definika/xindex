// SPDX-License-Identifier: BUSL-1.1
//! Fees in shares, the creator role, the gate and the mint pause (`docs/design/solana.md`, section 8.1).
//!
//! - Fees are shares, never legs. An issue's deposit backs the fee's shares on top of its own; a redeem's fee is minted
//!   to the recipients out of the shares it burns; the streaming fee is a unit scale, every accrual minting the fee
//!   owed since the last and shrinking the scale by as much.
//! - The recipients are share accounts at the ATA program's address for the creator role and the platform's
//!   recipient, read at each call. A platform recipient left at the default key folds its part into the creator's.
//! - The mint pause stops new shares and nothing else: no withdrawal, cancel, redeem, claim or rebalance reads it.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::get_associated_token_address,
    token::{self, Mint as ShareMint, MintTo, Token, TokenAccount as ShareAccount},
};

use crate::{
    constants::*,
    error::XindexError,
    events::*,
    math::{part_of, pending_accrual},
    state::{split, split_mut, Config, Index, IndexSeeds, Minter, PendingWeights},
};

/// The accounts every call that may mint fee shares passes: the share accounts of the creator role and, unless the
/// policy names nobody, of the platform's recipient.
pub struct Recipients<'a, 'info> {
    pub creator: &'a Account<'info, ShareAccount>,
    pub platform: Option<&'a Account<'info, ShareAccount>>,
}

/// What a fee needs of an index, copied out so no borrow of its data is held across a call.
#[derive(Clone, Copy)]
pub struct FeeView {
    pub creator_role: Pubkey,
    pub share_mint: Pubkey,
    pub gated: bool,
    pub creator_fee_bps: u16,
    pub platform_fee_bps: u16,
    pub referral_share_bps: u16,
    pub creator_streaming_bps: u16,
    pub platform_streaming_bps: u16,
}

pub fn fee_view(index: &AccountLoader<Index>) -> Result<(FeeView, IndexSeeds)> {
    let info = index.to_account_info();
    let data = info.try_borrow_data()?;
    let (header, _) = split(&data)?;
    require!(header.sealed == 1, XindexError::NotSealed);
    Ok((
        FeeView {
            creator_role: header.creator_role,
            share_mint: header.share_mint,
            gated: header.gated == 1,
            creator_fee_bps: header.creator_fee_bps,
            platform_fee_bps: header.platform_fee_bps,
            referral_share_bps: header.referral_share_bps,
            creator_streaming_bps: header.creator_streaming_bps,
            platform_streaming_bps: header.platform_streaming_bps,
        },
        header.seeds(),
    ))
}

/// Requires the recipients' accounts to be the ones the ATA program gives the creator role and the platform's
/// recipient for the share mint, and the platform's to be passed exactly when the policy names a recipient.
pub fn check_recipients(view: &FeeView, config: &Config, recipients: &Recipients) -> Result<()> {
    require_keys_eq!(
        recipients.creator.key(),
        get_associated_token_address(&view.creator_role, &view.share_mint),
        XindexError::WrongFeeAccount
    );
    match recipients.platform {
        Some(account) => require_keys_eq!(
            account.key(),
            get_associated_token_address(&config.platform_recipient, &view.share_mint),
            XindexError::WrongFeeAccount
        ),
        None => require_keys_eq!(
            config.platform_recipient,
            Pubkey::default(),
            XindexError::WrongFeeAccount
        ),
    }
    if recipients.platform.is_some() {
        require!(
            config.platform_recipient != Pubkey::default(),
            XindexError::WrongFeeAccount
        );
    }
    Ok(())
}

/// Mints `amount` shares to `to`, signed by the index's address.
pub fn mint_shares<'info>(
    token_program: &Program<'info, Token>,
    share_mint: &Account<'info, ShareMint>,
    index: &AccountInfo<'info>,
    seeds: &IndexSeeds,
    to: &AccountInfo<'info>,
    amount: u64,
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }
    let signer = seeds.seeds();
    token::mint_to(
        CpiContext::new_with_signer(
            token_program.key(),
            MintTo {
                mint: share_mint.to_account_info(),
                to: to.clone(),
                authority: index.clone(),
            },
            &[&signer],
        ),
        amount,
    )
}

/// Mints `fee_shares` to the recipients: `platform_part` to the platform, less a referrer's share of it (rounded down)
/// when a referrer is named, and the rest to the creator role. Returns what each got.
#[allow(clippy::too_many_arguments)]
pub fn mint_fee_shares<'info>(
    token_program: &Program<'info, Token>,
    share_mint: &Account<'info, ShareMint>,
    index: &AccountInfo<'info>,
    seeds: &IndexSeeds,
    recipients: &Recipients<'_, 'info>,
    referrer: Option<&Account<'info, ShareAccount>>,
    referral_share_bps: u16,
    fee_shares: u64,
    platform_part: u64,
) -> Result<(u64, u64, u64)> {
    if fee_shares == 0 {
        return Ok((0, 0, 0));
    }
    let mut platform = match recipients.platform {
        Some(_) => platform_part,
        None => 0,
    };
    let referred = match referrer {
        Some(_) => (platform as u128 * referral_share_bps as u128 / BPS) as u64,
        None => 0,
    };
    platform -= referred;
    let creator = fee_shares - platform - referred;
    mint_shares(
        token_program,
        share_mint,
        index,
        seeds,
        &recipients.creator.to_account_info(),
        creator,
    )?;
    if let Some(account) = recipients.platform {
        mint_shares(
            token_program,
            share_mint,
            index,
            seeds,
            &account.to_account_info(),
            platform,
        )?;
    }
    if let Some(account) = referrer {
        mint_shares(
            token_program,
            share_mint,
            index,
            seeds,
            &account.to_account_info(),
            referred,
        )?;
    }
    Ok((creator, platform, referred))
}

/// Accrues the streaming fee: mints what is owed since the last accrual to the recipients, split by the two rates, and
/// shrinks the scale. The clock restarts even when nothing is owed (XS-1). The share mint is reloaded after.
pub fn accrue<'info>(
    index: &AccountLoader<'info, Index>,
    share_mint: &mut Account<'info, ShareMint>,
    recipients: &Recipients<'_, 'info>,
    token_program: &Program<'info, Token>,
    now: i64,
) -> Result<()> {
    let info = index.to_account_info();
    let (fee, platform_part, seeds, scale) = {
        let mut data = info.try_borrow_mut_data()?;
        let (header, _) = split_mut(&mut data)?;
        let rate = header.streaming_bps();
        if rate == 0 {
            return Ok(());
        }
        let (scale, fee) = pending_accrual(
            rate,
            header.scale,
            share_mint.supply,
            header.last_accrual,
            now,
        );
        header.last_accrual = now;
        if fee == 0 {
            return Ok(());
        }
        header.scale = scale;
        (
            fee,
            part_of(
                fee,
                header.platform_streaming_bps,
                header.creator_streaming_bps,
            ),
            header.seeds(),
            scale,
        )
    };
    emit!(StreamingFeeAccrued {
        index: index.key(),
        fee_shares: fee,
        scale,
    });
    mint_fee_shares(
        token_program,
        share_mint,
        &info,
        &seeds,
        recipients,
        None,
        0,
        fee,
        platform_part,
    )?;
    share_mint.reload()
}

/// Whether `wallet` may receive `index`'s new shares: any wallet while the index is open, else its creator role and the
/// wallets it allows, `allowance` being the program's record of the allowance if one was passed.
pub fn may_receive(
    index: &Pubkey,
    view: &FeeView,
    wallet: &Pubkey,
    allowance: Option<&Account<Minter>>,
) -> bool {
    if !view.gated || *wallet == view.creator_role {
        return true;
    }
    allowance.is_some_and(|a| a.index == *index && a.wallet == *wallet)
}

#[derive(Accounts)]
pub struct AccrueFees<'info> {
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub creator_shares: Account<'info, ShareAccount>,
    #[account(mut)]
    pub platform_shares: Option<Account<'info, ShareAccount>>,
    pub token_program: Program<'info, Token>,
}

/// Anyone accrues an index's streaming fee.
pub fn handle_accrue_fees(ctx: Context<AccrueFees>) -> Result<()> {
    let (view, _) = fee_view(&ctx.accounts.index)?;
    let recipients = Recipients {
        creator: &ctx.accounts.creator_shares,
        platform: ctx.accounts.platform_shares.as_ref(),
    };
    check_recipients(&view, &ctx.accounts.config, &recipients)?;
    let now = Clock::get()?.unix_timestamp;
    accrue(
        &ctx.accounts.index,
        &mut ctx.accounts.share_mint,
        &recipients,
        &ctx.accounts.token_program,
        now,
    )
}

#[derive(Accounts)]
pub struct CreatorOnly<'info> {
    pub creator_role: Signer<'info>,
    #[account(mut, has_one = creator_role @ XindexError::NotCreator)]
    pub index: AccountLoader<'info, Index>,
}

/// Offers the creator role to `pending`, which takes it with `accept_creator`. The default key withdraws an offer.
pub fn handle_transfer_creator(ctx: Context<CreatorOnly>, pending: Pubkey) -> Result<()> {
    let mut index = ctx.accounts.index.load_mut()?;
    index.pending_creator = pending;
    emit!(CreatorTransferStarted {
        index: ctx.accounts.index.key(),
        creator: index.creator_role,
        pending,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptCreator<'info> {
    pub pending_creator: Signer<'info>,
    #[account(mut, has_one = pending_creator @ XindexError::NotPendingCreator)]
    pub index: AccountLoader<'info, Index>,
    #[account(mut, address = index.load()?.share_mint @ XindexError::WrongLegAccount)]
    pub share_mint: Account<'info, ShareMint>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub creator_shares: Account<'info, ShareAccount>,
    #[account(mut)]
    pub platform_shares: Option<Account<'info, ShareAccount>>,
    /// The index's proposed weights, if any were ever proposed: a pending change goes with the role (HK-16).
    #[account(mut, seeds = [WEIGHTS_SEED, index.key().as_ref()], bump = weights.bump)]
    pub weights: Option<Account<'info, PendingWeights>>,
    pub token_program: Program<'info, Token>,
}

/// Hands the role over: the streaming fee is accrued to the outgoing holder first (RW-6), and a pending change of
/// weights is cancelled, so no creator's proposal takes effect under the next (HK-16).
pub fn handle_accept_creator(ctx: Context<AcceptCreator>) -> Result<()> {
    let (view, _) = fee_view(&ctx.accounts.index)?;
    let recipients = Recipients {
        creator: &ctx.accounts.creator_shares,
        platform: ctx.accounts.platform_shares.as_ref(),
    };
    check_recipients(&view, &ctx.accounts.config, &recipients)?;
    let now = Clock::get()?.unix_timestamp;
    accrue(
        &ctx.accounts.index,
        &mut ctx.accounts.share_mint,
        &recipients,
        &ctx.accounts.token_program,
        now,
    )?;
    if let Some(weights) = ctx.accounts.weights.as_mut() {
        if weights.eta != 0 {
            weights.eta = 0;
            emit!(WeightsCancelled {
                index: ctx.accounts.index.key()
            });
        }
    }
    let mut index = ctx.accounts.index.load_mut()?;
    let previous = index.creator_role;
    index.creator_role = index.pending_creator;
    index.pending_creator = Pubkey::default();
    emit!(CreatorTransferred {
        index: ctx.accounts.index.key(),
        previous,
        creator: index.creator_role,
    });
    Ok(())
}

/// Opens a gated index for good.
pub fn handle_open_minting(ctx: Context<CreatorOnly>) -> Result<()> {
    let mut index = ctx.accounts.index.load_mut()?;
    require!(index.gated == 1, XindexError::NotGated);
    index.gated = 0;
    emit!(MintingOpened {
        index: ctx.accounts.index.key()
    });
    Ok(())
}

#[derive(Accounts)]
#[instruction(wallet: Pubkey)]
pub struct AllowMinter<'info> {
    #[account(mut)]
    pub creator_role: Signer<'info>,
    #[account(has_one = creator_role @ XindexError::NotCreator)]
    pub index: AccountLoader<'info, Index>,
    #[account(
        init_if_needed,
        payer = creator_role,
        space = 8 + Minter::INIT_SPACE,
        seeds = [MINTER_SEED, index.key().as_ref(), wallet.as_ref()],
        bump
    )]
    pub allowance: Account<'info, Minter>,
    pub system_program: Program<'info, System>,
}

/// Allows `wallet` to receive a gated index's new shares.
pub fn handle_allow_minter(ctx: Context<AllowMinter>, wallet: Pubkey) -> Result<()> {
    let allowance = &mut ctx.accounts.allowance;
    allowance.index = ctx.accounts.index.key();
    allowance.wallet = wallet;
    allowance.bump = ctx.bumps.allowance;
    emit!(MinterAllowed {
        index: allowance.index,
        wallet,
        allowed: true,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct DisallowMinter<'info> {
    #[account(mut)]
    pub creator_role: Signer<'info>,
    #[account(has_one = creator_role @ XindexError::NotCreator)]
    pub index: AccountLoader<'info, Index>,
    #[account(
        mut,
        close = creator_role,
        seeds = [MINTER_SEED, index.key().as_ref(), allowance.wallet.as_ref()],
        bump = allowance.bump
    )]
    pub allowance: Account<'info, Minter>,
}

pub fn handle_disallow_minter(ctx: Context<DisallowMinter>) -> Result<()> {
    emit!(MinterAllowed {
        index: ctx.accounts.allowance.index,
        wallet: ctx.accounts.allowance.wallet,
        allowed: false,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct SetFeePolicy<'info> {
    pub owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = owner @ XindexError::NotOwner)]
    pub config: Account<'info, Config>,
}

/// Sets the platform's policy for indexes created from now on: its two rates, a referrer's part, and the recipient,
/// which is read at every fee. A rate needs a recipient to go to.
pub fn handle_set_fee_policy(
    ctx: Context<SetFeePolicy>,
    platform_fee_bps: u16,
    platform_streaming_bps: u16,
    referral_share_bps: u16,
    recipient: Pubkey,
) -> Result<()> {
    require!(
        platform_fee_bps <= MAX_PLATFORM_FEE_BPS
            && platform_streaming_bps <= MAX_PLATFORM_STREAMING_BPS
            && referral_share_bps as u128 <= BPS
            && (recipient != Pubkey::default()
                || platform_fee_bps == 0 && platform_streaming_bps == 0),
        XindexError::InvalidFeePolicy
    );
    let config = &mut ctx.accounts.config;
    config.platform_fee_bps = platform_fee_bps;
    config.platform_streaming_bps = platform_streaming_bps;
    config.referral_share_bps = referral_share_bps;
    config.platform_recipient = recipient;
    emit!(FeePolicySet {
        platform_fee_bps,
        platform_streaming_bps,
        referral_share_bps,
        recipient,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct PauseIndex<'info> {
    pub signer: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub index: AccountLoader<'info, Index>,
}

/// The owner or the guardian pauses an index's minting; only the owner lifts it.
pub fn handle_set_mint_pause(ctx: Context<PauseIndex>, paused: bool) -> Result<()> {
    let config = &ctx.accounts.config;
    let signer = ctx.accounts.signer.key();
    require!(
        signer == config.owner
            || (paused && signer == config.guardian && signer != Pubkey::default()),
        XindexError::NotOwnerOrGuardian
    );
    let mut index = ctx.accounts.index.load_mut()?;
    index.mint_paused = paused as u8;
    emit!(MintingPaused {
        index: ctx.accounts.index.key(),
        paused,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct PauseAll<'info> {
    pub signer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

/// The owner or the guardian pauses every index's minting; only the owner lifts it.
pub fn handle_set_mint_pause_all(ctx: Context<PauseAll>, paused: bool) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let signer = ctx.accounts.signer.key();
    require!(
        signer == config.owner
            || (paused && signer == config.guardian && signer != Pubkey::default()),
        XindexError::NotOwnerOrGuardian
    );
    config.mint_paused_all = paused;
    emit!(MintingPaused {
        index: Pubkey::default(),
        paused,
    });
    Ok(())
}

/// Refuses an issue while the owner or the guardian has paused this index's minting or every index's.
pub fn require_minting(config: &Config, index: &Index) -> Result<()> {
    require!(
        !config.mint_paused_all && index.mint_paused == 0,
        XindexError::MintingPaused
    );
    Ok(())
}
