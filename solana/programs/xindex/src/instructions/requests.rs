// SPDX-License-Identifier: BUSL-1.1
//! Limit orders, the EVM's `MintRequests` (`docs/design/solana.md`, section 8.5). A requester escrows USDC or USDT for
//! at least `min_out` shares of an index, or shares for at least `min_out` of a stablecoin, until a deadline; anyone
//! fills it before then, paying the requester first, and the requester's limit is the only valuation: nothing reads a
//! price.
//!
//! - Each request is an account at `["request", requester, id]` with an escrow of its own, a token account it owns,
//!   credited with what it received. No balance is shared between requests, so none can pay for another's.
//! - A request fills only at the basket it was made on (its rebalance nonce, RW-2); a requester may name the nonce it
//!   priced at (CA-M1), and a filler the request's hash (RW-7).
//! - The escrow always comes back: the requester cancels at any time, anyone refunds after the deadline, neither
//!   reading a nonce.

use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{
        self, close_account, CloseAccount, Mint, TokenAccount, TokenInterface, TransferChecked,
    },
};

use crate::{
    constants::*,
    error::XindexError,
    events::{RequestClosed, RequestFilled, RequestOpened},
    state::{Config, Index, Request},
};

/// A request for shares, paid in a stablecoin.
pub const MINT_REQUEST: u8 = 0;
/// A request for a stablecoin, paid in shares.
pub const REDEEM_REQUEST: u8 = 1;

/// The hash a filler binds its fill to: every field of the request but its address, so it follows a request its
/// requester opened again under another id with the same terms.
pub fn request_hash(request: &Request) -> [u8; 32] {
    let mut bytes = Vec::with_capacity(32 * 4 + 8 * 4 + 1);
    bytes.extend_from_slice(request.requester.as_ref());
    bytes.extend_from_slice(request.index.as_ref());
    bytes.push(request.kind);
    bytes.extend_from_slice(request.pay_mint.as_ref());
    bytes.extend_from_slice(request.want_mint.as_ref());
    bytes.extend_from_slice(&request.escrowed.to_le_bytes());
    bytes.extend_from_slice(&request.min_out.to_le_bytes());
    bytes.extend_from_slice(&request.deadline.to_le_bytes());
    bytes.extend_from_slice(&request.rebalance_nonce.to_le_bytes());
    solana_sha256_hasher::hashv(&[&bytes]).to_bytes()
}

#[derive(Accounts)]
#[instruction(id: u64)]
pub struct OpenRequest<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    pub index: AccountLoader<'info, Index>,
    #[account(
        init,
        payer = requester,
        space = 8 + Request::INIT_SPACE,
        seeds = [REQUEST_SEED, requester.key().as_ref(), id.to_le_bytes().as_ref()],
        bump
    )]
    pub request: Account<'info, Request>,
    /// What the requester pays: a stablecoin for a mint request, the index's shares for a redeem request.
    pub pay_mint: InterfaceAccount<'info, Mint>,
    /// What it wants: the index's shares, or a stablecoin.
    pub want_mint: InterfaceAccount<'info, Mint>,
    #[account(mut, token::mint = pay_mint, token::authority = requester, token::token_program = token_program)]
    pub from: InterfaceAccount<'info, TokenAccount>,
    #[account(
        init,
        payer = requester,
        associated_token::mint = pay_mint,
        associated_token::authority = request,
        associated_token::token_program = token_program
    )]
    pub escrow: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/// Opens request `id`: `kind` says which way, `amount` is what the requester escrows, `min_out` its limit, and
/// `expected_nonce`, if named, the rebalance nonce the limit was priced at (`StaleRebalanceNonce` otherwise, before
/// anything moves). The escrow is credited with what it received.
#[allow(clippy::too_many_arguments)]
pub fn handle_open_request(
    ctx: Context<OpenRequest>,
    id: u64,
    kind: u8,
    amount: u64,
    min_out: u64,
    deadline: i64,
    expected_nonce: Option<u64>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    require!(amount != 0 && min_out != 0, XindexError::ZeroShares);
    require!(
        deadline > now && deadline <= now + MAX_REQUEST_DURATION,
        XindexError::BadDeadline
    );
    let (share_mint, nonce) = {
        let index = ctx.accounts.index.load()?;
        require!(index.sealed == 1, XindexError::NotSealed);
        (index.share_mint, index.rebalance_nonce)
    };
    if let Some(expected) = expected_nonce {
        require!(expected == nonce, XindexError::StaleRebalanceNonce);
    }
    let config = &ctx.accounts.config;
    let stable = |mint: &Pubkey| *mint == config.usdc || *mint == config.usdt;
    let (pay, want) = (ctx.accounts.pay_mint.key(), ctx.accounts.want_mint.key());
    match kind {
        MINT_REQUEST => {
            require!(stable(&pay), XindexError::NotAStable);
            require_keys_eq!(want, share_mint, XindexError::WrongLegAccount);
        }
        REDEEM_REQUEST => {
            require_keys_eq!(pay, share_mint, XindexError::WrongLegAccount);
            require!(stable(&want), XindexError::NotAStable);
        }
        _ => return err!(XindexError::BadRequest),
    }
    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            TransferChecked {
                from: ctx.accounts.from.to_account_info(),
                mint: ctx.accounts.pay_mint.to_account_info(),
                to: ctx.accounts.escrow.to_account_info(),
                authority: ctx.accounts.requester.to_account_info(),
            },
        ),
        amount,
        ctx.accounts.pay_mint.decimals,
    )?;
    ctx.accounts.escrow.reload()?;
    let escrowed = ctx.accounts.escrow.amount;
    require!(escrowed != 0, XindexError::ShortDeposit);
    let request = &mut ctx.accounts.request;
    request.requester = ctx.accounts.requester.key();
    request.index = ctx.accounts.index.key();
    request.id = id;
    request.kind = kind;
    request.pay_mint = pay;
    request.want_mint = want;
    request.pay_program = ctx.accounts.token_program.key();
    request.escrowed = escrowed;
    request.min_out = min_out;
    request.deadline = deadline;
    request.rebalance_nonce = nonce;
    request.bump = ctx.bumps.request;
    emit!(RequestOpened {
        request: request.key(),
        requester: request.requester,
        index: request.index,
        kind,
        escrowed,
        min_out,
        deadline,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct FillRequest<'info> {
    #[account(mut)]
    pub filler: Signer<'info>,
    pub index: AccountLoader<'info, Index>,
    /// CHECK: the requester, who receives the request's rent back; it is the request's own.
    #[account(mut, address = request.requester @ XindexError::WrongTicket)]
    pub requester: UncheckedAccount<'info>,
    #[account(
        mut,
        close = requester,
        has_one = index @ XindexError::WrongTicket,
        seeds = [REQUEST_SEED, request.requester.as_ref(), request.id.to_le_bytes().as_ref()],
        bump = request.bump
    )]
    pub request: Account<'info, Request>,
    #[account(address = request.pay_mint @ XindexError::WrongLegAccount)]
    pub pay_mint: InterfaceAccount<'info, Mint>,
    #[account(address = request.want_mint @ XindexError::WrongLegAccount)]
    pub want_mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        associated_token::mint = pay_mint,
        associated_token::authority = request,
        associated_token::token_program = pay_program
    )]
    pub escrow: InterfaceAccount<'info, TokenAccount>,
    /// The requester's account of what it wants, where the fill is measured.
    #[account(mut, token::mint = want_mint, token::authority = request.requester, token::token_program = want_program)]
    pub requester_account: InterfaceAccount<'info, TokenAccount>,
    /// The filler's account it pays from.
    #[account(mut, token::mint = want_mint, token::authority = filler, token::token_program = want_program)]
    pub filler_from: InterfaceAccount<'info, TokenAccount>,
    /// The filler's account the escrow is paid to.
    #[account(mut, token::mint = pay_mint, token::token_program = pay_program)]
    pub filler_to: InterfaceAccount<'info, TokenAccount>,
    pub pay_program: Interface<'info, TokenInterface>,
    pub want_program: Interface<'info, TokenInterface>,
}

/// Fills a request before its deadline, at the nonce it was made at: the filler sends `amount` of what the requester
/// wants into the requester's own account, which must receive at least the limit (`BelowLimit`), and is then paid the
/// whole escrow, and the request is closed. `expected`, if named, is the request's hash the filler priced
/// (`RequestChanged` otherwise).
pub fn handle_fill_request(
    ctx: Context<FillRequest>,
    amount: u64,
    expected: Option<[u8; 32]>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let request = &ctx.accounts.request;
    require!(now <= request.deadline, XindexError::RequestExpired);
    require!(
        ctx.accounts.index.load()?.rebalance_nonce == request.rebalance_nonce,
        XindexError::StaleRebalanceNonce
    );
    if let Some(hash) = expected {
        require!(request_hash(request) == hash, XindexError::RequestChanged);
    }
    let before = ctx.accounts.requester_account.amount;
    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.want_program.key(),
            TransferChecked {
                from: ctx.accounts.filler_from.to_account_info(),
                mint: ctx.accounts.want_mint.to_account_info(),
                to: ctx.accounts.requester_account.to_account_info(),
                authority: ctx.accounts.filler.to_account_info(),
            },
        ),
        amount,
        ctx.accounts.want_mint.decimals,
    )?;
    ctx.accounts.requester_account.reload()?;
    let received = ctx.accounts.requester_account.amount.saturating_sub(before);
    require!(received >= request.min_out, XindexError::BelowLimit);
    let escrowed = request.escrowed;
    pay_escrow(
        &ctx.accounts.request,
        &ctx.accounts.escrow,
        &ctx.accounts.pay_mint,
        &ctx.accounts.filler_to.to_account_info(),
        &ctx.accounts.requester.to_account_info(),
        &ctx.accounts.pay_program,
    )?;
    emit!(RequestFilled {
        request: ctx.accounts.request.key(),
        filler: ctx.accounts.filler.key(),
        paid: received,
        escrowed,
    });
    Ok(())
}

/// Pays the whole escrow to `to` and closes the escrow account, its rent to `rent_to`, signed by the request.
fn pay_escrow<'info>(
    request: &Account<'info, Request>,
    escrow: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    to: &AccountInfo<'info>,
    rent_to: &AccountInfo<'info>,
    token_program: &Interface<'info, TokenInterface>,
) -> Result<()> {
    let id = request.id.to_le_bytes();
    let seeds: [&[u8]; 4] = [
        REQUEST_SEED,
        request.requester.as_ref(),
        id.as_ref(),
        std::slice::from_ref(&request.bump),
    ];
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            token_program.key(),
            TransferChecked {
                from: escrow.to_account_info(),
                mint: mint.to_account_info(),
                to: to.clone(),
                authority: request.to_account_info(),
            },
            &[&seeds],
        ),
        escrow.amount,
        mint.decimals,
    )?;
    close_account(CpiContext::new_with_signer(
        token_program.key(),
        CloseAccount {
            account: escrow.to_account_info(),
            destination: rent_to.clone(),
            authority: request.to_account_info(),
        },
        &[&seeds],
    ))
}

#[derive(Accounts)]
pub struct CloseRequest<'info> {
    pub signer: Signer<'info>,
    /// CHECK: the requester, who receives the escrow's rent and the request's; it is the request's own.
    #[account(mut, address = request.requester @ XindexError::WrongTicket)]
    pub requester: UncheckedAccount<'info>,
    #[account(
        mut,
        close = requester,
        seeds = [REQUEST_SEED, request.requester.as_ref(), request.id.to_le_bytes().as_ref()],
        bump = request.bump
    )]
    pub request: Account<'info, Request>,
    #[account(address = request.pay_mint @ XindexError::WrongLegAccount)]
    pub pay_mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        associated_token::mint = pay_mint,
        associated_token::authority = request,
        associated_token::token_program = pay_program
    )]
    pub escrow: InterfaceAccount<'info, TokenAccount>,
    /// The requester's account the escrow comes back to.
    #[account(mut, token::mint = pay_mint, token::authority = request.requester, token::token_program = pay_program)]
    pub back_to: InterfaceAccount<'info, TokenAccount>,
    pub pay_program: Interface<'info, TokenInterface>,
}

/// The requester cancels its request at any time, and anyone refunds one after its deadline: the escrow comes back
/// whole to the requester, whatever the index's nonce.
pub fn handle_close_request(ctx: Context<CloseRequest>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let request = &ctx.accounts.request;
    require!(
        ctx.accounts.signer.key() == request.requester || now > request.deadline,
        XindexError::RequestOpen
    );
    pay_escrow(
        &ctx.accounts.request,
        &ctx.accounts.escrow,
        &ctx.accounts.pay_mint,
        &ctx.accounts.back_to.to_account_info(),
        &ctx.accounts.requester.to_account_info(),
        &ctx.accounts.pay_program,
    )?;
    emit!(RequestClosed {
        request: ctx.accounts.request.key(),
        by: ctx.accounts.signer.key(),
    });
    Ok(())
}
