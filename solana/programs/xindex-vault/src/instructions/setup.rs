use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::{CapSet, IndexRegistered};
use crate::program::XindexVault;
use crate::state::{Checkpoint, Config, IndexState, PendingChange, Successor};
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
    /// The owner's emergency multisig on Solana, which proposes a successor pair in a stall: a program-derived address,
    /// such as a Squads vault, never a key.
    pub recovery_proposer: Pubkey,
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [TREASURY_SEED], bump)]
    pub treasury: SystemAccount<'info>,
    /// CHECK: P1, a verifier program nobody can upgrade: checked in `check_immutable`.
    pub p1: UncheckedAccount<'info>,
    /// CHECK: P2, as P1.
    pub p2: UncheckedAccount<'info>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ VaultError::NotDeployer)]
    pub program: Program<'info, XindexVault>,
    #[account(constraint = program_data.upgrade_authority_address == Some(authority.key()) @ VaultError::NotDeployer)]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
    /// CHECK: P1's ProgramData account, when the upgradeable loader owns it; checked in `check_immutable`.
    pub p1_data: Option<UncheckedAccount<'info>>,
    /// CHECK: P2's, as P1's.
    pub p2_data: Option<UncheckedAccount<'info>>,
}

/// Only the program's upgrade authority, once: nobody can take the configuration in front of the deployer.
pub fn handle_initialize(ctx: Context<Initialize>, args: InitArgs) -> Result<()> {
    require!(
        args.factory != [0u8; 20]
            && args.hub_implementation != [0u8; 20]
            && args.freezer != Pubkey::default()
            && args.recovery_proposer != Pubkey::default(),
        VaultError::ZeroAddress
    );
    // The twin of `DeployVault`'s checks: the recovery proposer is a multisig, which on Solana is an address off the
    // ed25519 curve, so no single key can sign for it; and it is not the freezer, which vetoes what it proposes.
    require!(
        !args.recovery_proposer.is_on_curve(),
        VaultError::RecoveryNotMultisig
    );
    require_keys_neq!(args.recovery_proposer, args.freezer, VaultError::SameRole);
    // And as `DeployVault`: the deploying key is not the freezer; a floor above the cap would leave the speed limit
    // never binding; and Ethereum's own chain is not the vault's, under which no message could route (B2-02, B1-03).
    require_keys_neq!(
        args.freezer,
        ctx.accounts.authority.key(),
        VaultError::SameRole
    );
    require!(
        args.native_floor <= args.native_cap,
        VaultError::FloorAboveCap
    );
    require!(
        args.source_chain_id != args.chain_id,
        VaultError::WrongRoute
    );
    require_keys_neq!(
        ctx.accounts.p1.key(),
        ctx.accounts.p2.key(),
        VaultError::VerifiersNotDistinct
    );
    vault::check_immutable(
        &ctx.accounts.p1.to_account_info(),
        ctx.accounts.p1_data.as_ref().map(|d| d.as_ref()),
    )?;
    vault::check_immutable(
        &ctx.accounts.p2.to_account_info(),
        ctx.accounts.p2_data.as_ref().map(|d| d.as_ref()),
    )?;

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
        cap_nonce: 0,
        freezer_nonce: 0,
        rotation_nonce: 0,
        pending_cap: PendingChange::default(),
        pending_freezer: PendingChange::default(),
        pending_rotation: PendingChange::default(),
        treasury_bump: ctx.bumps.treasury,
        bump: ctx.bumps.config,
        recovery_proposer: args.recovery_proposer,
        // Its first week's grace: a stall is a week without a new checkpoint, counted from initialization until the
        // first.
        checkpoint: Checkpoint {
            block: 0,
            timestamp: vault::now()? as u64,
            state_root: [0u8; 32],
        },
        snapshot: Checkpoint::default(),
        successor: Successor::default(),
        last_message: [0u8; 32],
        vetoes: 0,
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
    vault::refresh_index(state, config.chain_id, &vault::vault_id(&config.key()));
    emit!(IndexRegistered { index, salt });
    Ok(())
}
