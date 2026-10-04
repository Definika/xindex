//! Solana's cryptography as `xindex_core`'s `Crypto`: the keccak, SHA-256, alt_bn128 and secp256k1 syscalls, which
//! take Ethereum's big-endian encodings (EIP-196 and EIP-197) as they stand. Off-chain, in host tests, the same crates
//! fall back to their pure-Rust code, so the tests check the very calls the programs make.

use solana_bn254::prelude::{
    alt_bn128_g1_addition_be, alt_bn128_g1_multiplication_be, alt_bn128_pairing_be,
};
use xindex_core::crypto::{Crypto, CryptoError};

/// The syscalls every Xindex program on Solana passes to the core.
#[derive(Clone, Copy, Debug, Default)]
pub struct Solana;

impl Crypto for Solana {
    fn keccak256(&self, parts: &[&[u8]]) -> [u8; 32] {
        solana_keccak_hasher::hashv(parts).to_bytes()
    }

    fn sha256(&self, parts: &[&[u8]]) -> [u8; 32] {
        solana_sha256_hasher::hashv(parts).to_bytes()
    }

    fn bn254_g1_add(&self, input: &[u8; 128]) -> Result<[u8; 64], CryptoError> {
        alt_bn128_g1_addition_be(input)
            .map_err(|_| CryptoError)?
            .try_into()
            .map_err(|_| CryptoError)
    }

    fn bn254_g1_mul(&self, input: &[u8; 96]) -> Result<[u8; 64], CryptoError> {
        alt_bn128_g1_multiplication_be(input)
            .map_err(|_| CryptoError)?
            .try_into()
            .map_err(|_| CryptoError)
    }

    fn bn254_pairing_check(&self, input: &[u8]) -> Result<bool, CryptoError> {
        let result = alt_bn128_pairing_be(input).map_err(|_| CryptoError)?;
        let mut one = [0u8; 32];
        one[31] = 1;
        Ok(result[..] == one)
    }

    fn secp256k1_recover(
        &self,
        hash: &[u8; 32],
        recovery_id: u8,
        signature: &[u8; 64],
    ) -> Result<[u8; 64], CryptoError> {
        solana_secp256k1_recover::secp256k1_recover(hash, recovery_id, signature)
            .map(|key| key.to_bytes())
            .map_err(|_| CryptoError)
    }
}
