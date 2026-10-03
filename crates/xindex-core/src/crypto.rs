//! The cryptography a chain's runtime gives a contract, in Ethereum's encodings: every chain implements this once over
//! its host functions (Solana's syscalls, NEAR's and Soroban's host functions), converting at that boundary where its
//! own encoding differs, and the rest of this crate is written against it alone.
//!
//! Encodings, as Ethereum's precompiles take them:
//! - a G1 point is `x ++ y`, each a 32-byte big-endian field element, the point at infinity `(0, 0)` (EIP-196);
//! - a G2 point is `x_im ++ x_re ++ y_im ++ y_re`, each 32 bytes big-endian, the imaginary part first (EIP-197);
//! - a scalar is 32 bytes big-endian.

/// The host refused the operation: a malformed point, an input of the wrong length, or a signature that recovers no
/// key. The callers here turn it into their own errors; none of them tells the cases apart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CryptoError;

pub trait Crypto {
    /// `keccak256` of the concatenation of `parts`.
    fn keccak256(&self, parts: &[&[u8]]) -> [u8; 32];

    /// SHA-256 of the concatenation of `parts`.
    fn sha256(&self, parts: &[&[u8]]) -> [u8; 32];

    /// `ECADD` (EIP-196): `a ++ b`, two G1 points, to `a + b`.
    fn bn254_g1_add(&self, input: &[u8; 128]) -> Result<[u8; 64], CryptoError>;

    /// `ECMUL` (EIP-196): `p ++ s`, a G1 point and a scalar, to `s * p`.
    fn bn254_g1_mul(&self, input: &[u8; 96]) -> Result<[u8; 64], CryptoError>;

    /// `ECPAIRING` (EIP-197): pairs of a G1 point then a G2 point, 192 bytes each; whether the product of their
    /// pairings is one. G2 points must lie in the subgroup.
    fn bn254_pairing_check(&self, input: &[u8]) -> Result<bool, CryptoError>;

    /// The secp256k1 public key, `x ++ y` without the `0x04` prefix, that signed the 32-byte `hash` with `signature`
    /// (`r ++ s`) and recovery id 0 or 1. Malleability is the caller's to check, as OpenZeppelin's `ECDSA` does.
    fn secp256k1_recover(
        &self,
        hash: &[u8; 32],
        recovery_id: u8,
        signature: &[u8; 64],
    ) -> Result<[u8; 64], CryptoError>;
}
