//! What the vault stores and what its methods take: fixed-size Ethereum values as `0x`-prefixed hex in JSON, amounts
//! of yoctoNEAR as `U128` strings in JSON and `u128` in storage, and the interfaces doc's account encoding
//! (`design/2026-10-03-near-stellar-interfaces.md`).

use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::json_types::U128;
use near_sdk::serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use near_sdk::{near, AccountId};

use crate::errors::{fail, Error};

fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(2 + 2 * bytes.len());
    out.push_str("0x");
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 15) as usize] as char);
    }
    out
}

fn from_hex<const N: usize>(s: &str) -> Option<[u8; N]> {
    let s = s.strip_prefix("0x")?;
    if s.len() != 2 * N {
        return None;
    }
    let mut out = [0u8; N];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(s.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

macro_rules! hex_bytes {
    ($name:ident, $n:literal) => {
        /// A fixed-size Ethereum value: `0x`-prefixed hex in JSON, its bytes in storage.
        #[derive(
            BorshSerialize,
            BorshDeserialize,
            Clone,
            Copy,
            Debug,
            Default,
            PartialEq,
            Eq,
            PartialOrd,
            Ord,
            Hash,
        )]
        #[borsh(crate = "near_sdk::borsh")]
        pub struct $name(pub [u8; $n]);

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&to_hex(&self.0))
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = <String as Deserialize>::deserialize(d)?;
                from_hex::<$n>(&s)
                    .map($name)
                    .ok_or_else(|| de::Error::custom(concat!("expected 0x and ", $n, " hex bytes")))
            }
        }
    };
}

hex_bytes!(Hex20, 20);
hex_bytes!(Hex32, 32);

/// A final Ethereum block: its number, timestamp and state root.
#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Checkpoint {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: Hex32,
}

impl Checkpoint {
    pub fn core(&self) -> xindex_core::checkpoint::Checkpoint {
        xindex_core::checkpoint::Checkpoint {
            block: self.block,
            timestamp: self.timestamp,
            state_root: self.state_root.0,
        }
    }
}

/// SP1's Groth16 proof (P1's), or RISC Zero's (P2's).
pub const SP1: u8 = 1;
pub const RISC_ZERO: u8 = 2;

/// A light client of Ethereum compiled into the vault: P1 or P2, or a successor or rotation candidate. Its 32-byte id,
/// which a `VERIFIER_ROTATION` names and a successor proposal names, is the hash of its configuration as first
/// registered (`verifier_id`), so the factory can name it on Ethereum before anyone registers it here.
#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VerifierConfig {
    /// `SP1` or `RISC_ZERO`.
    pub system: u8,
    /// P1's program key or P2's image id.
    pub key: Hex32,
    /// `keccak256(abi.encode(epoch, validatorsRoot, execHash, execNumber))` of the first checkpoint it trusts.
    pub anchor: Hex32,
    pub epoch: u64,
    /// The beacon chain's genesis time: 1606824023 on mainnet, 1655733600 on Sepolia.
    pub genesis_time: u64,
}

impl VerifierConfig {
    pub fn check(&self) {
        if self.system != SP1 && self.system != RISC_ZERO {
            fail(Error::UnknownSystem);
        }
        if self.key.0 == [0u8; 32] || self.anchor.0 == [0u8; 32] || self.genesis_time == 0 {
            fail(Error::ZeroAddress);
        }
    }
}

/// A light client's state: its configuration with the anchor and epoch moved by every proof since.
#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LightClient {
    pub system: u8,
    pub key: Hex32,
    pub anchor: Hex32,
    pub epoch: u64,
    pub genesis_time: u64,
}

/// A governance change waiting: the hash of its body and when it may apply, all zero when none waits.
#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PendingChange {
    pub body_hash: Hex32,
    pub ready_at: u64,
}

/// A successor pair under review, and when the review ends; zero when none is.
#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Successor {
    pub p1: Hex32,
    pub p2: Hex32,
    pub review_ends: u64,
}

/// An index registered here.
#[near(serializers = [borsh])]
#[derive(Clone, Debug, Default)]
pub struct IndexState {
    /// Whether NEAR is among the index's tokens: set by its first credit, as the EVM vault's `_indexTokens`.
    pub has_native: bool,
    pub balance: u128,
    /// Everything paid out of `balance`: to burn recipients, and into other indexes by migration.
    pub paid_total: u128,
    /// One hour's payouts per slot, tagged with its hour.
    pub outflow: [(u64, u128); xindex_core::constants::BUCKETS],
    pub digest: [u8; 32],
}

/// A mint order's or a rebalance delivery's deposits for one index.
#[near(serializers = [borsh])]
#[derive(Clone, Copy, Debug, Default)]
pub struct Intake {
    pub state: u8,
    pub has_native: bool,
    pub total: u128,
    pub digest: [u8; 32],
}

/// A burn, a migration or a snapshot claim accepted and not yet paid in full: to an account, or into another index.
#[near(serializers = [borsh])]
#[derive(Clone, Debug)]
pub struct Owed {
    pub recipient: Option<AccountId>,
    pub new_index: [u8; 20],
    pub remaining: u128,
}

/// What the vault's settings are at initialization.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct InitConfig {
    /// Ethereum's chain id, which every message must name.
    pub source_chain_id: u64,
    /// The id the factory's registry gives this chain (`near:mainnet` 339552387624818629).
    pub chain_id: u64,
    pub factory: Hex20,
    pub hub_implementation: Hex20,
    pub p1: VerifierConfig,
    pub p2: VerifierConfig,
    /// The guardian's freeze key on NEAR.
    pub freezer: AccountId,
    /// The owner's emergency multisig on NEAR: a contract account, never an implicit (single-key) one.
    pub recovery_proposer: AccountId,
    pub native_cap: U128,
    pub native_floor: U128,
}

/// The proofs of one claim by a pair of verifiers.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct PairProofs {
    pub proof1: near_sdk::json_types::Base64VecU8,
    pub proof2: near_sdk::json_types::Base64VecU8,
}

/// The last message a pair delivered on both proofs, as a successor proves it again.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct LastMessage {
    pub payload: near_sdk::json_types::Base64VecU8,
    pub block: u64,
    pub proofs: PairProofs,
}

/// What a successor pair must prove: the checkpoint the pair in force last accepted, a recent one, and the last message
/// delivered on both proofs, if there was one.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct Continuity {
    pub last: PairProofs,
    pub recent: Checkpoint,
    pub recent_proofs: PairProofs,
    pub message: Option<LastMessage>,
}

/// An index's books, as the views return them.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct IndexView {
    pub has_native: bool,
    pub balance: U128,
    pub paid_total: U128,
    pub digest: Hex32,
    pub available: U128,
}

#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct IntakeView {
    pub state: u8,
    pub total: U128,
    pub digest: Hex32,
}

#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct OwedView {
    pub recipient: Option<AccountId>,
    pub new_index: Option<Hex20>,
    pub remaining: U128,
}

/// The vault's settings and state, as the `config` view returns them.
#[near(serializers = [json])]
#[derive(Clone, Debug)]
pub struct ConfigView {
    pub source_chain_id: u64,
    pub chain_id: u64,
    pub vault_id: Hex32,
    pub factory: Hex20,
    pub hub_implementation: Hex20,
    pub p1: Hex32,
    pub p2: Hex32,
    pub freezer: AccountId,
    pub recovery_proposer: AccountId,
    pub frozen_until: u64,
    pub cap: U128,
    pub outflow_floor: U128,
    pub held: U128,
    pub nonces: [u64; 3],
    pub pending_cap: PendingChange,
    pub pending_freezer: PendingChange,
    pub pending_rotation: PendingChange,
    pub checkpoint: Checkpoint,
    pub snapshot: Checkpoint,
    pub successor: Successor,
    pub last_message: Hex32,
    pub vetoes: u8,
}

/// The account a 32-byte recipient names (interfaces doc): with its top 12 bytes zero, the ETH-implicit account
/// (NEP-518) `0x` and the low 20 bytes in lowercase hex; otherwise the ed25519 implicit account, all 32 bytes in
/// lowercase hex. Both are created by the first transfer to them, so no payout to one is stranded.
pub fn account_of(word: &[u8; 32]) -> AccountId {
    let id = if word[..12] == [0u8; 12] {
        to_hex(&word[12..])
    } else {
        to_hex(word)[2..].to_string()
    };
    id.parse().unwrap_or_else(|_| fail(Error::WrongRecipient))
}

/// Whether `account` is an implicit account, ed25519's (64 hex) or ETH-implicit (`0x` and 40 hex): one key holds it.
pub fn is_implicit(account: &AccountId) -> bool {
    let s = account.as_str();
    let hex_only = |t: &str| {
        t.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    (s.len() == 64 && hex_only(s)) || (s.len() == 42 && s.starts_with("0x") && hex_only(&s[2..]))
}
