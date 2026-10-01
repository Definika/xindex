//! BLS12-381 as the beacon chain signs: public keys in G1, signatures in G2, the proof-of-possession ciphersuite.

use bls12_381::hash_to_curve::{HashToField, MapToCurve};
use bls12_381::{multi_miller_loop, G1Affine, G2Affine, G2Prepared, G2Projective};
use generic_array::GenericArray;
use group::{Curve, Group};
use sha2::{Digest, Sha256};

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
    let hashed = hash_to_g2(message, DST).to_affine();
    let negated = -G1Affine::generator();
    let result = multi_miller_loop(&[
        (key, &G2Prepared::from(hashed)),
        (&negated, &G2Prepared::from(signature)),
    ])
    .final_exponentiation();
    bool::from(result.is_identity())
}

/// RFC 9380's `hash_to_curve` for G2 with `expand_message_xmd` over SHA-256, the beacon chain's suite: two field
/// elements from 256 uniform bytes, each mapped to the curve, added, and the cofactor cleared. It is written here from
/// the RFC's steps over the field and map functions that zkcrypto's `bls12_381` and the zkVMs' forks of it all share,
/// so the statement is the same code under SP1 and RISC Zero, whose forks differ in the signature of their own
/// `hash_to_curve`. `tests/hash_to_curve.rs` checks it against the RFC's vectors.
pub fn hash_to_g2(message: &[u8], dst: &[u8]) -> G2Projective {
    type Field = <G2Projective as MapToCurve>::Field;
    let uniform = expand_message_xmd::<256>(message, dst);
    let u0 = Field::from_okm(GenericArray::from_slice(&uniform[..128]));
    let u1 = Field::from_okm(GenericArray::from_slice(&uniform[128..]));
    (G2Projective::map_to_curve(&u0) + G2Projective::map_to_curve(&u1)).clear_h()
}

/// RFC 9380, section 5.3.1, with SHA-256: `N` uniform bytes from `message` under `dst`, which must be shorter than
/// 256 bytes, as every DST here is.
pub fn expand_message_xmd<const N: usize>(message: &[u8], dst: &[u8]) -> [u8; N] {
    const B: usize = 32;
    assert!(
        dst.len() < 256 && N <= 255 * B,
        "a DST of one length byte, at most 255 blocks"
    );
    let tail = |h: Sha256| h.chain_update(dst).chain_update([dst.len() as u8]);
    let b0 = tail(
        Sha256::new()
            .chain_update([0u8; 64])
            .chain_update(message)
            .chain_update((N as u16).to_be_bytes())
            .chain_update([0u8]),
    )
    .finalize();
    let mut out = [0u8; N];
    let mut previous = tail(Sha256::new().chain_update(b0).chain_update([1u8])).finalize();
    for i in 1..=N.div_ceil(B) {
        if i > 1 {
            let mut mixed = [0u8; B];
            for (j, m) in mixed.iter_mut().enumerate() {
                *m = b0[j] ^ previous[j];
            }
            previous = tail(Sha256::new().chain_update(mixed).chain_update([i as u8])).finalize();
        }
        let start = (i - 1) * B;
        let end = (start + B).min(N);
        out[start..end].copy_from_slice(&previous[..end - start]);
    }
    out
}
