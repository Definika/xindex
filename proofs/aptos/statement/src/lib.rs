//! Aptos's state, proven to Ethereum (`design/2026-10-04-four-chains-interfaces.md`): the statement
//! `AptosStateVerifier`'s SP1 program proves, in plain Rust, tested natively on mainnet's own data.
//!
//! **Finality.** AptosBFT commits a block once more than two thirds of its epoch's voting power sign a `LedgerInfo`
//! naming it: one BLS12-381 aggregate (min-pk, `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`) over
//! `sha3_256("APTOS::LedgerInfo") ++ bcs(ledger_info)`, its signers a bitmask over the epoch's validators in order
//! (`ValidatorVerifier::verify_multi_signatures`, quorum `total * 2 / 3 + 1`). The ledger info that ends an epoch
//! carries `next_epoch_state`, the next epoch's validators, so a chain of epoch-ending ledger infos, each signed by the
//! set the one before named, follows the validators from a set the verifier trusts (`EpochChangeProof::verify`).
//!
//! **State.** A ledger info commits to the transaction accumulator (`executed_state_id`) over every transaction's
//! `TransactionInfo` up to its version. A transaction info carries its status and `event_root_hash`, the accumulator
//! of its events. The vault proves a slot as NEAR's and Stellar's do, by a successful `attest(slots, values)`, which
//! aborts unless every slot holds its value and emits one module event `<package>::vault::Attested { record }`: the
//! statement writes that event itself from the slots and values, and the transaction info with the status `Success`,
//! and finds both under the ledger info. Only the vault's module can make an `Attested`, and `attest` is an entry
//! function, so one transaction holds at most one; the statement requires exactly one.
//!
//! Every preimage is written from typed fields (`bcs`); the keys' points are given uncompressed and checked against
//! the compressed keys the ledger infos carry, as P1 checks the beacon registry's, without the square root. Like
//! Aptos's own aggregation, the statement does not check a key's subgroup: each validator proved possession of its
//! key on chain, which checks it.

extern crate alloc;

pub mod bcs;

#[cfg(feature = "json")]
pub mod json;
#[cfg(feature = "testkit")]
pub mod testkit;

use alloc::vec::Vec;
use bls12_381::G1Projective;
use group::Curve;
use serde::{Deserialize, Serialize};
use xindex_finality::bls;

pub type Word = [u8; 32];

/// `keccak256("xindex.v4.aptos.update")` and `keccak256("xindex.v4.aptos.slots")`: the public values' first word.
pub const UPDATE: Word = hex32("11b68bff5fb1fa671de31dcd59a9b0ec1422f35531326db399eae9b702e04381");
pub const SLOTS: Word = hex32("f7afe75b71ac8888a50e79e2c776de207979c4690cd0d1290dcbabf7050a82f7");
/// `keccak256("xindex.v4.vault-attest")`: the record's first word.
pub const ATTEST_DOMAIN: Word =
    hex32("b0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c");
/// The vault's module and its event: `<package>::vault::Attested`.
pub const MODULE: &str = "vault";
pub const EVENT: &str = "Attested";
/// `MAX_ACCUMULATOR_PROOF_DEPTH`.
pub const MAX_DEPTH: usize = 63;

const fn hex32(s: &str) -> Word {
    let b = s.as_bytes();
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = (digit(b[2 * i]) << 4) | digit(b[2 * i + 1]);
        i += 1;
    }
    out
}

const fn digit(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("hex"),
    }
}

/// `ValidatorConsensusInfo`: an account, its consensus key (48 bytes, compressed G1) and its voting power.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Validator {
    pub address: Word,
    pub public_key: Vec<u8>,
    pub voting_power: u64,
}

/// `EpochState`: an epoch and its validators, in the order the signers' bitmask counts them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EpochState {
    pub epoch: u64,
    pub validators: Vec<Validator>,
}

/// `BlockInfo`, as given; the statement writes and hashes it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockInfo {
    pub epoch: u64,
    pub round: u64,
    pub id: Word,
    /// The transaction accumulator's root after `version`.
    pub executed_state_id: Word,
    pub version: u64,
    pub timestamp_usecs: u64,
    /// Set on the ledger info that ends an epoch: the next epoch's validators.
    pub next_epoch_state: Option<EpochState>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerInfo {
    pub commit_info: BlockInfo,
    pub consensus_data_hash: Word,
}

/// `LedgerInfoWithSignatures::V0`: the ledger info, its signers' bitmask (`BitVec`) and their aggregate signature (96
/// bytes, compressed G2); and, for the statement, each signer's key as an uncompressed point (96 bytes), in bitmask
/// order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Signed {
    pub ledger_info: LedgerInfo,
    pub bitmask: Vec<u8>,
    pub signature: Vec<u8>,
    pub points: Vec<Vec<u8>>,
}

/// A `TransactionInfo`'s fields but its status, which the statement writes `Success`, and its event root, which it
/// computes from the events.
// One input is read once per run; boxing the larger variant would only add an indirection.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransactionInfo {
    V0 {
        gas_used: u64,
        transaction_hash: Word,
        state_change_hash: Word,
        state_checkpoint_hash: Option<Word>,
        auxiliary_info_hash: Option<Word>,
    },
    V1 {
        gas_used: u64,
        transaction_hash: Word,
        state_change_hash: Word,
        state_checkpoint_hash: Option<Word>,
        hot_state_checkpoint_hash: Option<Word>,
        auxiliary_info_hash: Option<Word>,
        position_state_checkpoint_hash: Option<Word>,
        placeholders: [Option<Word>; 7],
    },
}

/// A transaction under a ledger info: its version, its info, the accumulator path from its info to the root (siblings
/// from the bottom level up), and all its events, in order, as their BCS.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Included {
    pub version: u64,
    pub info: TransactionInfo,
    pub siblings: Vec<Word>,
    pub events: Vec<Vec<u8>>,
}

/// The two claims. Each starts from a set the verifier trusts and follows `hops`, epoch-ending ledger infos, each
/// signed by the set before it.
// One input is read once per run; boxing the larger claim would only add an indirection.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    /// A later epoch's set to trust: at least one hop.
    Update {
        trusted: EpochState,
        hops: Vec<Signed>,
    },
    /// The vault's slots: `ledger_info`, of the epoch the hops reach, is signed by that epoch's set, and the transaction
    /// under it succeeded with exactly one `Attested` event of `package`, whose record is the one the statement writes.
    Slots {
        trusted: EpochState,
        hops: Vec<Signed>,
        ledger_info: Signed,
        transaction: Included,
        chain_id: u64,
        package: Word,
        vault_id: Word,
        timestamp: u64,
        slots: Vec<Word>,
        values: Vec<Word>,
    },
}

/// What a claim proves: the public values, `Output::abi_encode`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    Update {
        trusted_epoch: u64,
        trusted_set: Word,
        epoch: u64,
        set: Word,
        time: u64,
    },
    Slots {
        chain_id: u64,
        trusted_epoch: u64,
        trusted_set: Word,
        package: Word,
        vault_id: Word,
        version: u64,
        timestamp: u64,
        slots_hash: Word,
    },
}

impl Output {
    /// `abi.encode` of the claim's words, as `AptosStateVerifier` decodes them:
    /// update `(UPDATE, trustedEpoch, trustedSet, epoch, set, time)`, six words;
    /// slots `(SLOTS, chainId, trustedEpoch, trustedSet, package, vaultId, version, timestamp, slotsHash)`, nine.
    pub fn abi_encode(&self) -> Vec<u8> {
        let words: Vec<Word> = match self {
            Output::Update {
                trusted_epoch,
                trusted_set,
                epoch,
                set,
                time,
            } => alloc::vec![
                UPDATE,
                bcs::word_u64(*trusted_epoch),
                *trusted_set,
                bcs::word_u64(*epoch),
                *set,
                bcs::word_u64(*time),
            ],
            Output::Slots {
                chain_id,
                trusted_epoch,
                trusted_set,
                package,
                vault_id,
                version,
                timestamp,
                slots_hash,
            } => alloc::vec![
                SLOTS,
                bcs::word_u64(*chain_id),
                bcs::word_u64(*trusted_epoch),
                *trusted_set,
                *package,
                *vault_id,
                bcs::word_u64(*version),
                bcs::word_u64(*timestamp),
                *slots_hash,
            ],
        };
        words.concat()
    }
}

/// Why a claim does not hold. The index names the ledger info: the hops in order, then a slots claim's own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// An update without a hop.
    NoHops,
    /// Ledger info `i` is of another epoch than the set it is checked against, or names a next epoch that does not
    /// follow it.
    WrongEpoch(usize),
    /// Hop `i` ends no epoch.
    NoNextEpoch(usize),
    /// Ledger info `i`'s bitmask is not exactly one bit a validator, or names a validator past the set.
    BadBitmask(usize),
    /// Ledger info `i`'s signers hold no more than two thirds of the set's voting power.
    NoQuorum(usize),
    /// A signer of ledger info `i` has a key that is not 48 bytes, or a point that is not its key's.
    BadKey(usize),
    /// Ledger info `i`'s aggregate signature does not verify under its signers' keys.
    BadSignature(usize),
    /// More siblings than an accumulator has levels, or a version past them.
    BadPath,
    /// The transaction is after the ledger info.
    AfterLedgerInfo,
    /// The transaction info, written successful with its events' root, is not under the ledger info's root.
    NotInAccumulator,
    /// Not exactly one of the transaction's events has the vault's event type.
    NotOneEvent,
    /// The vault's event is not the one the statement writes.
    NotTheEvent,
    /// Slots and values differ in number.
    LengthMismatch,
}

/// The verifier's name for a validator set: `keccak256` of its BCS, `ValidatorVerifier`'s.
pub fn set_hash(validators: &[Validator]) -> Word {
    bcs::keccak(&[&bcs::validators(validators)])
}

/// Checks that `signed` is a ledger info of `set`'s epoch signed by validators of `set` holding more than two thirds
/// of its voting power (`ValidatorVerifier::verify_multi_signatures`); `at` names it in errors.
pub fn check(set: &EpochState, signed: &Signed, at: usize) -> Result<(), Error> {
    if signed.ledger_info.commit_info.epoch != set.epoch {
        return Err(Error::WrongEpoch(at));
    }
    let n = set.validators.len();
    // `BitVec`: bit `i` is `0x80 >> (i % 8)` of byte `i / 8`; exactly the bytes `n` bits need, and no bit past `n`
    // (`ValidatorVerifier::check_num_of_voters`).
    if signed.bitmask.len() != n.div_ceil(8) {
        return Err(Error::BadBitmask(at));
    }
    let mut key = G1Projective::identity();
    let mut power: u128 = 0;
    let mut total: u128 = 0;
    let mut k = 0;
    for i in 0..signed.bitmask.len() * 8 {
        if signed.bitmask[i / 8] & (0x80 >> (i % 8)) == 0 {
            continue;
        }
        let v = set.validators.get(i).ok_or(Error::BadBitmask(at))?;
        let compressed: &[u8; 48] = v
            .public_key
            .as_slice()
            .try_into()
            .map_err(|_| Error::BadKey(at))?;
        let point: &[u8; 96] = signed
            .points
            .get(k)
            .and_then(|p| p.as_slice().try_into().ok())
            .ok_or(Error::BadKey(at))?;
        key += bls::registry_key(point, compressed).ok_or(Error::BadKey(at))?;
        power += u128::from(v.voting_power);
        k += 1;
    }
    if k != signed.points.len() {
        return Err(Error::BadKey(at));
    }
    for v in &set.validators {
        total += u128::from(v.voting_power);
    }
    // `power >= total * 2 / 3 + 1`, which for integers is `3 * power > 2 * total`.
    if 3 * power <= 2 * total {
        return Err(Error::NoQuorum(at));
    }
    let signature: &[u8; 96] = signed
        .signature
        .as_slice()
        .try_into()
        .map_err(|_| Error::BadSignature(at))?;
    if !bls::verify(
        &key.to_affine(),
        &bcs::signing_message(&signed.ledger_info),
        signature,
    ) {
        return Err(Error::BadSignature(at));
    }
    Ok(())
}

/// Follows `hops` from `trusted` (`EpochChangeProof::verify`): each an epoch-ending ledger info of the current set's
/// epoch, signed by it, naming the next epoch's set. Returns the last set named, and the time of the ledger info that
/// named it (microseconds), or `trusted` and `None` without a hop.
pub fn follow<'a>(
    trusted: &'a EpochState,
    hops: &'a [Signed],
) -> Result<(&'a EpochState, Option<u64>), Error> {
    let mut set = trusted;
    let mut time = None;
    for (i, hop) in hops.iter().enumerate() {
        check(set, hop, i)?;
        let next = hop
            .ledger_info
            .commit_info
            .next_epoch_state
            .as_ref()
            .ok_or(Error::NoNextEpoch(i))?;
        if Some(next.epoch) != set.epoch.checked_add(1) {
            return Err(Error::WrongEpoch(i));
        }
        set = next;
        time = Some(hop.ledger_info.commit_info.timestamp_usecs);
    }
    Ok((set, time))
}

/// Proves that `t` succeeded under the accumulator root `root` of a ledger info at `ledger_version`, and that exactly
/// one of its events has the type `type_tag`, a module event with the data `data`.
///
/// The transaction info is written with the status `Success` and the root of the events given, so the path proves
/// both; an event's type is read only as a prefix, where its variant puts it, and a type tag's BCS is prefix-free, so
/// no event of that type escapes the count.
pub fn prove_event(
    root: &Word,
    ledger_version: u64,
    t: &Included,
    type_tag: &[u8],
    data: &[u8],
) -> Result<(), Error> {
    // `AccumulatorProof::verify` and `verify_transaction_info`: at most 63 levels, a version the levels hold, and
    // none past the ledger info's, which with the levels fixes the leaf's position.
    if t.siblings.len() > MAX_DEPTH || t.version >> t.siblings.len() != 0 {
        return Err(Error::BadPath);
    }
    if t.version > ledger_version {
        return Err(Error::AfterLedgerInfo);
    }
    let event_seed = bcs::seed("ContractEvent");
    let leaves: Vec<Word> = t
        .events
        .iter()
        .map(|e| bcs::sha3(&[&event_seed, e]))
        .collect();
    let event_root = bcs::accumulator_root(&bcs::seed("EventAccumulator"), &leaves);
    let info = bcs::transaction_info(&t.info, &event_root);
    let leaf = bcs::sha3(&[&bcs::seed("TransactionInfo"), &info]);
    if bcs::climb(
        &bcs::seed("TransactionAccumulator"),
        &leaf,
        t.version,
        &t.siblings,
    ) != *root
    {
        return Err(Error::NotInAccumulator);
    }
    let expected = bcs::module_event(type_tag, data);
    let mut found = 0;
    for e in &t.events {
        let typed = bcs::type_tag_at(e)
            .is_some_and(|at| e.get(at..).is_some_and(|rest| rest.starts_with(type_tag)));
        if typed {
            if *e != expected {
                return Err(Error::NotTheEvent);
            }
            found += 1;
        }
    }
    if found != 1 {
        return Err(Error::NotOneEvent);
    }
    Ok(())
}

/// Checks a claim and returns what it proves.
pub fn verify(input: &Input) -> Result<Output, Error> {
    match input {
        Input::Update { trusted, hops } => {
            if hops.is_empty() {
                return Err(Error::NoHops);
            }
            let (set, time) = follow(trusted, hops)?;
            Ok(Output::Update {
                trusted_epoch: trusted.epoch,
                trusted_set: set_hash(&trusted.validators),
                epoch: set.epoch,
                set: set_hash(&set.validators),
                time: time.ok_or(Error::NoHops)?,
            })
        }
        Input::Slots {
            trusted,
            hops,
            ledger_info,
            transaction,
            chain_id,
            package,
            vault_id,
            timestamp,
            slots,
            values,
        } => {
            if slots.len() != values.len() {
                return Err(Error::LengthMismatch);
            }
            let (set, _) = follow(trusted, hops)?;
            check(set, ledger_info, hops.len())?;
            let mut data = Vec::new();
            bcs::bytes(
                &mut data,
                &bcs::record(*chain_id, vault_id, *timestamp, slots, values),
            );
            let info = &ledger_info.ledger_info.commit_info;
            prove_event(
                &info.executed_state_id,
                info.version,
                transaction,
                &bcs::struct_tag(package, MODULE, EVENT),
                &data,
            )?;
            Ok(Output::Slots {
                chain_id: *chain_id,
                trusted_epoch: trusted.epoch,
                trusted_set: set_hash(&trusted.validators),
                package: *package,
                vault_id: *vault_id,
                version: transaction.version,
                timestamp: *timestamp,
                slots_hash: bcs::keccak(&[&bcs::abi_slots_values(slots, values)]),
            })
        }
    }
}
