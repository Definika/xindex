//! NEAR's host functions as the core's `Crypto`, in Ethereum's encodings: the conversion happens here and nowhere
//! else. NEAR takes BN254 field elements little-endian and an Fq2 element real part first (`alt_bn128.rs` in nearcore):
//! - a G1 point is `x ++ y`, each 32 bytes little-endian;
//! - a G2 point is `x_re ++ x_im ++ y_re ++ y_im`, each 32 bytes little-endian, where Ethereum writes
//!   `x_im ++ x_re ++ y_im ++ y_re` big-endian;
//! - `alt_bn128_g1_sum` takes `(sign ++ point)*`, sign 0 to add; `alt_bn128_g1_multiexp` takes `(point ++ scalar)*`, the
//!   scalar little-endian.
//!
//! A malformed point aborts the call inside the host function rather than returning an error: for the Groth16 checks,
//! which are the only callers, a refused proof and an aborted call are the same outcome.

use near_sdk::env;
use xindex_core::crypto::{Crypto, CryptoError};

/// The vault's cryptography: NEAR's host functions.
#[derive(Clone, Copy, Debug, Default)]
pub struct Near;

/// A 32-byte word with its byte order reversed: big-endian to little-endian, or back.
fn flip(word: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, b) in word.iter().enumerate().take(32) {
        out[31 - i] = *b;
    }
    out
}

/// A G1 point from Ethereum's encoding into NEAR's.
fn g1_to_near(point: &[u8]) -> [u8; 64] {
    let mut out = [0u8; 64];
    out[..32].copy_from_slice(&flip(&point[..32]));
    out[32..].copy_from_slice(&flip(&point[32..64]));
    out
}

/// A G1 point from NEAR's encoding into Ethereum's.
fn g1_from_near(point: &[u8]) -> Result<[u8; 64], CryptoError> {
    if point.len() != 64 {
        return Err(CryptoError);
    }
    let mut out = [0u8; 64];
    out[..32].copy_from_slice(&flip(&point[..32]));
    out[32..].copy_from_slice(&flip(&point[32..]));
    Ok(out)
}

/// A G2 point from Ethereum's encoding, `x_im ++ x_re ++ y_im ++ y_re` big-endian, into NEAR's,
/// `x_re ++ x_im ++ y_re ++ y_im` little-endian.
fn g2_to_near(point: &[u8]) -> [u8; 128] {
    let mut out = [0u8; 128];
    out[..32].copy_from_slice(&flip(&point[32..64]));
    out[32..64].copy_from_slice(&flip(&point[..32]));
    out[64..96].copy_from_slice(&flip(&point[96..128]));
    out[96..].copy_from_slice(&flip(&point[64..96]));
    out
}

impl Crypto for Near {
    fn keccak256(&self, parts: &[&[u8]]) -> [u8; 32] {
        env::keccak256_array(parts.concat())
    }

    fn sha256(&self, parts: &[&[u8]]) -> [u8; 32] {
        env::sha256_array(parts.concat())
    }

    fn bn254_g1_add(&self, input: &[u8; 128]) -> Result<[u8; 64], CryptoError> {
        let mut near = [0u8; 130];
        near[1..65].copy_from_slice(&g1_to_near(&input[..64]));
        near[66..].copy_from_slice(&g1_to_near(&input[64..]));
        g1_from_near(&env::alt_bn128_g1_sum(near))
    }

    fn bn254_g1_mul(&self, input: &[u8; 96]) -> Result<[u8; 64], CryptoError> {
        let mut near = [0u8; 96];
        near[..64].copy_from_slice(&g1_to_near(&input[..64]));
        near[64..].copy_from_slice(&flip(&input[64..]));
        g1_from_near(&env::alt_bn128_g1_multiexp(near))
    }

    fn bn254_pairing_check(&self, input: &[u8]) -> Result<bool, CryptoError> {
        if !input.len().is_multiple_of(192) {
            return Err(CryptoError);
        }
        let mut near = Vec::with_capacity(input.len());
        for pair in input.chunks(192) {
            near.extend_from_slice(&g1_to_near(&pair[..64]));
            near.extend_from_slice(&g2_to_near(&pair[64..]));
        }
        Ok(env::alt_bn128_pairing_check(near))
    }

    fn secp256k1_recover(
        &self,
        hash: &[u8; 32],
        recovery_id: u8,
        signature: &[u8; 64],
    ) -> Result<[u8; 64], CryptoError> {
        // Malleability is the caller's to check (`snapshot::check_signature` refuses a high `s`), as the core expects.
        env::ecrecover(hash, signature, recovery_id, false).ok_or(CryptoError)
    }
}

#[cfg(test)]
mod tests {
    //! The adapter against the core's pure-Rust cryptography, which takes Ethereum's encodings: each host function,
    //! through the conversions here, must answer as Ethereum's precompiles do, the point at infinity included. Then
    //! the two Groth16 checks the vault runs, on SP1's and RISC Zero's real proofs.

    use super::*;
    use crate::fixtures::{hex, risc0_receipt, sp1_fixture};
    use xindex_core::native::Native;

    /// The generator, and twice it, in Ethereum's encoding.
    fn g() -> [u8; 64] {
        let mut p = [0u8; 64];
        p[31] = 1;
        p[63] = 2;
        p
    }

    #[test]
    fn hashes_are_the_standard() {
        assert_eq!(Near.keccak256(&[b"ab", b"c"]), Native.keccak256(&[b"abc"]));
        assert_eq!(Near.sha256(&[b"a", b"bc"]), Native.sha256(&[b"abc"]));
    }

    #[test]
    fn g1_operations_are_ethereums() {
        let mut add = [0u8; 128];
        add[..64].copy_from_slice(&g());
        add[64..].copy_from_slice(&g());
        let two = Native.bn254_g1_add(&add).unwrap();
        assert_eq!(Near.bn254_g1_add(&add).unwrap(), two);
        let mut mul = [0u8; 96];
        mul[..64].copy_from_slice(&g());
        mul[95] = 2;
        assert_eq!(Near.bn254_g1_mul(&mul).unwrap(), two);
        // A scalar of several bytes, so byte order matters, and the point at infinity both ways.
        mul[64..].copy_from_slice(&hex(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ));
        assert_eq!(
            Near.bn254_g1_mul(&mul).unwrap(),
            Native.bn254_g1_mul(&mul).unwrap()
        );
        mul[64..].fill(0);
        assert_eq!(Near.bn254_g1_mul(&mul).unwrap(), [0u8; 64]);
        let mut with_zero = [0u8; 128];
        with_zero[64..].copy_from_slice(&g());
        assert_eq!(Near.bn254_g1_add(&with_zero).unwrap(), g());
    }

    #[test]
    fn groth16_checks_pass_on_real_proofs() {
        let (key, values, proof) = sp1_fixture();
        assert_eq!(
            xindex_core::sp1::verify(&Near, &key, &values, &proof),
            Ok(())
        );
        let mut wrong = values.clone();
        wrong[0] ^= 1;
        assert!(xindex_core::sp1::verify(&Near, &key, &wrong, &proof).is_err());
        let (image, journal, seal) = risc0_receipt();
        assert_eq!(
            xindex_core::risc0::verify(&Near, &image, &journal, &seal),
            Ok(())
        );
        let mut wrong = journal.clone();
        wrong.push(0);
        assert!(xindex_core::risc0::verify(&Near, &image, &wrong, &seal).is_err());
    }

    /// `cast wallet sign --no-hash` by the key 1 over a fixed hash: recovered as Ethereum's `ecrecover` recovers it, to
    /// the address `cast wallet address` gives that key, with the wrong recovery id to another.
    #[test]
    fn recovery_is_ethereums() {
        let hash: [u8; 32] =
            hex("456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3")
                .try_into()
                .unwrap();
        let signed = hex("37ac0657cf003eeb682b39c1b6b4a7b9fbd6bb5e4fc05d3ff0f2db3958d8c3e21257f365e84a3a5218eecce74f2c933ee1bd4d68e99f8b959a4c622c01d4e7a41c");
        let sig: [u8; 64] = signed[..64].try_into().unwrap();
        let id = signed[64] - 27;
        let key = Near.secp256k1_recover(&hash, id, &sig).unwrap();
        assert_eq!(key, Native.secp256k1_recover(&hash, id, &sig).unwrap());
        assert_eq!(
            Near.keccak256(&[&key])[12..],
            hex("7E5F4552091A69125d5DfCb7b8C2659029395Bdf")[..]
        );
        assert_eq!(
            Near.secp256k1_recover(&hash, 1 - id, &sig),
            Native.secp256k1_recover(&hash, 1 - id, &sig)
        );
    }
}
