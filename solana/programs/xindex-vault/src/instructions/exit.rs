//! The snapshot exit (Stage B spec, section 5.6; design 6.9, layer 4), after `begin_snapshot`: every read of the hub's
//! storage is under the snapshot's state root, proven with `eth_getProof`'s nodes (`state_reader`). Holders at the
//! snapshot claim their share directly, within the speed limit; an intake still open is settled or failed from the
//! hub's mark of the settle message it sent; a burn or migration the hub marked sent is paid as a delivered one would
//! be. The proof travels inline or, when too long for a transaction, in a loader buffer, the first remaining account.

use anchor_lang::prelude::*;

use crate::abi;
use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::instructions::messages::{
    self, check_route, pay_recipient, DeliverBurn, DeliverMigrate,
};
use crate::snapshot;
use crate::state::{Config, IndexState, Intake, Owed};
use crate::state_reader;
use crate::vault;

/// One slot of `index`'s storage at the snapshot.
fn read_hub(
    config: &Config,
    index: &[u8; 20],
    slot: [u8; 32],
    proof: &[u8],
    remaining: &[AccountInfo],
) -> Result<[u8; 32]> {
    let root = vault::snapshot_root(config)?;
    state_reader::staged(proof, remaining.first(), |p| {
        Ok(state_reader::read_slots(&root, index, &[slot], p)?[0])
    })
}

// ---------------------------------------------------------------------
// claim_snapshot
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(index: [u8; 20], holder: [u8; 20])]
pub struct ClaimSnapshot<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    /// Exists only once registered.
    #[account(mut, seeds = [INDEX_SEED, index.as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    /// The claim's payout, at an address its index and holder derive: a holder claims once.
    #[account(
        init,
        payer = payer,
        space = 8 + Owed::INIT_SPACE,
        seeds = [OWED_SEED, index.as_ref(), snapshot::claim_id(&index, &holder).as_ref()],
        bump
    )]
    pub owed: Account<'info, Owed>,
    /// CHECK: the recipient, checked against the holder's recovery key or signature; it receives lamports only.
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,
    #[account(mut, seeds = [TREASURY_SEED], bump = config.treasury_bump)]
    pub treasury: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Anyone, after the snapshot: pays `holder`'s share of SOL in `index` at the snapshot, read from the hub's storage
/// there (`snapshot::share`), to `recipient`: the recovery key it registered in the hub for this chain, if any, which a
/// contract holder must register; otherwise the recipient it signed for with its Ethereum key (EIP-712). Paid within
/// the speed limit, as any payout: a snapshot of a forged checkpoint takes no more than a forged burn.
pub fn handle_claim_snapshot<'info>(
    ctx: Context<'info, ClaimSnapshot<'info>>,
    index: [u8; 20],
    holder: [u8; 20],
    component: u64,
    signature: Vec<u8>,
    proof: Vec<u8>,
) -> Result<()> {
    let accounts = ctx.accounts;
    let config = &accounts.config;
    let recipient = accounts.recipient.key();
    require!(recipient != Pubkey::default(), VaultError::ZeroAddress);
    // The treasury, or any account of this program, would strand the payout (SOL-9).
    require!(
        recipient != accounts.treasury.key() && *accounts.recipient.owner != crate::ID,
        VaultError::WrongRecipient
    );
    let root = vault::snapshot_root(config)?;
    let slots = snapshot::claim_slots(&holder, component, config.chain_id);
    let values = state_reader::staged(&proof, ctx.remaining_accounts.first(), |p| {
        state_reader::read_slots(&root, &index, &slots, p)
    })?;
    let (amount, registered) = snapshot::share(&values, component, config.chain_id)?;
    match registered {
        // A holder that registered a recovery key, such as a contract, is paid there and nowhere else.
        Some(key) => require_keys_eq!(recipient, key, VaultError::WrongRecipient),
        None => {
            let digest = snapshot::claim_digest(
                &vault::vault_id(&config.key()),
                config.chain_id,
                &index,
                &holder,
                &recipient,
            );
            snapshot::check_signature(&digest, &signature, &holder)?;
        }
    }
    let id = snapshot::claim_id(&index, &holder);
    accounts.owed.set_inner(Owed {
        index,
        id,
        to_index: false,
        recipient,
        new_index: [0u8; 20],
        remaining: amount,
        bump: ctx.bumps.owed,
    });
    emit!(SnapshotClaimed {
        index,
        holder,
        recipient,
        amount,
        id
    });
    pay_recipient(
        &mut accounts.config,
        &mut accounts.index_state,
        &mut accounts.owed,
        &accounts.recipient,
        &accounts.treasury,
        &accounts.system_program,
    )
}

// ---------------------------------------------------------------------
// resolve_intake
// ---------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(index: [u8; 20], intake_id: [u8; 32])]
pub struct ResolveIntake<'info> {
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [INDEX_SEED, index.as_ref()], bump = index_state.bump)]
    pub index_state: Account<'info, IndexState>,
    #[account(mut, seeds = [INTAKE_SEED, index.as_ref(), intake_id.as_ref()], bump = intake.bump)]
    pub intake: Account<'info, Intake>,
}

/// Anyone, after the snapshot: settles an intake still open if the hub had sent its settle message by the snapshot, and
/// otherwise fails it, so its depositors take their coins back. The hub marks an intake settled in the transaction that
/// sends its settle message (`_settledIntakes`), so its mark at the snapshot says whether that message was sent by then:
/// nothing sent later will ever run here.
pub fn handle_resolve_intake<'info>(
    ctx: Context<'info, ResolveIntake<'info>>,
    index: [u8; 20],
    intake_id: [u8; 32],
    proof: Vec<u8>,
) -> Result<()> {
    let accounts = ctx.accounts;
    require!(
        accounts.intake.state == INTAKE_OPEN,
        VaultError::IntakeNotOpen
    );
    let mark = read_hub(
        &accounts.config,
        &index,
        snapshot::settled_slot(&intake_id),
        &proof,
        ctx.remaining_accounts,
    )?;
    let settled = mark != [0u8; 32];
    emit!(IntakeResolved {
        index,
        intake_id,
        settled
    });
    messages::resolve(
        &accounts.config,
        &mut accounts.index_state,
        &mut accounts.intake,
        settled,
    );
    Ok(())
}

// ---------------------------------------------------------------------
// deliver_recorded_burn, deliver_recorded_migrate
// ---------------------------------------------------------------------

/// The checks of the EVM vault's `deliverRecorded`: the kind, the route, and the index's own mark of the message in its
/// storage at the snapshot (`_sentMessages`). The index marks each burn and migration in the transaction that sends it,
/// and only it writes its storage, so its mark at the snapshot shows the index sent this message by then. Every other
/// kind in flight at the snapshot resolves without one: an intake's through `resolve_intake`, and governance not at all.
fn accept_recorded<'a>(
    config: &Account<Config>,
    payload: &'a [u8],
    kind: u8,
    proof: &[u8],
    remaining: &[AccountInfo],
) -> Result<(abi::Message<'a>, [u8; 32])> {
    let id = abi::message_id(payload);
    let m = abi::decode_message(payload)?;
    require!(m.kind == kind, VaultError::UnknownKind);
    check_route(config, &m)?;
    let mark = read_hub(config, &m.index, snapshot::sent_slot(&id), proof, remaining)?;
    require!(mark != [0u8; 32], VaultError::NotRecorded);
    emit!(MessageDelivered {
        id,
        kind: m.kind,
        index: m.index
    });
    Ok((m, id))
}

/// Anyone, after the snapshot: a burn the index sent before it and that never arrived runs on the index's own record of
/// it, once, within the speed limit, as a delivered one would.
pub fn handle_deliver_recorded_burn<'info>(
    ctx: Context<'info, DeliverBurn<'info>>,
    payload: Vec<u8>,
    proof: Vec<u8>,
) -> Result<()> {
    let (m, id) = accept_recorded(
        &ctx.accounts.config,
        &payload,
        BURN,
        &proof,
        ctx.remaining_accounts,
    )?;
    messages::burn(ctx.accounts, ctx.bumps.used, ctx.bumps.owed, &m, id)
}

/// Anyone, after the snapshot: a migration the index sent before it, as `deliver_recorded_burn` runs a burn.
pub fn handle_deliver_recorded_migrate<'info>(
    ctx: Context<'info, DeliverMigrate<'info>>,
    payload: Vec<u8>,
    proof: Vec<u8>,
) -> Result<()> {
    let (m, id) = accept_recorded(
        &ctx.accounts.config,
        &payload,
        MIGRATE,
        &proof,
        ctx.remaining_accounts,
    )?;
    messages::migrate(ctx.accounts, ctx.bumps.used, ctx.bumps.owed, &m, id)
}
