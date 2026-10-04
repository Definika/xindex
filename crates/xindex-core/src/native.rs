//! A `Crypto` in pure Rust, for host tests: the very crates Solana's runtime falls back to off-chain (`sha3`, `sha2`,
//! `k256`, and `solana-bn254`'s arkworks code, which Agave's syscalls run), so a test here answers as the chain does.

extern crate std;

use crate::crypto::{Crypto, CryptoError};
use sha2::{Digest, Sha256};
use sha3::Keccak256;
use solana_bn254::prelude::{
    alt_bn128_g1_addition_be, alt_bn128_g1_multiplication_be, alt_bn128_pairing_be,
};

/// The host tests' cryptography.
#[derive(Clone, Copy, Debug, Default)]
pub struct Native;

fn point(v: std::vec::Vec<u8>) -> Result<[u8; 64], CryptoError> {
    v.try_into().map_err(|_| CryptoError)
}

impl Crypto for Native {
    fn keccak256(&self, parts: &[&[u8]]) -> [u8; 32] {
        let mut h = Keccak256::new();
        parts.iter().for_each(|p| h.update(p));
        h.finalize().into()
    }

    fn sha256(&self, parts: &[&[u8]]) -> [u8; 32] {
        let mut h = Sha256::new();
        parts.iter().for_each(|p| h.update(p));
        h.finalize().into()
    }

    fn bn254_g1_add(&self, input: &[u8; 128]) -> Result<[u8; 64], CryptoError> {
        point(alt_bn128_g1_addition_be(input).map_err(|_| CryptoError)?)
    }

    fn bn254_g1_mul(&self, input: &[u8; 96]) -> Result<[u8; 64], CryptoError> {
        point(alt_bn128_g1_multiplication_be(input).map_err(|_| CryptoError)?)
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
        let id = k256::ecdsa::RecoveryId::try_from(recovery_id).map_err(|_| CryptoError)?;
        let signature = k256::ecdsa::Signature::from_slice(signature).map_err(|_| CryptoError)?;
        let key = k256::ecdsa::VerifyingKey::recover_from_prehash(hash, &signature, id)
            .map_err(|_| CryptoError)?;
        key.to_encoded_point(false).as_bytes()[1..65]
            .try_into()
            .map_err(|_| CryptoError)
    }
}
