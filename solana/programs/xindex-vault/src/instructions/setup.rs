use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::{CapSet, IndexRegistered};
use crate::program::XindexVault;
use crate::state::{Config, IndexState};
use crate::vault;

/// The vault's settings, fixed at initialization but for what governance messages change.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitArgs {
    /// Ethereum's chain id, which every message must name.
    pub source_chain_id: u64,
    /// The id the factory's chain registry gives this chain.
    pub chain_id: u64,
    pub factory: [u8; 20],
    pub hub_implementation: [u8; 20],
    pub freezer: Pubkey,
    pub native_cap: u64,
    pub native_floor: u64,
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [TREASURY_SEED], bump)]
    pub treasury: SystemAccount<'info>,
    /// CHECK: P1, a verifier program: only its key and that it is a program are kept.
    #[account(executable)]
    pub p1: UncheckedAccount<'info>,
    /// CHECK: P2, as P1.
    #[account(executable)]
    pub p2: UncheckedAccount<'info>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ VaultError::NotDeployer)]
    pub program: Program<'info, XindexVault>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ VaultError::NotDeployer)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

/// Only the program's upgrade authority, once: nobody can take the configuration in front of the deployer.
pub fn handle_initialize(ctx: Context<Initialize>, args: InitArgs) -> Result<()> {
    require!(
        args.factory != [0u8; 20]
            && args.hub_implementation != [0u8; 20]
            && args.freezer != Pubkey::default(),
        VaultError::ZeroAddress
    );
    require_keys_neq!(
        ctx.accounts.p1.key(),
        ctx.accounts.p2.key(),
        VaultError::VerifiersNotDistinct
    );

    // The treasury exists from the start, rent-exempt, outside `held`, so no payout can leave it short of rent.
    let reserve = Rent::get()?.minimum_balance(0);
    let lamports = ctx.accounts.treasury.lamports();
    if lamports < reserve {
        transfer(
            CpiContext::new(
                ctx.accounts.system_program.key(),
                Transfer {
                    from: ctx.accounts.authority.to_account_info(),
                    to: ctx.accounts.treasury.to_account_info(),
                },
            ),
            reserve - lamports,
        )?;
    }

    ctx.accounts.config.set_inner(Config {
        source_chain_id: args.source_chain_id,
        chain_id: args.chain_id,
        factory: args.factory,
        hub_implementation: args.hub_implementation,
        p1: ctx.accounts.p1.key(),
        p2: ctx.accounts.p2.key(),
        freezer: args.freezer,
        frozen_until: 0,
        cap: args.native_cap,
        outflow_floor: args.native_floor,
        held: 0,
        treasury_bump: ctx.bumps.treasury,
        bump: ctx.bumps.config,
    });
    emit!(CapSet {
        cap: args.native_cap,
        outflow_floor: args.native_floor
    });
    Ok(())
}

#[derive(Accounts)]
#[instruction(index: [u8; 20])]
pub struct RegisterIndex<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + IndexState::INIT_SPACE,
        seeds = [INDEX_SEED, index.as_ref()],
        bump
    )]
    pub index_state: Account<'info, IndexState>,
    pub system_program: Program<'info, System>,
}

/// Anyone: records `index` once its address is shown to be the factory's CREATE2 clone of the hub template under
/// `salt`. Only a registered index takes deposits or sends messages.
pub fn handle_register_index(
    ctx: Context<RegisterIndex>,
    index: [u8; 20],
    salt: [u8; 32],
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(
        abi::predict_clone(&config.hub_implementation, &salt, &config.factory) == index,
        VaultError::NotAnIndex
    );
    let state = &mut ctx.accounts.index_state;
    if state.index == index {
        return Ok(());
    }
    state.index = index;
    state.bump = ctx.bumps.index_state;
    vault::refresh_index(state, config.chain_id, &vault::vault_address(&config.key()));
    emit!(IndexRegistered { index, salt });
    Ok(())
}
