//! The vault's constants: its account seeds, and every rule, message format and hub slot all vault chains share
//! (`xindex_core::constants`): those of the EVM vault (`src/vault/XindexVault.sol`) and of
//! `src/libraries/VaultMessages.sol`, byte for byte.

pub use xindex_core::constants::*;

pub const CONFIG_SEED: &[u8] = b"config";
pub const TREASURY_SEED: &[u8] = b"treasury";
pub const INDEX_SEED: &[u8] = b"index";
pub const INTAKE_SEED: &[u8] = b"intake";
pub const DEPOSIT_SEED: &[u8] = b"deposit";
pub const USED_SEED: &[u8] = b"used";
pub const OWED_SEED: &[u8] = b"owed";
