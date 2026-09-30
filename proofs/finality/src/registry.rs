//! The validator registry as `BeaconState.validators` holds it, and its SSZ root.

use crate::ssz::{hash_pair, merkleize, mix_in_length, u64_chunk};
use crate::Root;
use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;

/// `VALIDATOR_REGISTRY_LIMIT` is 2^40.
pub const REGISTRY_DEPTH: usize = 40;

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
        let mut low = [0u8; 32];
        low.copy_from_slice(&self.pubkey[..32]);
        let mut high = [0u8; 32];
        high[..16].copy_from_slice(&self.pubkey[32..]);
        let mut slashed = [0u8; 32];
        slashed[0] = self.slashed as u8;
        merkleize(
            &[
                hash_pair(&low, &high),
                self.withdrawal_credentials,
                u64_chunk(self.effective_balance),
                slashed,
                u64_chunk(self.activation_eligibility_epoch),
                u64_chunk(self.activation_epoch),
                u64_chunk(self.exit_epoch),
                u64_chunk(self.withdrawable_epoch),
            ],
            3,
        )
    }

    /// The consensus specs' `is_active_validator`.
    pub fn is_active(&self, epoch: u64) -> bool {
        self.activation_epoch <= epoch && epoch < self.exit_epoch
    }
}

/// `hash_tree_root(List[Validator, VALIDATOR_REGISTRY_LIMIT])`.
pub fn validators_root(validators: &[Validator]) -> Root {
    let leaves: Vec<Root> = validators.iter().map(Validator::hash_tree_root).collect();
    mix_in_length(&merkleize(&leaves, REGISTRY_DEPTH), validators.len() as u64)
}
