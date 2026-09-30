//! STUB, NOT A PROOF SYSTEM. An Ethereum-event verifier for testnets that accepts any log its relayer key signed.
//!
//! It stands in for P1 or P2 in the hackathon demonstration (`design/2026-09-30-hackathon-plan.md`) and implements the
//! vault's verifier interface (`xindex_vault::verify`), so the vault runs unchanged. It proves nothing: whoever holds the
//! relayer key can make the vault accept any message. It must never be a mainnet vault's verifier. It is a plain Solana
//! program, with no program id of its own, so one build is deployed twice, once as P1 and once as P2, under two keys.
//!
//! Instructions, by their first byte:
//! - `0`, verify_event: accounts `[state, relayer]`; succeeds only if `relayer` is the key `state` holds and signed.
//! - `1`, initialize: accounts `[state, payer, system_program]`, data the relayer's key; once.
//!
//! `state` is this program's account at the seed `"verifier"`.

use anchor_lang::solana_program::account_info::AccountInfo;
use anchor_lang::solana_program::entrypoint::ProgramResult;
use anchor_lang::solana_program::msg;
use anchor_lang::solana_program::program::invoke_signed;
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
            let relayer: [u8; 32] = rest
                .try_into()
                .map_err(|_| ProgramError::InvalidInstructionData)?;
            if state.lamports() != 0 {
                return Err(ProgramError::AccountAlreadyInitialized);
            }
            invoke_signed(
                &system_instruction::create_account(
                    payer.key,
                    state.key,
                    Rent::default().minimum_balance(32),
                    32,
                    program_id,
                ),
                &[payer.clone(), state.clone(), system.clone()],
                &[&[STATE_SEED, &[bump]]],
            )?;
            state.data.borrow_mut().copy_from_slice(&relayer);
            Ok(())
        }
        _ => Err(ProgramError::InvalidInstructionData),
    }
}
