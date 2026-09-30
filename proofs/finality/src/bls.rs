//! BLS12-381 as the beacon chain signs: public keys in G1, signatures in G2, the proof-of-possession ciphersuite.

use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{multi_miller_loop, G1Affine, G2Affine, G2Prepared, G2Projective};
use group::{Curve, Group};
use sha2::Sha256;

pub const DST: &[u8] = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

/// The point of a registry key, read from its uncompressed form without the costly square root: it must lie on the
/// curve and compress to exactly the key the registry holds. Two points share an x only as `±y`, and the compressed
/// form's sign flag tells them apart, so this is the registry's key. The beacon chain checked that key's subgroup when
/// its deposit was processed, so the point is in G1.
pub fn registry_key(uncompressed: &[u8; 96], compressed: &[u8; 48]) -> Option<G1Affine> {
    let point = Option::<G1Affine>::from(G1Affine::from_uncompressed_unchecked(uncompressed))?;
    if !bool::from(point.is_on_curve())
        || bool::from(point.is_identity())
        || point.to_compressed() != *compressed
    {
        return None;
    }
    Some(point)
}

/// Whether `signature` is a valid signature of `message` under `key`. The signature is fully checked, its subgroup
/// included.
pub fn verify(key: &G1Affine, message: &[u8], signature: &[u8; 96]) -> bool {
    let signature = match Option::<G2Affine>::from(G2Affine::from_compressed(signature)) {
        Some(s) => s,
        None => return false,
    };
    if bool::from(key.is_identity()) {
        return false;
    }
    let hashed = <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([message], DST)
        .to_affine();
    let negated = -G1Affine::generator();
    let result = multi_miller_loop(&[
        (key, &G2Prepared::from(hashed)),
        (&negated, &G2Prepared::from(signature)),
    ])
    .final_exponentiation();
    bool::from(result.is_identity())
}
