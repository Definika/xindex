//! The validator registry as `BeaconState.validators` holds it, its SSZ root, and the compact form P1's input carries
//! it in, which the statement reads in one pass.

use crate::beacon::FAR_FUTURE_EPOCH;
use crate::bls;
use crate::ssz::{hash_pair, mix_in_length, root_of_eight, u64_chunk, Merkleizer};
use crate::statement::Error;
use crate::Root;
use bls12_381::G1Affine;
use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;

/// `VALIDATOR_REGISTRY_LIMIT` is 2^40.
pub const REGISTRY_DEPTH: usize = 40;
/// A validator's SSZ encoding: its key, credentials, balance, slashed flag and four epochs.
pub const VALIDATOR_BYTES: usize = 121;

/// The input's record of a validator that does not sign: its SSZ encoding.
pub const FULL: u8 = 0;
/// A signer's record: its SSZ encoding, then the y coordinate of its key, big-endian, so the statement reads the key
/// without a square root.
pub const SIGNER: u8 = 1;
/// The record of a validator that exited at or before C1's epoch, so it is active at neither target and cannot count:
/// its exit and withdrawable epochs, then the root of its two activation epochs and the root of its first four fields.
/// That is all its leaf needs.
pub const EXITED: u8 = 2;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Validator {
    #[serde(with = "BigArray")]
    pub pubkey: [u8; 48],
    pub withdrawal_credentials: Root,
    pub effective_balance: u64,
    pub slashed: bool,
    pub activation_eligibility_epoch: u64,
    pub activation_epoch: u64,
    pub exit_epoch: u64,
    pub withdrawable_epoch: u64,
}

impl Validator {
    pub fn hash_tree_root(&self) -> Root {
        root_of_eight(&self.chunks())
    }

    fn chunks(&self) -> [Root; 8] {
        let mut slashed = [0u8; 32];
        slashed[0] = self.slashed as u8;
        [
            pubkey_root(&self.pubkey),
            self.withdrawal_credentials,
            u64_chunk(self.effective_balance),
            slashed,
            u64_chunk(self.activation_eligibility_epoch),
            u64_chunk(self.activation_epoch),
            u64_chunk(self.exit_epoch),
            u64_chunk(self.withdrawable_epoch),
        ]
    }

    /// The consensus specs' `is_active_validator`.
    pub fn is_active(&self, epoch: u64) -> bool {
        self.activation_epoch <= epoch && epoch < self.exit_epoch
    }

    pub fn to_ssz(&self) -> [u8; VALIDATOR_BYTES] {
        let mut b = [0u8; VALIDATOR_BYTES];
        b[..48].copy_from_slice(&self.pubkey);
        b[48..80].copy_from_slice(&self.withdrawal_credentials);
        b[80..88].copy_from_slice(&self.effective_balance.to_le_bytes());
        b[88] = self.slashed as u8;
        b[89..97].copy_from_slice(&self.activation_eligibility_epoch.to_le_bytes());
        b[97..105].copy_from_slice(&self.activation_epoch.to_le_bytes());
        b[105..113].copy_from_slice(&self.exit_epoch.to_le_bytes());
        b[113..121].copy_from_slice(&self.withdrawable_epoch.to_le_bytes());
        b
    }

    /// A validator from its SSZ encoding, whose slashed flag must be a boolean's.
    pub fn from_ssz(b: &[u8]) -> Option<Validator> {
        if b.len() != VALIDATOR_BYTES || b[88] > 1 {
            return None;
        }
        Some(Validator {
            pubkey: b[..48].try_into().unwrap(),
            withdrawal_credentials: b[48..80].try_into().unwrap(),
            effective_balance: le64(&b[80..]),
            slashed: b[88] == 1,
            activation_eligibility_epoch: le64(&b[89..]),
            activation_epoch: le64(&b[97..]),
            exit_epoch: le64(&b[105..]),
            withdrawable_epoch: le64(&b[113..]),
        })
    }
}

/// A 48-byte key's SSZ root: its two chunks, the second zero-padded.
fn pubkey_root(pubkey: &[u8; 48]) -> Root {
    let mut low = [0u8; 32];
    low.copy_from_slice(&pubkey[..32]);
    let mut high = [0u8; 32];
    high[..16].copy_from_slice(&pubkey[32..]);
    hash_pair(&low, &high)
}

fn le64(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

/// `hash_tree_root(List[Validator, VALIDATOR_REGISTRY_LIMIT])`.
pub fn validators_root(validators: &[Validator]) -> Root {
    let mut m = Merkleizer::new(REGISTRY_DEPTH);
    for v in validators {
        m.push(&v.hash_tree_root());
    }
    mix_in_length(&m.root(), validators.len() as u64)
}

/// The registry as the input carries it. `key_y(i)` is the y coordinate of validator `i`'s key where it signs, and
/// `None` elsewhere; a validator that does not sign and exited by `c1_epoch` goes as `EXITED`.
pub fn encode(
    validators: &[Validator],
    c1_epoch: u64,
    key_y: impl Fn(usize) -> Option<[u8; 48]>,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(validators.len() * (1 + VALIDATOR_BYTES));
    for (i, v) in validators.iter().enumerate() {
        match key_y(i) {
            Some(y) => {
                out.push(SIGNER);
                out.extend_from_slice(&v.to_ssz());
                out.extend_from_slice(&y);
            }
            None if v.exit_epoch <= c1_epoch => {
                let c = v.chunks();
                out.push(EXITED);
                out.extend_from_slice(&v.exit_epoch.to_le_bytes());
                out.extend_from_slice(&v.withdrawable_epoch.to_le_bytes());
                out.extend_from_slice(&hash_pair(&c[4], &c[5]));
                out.extend_from_slice(&hash_pair(
                    &hash_pair(&c[0], &c[1]),
                    &hash_pair(&c[2], &c[3]),
                ));
            }
            None => {
                out.push(FULL);
                out.extend_from_slice(&v.to_ssz());
            }
        }
    }
    out
}

/// A key that signs, read once for both links, and the stake it counts at C1's epoch and at the next: its effective
/// balance where its record shows it unslashed and active then, and nothing otherwise.
pub struct Signer {
    pub key: G1Affine,
    pub stake: [u64; 2],
}

/// What the statement learns from the registry in one pass.
pub struct Registry {
    pub root: Root,
    pub len: usize,
    /// The stake the threshold is two thirds of, at C1's epoch and at the next: what the records show active then,
    /// plus every validator the records show not yet given an activation epoch (LG-6). Electra puts its churn on
    /// deposits entering the registry, not on activations: once finality returns it activates every validator queued
    /// in the registry at once, however long the queue grew while finality stalled, so stake queued at the anchor can
    /// be active at C1 although no record says so. It counts here, and never as signed stake. Stake that enters the
    /// registry after the anchor comes through the deposit churn, which the margin covers.
    pub total: [u128; 2],
    pub signers: Vec<Signer>,
    /// Each validator's position in `signers`, or `NO_KEY` where its record carries no key.
    slots: Vec<u32>,
}

const NO_KEY: u32 = u32::MAX;

impl Registry {
    /// Reads the encoded registry, hashing every record into the root as it goes. A record that is malformed, or
    /// `EXITED` while active at C1's epoch, is `BadRecord`; a signer whose key is not its record's is `BadKey`.
    pub fn read(bytes: &[u8], c1_epoch: u64) -> Result<Registry, Error> {
        let mut tree = Merkleizer::new(REGISTRY_DEPTH);
        let mut total = [0u128; 2];
        let mut signers = Vec::new();
        let mut slots = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            let index = slots.len() as u32;
            let bad = Error::BadRecord(index);
            let tag = bytes[at];
            at += 1;
            let size = match tag {
                FULL => VALIDATOR_BYTES,
                SIGNER => VALIDATOR_BYTES + 48,
                EXITED => 80,
                _ => return Err(bad),
            };
            let record = bytes.get(at..at + size).ok_or(bad.clone())?;
            at += size;
            if tag == EXITED {
                let exit_epoch = le64(record);
                if exit_epoch > c1_epoch {
                    return Err(bad);
                }
                let tail = hash_pair(&u64_chunk(exit_epoch), &u64_chunk(le64(&record[8..])));
                let activations: Root = record[16..48].try_into().unwrap();
                let head: Root = record[48..80].try_into().unwrap();
                tree.push(&hash_pair(&head, &hash_pair(&activations, &tail)));
                slots.push(NO_KEY);
                continue;
            }
            let v = Validator::from_ssz(&record[..VALIDATOR_BYTES]).ok_or(bad)?;
            tree.push(&v.hash_tree_root());
            let mut stake = [0u64; 2];
            for (k, epoch) in [c1_epoch, c1_epoch + 1].into_iter().enumerate() {
                if v.is_active(epoch) {
                    total[k] += v.effective_balance as u128;
                    if !v.slashed {
                        stake[k] = v.effective_balance;
                    }
                } else if v.activation_epoch == FAR_FUTURE_EPOCH {
                    // Queued, or still to be queued: it may be active at C1 in fact, so it counts in the total only.
                    total[k] += v.effective_balance as u128;
                }
            }
            if tag == FULL {
                slots.push(NO_KEY);
                continue;
            }
            // The uncompressed key: the record's x without its three flag bits, then the y given.
            let mut uncompressed = [0u8; 96];
            uncompressed[..48].copy_from_slice(&v.pubkey);
            uncompressed[0] &= 0x1f;
            uncompressed[48..].copy_from_slice(&record[VALIDATOR_BYTES..]);
            let key = bls::registry_key(&uncompressed, &v.pubkey).ok_or(Error::BadKey(index))?;
            slots.push(signers.len() as u32);
            signers.push(Signer { key, stake });
        }
        Ok(Registry {
            root: mix_in_length(&tree.root(), slots.len() as u64),
            len: slots.len(),
            total,
            signers,
            slots,
        })
    }

    /// The signer at registry index `index` and its position, or `None` where the record carries no key.
    pub fn signer(&self, index: usize) -> Option<(usize, &Signer)> {
        let slot = *self.slots.get(index)?;
        if slot == NO_KEY {
            return None;
        }
        Some((slot as usize, &self.signers[slot as usize]))
    }
}
