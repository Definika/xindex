//! What P1 and P2 share on Stellar: `FinalityVerifier.sol`'s light client of Ethereum (`xindex_core::light_client`),
//! with its anchor and recorded ranges in Soroban storage. Each verifier contract passes its own proof check, SP1's for P1
//! and RISC Zero's for P2, and is otherwise the same code, as the two EVM verifiers are.
//!
//! No owner and no upgrade path: the deployer's constructor arguments set the program key (or image id) and the first
//! anchor at deployment, atomically, so nobody can set them first; every later anchor is proven. The contract has no
//! call that replaces its Wasm, and the vault pins its code by hash.
//!
//! Storage: the state in the instance; each recorded range in persistent storage under its headers root, extended to
//! the network's maximum TTL when written. A range archived later is restored by the transaction that reads it, never
//! read as missing.

use alloc::vec::Vec;
use soroban_sdk::{contracterror, contracttype, panic_with_error, Bytes, BytesN, Env};
use xindex_core::groth16::ProofError;
use xindex_core::light_client::{self as lc, CheckpointClaim, LogClaim};

use crate::crypto::Soroban;

/// The light client's refusals, numbered from 101 so that one reaching a caller through the vault, whose own codes run
/// from 1, names its source.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum VerifierError {
    ZeroValue = 101,
    WrongAnchor = 102,
    BadPublicValues = 103,
    Lagging = 104,
    UnknownHeaders = 105,
    NotInRange = 106,
    BadHeaderPath = 107,
    BadEventProof = 108,
    BadReceiptProof = 109,
    NoReceipt = 110,
    FailedTransaction = 111,
    NoLog = 112,
    NotTheLog = 113,
    NotTheCheckpoint = 114,
    InvalidProof = 115,
    /// An update's checkpoint is of an epoch that began more than MAX_UPDATE_AGE ago (B5-01).
    Stale = 116,
}

impl From<lc::Error> for VerifierError {
    fn from(e: lc::Error) -> Self {
        match e {
            lc::Error::WrongAnchor => VerifierError::WrongAnchor,
            lc::Error::BadPublicValues => VerifierError::BadPublicValues,
            lc::Error::Lagging => VerifierError::Lagging,
            lc::Error::UnknownHeaders => VerifierError::UnknownHeaders,
            lc::Error::NotInRange => VerifierError::NotInRange,
            lc::Error::BadHeaderPath => VerifierError::BadHeaderPath,
            lc::Error::BadEventProof => VerifierError::BadEventProof,
            lc::Error::BadReceiptProof => VerifierError::BadReceiptProof,
            lc::Error::NoReceipt => VerifierError::NoReceipt,
            lc::Error::FailedTransaction => VerifierError::FailedTransaction,
            lc::Error::NoLog => VerifierError::NoLog,
            lc::Error::NotTheLog => VerifierError::NotTheLog,
            lc::Error::NotTheCheckpoint => VerifierError::NotTheCheckpoint,
            lc::Error::Stale => VerifierError::Stale,
        }
    }
}

/// The verifier's state: its program key (P1) or image id (P2), the anchor, the anchor's epoch, and the network's
/// beacon genesis time, which dates the epoch for the lag rule (LG-4).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct State {
    pub key: BytesN<32>,
    pub anchor: BytesN<32>,
    pub epoch: u64,
    pub genesis_time: u64,
}

/// The execution blocks one proof covered.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Range {
    pub first: u64,
    pub last: u64,
}

/// Where the state and each range live: public so that tests can record a range as a proof would have.
#[contracttype]
#[derive(Clone)]
pub enum Key {
    State,
    Range(BytesN<32>),
}

/// A proof system's check: succeeds only if `proof` shows that the program `key` committed `values`.
pub type ProofCheck = fn(&Soroban, &[u8; 32], &[u8], &[u8]) -> Result<(), ProofError>;

fn fail(env: &Env, e: VerifierError) -> ! {
    panic_with_error!(env, e)
}

fn keep_instance(env: &Env) {
    let max = env.storage().max_ttl();
    env.storage().instance().extend_ttl(max / 2, max);
}

/// The constructor: the program key and the first anchor, checked during the vault chain's registration delay as the
/// BNB verifier's first set is, and the genesis time of the network the program was built for.
pub fn construct(env: &Env, key: BytesN<32>, anchor: BytesN<32>, epoch: u64, genesis_time: u64) {
    let zero = BytesN::from_array(env, &[0u8; 32]);
    if key == zero || anchor == zero || genesis_time == 0 {
        fail(env, VerifierError::ZeroValue);
    }
    env.storage().instance().set(
        &Key::State,
        &State {
            key,
            anchor,
            epoch,
            genesis_time,
        },
    );
    keep_instance(env);
}

pub fn state(env: &Env) -> State {
    env.storage().instance().get(&Key::State).unwrap()
}

/// The last second the anchor may be advanced from: MAX_LAG after its epoch began.
pub fn lag_ends(env: &Env) -> u64 {
    let s = state(env);
    lc::lag_ends(s.epoch, s.genesis_time)
}

/// The blocks the proof that recorded `headers_root` covered, if one did.
pub fn range(env: &Env, headers_root: &BytesN<32>) -> Option<Range> {
    env.storage()
        .persistent()
        .get(&Key::Range(headers_root.clone()))
}

/// Anyone, within MAX_LAG of the anchor's epoch: accepts a proof of the statement from the stored anchor, and records
/// the blocks it covers. The lag is checked before the proof, so a stale anchor costs little to refuse (LG-4).
pub fn update(env: &Env, values: &Bytes, proof: &Bytes, check: ProofCheck) {
    keep_instance(env);
    let mut s = state(env);
    if let Err(e) = lc::check_lag(s.epoch, s.genesis_time, env.ledger().timestamp() as i64) {
        fail(env, e.into());
    }
    let values: Vec<u8> = values.to_alloc_vec();
    if check(
        &Soroban(env),
        &s.key.to_array(),
        &values,
        &proof.to_alloc_vec(),
    )
    .is_err()
    {
        fail(env, VerifierError::InvalidProof);
    }
    let mut anchor = s.anchor.to_array();
    let now = env.ledger().timestamp() as i64;
    let v = lc::advance(&mut anchor, &mut s.epoch, &values, s.genesis_time, now)
        .unwrap_or_else(|e| fail(env, e.into()));
    s.anchor = BytesN::from_array(env, &anchor);
    env.storage().instance().set(&Key::State, &s);
    let key = Key::Range(BytesN::from_array(env, &v.headers_root));
    env.storage().persistent().set(
        &key,
        &Range {
            first: v.first,
            last: v.last,
        },
    );
    let max = env.storage().max_ttl();
    env.storage().persistent().extend_ttl(&key, max / 2, max);
}

fn range_of(env: &Env, headers_root: &[u8; 32]) -> Result<(u64, u64), lc::Error> {
    range(env, &BytesN::from_array(env, headers_root))
        .map(|r| (r.first, r.last))
        .ok_or(lc::Error::UnknownHeaders)
}

/// The vault's call: succeeds only if `proof` shows that log, of a successful transaction, in its block, under a
/// headers root a proof recorded.
pub fn verify_event(
    env: &Env,
    block: u64,
    emitter: &BytesN<20>,
    topic0: &BytesN<32>,
    topic1: &BytesN<32>,
    data_hash: &BytesN<32>,
    proof: &Bytes,
) {
    let claim = LogClaim {
        block,
        emitter: emitter.to_array(),
        topic0: topic0.to_array(),
        topic1: topic1.to_array(),
        data_hash: data_hash.to_array(),
    };
    if let Err(e) = lc::verify_event(&Soroban(env), &proof.to_alloc_vec(), &claim, |root| {
        range_of(env, root)
    }) {
        fail(env, e.into());
    }
}

/// The vault's call: succeeds only if `proof` places that block, with that timestamp and state root, under a headers
/// root a proof recorded, as `FinalityVerifier.verifyCheckpoint` returns it.
pub fn verify_checkpoint(
    env: &Env,
    block: u64,
    timestamp: u64,
    state_root: &BytesN<32>,
    proof: &Bytes,
) {
    let claim = CheckpointClaim {
        block,
        timestamp,
        state_root: state_root.to_array(),
    };
    if let Err(e) = lc::verify_checkpoint(&Soroban(env), &proof.to_alloc_vec(), &claim, |root| {
        range_of(env, root)
    }) {
        fail(env, e.into());
    }
}

/// Succeeds only if `proof` is the proof system's proof that the program `key` committed `values`.
pub fn check_proof(env: &Env, key: &BytesN<32>, proof: &Bytes, values: &Bytes, check: ProofCheck) {
    if check(
        &Soroban(env),
        &key.to_array(),
        &values.to_alloc_vec(),
        &proof.to_alloc_vec(),
    )
    .is_err()
    {
        fail(env, VerifierError::InvalidProof);
    }
}
