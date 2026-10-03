//! Xindex v4 Stage B on Stellar: what the Soroban contracts share. The vault chains' common Rust
//! (`crates/xindex-core`) runs here over Soroban's host functions ([`Soroban`]), and P1 and P2 share one light client
//! ([`light_client`]), which differs between them only in the check of a proof, as `FinalityVerifier.sol` differs from
//! its two subclasses.

#![no_std]

extern crate alloc;

pub mod crypto;
pub mod light_client;

pub use crypto::Soroban;
