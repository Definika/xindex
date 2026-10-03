//! `xindex_core::Crypto` over Soroban's host functions. Soroban's BN254 functions take Ethereum's encodings already
//! (CAP-0074: a G1 point `x ++ y` big-endian, a G2 point with each coordinate's imaginary part first, the point at
//! infinity all zero), so nothing is converted; a scalar is reduced modulo the group's order, which leaves a product
//! unchanged since every G1 point has that order. Where Ethereum's precompile would return an error, Soroban's host
//! traps instead, which fails the whole call: every caller in the core treats a `CryptoError` as a refusal anyway.

use soroban_sdk::crypto::bn254::{Bn254Fr, Bn254G1Affine, Bn254G2Affine};
use soroban_sdk::crypto::CryptoHazmat;
use soroban_sdk::{Bytes, BytesN, Env, Vec};
use xindex_core::crypto::{Crypto, CryptoError};

/// The core's cryptography, on the host of `env`.
pub struct Soroban<'a>(pub &'a Env);

impl Soroban<'_> {
    fn bytes(&self, parts: &[&[u8]]) -> Bytes {
        let mut b = Bytes::new(self.0);
        for p in parts {
            b.extend_from_slice(p);
        }
        b
    }

    fn g1(&self, p: &[u8]) -> Bn254G1Affine {
        Bn254G1Affine::from_bytes(BytesN::from_array(self.0, p.try_into().unwrap()))
    }
}

impl Crypto for Soroban<'_> {
    fn keccak256(&self, parts: &[&[u8]]) -> [u8; 32] {
        self.0.crypto().keccak256(&self.bytes(parts)).to_array()
    }

    fn sha256(&self, parts: &[&[u8]]) -> [u8; 32] {
        self.0.crypto().sha256(&self.bytes(parts)).to_array()
    }

    fn bn254_g1_add(&self, input: &[u8; 128]) -> Result<[u8; 64], CryptoError> {
        let bn = self.0.crypto().bn254();
        Ok(bn
            .g1_add(&self.g1(&input[..64]), &self.g1(&input[64..]))
            .to_array())
    }

    fn bn254_g1_mul(&self, input: &[u8; 96]) -> Result<[u8; 64], CryptoError> {
        let scalar =
            Bn254Fr::from_bytes(BytesN::from_array(self.0, input[64..].try_into().unwrap()));
        Ok(self
            .0
            .crypto()
            .bn254()
            .g1_mul(&self.g1(&input[..64]), &scalar)
            .to_array())
    }

    fn bn254_pairing_check(&self, input: &[u8]) -> Result<bool, CryptoError> {
        if input.is_empty() || !input.len().is_multiple_of(192) {
            return Err(CryptoError);
        }
        let mut g1s = Vec::new(self.0);
        let mut g2s = Vec::new(self.0);
        for pair in input.chunks(192) {
            g1s.push_back(self.g1(&pair[..64]));
            g2s.push_back(Bn254G2Affine::from_bytes(BytesN::from_array(
                self.0,
                pair[64..].try_into().unwrap(),
            )));
        }
        Ok(self.0.crypto().bn254().pairing_check(g1s, g2s))
    }

    fn secp256k1_recover(
        &self,
        hash: &[u8; 32],
        recovery_id: u8,
        signature: &[u8; 64],
    ) -> Result<[u8; 64], CryptoError> {
        if recovery_id > 1 {
            return Err(CryptoError);
        }
        // The digest is the core's EIP-712 digest, a keccak hash, as the hazmat function requires.
        let hazmat: CryptoHazmat = self.0.crypto_hazmat();
        let key = hazmat.secp256k1_recover(
            &BytesN::from_array(self.0, hash),
            &BytesN::from_array(self.0, signature),
            recovery_id as u32,
        );
        let key = key.to_array();
        Ok(key[1..].try_into().unwrap())
    }
}
