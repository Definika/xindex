//! STUB, NOT A PROOF SYSTEM. An Ethereum-event verifier for testnets that accepts any log its relayer key signed.
//!
//! It stands in for P1 or P2 in the hackathon demonstration (`design/2026-09-30-hackathon-plan.md`) and implements the
//! vault's verifier interface (`xindex_vault::verify`), so the vault runs unchanged. It proves nothing: whoever holds the
//! relayer key can make the vault accept any message. It must never be a mainnet vault's verifier. It is a plain Solana
//! program, with no program id of its own, so one build is deployed twice, once as P1 and once as P2, under two keys.
//!
//! Instructions, by their first byte:
//! - `0`, verify_event: accounts `[state, relayer]`; succeeds only if `relayer` is the key `state` holds and signed.
//! - `1`, initialize: accounts `[state, payer, system_program, program_data]`, data the relayer's key; once, and only
//!   by this program's upgrade authority, so nobody can set the key in front of its deployer. The deployer then makes
//!   the program immutable, which the vault requires of a verifier.
//!
//! `state` is this program's account at the seed `"verifier"`.

use anchor_lang::solana_program::account_info::AccountInfo;
use anchor_lang::solana_program::bpf_loader_upgradeable;
use anchor_lang::solana_program::entrypoint::ProgramResult;
use anchor_lang::solana_program::msg;
use anchor_lang::solana_program::program::{invoke, invoke_signed};
use anchor_lang::solana_program::program_error::ProgramError;
use anchor_lang::solana_program::pubkey::Pubkey;
use anchor_lang::solana_program::rent::Rent;
use anchor_lang::solana_program::system_instruction;

pub const STATE_SEED: &[u8] = b"verifier";
pub const VERIFY_EVENT: u8 = 0;
pub const INITIALIZE: u8 = 1;
/// The log the vault passes: block (8), emitter (20), topic0, topic1 and the data's hash (32 each).
const LOG_LEN: usize = 8 + 20 + 3 * 32;

#[cfg(not(feature = "no-entrypoint"))]
anchor_lang::solana_program::entrypoint!(process);

pub fn process(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    let (tag, rest) = data
        .split_first()
        .ok_or(ProgramError::InvalidInstructionData)?;
    let (state_key, bump) = Pubkey::find_program_address(&[STATE_SEED], program_id);
    let state = accounts.first().ok_or(ProgramError::NotEnoughAccountKeys)?;
    if *state.key != state_key {
        return Err(ProgramError::InvalidSeeds);
    }
    match *tag {
        VERIFY_EVENT => {
            let relayer = accounts.get(1).ok_or(ProgramError::NotEnoughAccountKeys)?;
            if state.owner != program_id || state.data_len() != 32 {
                return Err(ProgramError::UninitializedAccount);
            }
            if !relayer.is_signer || relayer.key.as_ref() != &state.data.borrow()[..] {
                return Err(ProgramError::MissingRequiredSignature);
            }
            if rest.len() < LOG_LEN {
                return Err(ProgramError::InvalidInstructionData);
            }
            msg!("STUB verifier: log accepted on the relayer's signature alone");
            Ok(())
        }
        INITIALIZE => {
            let payer = accounts.get(1).ok_or(ProgramError::NotEnoughAccountKeys)?;
            let system = accounts.get(2).ok_or(ProgramError::NotEnoughAccountKeys)?;
            let program_data = accounts.get(3).ok_or(ProgramError::NotEnoughAccountKeys)?;
            let relayer: [u8; 32] = rest
                .try_into()
                .map_err(|_| ProgramError::InvalidInstructionData)?;
            check_upgrade_authority(program_id, program_data, payer)?;
            if state.owner == program_id {
                return Err(ProgramError::AccountAlreadyInitialized);
            }
            // Transfer, allocate and assign rather than create: lamports someone sent to the address in advance cannot
            // block the account's creation.
            let rent = Rent::default().minimum_balance(32);
            if state.lamports() < rent {
                invoke(
                    &system_instruction::transfer(payer.key, state.key, rent - state.lamports()),
                    &[payer.clone(), state.clone(), system.clone()],
                )?;
            }
            let seeds: &[&[u8]] = &[STATE_SEED, &[bump]];
            invoke_signed(
                &system_instruction::allocate(state.key, 32),
                &[state.clone(), system.clone()],
                &[seeds],
            )?;
            invoke_signed(
                &system_instruction::assign(state.key, program_id),
                &[state.clone(), system.clone()],
                &[seeds],
            )?;
            state.data.borrow_mut().copy_from_slice(&relayer);
            Ok(())
        }
        _ => Err(ProgramError::InvalidInstructionData),
    }
}

/// `program_data` is this program's ProgramData account, and `payer` its upgrade authority, signing.
fn check_upgrade_authority(
    program_id: &Pubkey,
    program_data: &AccountInfo,
    payer: &AccountInfo,
) -> ProgramResult {
    let loader = bpf_loader_upgradeable::id();
    let expected = Pubkey::find_program_address(&[program_id.as_ref()], &loader).0;
    if *program_data.key != expected || *program_data.owner != loader {
        return Err(ProgramError::InvalidAccountData);
    }
    let data = program_data.data.borrow();
    // UpgradeableLoaderState::ProgramData: tag 3 (u32), slot (u64), then Option<Pubkey> for the upgrade authority.
    let authority_is_payer = data.len() >= 45
        && data[..4] == [3, 0, 0, 0]
        && data[12] == 1
        && data[13..45] == payer.key.as_ref()[..];
    if !authority_is_payer || !payer.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    Ok(())
}
