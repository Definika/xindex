//! P1 on Solana (Stage B spec, section 10): a light client of Ethereum that anyone advances with an SP1 proof that a
//! checkpoint is finalized by two thirds of the anchor's validators, and that proves a vault message by its receipt in
//! any execution block those proofs covered. The twin of `EthereumFinalityVerifier.sol`, behind the vault's verifier
//! interface (`xindex_vault::verify`).
//!
//! No owner and no upgrade: the deployer's upgrade authority sets the program key and the first anchor once, then
//! makes the program immutable, which the vault requires of a verifier. Every later anchor is proven. A plain Solana
//! program, with no program id of its own, so one build can serve one vault's P1 under any key.
//!
//! Instructions, by their first byte:
//! - `0`, verify_event: the vault's call. Data `block (u64) ++ emitter (20) ++ topic0 ++ topic1 ++ keccak256(data)
//!   ++ proof`, accounts `[range]`, or `[range, buffer]` with an empty proof, read then from the buffer. Succeeds only
//!   if the proof shows that log, of a successful transaction, in a block a recorded proof covered.
//! - `1`, initialize: data `programKey ++ anchor ++ epoch (u64)`, accounts `[state, authority (signer), system program,
//!   program data]`; once, and only by the program's upgrade authority.
//! - `2`, update: data `publicValues (192) ++ proof (356)`, accounts `[state, range, payer (signer), system program]`.
//!   Anyone. Accepts an SP1 proof of the statement from the stored anchor, and records the blocks it covers in the
//!   range account of their headers root.
//! - `3`, check_proof: data `programKey ++ proof (356) ++ publicValues`, no accounts. Succeeds only if the proof is
//!   SP1 v6's Groth16 proof that the program committed those values.
//!
//! Integers are little-endian. `state` is the account at the seed `"verifier"`; a range is at `"range" ++ headersRoot`.

pub mod event;
pub mod groth16;
pub mod mpt;
pub mod rlp;
pub mod vk;

use anchor_lang::solana_program::account_info::AccountInfo;
use anchor_lang::solana_program::bpf_loader_upgradeable;
use anchor_lang::solana_program::entrypoint::ProgramResult;
use anchor_lang::solana_program::program::{invoke, invoke_signed};
use anchor_lang::solana_program::program_error::ProgramError;
use anchor_lang::solana_program::pubkey::Pubkey;
use anchor_lang::solana_program::rent::Rent;
use anchor_lang::solana_program::system_instruction;

pub const STATE_SEED: &[u8] = b"verifier";
pub const RANGE_SEED: &[u8] = b"range";

pub const VERIFY_EVENT: u8 = 0;
pub const INITIALIZE: u8 = 1;
pub const UPDATE: u8 = 2;
pub const CHECK_PROOF: u8 = 3;

/// The log the vault passes: block (8), emitter (20), topic0, topic1 and the data's hash (32 each).
pub const LOG_LEN: usize = 8 + 20 + 3 * 32;
/// `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`, as the P1 program commits it.
pub const PUBLIC_VALUES_LEN: usize = 6 * 32;
/// The state: the program key, the anchor, and the anchor's epoch.
pub const STATE_LEN: usize = 32 + 32 + 8;
/// A range: the first and last block it covers, and its address's bump.
pub const RANGE_LEN: usize = 8 + 8 + 1;
/// A loader buffer's data starts after its metadata: the state tag and the authority option.
pub const BUFFER_METADATA: usize = 37;
const BUFFER_TAG: [u8; 4] = [1, 0, 0, 0];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum VerifierError {
    BadInstruction = 0,
    WrongAccount,
    AlreadyInitialized,
    NotUpgradeAuthority,
    WrongAnchor,
    BadPublicValues,
    InvalidProof,
    UnknownHeaders,
    NotInRange,
    BadHeaderPath,
    BadEventProof,
    BadReceiptProof,
    NoReceipt,
    FailedTransaction,
    NoLog,
    NotTheLog,
}

impl From<VerifierError> for ProgramError {
    fn from(e: VerifierError) -> Self {
        ProgramError::Custom(e as u32)
    }
}

pub fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    solana_keccak_hasher::hashv(parts).to_bytes()
}

#[cfg(not(feature = "no-entrypoint"))]
anchor_lang::solana_program::entrypoint!(process);

pub fn process(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    let (tag, rest) = data.split_first().ok_or(VerifierError::BadInstruction)?;
    match *tag {
        VERIFY_EVENT => verify_event(program_id, accounts, rest),
        INITIALIZE => initialize(program_id, accounts, rest),
        UPDATE => update(program_id, accounts, rest),
        CHECK_PROOF => {
            let (key, rest) = split::<32>(rest)?;
            if rest.len() < groth16::PROOF_LEN {
                return Err(VerifierError::BadInstruction.into());
            }
            let (proof, values) = rest.split_at(groth16::PROOF_LEN);
            groth16::verify(&key, values, proof).map_err(|_| VerifierError::InvalidProof)?;
            Ok(())
        }
        _ => Err(VerifierError::BadInstruction.into()),
    }
}

fn split<const N: usize>(data: &[u8]) -> Result<([u8; N], &[u8]), VerifierError> {
    if data.len() < N {
        return Err(VerifierError::BadInstruction);
    }
    let (head, rest) = data.split_at(N);
    Ok((head.try_into().unwrap(), rest))
}

// ---------------------------------------------------------------------
// verify_event
// ---------------------------------------------------------------------

fn verify_event(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() < LOG_LEN {
        return Err(VerifierError::BadInstruction.into());
    }
    let block = u64::from_le_bytes(data[..8].try_into().unwrap());
    let emitter: [u8; 20] = data[8..28].try_into().unwrap();
    let topic0: [u8; 32] = data[28..60].try_into().unwrap();
    let topic1: [u8; 32] = data[60..92].try_into().unwrap();
    let data_hash: [u8; 32] = data[92..124].try_into().unwrap();
    let inline = &data[LOG_LEN..];
    let range = accounts.first().ok_or(VerifierError::WrongAccount)?;

    // A proof too long for a transaction is staged in a loader buffer: its length (u32), then its bytes. What the
    // buffer holds is no more trusted than instruction data, so whose buffer it is does not matter.
    let staged;
    let proof: &[u8] = if inline.is_empty() {
        let buffer = accounts.get(1).ok_or(VerifierError::WrongAccount)?;
        if *buffer.owner != bpf_loader_upgradeable::id() {
            return Err(VerifierError::WrongAccount.into());
        }
        staged = buffer.data.borrow();
        if staged.len() < BUFFER_METADATA + 4 || staged[..4] != BUFFER_TAG {
            return Err(VerifierError::WrongAccount.into());
        }
        let len = u32::from_le_bytes(
            staged[BUFFER_METADATA..BUFFER_METADATA + 4]
                .try_into()
                .unwrap(),
        ) as usize;
        let start = BUFFER_METADATA + 4;
        staged
            .get(start..start + len)
            .ok_or(VerifierError::BadEventProof)?
    } else {
        inline
    };

    let p = event::parse(proof)?;
    let (first, last) = read_range(program_id, range, &p.header.headers_root)?;
    event::check_header(&p.header, first, last)?;
    if p.header.number != block {
        return Err(VerifierError::NotTheLog.into());
    }
    let log = event::log(&p.header.receipts_root, &p.nodes, p.tx_index, p.log_index)?;
    if log.emitter != emitter
        || log.topic0 != topic0
        || log.topic1 != topic1
        || keccak(&[log.data]) != data_hash
    {
        return Err(VerifierError::NotTheLog.into());
    }
    Ok(())
}

/// The blocks the proof that recorded `headers_root` covered: its range account, this program's, at its address.
fn read_range(
    program_id: &Pubkey,
    range: &AccountInfo,
    headers_root: &[u8; 32],
) -> Result<(u64, u64), VerifierError> {
    if range.owner != program_id || range.data_len() != RANGE_LEN {
        return Err(VerifierError::UnknownHeaders);
    }
    let d = range.data.borrow();
    let expected =
        Pubkey::create_program_address(&[RANGE_SEED, headers_root, &[d[16]]], program_id)
            .map_err(|_| VerifierError::UnknownHeaders)?;
    if *range.key != expected {
        return Err(VerifierError::UnknownHeaders);
    }
    Ok((
        u64::from_le_bytes(d[..8].try_into().unwrap()),
        u64::from_le_bytes(d[8..16].try_into().unwrap()),
    ))
}

// ---------------------------------------------------------------------
// initialize and update
// ---------------------------------------------------------------------

fn initialize(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    let (key, rest) = split::<32>(data)?;
    let (anchor, rest) = split::<32>(rest)?;
    let (epoch, rest) = split::<8>(rest)?;
    if !rest.is_empty() || key == [0u8; 32] || anchor == [0u8; 32] {
        return Err(VerifierError::BadInstruction.into());
    }
    let [state, payer, system, program_data] = accounts else {
        return Err(VerifierError::WrongAccount.into());
    };
    check_upgrade_authority(program_id, program_data, payer)?;
    let (state_key, bump) = Pubkey::find_program_address(&[STATE_SEED], program_id);
    if *state.key != state_key {
        return Err(VerifierError::WrongAccount.into());
    }
    if state.owner == program_id {
        return Err(VerifierError::AlreadyInitialized.into());
    }
    create(
        program_id,
        state,
        payer,
        system,
        &[STATE_SEED, &[bump]],
        STATE_LEN,
    )?;
    state
        .data
        .borrow_mut()
        .copy_from_slice(&[&key[..], &anchor, &epoch].concat());
    Ok(())
}

fn update(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != PUBLIC_VALUES_LEN + groth16::PROOF_LEN {
        return Err(VerifierError::BadInstruction.into());
    }
    let (values, proof) = data.split_at(PUBLIC_VALUES_LEN);
    let [state, range, payer, system] = accounts else {
        return Err(VerifierError::WrongAccount.into());
    };
    let state_key = Pubkey::find_program_address(&[STATE_SEED], program_id).0;
    if *state.key != state_key || state.owner != program_id || state.data_len() != STATE_LEN {
        return Err(VerifierError::WrongAccount.into());
    }
    let key: [u8; 32] = state.data.borrow()[..32].try_into().unwrap();
    groth16::verify(&key, values, proof).map_err(|_| VerifierError::InvalidProof)?;
    let v = apply_update(&mut state.data.borrow_mut(), values)?;
    let (range_key, bump) =
        Pubkey::find_program_address(&[RANGE_SEED, &v.headers_root], program_id);
    if *range.key != range_key {
        return Err(VerifierError::WrongAccount.into());
    }
    if range.owner != program_id {
        let seeds: &[&[u8]] = &[RANGE_SEED, &v.headers_root, &[bump]];
        create(program_id, range, payer, system, seeds, RANGE_LEN)?;
    }
    range
        .data
        .borrow_mut()
        .copy_from_slice(&[&v.first.to_le_bytes()[..], &v.last.to_le_bytes(), &[bump]].concat());
    Ok(())
}

/// Moves the anchor in `state` (the state account's data) one proven step: the proof must start from the stored
/// anchor. Returns the values, whose headers root and blocks the caller records.
pub fn apply_update(state: &mut [u8], values: &[u8]) -> Result<PublicValues, VerifierError> {
    let v = PublicValues::decode(values)?;
    if state[32..64] != v.anchor_in {
        return Err(VerifierError::WrongAnchor);
    }
    state[32..64].copy_from_slice(&v.anchor_out);
    state[64..72].copy_from_slice(&v.epoch.to_le_bytes());
    Ok(v)
}

/// What a P1 proof commits: the anchor in and out, the epoch of its checkpoint, and the headers root over the blocks
/// `first` to `last`.
pub struct PublicValues {
    pub anchor_in: [u8; 32],
    pub anchor_out: [u8; 32],
    pub epoch: u64,
    pub headers_root: [u8; 32],
    pub first: u64,
    pub last: u64,
}

impl PublicValues {
    pub fn decode(values: &[u8]) -> Result<Self, VerifierError> {
        if values.len() != PUBLIC_VALUES_LEN {
            return Err(VerifierError::BadPublicValues);
        }
        let word = |i: usize| -> [u8; 32] { values[32 * i..32 * (i + 1)].try_into().unwrap() };
        let small = |i: usize| -> Result<u64, VerifierError> {
            let w = word(i);
            if w[..24].iter().any(|b| *b != 0) {
                return Err(VerifierError::BadPublicValues);
            }
            Ok(u64::from_be_bytes(w[24..].try_into().unwrap()))
        };
        Ok(PublicValues {
            anchor_in: word(0),
            anchor_out: word(1),
            epoch: small(2)?,
            headers_root: word(3),
            first: small(4)?,
            last: small(5)?,
        })
    }
}

/// Creates `account` at its program address with `len` bytes, owned by this program. Transfer, allocate and assign
/// rather than create: lamports someone sent to the address in advance cannot block it.
fn create<'a>(
    program_id: &Pubkey,
    account: &AccountInfo<'a>,
    payer: &AccountInfo<'a>,
    system: &AccountInfo<'a>,
    seeds: &[&[u8]],
    len: usize,
) -> ProgramResult {
    let rent = Rent::default().minimum_balance(len);
    if account.lamports() < rent {
        invoke(
            &system_instruction::transfer(payer.key, account.key, rent - account.lamports()),
            &[payer.clone(), account.clone(), system.clone()],
        )?;
    }
    invoke_signed(
        &system_instruction::allocate(account.key, len as u64),
        &[account.clone(), system.clone()],
        &[seeds],
    )?;
    invoke_signed(
        &system_instruction::assign(account.key, program_id),
        &[account.clone(), system.clone()],
        &[seeds],
    )?;
    Ok(())
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
        return Err(VerifierError::WrongAccount.into());
    }
    let data = program_data.data.borrow();
    // UpgradeableLoaderState::ProgramData: tag 3 (u32), slot (u64), then Option<Pubkey> for the upgrade authority.
    let authority_is_payer = data.len() >= 45
        && data[..4] == [3, 0, 0, 0]
        && data[12] == 1
        && data[13..45] == payer.key.as_ref()[..];
    if !authority_is_payer || !payer.is_signer {
        return Err(VerifierError::NotUpgradeAuthority.into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values(anchor_in: u8, anchor_out: u8, epoch: u64, first: u64, last: u64) -> Vec<u8> {
        let small = |x: u64| {
            let mut w = [0u8; 32];
            w[24..].copy_from_slice(&x.to_be_bytes());
            w
        };
        [
            [anchor_in; 32],
            [anchor_out; 32],
            small(epoch),
            [0x77; 32],
            small(first),
            small(last),
        ]
        .concat()
    }

    /// Each proof starts from the stored anchor and moves it one step: as `EthereumFinalityVerifier.update`.
    #[test]
    fn an_update_follows_the_anchor() {
        let mut state = [[0x11u8; 32], [0xaa; 32]].concat();
        state.extend_from_slice(&5u64.to_le_bytes());
        let v = apply_update(&mut state, &values(0xaa, 0xbb, 6, 100, 163)).unwrap();
        assert_eq!(&state[32..64], &[0xbb; 32]);
        assert_eq!(u64::from_le_bytes(state[64..72].try_into().unwrap()), 6);
        assert_eq!((v.headers_root, v.first, v.last), ([0x77; 32], 100, 163));
        assert_eq!(&state[..32], &[0x11; 32], "the program key never moves");
        // The same proof again starts from an anchor no longer held.
        assert!(matches!(
            apply_update(&mut state, &values(0xaa, 0xbb, 6, 100, 163)),
            Err(VerifierError::WrongAnchor)
        ));
        assert!(apply_update(&mut state, &values(0xbb, 0xcc, 7, 164, 200)).is_ok());
    }

    #[test]
    fn public_values_are_six_words_of_the_right_widths() {
        let mut state = [[0x11u8; 32], [0xaa; 32], [0u8; 32]].concat();
        state.truncate(72);
        let mut v = values(0xaa, 0xbb, 6, 100, 163);
        v[2 * 32] = 1;
        assert!(
            matches!(
                apply_update(&mut state, &v),
                Err(VerifierError::BadPublicValues)
            ),
            "an epoch past 64 bits"
        );
        let mut v = values(0xaa, 0xbb, 6, 100, 163);
        v[5 * 32 + 23] = 1;
        assert!(
            matches!(
                apply_update(&mut state, &v),
                Err(VerifierError::BadPublicValues)
            ),
            "a block past 64 bits"
        );
        let v = values(0xaa, 0xbb, 6, 100, 163);
        assert!(matches!(
            apply_update(&mut state, &v[..191]),
            Err(VerifierError::BadPublicValues)
        ));
        assert_eq!(&state[32..64], &[0xaa; 32], "nothing moved");
    }
}
