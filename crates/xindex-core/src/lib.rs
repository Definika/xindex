//! What every vault chain's Rust programs share (Stage B spec, sections 4, 5.6, 7 and 10), taken from the Solana
//! programs, which run on it: Ethereum's encodings and proofs, P1's and P2's Groth16 checks, the light client's rules,
//! and the vault's messages, digests, speed limit and snapshot reads. Nothing here touches a chain's accounts, storage,
//! coins, clock or events: each chain's program keeps those, passes `now` in, and gives the cryptography its host
//! functions provide as a [`crypto::Crypto`].
//!
//! `no_std` with `alloc`, and no dependency unless the `native` feature asks for the host tests' pure-Rust
//! [`native::Native`], so the same code builds for Solana's SBF, NEAR's Wasm and Soroban's Wasm.

#![no_std]

extern crate alloc;

pub mod abi;
pub mod checkpoint;
pub mod constants;
pub mod crypto;
pub mod event;
pub mod groth16;
pub mod hex;
pub mod light_client;
pub mod mpt;
#[cfg(feature = "native")]
pub mod native;
pub mod risc0;
pub mod rlp;
pub mod snapshot;
pub mod sp1;
pub mod speed;
pub mod state_reader;

pub use crypto::{Crypto, CryptoError};
