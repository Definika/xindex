//! The statement P1 proves (Stage B spec, section 10): given a trusted anchor, a checkpoint is finalized by votes of
//! the anchor's own validators, and the execution headers since the anchor lead to that checkpoint's block.

use crate::beacon::{
    compute_domain, fork_version, signing_root, AttestationData, BeaconBlockHeader, Checkpoint,
    BODY_BLOCK_HASH_DEPTH, BODY_BLOCK_HASH_INDEX, DOMAIN_BEACON_ATTESTER, GENESIS_VALIDATORS_ROOT,
    SLOTS_PER_EPOCH, STATE_DEPTH, STATE_VALIDATORS_INDEX,
};
use crate::bls;
use crate::execution::{keccak, keccak_root, parse_header, ExecHeader};
use crate::registry::{validators_root, Validator};
use crate::ssz::is_valid_branch;
use crate::Root;
use bls12_381::{G1Affine, G1Projective};
use group::Curve;
use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;

/// The most epochs a proof may cover past its anchor: a day. A verifier left further behind stops for good.
pub const MAX_EPOCH_GAP: u64 = 225;
/// The stake the anchor's records may overstate, per epoch since the anchor, in Gwei: over twice the balance churn at
/// any stake below about 67M ETH, which bounds what exits and consolidations can move.
pub const MARGIN_PER_EPOCH_GWEI: u128 = 2_048 * 1_000_000_000;
/// The most execution headers one proof carries: a day of blocks, with room.
pub const MAX_HEADERS: usize = 8_192;

/// What a verifier on a vault chain keeps: the last checkpoint it accepted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Anchor {
    pub epoch: u64,
    /// `hash_tree_root(state.validators)` in the checkpoint's state.
    pub validators_root: Root,
    /// The last execution block covered, which the next proof's headers descend from.
    pub exec_hash: Root,
    pub exec_number: u64,
}

impl Anchor {
    /// `keccak256(abi.encode(uint64 epoch, bytes32 validatorsRoot, bytes32 execHash, uint64 execNumber))`.
    pub fn hash(&self) -> Root {
        keccak(&[
            &word(self.epoch),
            &self.validators_root,
            &self.exec_hash,
            &word(self.exec_number),
        ])
    }
}

/// One aggregate attestation: its data, its signature, and the registry indices of its signers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Aggregate {
    pub data: AttestationData,
    #[serde(with = "BigArray")]
    pub signature: [u8; 96],
    pub signers: Vec<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Input {
    pub anchor: Anchor,
    /// The anchor's whole registry, in index order, and each key's uncompressed form.
    pub validators: Vec<Validator>,
    pub keys: Vec<UncompressedKey>,
    /// Votes of one source for the target `C1 = (e1, r1)`.
    pub justification: Vec<Aggregate>,
    /// Votes of source `C1` for the target `C2 = (e1 + 1, r2)`.
    pub finalization: Vec<Aggregate>,
    /// `C1`'s block header, which hashes to `r1`.
    pub header: BeaconBlockHeader,
    /// The registry root in `C1`'s state, and its branch from the header's state root.
    pub new_validators_root: Root,
    pub validators_branch: Vec<Root>,
    /// The execution payload's block hash, from the header's body root.
    pub block_hash: Root,
    pub block_hash_branch: Vec<Root>,
    /// Every execution header after the anchor's, up to `C1`'s, oldest first, as RLP.
    pub exec_headers: Vec<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UncompressedKey(#[serde(with = "BigArray")] pub [u8; 96]);

/// The proof's public values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Output {
    pub anchor_in: Root,
    pub anchor_out: Root,
    pub epoch: u64,
    pub headers_root: Root,
    pub first_number: u64,
    pub last_number: u64,
}

impl Output {
    /// `abi.encode(bytes32, bytes32, uint64, bytes32, uint64, uint64)`, which the verifier contracts decode.
    pub fn abi_encode(&self) -> Vec<u8> {
        [
            self.anchor_in,
            self.anchor_out,
            word(self.epoch),
            self.headers_root,
            word(self.first_number),
            word(self.last_number),
        ]
        .concat()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    RegistryMismatch,
    KeyCountMismatch,
    NoVotes,
    LinksDisagree,
    NotAfterAnchor,
    TooFarFromAnchor,
    SlotOutsideTarget,
    UnknownFork(u64),
    BadSigner(u32),
    BadKey(u32),
    BadSignature,
    BelowThreshold {
        signed: u128,
        total: u128,
        margin: u128,
    },
    HeaderMismatch,
    BadStateBranch,
    BadBlockHashBranch,
    BadExecHeader(usize),
    BrokenChain(usize),
    WrongHeaderCount,
}

/// Checks the statement and returns the public values, or why it does not hold.
pub fn verify(input: &Input) -> Result<Output, Error> {
    let anchor = &input.anchor;
    if validators_root(&input.validators) != anchor.validators_root {
        return Err(Error::RegistryMismatch);
    }
    if input.keys.len() != input.validators.len() {
        return Err(Error::KeyCountMismatch);
    }

    // The two links: one source into C1, then C1 into its direct child checkpoint.
    let (first, second) = match (input.justification.first(), input.finalization.first()) {
        (Some(a), Some(b)) => (a.data, b.data),
        _ => return Err(Error::NoVotes),
    };
    let c1 = first.target;
    let c2 = second.target;
    if second.source != c1 || c2.epoch != c1.epoch + 1 {
        return Err(Error::LinksDisagree);
    }
    if c1.epoch <= anchor.epoch {
        return Err(Error::NotAfterAnchor);
    }
    if c2.epoch - anchor.epoch > MAX_EPOCH_GAP + 1 {
        return Err(Error::TooFarFromAnchor);
    }
    count_link(input, &input.justification, first.source, c1)?;
    count_link(input, &input.finalization, c1, c2)?;

    // C1's block: its state holds the next registry, its body the execution block hash.
    let header = &input.header;
    if header.hash_tree_root() != c1.root {
        return Err(Error::HeaderMismatch);
    }
    if !is_valid_branch(
        &input.new_validators_root,
        &input.validators_branch,
        STATE_DEPTH,
        STATE_VALIDATORS_INDEX,
        &header.state_root,
    ) {
        return Err(Error::BadStateBranch);
    }
    if !is_valid_branch(
        &input.block_hash,
        &input.block_hash_branch,
        BODY_BLOCK_HASH_DEPTH,
        BODY_BLOCK_HASH_INDEX,
        &header.body_root,
    ) {
        return Err(Error::BadBlockHashBranch);
    }

    // The execution headers, each the parent of the next, from the anchor's block to C1's.
    let n = input.exec_headers.len();
    if n == 0 || n > MAX_HEADERS {
        return Err(Error::WrongHeaderCount);
    }
    let mut leaves = Vec::with_capacity(n);
    let mut previous: (Root, u64) = (anchor.exec_hash, anchor.exec_number);
    let mut last: Option<ExecHeader> = None;
    for (i, rlp) in input.exec_headers.iter().enumerate() {
        let h = parse_header(rlp).ok_or(Error::BadExecHeader(i))?;
        if h.parent_hash != previous.0 || h.number != previous.1 + 1 {
            return Err(Error::BrokenChain(i));
        }
        leaves.push(h.leaf());
        previous = (h.hash, h.number);
        last = Some(h);
    }
    let last = last.expect("at least one header");
    if last.hash != input.block_hash {
        return Err(Error::BrokenChain(n));
    }

    let anchor_out = Anchor {
        epoch: c1.epoch,
        validators_root: input.new_validators_root,
        exec_hash: last.hash,
        exec_number: last.number,
    };
    Ok(Output {
        anchor_in: anchor.hash(),
        anchor_out: anchor_out.hash(),
        epoch: c1.epoch,
        headers_root: keccak_root(&leaves),
        first_number: anchor.exec_number + 1,
        last_number: last.number,
    })
}

/// Checks one supermajority link `source → target`: every aggregate votes for it within the target epoch and verifies
/// under its signers' keys, and the distinct, unslashed signers active at the target epoch hold two thirds of the stake
/// the anchor's records show active then, plus the margin.
fn count_link(
    input: &Input,
    aggregates: &[Aggregate],
    source: Checkpoint,
    target: Checkpoint,
) -> Result<(), Error> {
    let version = fork_version(target.epoch).ok_or(Error::UnknownFork(target.epoch))?;
    let domain = compute_domain(DOMAIN_BEACON_ATTESTER, version, &GENESIS_VALIDATORS_ROOT);
    let validators = &input.validators;
    let mut counted = vec![false; validators.len()];
    let mut signed: u128 = 0;
    for aggregate in aggregates {
        let data = &aggregate.data;
        if data.source != source || data.target != target {
            return Err(Error::LinksDisagree);
        }
        if data.slot / SLOTS_PER_EPOCH != target.epoch {
            return Err(Error::SlotOutsideTarget);
        }
        if aggregate.signers.is_empty() {
            return Err(Error::NoVotes);
        }
        let mut key = G1Projective::identity();
        for &i in &aggregate.signers {
            let v = validators.get(i as usize).ok_or(Error::BadSigner(i))?;
            key +=
                bls::registry_key(&input.keys[i as usize].0, &v.pubkey).ok_or(Error::BadKey(i))?;
            // A key may sign in several aggregates, but its stake counts once per link.
            if !counted[i as usize] && !v.slashed && v.is_active(target.epoch) {
                signed += v.effective_balance as u128;
            }
            counted[i as usize] = true;
        }
        let key: G1Affine = key.to_affine();
        if !bls::verify(
            &key,
            &signing_root(&data.hash_tree_root(), &domain),
            &aggregate.signature,
        ) {
            return Err(Error::BadSignature);
        }
    }
    let total: u128 = validators
        .iter()
        .filter(|v| v.is_active(target.epoch))
        .map(|v| v.effective_balance as u128)
        .sum();
    // The anchor's records may be one epoch older than its epoch, so the margin counts one more.
    let margin = MARGIN_PER_EPOCH_GWEI * (target.epoch - input.anchor.epoch + 1) as u128;
    if 3 * signed < 2 * total + 3 * margin {
        return Err(Error::BelowThreshold {
            signed,
            total,
            margin,
        });
    }
    Ok(())
}

/// A `uint64` as an ABI word.
fn word(x: u64) -> Root {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}
