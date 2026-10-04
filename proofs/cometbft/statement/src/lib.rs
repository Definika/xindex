//! The CometBFT state verifier's statement (`design/2026-10-04-four-chains-interfaces.md`): an EVM vault's storage on a
//! CometBFT chain, Injective's first, proven to Ethereum. Two claims, each from a header the verifier on Ethereum
//! already trusts:
//!
//! - **update**: light-client hops from the trusted header to a later one, which the verifier then trusts;
//! - **slots**: hops from a trusted header to header `H+1`, then ICS-23 proofs of the vault's slots under `H+1`'s
//!   `app_hash`, which commits the state after block `H`; the claim gives block `H`'s height and time.
//!
//! Every hop is tendermint-rs's light-client check (`ProdVerifier::verify_update_header`, the one IBC's SP1 Tendermint
//! client runs), with one rule tightened: **more than two thirds of the trusted set's power must sign the new header**,
//! adjacent or skipping, not ibc-go's third. An adjacent header must be signed by the trusted header's next set; a
//! skipping one by more than two thirds of that set and of its own. So a forged header always needs more than two
//! thirds of a set the verifier already trusts, as BNB Chain's verifier requires, and never merely a third.
//!
//! The rest of each hop is tendermint-rs's, unchanged: the headers' chain id is the trusted one's, heights and times
//! rise, each header's validator sets hash to what it names, the commit is for the header's hash, its signatures are
//! ed25519 over the canonical precommit and are counted once per validator. The trusted header's next set must hash to
//! its `next_validators_hash`, which tendermint-rs leaves to its caller. The trusting period is `MAX_LAG`, a day, timed
//! from the last header of the proof, so every set signs within a day of the header it was trusted at; the verifier on
//! Ethereum bounds the trusted header's own age by the same day against its clock.
//!
//! The state follows Injective's `x/evm` (`InjectiveLabs/sdk-go` `chain/evm/types/key.go`, an Ethermint fork): a
//! contract's slot is the key `0x02 ++ address ++ slot` of the `evm` store, holding the 32-byte value; the EVM reads an
//! absent key as zero. A slot's proof is the `ics23:iavl` operation of an `abci_query` with `prove`, under the `evm`
//! store's root, which the `ics23:simple` operation opens under the multistore root, the `app_hash` of the next header.
//! A present key is an existence proof, an absent one a non-existence proof (its two neighbours, adjacent). The value
//! is what the keeper's `GetState` returns for the stored bytes: `common.BytesToHash`, which the 32 bytes the keeper
//! writes pass unchanged. Checked on mainnet against `eth_getStorageAt` (`fixtures/generate.py`).

use core::time::Duration;

use ics23::{commitment_proof::Proof, CommitmentProof, HostFunctionsManager};
use prost::Message;
use serde::{Deserialize, Serialize};
use tendermint::{
    block::{signed_header::SignedHeader, Header},
    validator::Set,
};
use tendermint_light_client_verifier::{
    options::Options,
    types::{TrustThreshold, TrustedBlockState, UntrustedBlockState},
    ProdVerifier, Verdict, Verifier,
};
use tendermint_proto::{
    v0_38::types::{
        Header as RawHeader, SignedHeader as RawSignedHeader, ValidatorSet as RawValidatorSet,
    },
    Protobuf,
};
use tiny_keccak::{Hasher, Keccak};

#[cfg(feature = "json")]
pub mod json;

pub type Hash = [u8; 32];

/// How long a set stays trusted after its header, in seconds: the verifier's `MAX_LAG`, a day.
pub const MAX_LAG: u64 = 86_400;
/// The EVM module's store.
pub const EVM_STORE: &[u8] = b"evm";
/// `KeyPrefixStorage`: a contract's slots in the `evm` store.
pub const STORAGE_PREFIX: u8 = 0x02;

/// A header the hops lead to: its signed header, its validator set and its next validator set, each as CometBFT's
/// protobuf (`tendermint.types.SignedHeader`, `ValidatorSet`). The next set may be empty on the last hop only.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hop {
    pub signed_header: Vec<u8>,
    pub validators: Vec<u8>,
    pub next_validators: Vec<u8>,
}

/// The chain id the proof is for, the trusted header (`tendermint.types.Header`) and its next validator set, and the
/// hops from it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chain {
    pub chain_id: String,
    pub trusted_header: Vec<u8>,
    pub trusted_next_validators: Vec<u8>,
    pub hops: Vec<Hop>,
}

/// One slot and its ICS-23 proof in the `evm` store (`ics23.CommitmentProof`, an existence or non-existence proof).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Slot {
    pub slot: Hash,
    pub proof: Vec<u8>,
}

/// Block `H`'s header (`tendermint.types.Header`), the parent of the last header the hops reach; the vault; the
/// multistore proof of the `evm` store's root; and the slots.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    pub header: Vec<u8>,
    pub vault: [u8; 20],
    pub store_proof: Vec<u8>,
    pub slots: Vec<Slot>,
}

/// What the program reads: an update, or slots.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    Update(Chain),
    Slots(Chain, State),
}

/// A header as the verifier records it: its height, its hash, and its time in whole seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Head {
    pub height: u64,
    pub hash: Hash,
    pub time: u64,
}

/// What a proof commits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    /// The trusted header and the header the hops reach.
    Update {
        chain_id_hash: Hash,
        trusted: Head,
        head: Head,
    },
    /// The trusted header, block `H`'s height and time (seconds), the vault, and its slots' values.
    Slots {
        chain_id_hash: Hash,
        trusted: Head,
        height: u64,
        time: u64,
        vault: [u8; 20],
        slots: Vec<Hash>,
        values: Vec<Hash>,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// An input that does not decode as the protobuf it must be.
    Decode(&'static str),
    /// The trusted header is another chain's.
    WrongChain,
    /// The trusted header's next set is not the one it names.
    WrongNextValidators,
    /// An update with no hop.
    NoHops,
    /// A hop before the last without the next set the following hop is checked against.
    MissingNextValidators { hop: usize },
    /// A hop tendermint-rs refuses, and its verdict.
    Hop { hop: usize, verdict: Box<Verdict> },
    /// A header dated before 1970.
    BadTime,
    /// Block `H` is not the parent of the last header.
    NotTheParent,
    /// The multistore proof does not open the `evm` store under the last header's `app_hash`.
    StoreProof,
    /// A slot's proof does not prove it present or absent under the `evm` store's root.
    SlotProof { slot: usize },
}

/// `keccak256`.
pub fn keccak(parts: &[&[u8]]) -> Hash {
    let mut k = Keccak::v256();
    for p in parts {
        k.update(p);
    }
    let mut out = [0u8; 32];
    k.finalize(&mut out);
    out
}

/// The public values' first word: which claim they are.
pub fn update_kind() -> Hash {
    keccak(&[b"xindex.v4.cometbft.update"])
}

pub fn slots_kind() -> Hash {
    keccak(&[b"xindex.v4.cometbft.slots"])
}

/// The `evm` store's key of `slot` of `vault`.
pub fn storage_key(vault: &[u8; 20], slot: &Hash) -> Vec<u8> {
    [&[STORAGE_PREFIX][..], vault, slot].concat()
}

/// What the EVM reads for a stored value: `common.BytesToHash`, the last 32 bytes, left-padded.
pub fn evm_value(raw: &[u8]) -> Hash {
    let mut out = [0u8; 32];
    let take = raw.len().min(32);
    out[32 - take..].copy_from_slice(&raw[raw.len() - take..]);
    out
}

fn header(bytes: &[u8]) -> Result<Header, Error> {
    <Header as Protobuf<RawHeader>>::decode_vec(bytes).map_err(|_| Error::Decode("header"))
}

fn signed_header(bytes: &[u8]) -> Result<SignedHeader, Error> {
    <SignedHeader as Protobuf<RawSignedHeader>>::decode_vec(bytes)
        .map_err(|_| Error::Decode("signed header"))
}

/// A validator set; decoding checks each address against its key and the total power.
fn validator_set(bytes: &[u8]) -> Result<Set, Error> {
    <Set as Protobuf<RawValidatorSet>>::decode_vec(bytes)
        .map_err(|_| Error::Decode("validator set"))
}

fn commitment_proof(bytes: &[u8]) -> Result<CommitmentProof, Error> {
    CommitmentProof::decode(bytes).map_err(|_| Error::Decode("commitment proof"))
}

/// Whole seconds since 1970, as the EVM dates a block from its header.
fn seconds(header: &Header) -> Result<u64, Error> {
    u64::try_from(header.time.unix_timestamp()).map_err(|_| Error::BadTime)
}

fn head(header: &Header) -> Result<Head, Error> {
    Ok(Head {
        height: header.height.value(),
        hash: header
            .hash()
            .as_bytes()
            .try_into()
            .map_err(|_| Error::Decode("hash"))?,
        time: seconds(header)?,
    })
}

/// The light client's options: more than two thirds of the trusted set, trusted for `MAX_LAG`. The clock is the last
/// header's time, which no earlier header passes, so the drift allowance is a formality: the verifier on Ethereum
/// refuses a last header dated after its own clock.
pub fn options() -> Options {
    Options {
        trust_threshold: TrustThreshold::TWO_THIRDS,
        trusting_period: Duration::from_secs(MAX_LAG),
        clock_drift: Duration::from_nanos(1),
    }
}

/// Follows the hops from the trusted header. Returns the trusted header and the last header reached, the trusted one
/// itself when there is no hop.
pub fn follow(chain: &Chain) -> Result<(Header, Header), Error> {
    let trusted = header(&chain.trusted_header)?;
    if trusted.chain_id.as_str() != chain.chain_id {
        return Err(Error::WrongChain);
    }
    let mut next = validator_set(&chain.trusted_next_validators)?;
    if next.hash() != trusted.next_validators_hash {
        return Err(Error::WrongNextValidators);
    }
    let mut hops = Vec::with_capacity(chain.hops.len());
    for (i, hop) in chain.hops.iter().enumerate() {
        let next_validators = if hop.next_validators.is_empty() {
            if i + 1 < chain.hops.len() {
                return Err(Error::MissingNextValidators { hop: i });
            }
            None
        } else {
            Some(validator_set(&hop.next_validators)?)
        };
        hops.push((
            signed_header(&hop.signed_header)?,
            validator_set(&hop.validators)?,
            next_validators,
        ));
    }
    // Every set must still be trusted at the last header's time.
    let now = hops.last().map_or(trusted.time, |h| h.0.header.time);
    let options = options();
    let verifier = ProdVerifier::default();
    let mut current = trusted.clone();
    for (i, (signed, validators, next_validators)) in hops.into_iter().enumerate() {
        let verdict = verifier.verify_update_header(
            UntrustedBlockState {
                signed_header: &signed,
                validators: &validators,
                next_validators: next_validators.as_ref(),
            },
            TrustedBlockState {
                chain_id: &current.chain_id,
                header_time: current.time,
                height: current.height,
                next_validators: &next,
                next_validators_hash: current.next_validators_hash,
            },
            &options,
            now,
        );
        if verdict != Verdict::Success {
            return Err(Error::Hop {
                hop: i,
                verdict: Box::new(verdict),
            });
        }
        current = signed.header;
        if let Some(n) = next_validators {
            next = n;
        }
    }
    Ok((trusted, current))
}

/// Opens the vault's slots under `last`'s `app_hash`, from block `H`, `last`'s parent. Returns `H`'s height and time
/// and the values.
pub fn prove_state(last: &Header, state: &State) -> Result<(u64, u64, Vec<Hash>), Error> {
    let block = header(&state.header)?;
    let parent = last.last_block_id.ok_or(Error::NotTheParent)?;
    if block.hash() != parent.hash || block.height.increment() != last.height {
        return Err(Error::NotTheParent);
    }
    let store = commitment_proof(&state.store_proof)?;
    let Some(Proof::Exist(opened)) = &store.proof else {
        return Err(Error::StoreProof);
    };
    let root = opened.value.clone();
    if !ics23::verify_membership::<HostFunctionsManager>(
        &store,
        &ics23::tendermint_spec(),
        &last.app_hash.as_bytes().to_vec(),
        EVM_STORE,
        &root,
    ) {
        return Err(Error::StoreProof);
    }
    let iavl = ics23::iavl_spec();
    let mut values = Vec::with_capacity(state.slots.len());
    for (i, s) in state.slots.iter().enumerate() {
        let key = storage_key(&state.vault, &s.slot);
        let proof = commitment_proof(&s.proof)?;
        let value = match &proof.proof {
            Some(Proof::Exist(ex))
                if ics23::verify_membership::<HostFunctionsManager>(
                    &proof, &iavl, &root, &key, &ex.value,
                ) =>
            {
                evm_value(&ex.value)
            }
            Some(Proof::Nonexist(_))
                if ics23::verify_non_membership::<HostFunctionsManager>(
                    &proof, &iavl, &root, &key,
                ) =>
            {
                [0u8; 32]
            }
            _ => return Err(Error::SlotProof { slot: i }),
        };
        values.push(value);
    }
    Ok((block.height.value(), seconds(&block)?, values))
}

/// Checks the statement. Returns the public values to commit.
pub fn verify(input: &Input) -> Result<Output, Error> {
    match input {
        Input::Update(chain) => {
            if chain.hops.is_empty() {
                return Err(Error::NoHops);
            }
            let (trusted, last) = follow(chain)?;
            Ok(Output::Update {
                chain_id_hash: keccak(&[chain.chain_id.as_bytes()]),
                trusted: head(&trusted)?,
                head: head(&last)?,
            })
        }
        Input::Slots(chain, state) => {
            let (trusted, last) = follow(chain)?;
            let (height, time, values) = prove_state(&last, state)?;
            Ok(Output::Slots {
                chain_id_hash: keccak(&[chain.chain_id.as_bytes()]),
                trusted: head(&trusted)?,
                height,
                time,
                vault: state.vault,
                slots: state.slots.iter().map(|s| s.slot).collect(),
                values,
            })
        }
    }
}

fn word(x: u64) -> Hash {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

/// `abi.encode(bytes32[] slots, bytes32[] values)`.
pub fn abi_slots_values(slots: &[Hash], values: &[Hash]) -> Vec<u8> {
    let n = slots.len() as u64;
    let mut out = Vec::with_capacity(32 * (4 + slots.len() + values.len()));
    out.extend_from_slice(&word(0x40));
    out.extend_from_slice(&word(0x40 + 32 * (n + 1)));
    out.extend_from_slice(&word(n));
    slots.iter().for_each(|s| out.extend_from_slice(s));
    out.extend_from_slice(&word(values.len() as u64));
    values.iter().for_each(|v| out.extend_from_slice(v));
    out
}

impl Output {
    /// The public values `CometBftStateVerifier` decodes:
    ///
    /// - an update, eight words: `abi.encode(UPDATE, keccak256(chainId), trustedHeight, trustedHash, trustedTime,
    ///   height, hash, time)`;
    /// - slots, nine words: `abi.encode(SLOTS, keccak256(chainId), trustedHeight, trustedHash, trustedTime, height,
    ///   time, vault, keccak256(abi.encode(slots, values)))`, the height and time block `H`'s.
    pub fn abi_encode(&self) -> Vec<u8> {
        match self {
            Output::Update {
                chain_id_hash,
                trusted,
                head,
            } => [
                update_kind(),
                *chain_id_hash,
                word(trusted.height),
                trusted.hash,
                word(trusted.time),
                word(head.height),
                head.hash,
                word(head.time),
            ]
            .concat(),
            Output::Slots {
                chain_id_hash,
                trusted,
                height,
                time,
                vault,
                slots,
                values,
            } => {
                let mut v = [0u8; 32];
                v[12..].copy_from_slice(vault);
                [
                    slots_kind(),
                    *chain_id_hash,
                    word(trusted.height),
                    trusted.hash,
                    word(trusted.time),
                    word(*height),
                    word(*time),
                    v,
                    keccak(&[&abi_slots_values(slots, values)]),
                ]
                .concat()
            }
        }
    }
}
