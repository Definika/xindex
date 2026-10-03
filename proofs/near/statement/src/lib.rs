//! NEAR's state verifier's statement (`design/2026-10-03-near-stellar-interfaces.md`): from a trusted epoch and its
//! block producers, a chain of NEAR light-client blocks, each final under the producers of its epoch, the last one the
//! head whose `block_merkle_root` the verifier on Ethereum records. Every rule follows nearcore's light client
//! (`validate_and_update_head`, Nomicon's "Light Client" chapter, `chain/chain/src/lightclient.rs`):
//!
//! - a block's hash is `sha256(sha256(sha256(borsh(inner_lite)) ++ inner_rest_hash) ++ prev_block_hash)`, and the
//!   approvals in the block after next endorse the next block, whose hash is `sha256(next_block_inner_hash ++ hash)`,
//!   at the height after it: the message `borsh(ApprovalInner::Endorsement(next_hash)) ++ le(height + 2)`. An
//!   endorsement only ever targets its block's own next height, so a quorum of them makes the block final by
//!   Doomslug's BFT rule, never merely Doomslug-final;
//! - each present approval must verify under its producer's ed25519 key, with ed25519-dalek's `verify`, the non-strict
//!   check nearcore uses, and a key that does not decompress fails it, as `Signature::verify` returns false there;
//! - the approving stake must be strictly above two thirds of the epoch's whole producer stake. nearcore zips the
//!   approvals with the producers and so counts only those with a slot; counting every producer, as here, is the
//!   stricter of the two and the same whenever, as always, each producer has its slot;
//! - a block that names the next epoch's producers must name exactly those its header commits to:
//!   `sha256(borsh(next_bps)) == next_bp_hash`. Only such a block moves the statement to the next epoch, so every
//!   block is checked by the producers of its own epoch, learned one epoch at a time, none skipped.
//!
//! Producers' keys are ed25519 only, as every mainnet validator's is (2026-10-03). nearcore also knows other key types;
//! a set holding one cannot be written here, so no proof of it exists, and the verifier stalls rather than accept it.

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;
use sha2::{Digest, Sha256};

pub type Hash = [u8; 32];

/// A block producer, as `ValidatorStake::V1`: its account, its ed25519 key and its stake, in yoctoNEAR.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Producer {
    pub account_id: String,
    pub public_key: Hash,
    pub stake: u128,
}

/// An ed25519 signature's 64 bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sig(#[serde(with = "BigArray")] pub [u8; 64]);

/// `BlockHeaderInnerLite`, the fields a light client reads, in nearcore's order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InnerLite {
    pub height: u64,
    pub epoch_id: Hash,
    pub next_epoch_id: Hash,
    pub prev_state_root: Hash,
    pub outcome_root: Hash,
    /// Nanoseconds since the Unix epoch.
    pub timestamp: u64,
    pub next_bp_hash: Hash,
    pub block_merkle_root: Hash,
}

/// `LightClientBlockView`: a block's light header, the hashes that link it to its successor, the next epoch's
/// producers if it names them, and the approvals of the block after next, in the order of its epoch's producers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LightClientBlock {
    pub prev_block_hash: Hash,
    pub next_block_inner_hash: Hash,
    pub inner_lite: InnerLite,
    pub inner_rest_hash: Hash,
    pub next_bps: Option<Vec<Producer>>,
    pub approvals_after_next: Vec<Option<Sig>>,
}

/// The statement's input: the epoch the verifier trusts, its producers, and the blocks that follow it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Input {
    pub epoch_id: Hash,
    pub producers: Vec<Producer>,
    pub blocks: Vec<LightClientBlock>,
}

/// What a proof commits: the epoch and producer-set hash it started from and ended at, when the producer set it ended
/// at was named (nanoseconds; zero when it named none), and the head: its height, time and `block_merkle_root`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    pub epoch_in: Hash,
    pub producers_in: Hash,
    pub epoch_out: Hash,
    pub producers_out: Hash,
    pub named_at: u64,
    pub height: u64,
    pub timestamp: u64,
    pub block_merkle_root: Hash,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    NoBlocks,
    NotAfterTheLast {
        height: u64,
        last: u64,
    },
    WrongEpoch {
        height: u64,
    },
    BadKey {
        height: u64,
        producer: usize,
    },
    BadSignature {
        height: u64,
        producer: usize,
    },
    NotEnoughStake {
        height: u64,
        approved: u128,
        total: u128,
    },
    WrongNextProducers {
        height: u64,
    },
}

pub fn sha256(parts: &[&[u8]]) -> Hash {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// `borsh(BlockHeaderInnerLite)`: integers little-endian, hashes as they are.
pub fn inner_lite_bytes(l: &InnerLite) -> Vec<u8> {
    let mut out = Vec::with_capacity(208);
    out.extend_from_slice(&l.height.to_le_bytes());
    out.extend_from_slice(&l.epoch_id);
    out.extend_from_slice(&l.next_epoch_id);
    out.extend_from_slice(&l.prev_state_root);
    out.extend_from_slice(&l.outcome_root);
    out.extend_from_slice(&l.timestamp.to_le_bytes());
    out.extend_from_slice(&l.next_bp_hash);
    out.extend_from_slice(&l.block_merkle_root);
    out
}

/// A block's hash from its light header: `BlockHeader::compute_hash`, `combine_hash(a, b) = sha256(a ++ b)`.
pub fn block_hash(inner_lite: &InnerLite, inner_rest_hash: &Hash, prev_block_hash: &Hash) -> Hash {
    let inner = sha256(&[&sha256(&[&inner_lite_bytes(inner_lite)]), inner_rest_hash]);
    sha256(&[&inner, prev_block_hash])
}

/// What the approvals of the block after next sign: `borsh(ApprovalInner::Endorsement(next_hash)) ++ le(height + 2)`.
pub fn approval_message(b: &LightClientBlock) -> Vec<u8> {
    let current = block_hash(&b.inner_lite, &b.inner_rest_hash, &b.prev_block_hash);
    let next = sha256(&[&b.next_block_inner_hash, &current]);
    let mut out = Vec::with_capacity(41);
    out.push(0); // ApprovalInner::Endorsement
    out.extend_from_slice(&next);
    out.extend_from_slice(&(b.inner_lite.height + 2).to_le_bytes());
    out
}

/// `sha256(borsh(Vec<ValidatorStake>))`, each `ValidatorStake::V1` after its enum tag, each key `KeyType::ED25519`.
pub fn producers_hash(producers: &[Producer]) -> Hash {
    let mut out = Vec::with_capacity(4 + producers.len() * 96);
    out.extend_from_slice(&(producers.len() as u32).to_le_bytes());
    for p in producers {
        out.push(0); // ValidatorStake::V1
        out.extend_from_slice(&(p.account_id.len() as u32).to_le_bytes());
        out.extend_from_slice(p.account_id.as_bytes());
        out.push(0); // KeyType::ED25519
        out.extend_from_slice(&p.public_key);
        out.extend_from_slice(&p.stake.to_le_bytes());
    }
    sha256(&[&out])
}

/// The approving stake of `b` under `producers`, every present approval checked: it fails on any that does not
/// verify, as nearcore's light client rejects the block. Approvals past the last producer are ignored, as nearcore's
/// zip ignores them, and a producer without a slot counts as not approving.
pub fn approved_stake(b: &LightClientBlock, producers: &[Producer]) -> Result<(u128, u128), Error> {
    let height = b.inner_lite.height;
    let message = approval_message(b);
    let mut total = 0u128;
    let mut approved = 0u128;
    for (i, p) in producers.iter().enumerate() {
        total += p.stake;
        let Some(Some(sig)) = b.approvals_after_next.get(i) else {
            continue;
        };
        let key = VerifyingKey::from_bytes(&p.public_key).map_err(|_| Error::BadKey {
            height,
            producer: i,
        })?;
        key.verify(&message, &Signature::from_bytes(&sig.0))
            .map_err(|_| Error::BadSignature {
                height,
                producer: i,
            })?;
        approved += p.stake;
    }
    Ok((approved, total))
}

/// Checks the statement: every block, in order, final under the producers of its epoch. Returns the public values.
pub fn verify(input: &Input) -> Result<Output, Error> {
    let last_block = input.blocks.last().ok_or(Error::NoBlocks)?;
    let producers_in = producers_hash(&input.producers);
    let mut epoch = input.epoch_id;
    let mut producers = input.producers.clone();
    let mut producers_out = producers_in;
    let mut named_at = 0u64;
    let mut last = 0u64;
    for b in &input.blocks {
        let height = b.inner_lite.height;
        if height <= last {
            return Err(Error::NotAfterTheLast { height, last });
        }
        if b.inner_lite.epoch_id != epoch {
            return Err(Error::WrongEpoch { height });
        }
        let (approved, total) = approved_stake(b, &producers)?;
        if approved <= total * 2 / 3 {
            return Err(Error::NotEnoughStake {
                height,
                approved,
                total,
            });
        }
        if let Some(next) = &b.next_bps {
            let hash = producers_hash(next);
            if hash != b.inner_lite.next_bp_hash {
                return Err(Error::WrongNextProducers { height });
            }
            epoch = b.inner_lite.next_epoch_id;
            producers = next.clone();
            producers_out = hash;
            named_at = b.inner_lite.timestamp;
        }
        last = height;
    }
    Ok(Output {
        epoch_in: input.epoch_id,
        producers_in,
        epoch_out: epoch,
        producers_out,
        named_at,
        height: last_block.inner_lite.height,
        timestamp: last_block.inner_lite.timestamp,
        block_merkle_root: last_block.inner_lite.block_merkle_root,
    })
}

fn word(x: u128) -> Hash {
    let mut w = [0u8; 32];
    w[16..].copy_from_slice(&x.to_be_bytes());
    w
}

impl Output {
    /// `abi.encode(epochIn, producersIn, epochOut, producersOut, namedAt, height, timestamp, blockMerkleRoot)`, as
    /// `NearStateVerifier.update` decodes it: eight words.
    pub fn abi_encode(&self) -> Vec<u8> {
        [
            self.epoch_in,
            self.producers_in,
            self.epoch_out,
            self.producers_out,
            word(self.named_at.into()),
            word(self.height.into()),
            word(self.timestamp.into()),
            self.block_merkle_root,
        ]
        .concat()
    }
}
