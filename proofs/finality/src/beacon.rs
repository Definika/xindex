//! The beacon chain's constants and the containers a vote is made of, from Electra on. The network's own constants
//! (its genesis, its fork versions) are mainnet's, or Sepolia's with the `sepolia` feature, for the testnets.

use crate::ssz::{hash_pair, merkleize, u64_chunk};
use crate::Root;
use serde::{Deserialize, Serialize};

pub const SLOTS_PER_EPOCH: u64 = 32;
pub const FAR_FUTURE_EPOCH: u64 = u64::MAX;
pub const DOMAIN_BEACON_ATTESTER: [u8; 4] = [1, 0, 0, 0];
pub const DOMAIN_DEPOSIT: [u8; 4] = [3, 0, 0, 0];
pub use network::{FORKS, GENESIS_FORK_VERSION, GENESIS_VALIDATORS_ROOT, NETWORK};

/// Mainnet. A program built for one network computes the other's signing domains wrongly, so no vote of the other
/// verifies in it: each network's program is its own key.
#[cfg(not(feature = "sepolia"))]
mod network {
    use crate::Root;

    pub const NETWORK: &str = "mainnet";
    pub const GENESIS_FORK_VERSION: [u8; 4] = [0, 0, 0, 0];

    /// Mainnet's `genesis_validators_root`.
    pub const GENESIS_VALIDATORS_ROOT: Root = [
        0x4b, 0x36, 0x3d, 0xb9, 0x4e, 0x28, 0x61, 0x20, 0xd7, 0x6e, 0xb9, 0x05, 0x34, 0x0f, 0xdd,
        0x4e, 0x54, 0xbf, 0xe9, 0xf0, 0x6b, 0xf3, 0x3f, 0xf6, 0xcf, 0x5a, 0xd2, 0x7f, 0x51, 0x1b,
        0xfe, 0x95,
    ];

    /// Mainnet's forks from Electra on, by first epoch. A later fork is a new program and a verifier rotation: until
    /// then its votes carry a domain this program does not compute, so they fail to verify, and nothing unsound
    /// follows.
    pub const FORKS: [(u64, [u8; 4]); 2] = [(364_032, [5, 0, 0, 0]), (411_392, [6, 0, 0, 0])];
}

/// Sepolia, for the testnets, from its beacon node's `/eth/v1/beacon/genesis` and `/eth/v1/config/fork_schedule`.
#[cfg(feature = "sepolia")]
mod network {
    use crate::Root;

    pub const NETWORK: &str = "sepolia";
    pub const GENESIS_FORK_VERSION: [u8; 4] = [0x90, 0x00, 0x00, 0x69];

    /// Sepolia's `genesis_validators_root`.
    pub const GENESIS_VALIDATORS_ROOT: Root = [
        0xd8, 0xea, 0x17, 0x1f, 0x3c, 0x94, 0xae, 0xa2, 0x1e, 0xbc, 0x42, 0xa1, 0xed, 0x61, 0x05,
        0x2a, 0xcf, 0x3f, 0x92, 0x09, 0xc0, 0x0e, 0x4e, 0xfb, 0xaa, 0xdd, 0xac, 0x09, 0xed, 0x9b,
        0x80, 0x78,
    ];

    /// Sepolia's forks from Electra on, by first epoch, under the same rule as mainnet's.
    pub const FORKS: [(u64, [u8; 4]); 2] = [
        (222_464, [0x90, 0x00, 0x00, 0x74]),
        (272_640, [0x90, 0x00, 0x00, 0x75]),
    ];
}

/// The fork version in force at `epoch`, or `None` before Electra.
pub fn fork_version(epoch: u64) -> Option<[u8; 4]> {
    FORKS
        .iter()
        .rev()
        .find(|(first, _)| epoch >= *first)
        .map(|(_, version)| *version)
}

/// `BeaconState` has 37 fields in Electra and 38 in Fulu, so 64 leaves either way; `validators` is field 11.
pub const STATE_DEPTH: usize = 6;
pub const STATE_VALIDATORS_INDEX: u64 = 11;
/// From a block's state root to the `block_hash` of the execution payload that block carried: the state's
/// `latest_execution_payload_header` is field 24, and an `ExecutionPayloadHeader` has 17 fields (32 leaves) with
/// `block_hash` at 12. A block's state is its post-state, so that header is the block's own payload's.
pub const STATE_BLOCK_HASH_DEPTH: usize = STATE_DEPTH + 5;
pub const STATE_BLOCK_HASH_INDEX: u64 = 24 * 32 + 12;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Checkpoint {
    pub epoch: u64,
    pub root: Root,
}

impl Checkpoint {
    pub fn hash_tree_root(&self) -> Root {
        hash_pair(&u64_chunk(self.epoch), &self.root)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttestationData {
    pub slot: u64,
    pub index: u64,
    pub beacon_block_root: Root,
    pub source: Checkpoint,
    pub target: Checkpoint,
}

impl AttestationData {
    pub fn hash_tree_root(&self) -> Root {
        merkleize(
            &[
                u64_chunk(self.slot),
                u64_chunk(self.index),
                self.beacon_block_root,
                self.source.hash_tree_root(),
                self.target.hash_tree_root(),
            ],
            3,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BeaconBlockHeader {
    pub slot: u64,
    pub proposer_index: u64,
    pub parent_root: Root,
    pub state_root: Root,
    pub body_root: Root,
}

impl BeaconBlockHeader {
    pub fn hash_tree_root(&self) -> Root {
        merkleize(
            &[
                u64_chunk(self.slot),
                u64_chunk(self.proposer_index),
                self.parent_root,
                self.state_root,
                self.body_root,
            ],
            3,
        )
    }
}

/// The consensus specs' `compute_domain`.
pub fn compute_domain(
    domain_type: [u8; 4],
    fork_version: [u8; 4],
    genesis_validators_root: &Root,
) -> Root {
    let mut version = [0u8; 32];
    version[..4].copy_from_slice(&fork_version);
    let fork_data_root = hash_pair(&version, genesis_validators_root);
    let mut domain = [0u8; 32];
    domain[..4].copy_from_slice(&domain_type);
    domain[4..].copy_from_slice(&fork_data_root[..28]);
    domain
}

/// The consensus specs' `compute_signing_root`: the root of `SigningData(object_root, domain)`.
pub fn signing_root(object_root: &Root, domain: &Root) -> Root {
    hash_pair(object_root, domain)
}

/// The root of `DepositMessage(pubkey, withdrawal_credentials, amount)`, which a deposit signs.
pub fn deposit_message_root(pubkey: &[u8; 48], withdrawal_credentials: &Root, amount: u64) -> Root {
    let mut low = [0u8; 32];
    low.copy_from_slice(&pubkey[..32]);
    let mut high = [0u8; 32];
    high[..16].copy_from_slice(&pubkey[32..]);
    merkleize(
        &[
            hash_pair(&low, &high),
            *withdrawal_credentials,
            u64_chunk(amount),
        ],
        2,
    )
}
