//! RISC Zero v3.0's Groth16 check, as `RiscZeroGroth16Verifier.verify(seal, imageId, journalDigest)` and
//! `Groth16Verifier.verifyProof` make it (risc0-ethereum v3.0.1, vendored in `vendor/risc0-ethereum`), on Solana's
//! alt_bn128 syscalls through P1's helpers (`ethereum_verifier::groth16`). Natively the same functions run on arkworks,
//! so the host tests check the very code the program runs.

use crate::vk::*;
use ethereum_verifier::groth16::{linear_combination, pairing_is_one, ProofError};

/// A seal: the verifier's selector, then the Groth16 points A, B and C as eight words, `abi.encode(Seal)`.
pub const SEAL_LEN: usize = 4 + 8 * 32;

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    solana_sha256_hasher::hashv(parts).to_bytes()
}

/// `ReceiptClaimLib.ok(imageId, journalDigest).digest()`: the claim that the image `image_id` ran, halted with exit
/// code 0, committed the journal of digest `journal_digest`, and assumed nothing. Each struct's digest is SHA-256 of
/// its tag's digest, its digest fields, its data, and its count of digest fields as a little-endian `u16`.
pub fn claim_digest(image_id: &[u8; 32], journal_digest: &[u8; 32]) -> [u8; 32] {
    // Output { journalDigest, assumptionsDigest: 0 }
    let output = sha256(&[
        &sha256(&[b"risc0.Output"]),
        journal_digest,
        &[0u8; 32],
        &[2, 0],
    ]);
    // ReceiptClaim { input: 0, preStateDigest: imageId, postStateDigest: SYSTEM_STATE_ZERO_DIGEST, output }, then the
    // exit code (Halted, 0) as two u32s shifted by 24, which are zero.
    sha256(&[
        &sha256(&[b"risc0.ReceiptClaim"]),
        &[0u8; 32],
        image_id,
        &SYSTEM_STATE_ZERO_DIGEST,
        &output,
        &[0u8; 4],
        &[0u8; 4],
        &[4, 0],
    ])
}

/// `splitDigest`: the digest's bytes reversed, then its low and its high 128 bits, each as a public input.
pub fn split_digest(digest: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let (mut low, mut high) = ([0u8; 32], [0u8; 32]);
    for i in 0..16 {
        low[16 + i] = digest[15 - i];
        high[16 + i] = digest[31 - i];
    }
    (low, high)
}

/// `q - y`, the y-coordinate of `-A`, as `mod(sub(q, y), q)` computes it for a coordinate in the field. One at or past
/// `q`, which no prover writes, is refused here; the EVM would reduce it, so this is the stricter of the two.
fn negate(y: &[u8; 32]) -> Result<[u8; 32], ProofError> {
    if *y >= Q {
        return Err(ProofError::NotInField);
    }
    if *y == [0u8; 32] {
        return Ok([0u8; 32]);
    }
    let mut out = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = i16::from(Q[i]) - i16::from(y[i]) - borrow;
        (out[i], borrow) = if d < 0 {
            ((d + 256) as u8, 1)
        } else {
            (d as u8, 0)
        };
    }
    Ok(out)
}

/// Succeeds only if `seal` is RISC Zero v3.0's Groth16 seal of a receipt claiming that the image `image_id` ran and
/// committed `journal`, as `verify(seal, imageId, sha256(journal))` succeeds on the EVM.
pub fn verify(image_id: &[u8; 32], journal: &[u8], seal: &[u8]) -> Result<(), ProofError> {
    if seal.len() != SEAL_LEN {
        return Err(ProofError::WrongLength);
    }
    if seal[..4] != SELECTOR {
        return Err(ProofError::WrongSelector);
    }
    let claim = claim_digest(image_id, &sha256(&[journal]));
    let (root_0, root_1) = split_digest(&CONTROL_ROOT);
    let (claim_0, claim_1) = split_digest(&claim);
    let inputs = [root_0, root_1, claim_0, claim_1, BN254_CONTROL_ID];
    let vk_x = linear_combination(IC[0], &IC[1..], &inputs)?;
    let a_y: [u8; 32] = seal[36..68].try_into().unwrap();
    // e(-A, B) e(alpha, beta) e(vk_x, gamma) e(C, delta) == 1, in `verifyProof`'s order.
    let pairing = [
        &seal[4..36],
        &negate(&a_y)?,
        &seal[68..196],
        &ALPHA_X,
        &ALPHA_Y,
        &BETA_X_1,
        &BETA_X_2,
        &BETA_Y_1,
        &BETA_Y_2,
        &vk_x,
        &GAMMA_X_1,
        &GAMMA_X_2,
        &GAMMA_Y_1,
        &GAMMA_Y_2,
        &seal[196..],
        &DELTA_X_1,
        &DELTA_X_2,
        &DELTA_Y_1,
        &DELTA_Y_2,
    ]
    .concat();
    pairing_is_one(&pairing)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// RISC Zero's own v3.0 receipt (`vendor/risc0-ethereum/test/TestReceiptV3_0.sol`): the image id, the journal and
    /// the seal, which `RiscZeroGroth16Verifier` accepts on the EVM and on TRON's VM (`tron/`).
    pub fn receipt() -> ([u8; 32], Vec<u8>, Vec<u8>) {
        let t = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../vendor/risc0-ethereum/test/TestReceiptV3_0.sol"
        ))
        .unwrap();
        let grab = |name: &str| -> Vec<u8> {
            let rest = &t[t.find(name).unwrap()..];
            let start = rest.find("hex\"").unwrap() + 4;
            let end = start + rest[start..].find('"').unwrap();
            hex(&rest[start..end])
        };
        (
            grab("IMAGE_ID =").try_into().unwrap(),
            grab("JOURNAL ="),
            grab("SEAL ="),
        )
    }

    #[test]
    fn verifies_risc_zeros_own_receipt() {
        let (image_id, journal, seal) = receipt();
        assert_eq!(seal.len(), SEAL_LEN);
        assert_eq!(verify(&image_id, &journal, &seal), Ok(()));
    }

    #[test]
    fn refuses_anything_else() {
        let (image_id, journal, seal) = receipt();
        let mut j = journal.clone();
        j[0] ^= 1;
        assert_eq!(
            verify(&image_id, &j, &seal),
            Err(ProofError::Invalid),
            "another journal"
        );
        let digest = sha256(&[&journal]);
        assert_eq!(
            verify(&image_id, &digest, &seal),
            Err(ProofError::Invalid),
            "the journal's digest in its place: the check hashes the journal itself"
        );
        let mut i = image_id;
        i[31] ^= 1;
        assert_eq!(
            verify(&i, &journal, &seal),
            Err(ProofError::Invalid),
            "another image"
        );
        let mut s = seal.clone();
        s[0] ^= 1;
        assert_eq!(
            verify(&image_id, &journal, &s),
            Err(ProofError::WrongSelector)
        );
        assert_eq!(
            verify(&image_id, &journal, &seal[..SEAL_LEN - 1]),
            Err(ProofError::WrongLength)
        );
        assert_eq!(
            verify(&image_id, &journal, &[&seal[..], &[0]].concat()),
            Err(ProofError::WrongLength)
        );
        let mut s = seal.clone();
        s[200] ^= 1;
        assert!(verify(&image_id, &journal, &s).is_err(), "another C");
        let mut s = seal.clone();
        s[100] ^= 1;
        assert!(verify(&image_id, &journal, &s).is_err(), "another B");
        // A's y-coordinate past the field, which the EVM would reduce: refused.
        let mut s = seal.clone();
        s[36..68].copy_from_slice(&Q);
        assert_eq!(verify(&image_id, &journal, &s), Err(ProofError::NotInField));
    }

    #[test]
    fn negation_is_the_fields() {
        assert_eq!(negate(&[0u8; 32]), Ok([0u8; 32]));
        let mut one = [0u8; 32];
        one[31] = 1;
        let mut q_minus_one = Q;
        q_minus_one[31] -= 1;
        assert_eq!(negate(&one), Ok(q_minus_one));
        assert_eq!(negate(&q_minus_one), Ok(one));
        let mut w = [0u8; 32];
        w[30] = 1; // 256, which borrows across a byte
        let n = negate(&w).unwrap();
        let mut sum = [0u8; 32];
        let mut carry = 0u16;
        for i in (0..32).rev() {
            let v = u16::from(n[i]) + u16::from(w[i]) + carry;
            sum[i] = v as u8;
            carry = v >> 8;
        }
        assert_eq!(sum, Q, "y + (q - y) = q");
    }

    /// `splitDigest` of `RiscZeroGroth16Verifier`: reverse the 32 bytes, then take the low and high 128 bits.
    #[test]
    fn split_digest_reverses_then_halves() {
        let d: [u8; 32] = core::array::from_fn(|i| i as u8);
        let (low, high) = split_digest(&d);
        let mut reversed = d;
        reversed.reverse();
        assert_eq!(low[..16], [0u8; 16]);
        assert_eq!(high[..16], [0u8; 16]);
        assert_eq!(low[16..], reversed[16..]);
        assert_eq!(high[16..], reversed[..16]);
    }
}
