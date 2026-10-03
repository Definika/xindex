//! P1 on Solana (Stage B spec, section 10): a light client of Ethereum that anyone advances with an SP1 proof that a
//! checkpoint is finalized by two thirds of the anchor's validators, and that proves a vault message by its receipt in
//! any execution block those proofs covered. The twin of `EthereumFinalityVerifier.sol`, behind the vault's verifier
//! interface (`xindex_vault::verify`).
//!
//! What P1 and P2 share is this crate's core, `process_with`, as `FinalityVerifier.sol` is what both EVM verifiers
//! share: the anchor, the recorded ranges, the headers tree, the receipt proofs and the checkpoints. Each system adds
//! only the check of its proof, a `ProofSystem`: P1's entrypoint passes SP1's (`SP1`), and P2, the `risc0-verifier`
//! program, RISC Zero's.
//!
//! No owner and no upgrade: the deployer's upgrade authority sets the program key and the first anchor once, then
//! makes the program immutable, which the vault requires of a verifier. Every later anchor is proven. A plain Solana
//! program, with no program id of its own, so one build can serve one vault's P1 under any key.
//!
//! Instructions, by their first byte:
//! - `0`, verify_event: the vault's call. Data `block (u64) ++ emitter (20) ++ topic0 ++ topic1 ++ keccak256(data)
//!   ++ proof`, accounts `[range]`, or `[range, buffer]` with an empty proof, read then from the buffer. Succeeds only
//!   if the proof shows that log, of a successful transaction, in a block a recorded proof covered.
//! - `1`, initialize: data `programKey ++ anchor ++ epoch (u64) ++ genesisTime (u64)`, accounts `[state, authority
//!   (signer), system program, program data]`; once, and only by the program's upgrade authority. `genesisTime` is the
//!   beacon chain's: 1606824023 on mainnet, 1655733600 on Sepolia.
//! - `2`, update: data `publicValues (192) ++ proof`, accounts `[state, range, payer (signer), system program]`.
//!   Anyone, until a day after the stored anchor's epoch began. Accepts a proof of the statement from the stored
//!   anchor, and records the blocks it covers in the range account of their headers root. P1's proof is 356 bytes.
//! - `3`, check_proof: data `programKey ++ proof ++ publicValues`, no accounts. Succeeds only if the proof is the
//!   system's Groth16 proof that the program committed those values: SP1 v6's, for P1.
//! - `4`, verify_checkpoint: the vault's call. Data `block (u64) ++ timestamp (u64) ++ stateRoot (32) ++ proof`,
//!   accounts `[range]`, or `[range, buffer]` with an empty proof, read then from the buffer. The proof is an event
//!   proof's header part. Succeeds only if that block, with that timestamp and state root, lies at its place under a
//!   recorded headers root, as `FinalityVerifier.verifyCheckpoint` returns it.
//!
//! Integers are little-endian. `state` is the account at the seed `"verifier"`; a range is at `"range" ++ headersRoot`.

pub mod event;
pub mod groth16;
pub mod mpt;
pub mod rlp;
pub mod vk;

use anchor_lang::prelude::SolanaSysvar;
use anchor_lang::solana_program::account_info::AccountInfo;
use anchor_lang::solana_program::bpf_loader_upgradeable;
use anchor_lang::solana_program::clock::Clock;
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
pub const VERIFY_CHECKPOINT: u8 = 4;

/// The log the vault passes: block (8), emitter (20), topic0, topic1 and the data's hash (32 each).
pub const LOG_LEN: usize = 8 + 20 + 3 * 32;
/// The checkpoint the vault passes: block (8), timestamp (8) and state root (32).
pub const CHECKPOINT_LEN: usize = 8 + 8 + 32;
/// `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`, as the P1 program commits it.
pub const PUBLIC_VALUES_LEN: usize = 6 * 32;
/// The state: the program key, the anchor, the anchor's epoch, and the network's genesis time.
pub const STATE_LEN: usize = 32 + 32 + 8 + 8;
/// How long after its anchor's epoch began the verifier still takes a proof, as `FinalityVerifier.MAX_LAG`. Past it the
/// verifier stops for good: catching up from an old anchor would trust stake that may have left since, and could sign
/// a forged finality at no risk (LG-4).
pub const MAX_LAG: u64 = 86_400;
/// An epoch's length: 32 slots of 12 seconds.
pub const SECONDS_PER_EPOCH: u64 = 384;
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
    Lagging,
    NotTheCheckpoint,
}

impl From<VerifierError> for ProgramError {
    fn from(e: VerifierError) -> Self {
        ProgramError::Custom(e as u32)
    }
}

pub fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    solana_keccak_hasher::hashv(parts).to_bytes()
}

/// What a proof system adds to the shared core: the length of its proof, and the check that `proof` proves the program
/// `key` committed `public_values`, as each EVM verifier's `_verifyProof`.
pub struct ProofSystem {
    pub proof_len: usize,
    pub verify: fn(key: &[u8; 32], public_values: &[u8], proof: &[u8]) -> bool,
}

/// P1's: SP1 v6's Groth16 proof (`groth16`).
pub const SP1: ProofSystem = ProofSystem {
    proof_len: groth16::PROOF_LEN,
    verify: |key, values, proof| groth16::verify(key, values, proof).is_ok(),
};

#[cfg(not(feature = "no-entrypoint"))]
anchor_lang::solana_program::entrypoint!(process);

/// P1's entrypoint: the shared core with SP1's check.
pub fn process(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    process_with(program_id, accounts, data, &SP1)
}

/// The shared core of P1 and P2: every instruction, with `system` checking each proof.
pub fn process_with(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
    system: &ProofSystem,
) -> ProgramResult {
    let (tag, rest) = data.split_first().ok_or(VerifierError::BadInstruction)?;
    match *tag {
        VERIFY_EVENT => verify_event(program_id, accounts, rest),
        INITIALIZE => initialize(program_id, accounts, rest),
        UPDATE => update(program_id, accounts, rest, system),
        CHECK_PROOF => {
            let (key, rest) = split::<32>(rest)?;
            if rest.len() < system.proof_len {
                return Err(VerifierError::BadInstruction.into());
            }
            let (proof, values) = rest.split_at(system.proof_len);
            if !(system.verify)(&key, values, proof) {
                return Err(VerifierError::InvalidProof.into());
            }
            Ok(())
        }
        VERIFY_CHECKPOINT => verify_checkpoint(program_id, accounts, rest),
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
    let range = accounts.first().ok_or(VerifierError::WrongAccount)?;
    with_proof(accounts, &data[LOG_LEN..], |proof| {
        let p = event::parse(proof)?;
        let (first, last) = read_range(program_id, range, &p.header.headers_root)?;
        event::check_header(&p.header, first, last)?;
        if p.header.number != block {
            return Err(VerifierError::NotTheLog);
        }
        let log = event::log(&p.header.receipts_root, &p.nodes, p.tx_index, p.log_index)?;
        if log.emitter != emitter
            || log.topic0 != topic0
            || log.topic1 != topic1
            || keccak(&[log.data]) != data_hash
        {
            return Err(VerifierError::NotTheLog);
        }
        Ok(())
    })
}

/// Runs `check` on the proof: `inline` when it is not empty, else the one staged in the loader buffer that follows the
/// range among `accounts`, as its length (u32) then its bytes. A proof too long for a transaction is staged so. What
/// the buffer holds is no more trusted than instruction data, so whose buffer it is does not matter; it is read in
/// place, never copied, so a receipt of megabytes needs no heap.
fn with_proof(
    accounts: &[AccountInfo],
    inline: &[u8],
    check: impl FnOnce(&[u8]) -> Result<(), VerifierError>,
) -> ProgramResult {
    if !inline.is_empty() {
        return Ok(check(inline)?);
    }
    let buffer = accounts.get(1).ok_or(VerifierError::WrongAccount)?;
    if *buffer.owner != bpf_loader_upgradeable::id() {
        return Err(VerifierError::WrongAccount.into());
    }
    let staged = buffer.data.borrow();
    if staged.len() < BUFFER_METADATA + 4 || staged[..4] != BUFFER_TAG {
        return Err(VerifierError::WrongAccount.into());
    }
    let len = u32::from_le_bytes(
        staged[BUFFER_METADATA..BUFFER_METADATA + 4]
            .try_into()
            .unwrap(),
    ) as usize;
    let start = BUFFER_METADATA + 4;
    let proof = staged
        .get(start..start + len)
        .ok_or(VerifierError::BadEventProof)?;
    Ok(check(proof)?)
}

// ---------------------------------------------------------------------
// verify_checkpoint
// ---------------------------------------------------------------------

/// The vault's checkpoint: the block, its timestamp and its state root, claimed by the caller and attested only if a
/// header proof places that very leaf under a recorded headers root, as `FinalityVerifier.verifyCheckpoint` returns
/// it on an EVM chain.
fn verify_checkpoint(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() < CHECKPOINT_LEN {
        return Err(VerifierError::BadInstruction.into());
    }
    let block = u64::from_le_bytes(data[..8].try_into().unwrap());
    let timestamp = u64::from_le_bytes(data[8..16].try_into().unwrap());
    let state_root: [u8; 32] = data[16..48].try_into().unwrap();
    let range = accounts.first().ok_or(VerifierError::WrongAccount)?;
    with_proof(accounts, &data[CHECKPOINT_LEN..], |proof| {
        let h = event::parse_header(proof)?;
        let (first, last) = read_range(program_id, range, &h.headers_root)?;
        event::check_header(&h, first, last)?;
        if h.number != block || h.timestamp != timestamp || h.state_root != state_root {
            return Err(VerifierError::NotTheCheckpoint);
        }
        Ok(())
    })
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
    let (genesis_time, rest) = split::<8>(rest)?;
    if !rest.is_empty() || key == [0u8; 32] || anchor == [0u8; 32] || genesis_time == [0u8; 8] {
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
        .copy_from_slice(&[&key[..], &anchor, &epoch, &genesis_time].concat());
    Ok(())
}

fn update(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
    proofs: &ProofSystem,
) -> ProgramResult {
    if data.len() != PUBLIC_VALUES_LEN + proofs.proof_len {
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
    check_lag(&state.data.borrow(), Clock::get()?.unix_timestamp)?;
    let key: [u8; 32] = state.data.borrow()[..32].try_into().unwrap();
    if !(proofs.verify)(&key, values, proof) {
        return Err(VerifierError::InvalidProof.into());
    }
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

/// Refuses an update at `now` (unix seconds) more than `MAX_LAG` after the stored anchor's epoch began, as
/// `FinalityVerifier.update` does: `now > genesisTime + epoch * 384 + MAX_LAG`. The statement bounds a step to 225
/// epochs, which is one day, so an honest prover keeps up only by proving at least daily (LG-4).
pub fn check_lag(state: &[u8], now: i64) -> Result<(), VerifierError> {
    let epoch = u64::from_le_bytes(state[64..72].try_into().unwrap());
    let genesis_time = u64::from_le_bytes(state[72..80].try_into().unwrap());
    let deadline = epoch
        .saturating_mul(SECONDS_PER_EPOCH)
        .saturating_add(genesis_time)
        .saturating_add(MAX_LAG);
    if i128::from(now) > i128::from(deadline) {
        return Err(VerifierError::Lagging);
    }
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

    /// LG-4: an update is taken until exactly a day after the anchor's epoch began, and refused a second later.
    #[test]
    fn test_lg4_an_update_comes_at_most_a_day_after_its_anchor() {
        let (genesis, epoch) = (1_606_824_023u64, 400_000u64);
        let state = [
            &[0x11u8; 32][..],
            &[0xaa; 32],
            &epoch.to_le_bytes(),
            &genesis.to_le_bytes(),
        ]
        .concat();
        let bound = (genesis + epoch * 384 + 86_400) as i64;
        assert_eq!(check_lag(&state, bound), Ok(()));
        assert_eq!(check_lag(&state, bound + 1), Err(VerifierError::Lagging));
        assert_eq!(check_lag(&state, 0), Ok(()), "a clock before the bound");
        // A year-old anchor, which the statement alone would still let a prover step forward from.
        assert_eq!(
            check_lag(&state, bound + 365 * 86_400),
            Err(VerifierError::Lagging)
        );
        let mut far = state.clone();
        far[64..72].copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(check_lag(&far, i64::MAX), Ok(()), "saturates, never wraps");
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
