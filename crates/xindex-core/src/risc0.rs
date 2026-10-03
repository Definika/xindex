//! P2's check: RISC Zero v3.0's Groth16 seal, as `RiscZeroGroth16Verifier.verify(seal, imageId, journalDigest)` and
//! `Groth16Verifier.verifyProof` make it (risc0-ethereum v3.0.1, vendored in `vendor/risc0-ethereum`, at commit
//! 365e7b2db4f620fa256580c27558d2623362b9ae). The verifying key and the fields are those of
//! `src/groth16/Groth16Verifier.sol`, where they are decimal; the control ids those of `src/groth16/ControlID.sol`; the
//! zero system state's digest that of `src/IRiscZeroVerifier.sol`. Each is a 32-byte big-endian word, and the tests
//! (`tests/proofs.rs`) read every one back from those files.

use alloc::vec::Vec;

use crate::crypto::Crypto;
use crate::groth16::{linear_combination, pairing_is_one, ProofError, Q};
use crate::hex::h;

/// A seal: the verifier's selector, then the Groth16 points A, B and C as eight words, `abi.encode(Seal)`.
pub const SEAL_LEN: usize = 4 + 8 * 32;

pub const ALPHA_X: [u8; 32] = h("2d4d9aa7e302d9df41749d5507949d05dbea33fbb16c643b22f599a2be6df2e2");
pub const ALPHA_Y: [u8; 32] = h("14bedd503c37ceb061d8ec60209fe345ce89830a19230301f076caff004d1926");
pub const BETA_X_1: [u8; 32] =
    h("0967032fcbf776d1afc985f88877f182d38480a653f2decaa9794cbc3bf3060c");
pub const BETA_X_2: [u8; 32] =
    h("0e187847ad4c798374d0d6732bf501847dd68bc0e071241e0213bc7fc13db7ab");
pub const BETA_Y_1: [u8; 32] =
    h("304cfbd1e08a704a99f5e847d93f8c3caafddec46b7a0d379da69a4d112346a7");
pub const BETA_Y_2: [u8; 32] =
    h("1739c1b1a457a8c7313123d24d2f9192f896b7c63eea05a9d57f06547ad0cec8");
pub const GAMMA_X_1: [u8; 32] =
    h("198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2");
pub const GAMMA_X_2: [u8; 32] =
    h("1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed");
pub const GAMMA_Y_1: [u8; 32] =
    h("090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b");
pub const GAMMA_Y_2: [u8; 32] =
    h("12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");
pub const DELTA_X_1: [u8; 32] =
    h("03b03cd5effa95ac9bee94f1f5ef907157bda4812ccf0b4c91f42bb629f83a1c");
pub const DELTA_X_2: [u8; 32] =
    h("1aa085ff28179a12d922dba0547057ccaae94b9d69cfaa4e60401fea7f3e0333");
pub const DELTA_Y_1: [u8; 32] =
    h("110c10134f200b19f6490846d518c9aea868366efb7228ca5c91d2940d030762");
pub const DELTA_Y_2: [u8; 32] =
    h("1e60f31fcbf757e837e867178318832d0b2d74d59e2fea1c7142df187d3fc6d3");

/// The public inputs' points: `IC0` is the base, `IC1` to `IC5` weigh the control root's halves, the claim's halves and
/// the BN254 control id.
pub const IC: [([u8; 32], [u8; 32]); 6] = [
    (
        h("12ac9a25dcd5e1a832a9061a082c15dd1d61aa9c4d553505739d0f5d65dc3be4"),
        h("025aa744581ebe7ad91731911c898569106ff5a2d30f3eee2b23c60ee980acd4"),
    ),
    (
        h("0707b920bc978c02f292fae2036e057be54294114ccc3c8769d883f688a1423f"),
        h("2e32a094b7589554f7bc357bf63481acd2d55555c203383782a4650787ff6642"),
    ),
    (
        h("0bca36e2cbe6394b3e249751853f961511011c7148e336f4fd974644850fc347"),
        h("2ede7c9acf48cf3a3729fa3d68714e2a8435d4fa6db8f7f409c153b1fcdf9b8b"),
    ),
    (
        h("1b8af999dbfbb3927c091cc2aaf201e488cbacc3e2c6b6fb5a25f9112e04f2a7"),
        h("2b91a26aa92e1b6f5722949f192a81c850d586d81a60157f3e9cf04f679cccd6"),
    ),
    (
        h("2b5f494ed674235b8ac1750bdfd5a7615f002d4a1dcefeddd06eda5a076ccd0d"),
        h("2fe520ad2020aab9cbba817fcbb9a863b8a76ff88f14f912c5e71665b2ad5e82"),
    ),
    (
        h("0f1c3c0d5d9da0fa03666843cde4e82e869ba5252fce3c25d5940320b1c4d493"),
        h("214bfcff74f425f6fe8c0d07b307482d8bc8bb2f3608f68287aa01bd0b69e809"),
    ),
];

/// `ControlID.CONTROL_ROOT`, which the deployed verifier splits into two public inputs.
pub const CONTROL_ROOT: [u8; 32] =
    h("a54dc85ac99f851c92d7c96d7318af41dbe7c0194edfcc37eb4d422a998c1f56");
/// `ControlID.BN254_CONTROL_ID`, a public input as it stands.
pub const BN254_CONTROL_ID: [u8; 32] =
    h("04446e66d300eb7fb45c9726bb53c793dda407a62e9601618bb43c5c14657ac0");
/// `ReceiptClaimLib.SYSTEM_STATE_ZERO_DIGEST`: the post-state of a halted guest.
pub const SYSTEM_STATE_ZERO_DIGEST: [u8; 32] =
    h("a3acc27117418996340b84e5a90f3ef4c49d22c79e44aad822ec9c313e1eb8e2");
/// The verifier's selector, the first four bytes of every seal: `bytes4` of the hash of the verifier's parameters,
/// which the constructor computes from the key and the control ids. `script/DeployVault.s.sol` pins the same value
/// for P2's EVM verifier (`RISC_ZERO_SELECTOR`).
pub const SELECTOR: [u8; 4] = [0x73, 0xc4, 0x57, 0xba];

/// `ReceiptClaimLib.ok(imageId, journalDigest).digest()`: the claim that the image `image_id` ran, halted with exit
/// code 0, committed the journal of digest `journal_digest`, and assumed nothing. Each struct's digest is SHA-256 of
/// its tag's digest, its digest fields, its data, and its count of digest fields as a little-endian `u16`.
pub fn claim_digest<C: Crypto>(c: &C, image_id: &[u8; 32], journal_digest: &[u8; 32]) -> [u8; 32] {
    // Output { journalDigest, assumptionsDigest: 0 }
    let output = c.sha256(&[
        &c.sha256(&[b"risc0.Output"]),
        journal_digest,
        &[0u8; 32],
        &[2, 0],
    ]);
    // ReceiptClaim { input: 0, preStateDigest: imageId, postStateDigest: SYSTEM_STATE_ZERO_DIGEST, output }, then the
    // exit code (Halted, 0) as two u32s shifted by 24, which are zero.
    c.sha256(&[
        &c.sha256(&[b"risc0.ReceiptClaim"]),
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
pub fn negate(y: &[u8; 32]) -> Result<[u8; 32], ProofError> {
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
pub fn verify<C: Crypto>(
    c: &C,
    image_id: &[u8; 32],
    journal: &[u8],
    seal: &[u8],
) -> Result<(), ProofError> {
    if seal.len() != SEAL_LEN {
        return Err(ProofError::WrongLength);
    }
    if seal[..4] != SELECTOR {
        return Err(ProofError::WrongSelector);
    }
    let claim = claim_digest(c, image_id, &c.sha256(&[journal]));
    let (root_0, root_1) = split_digest(&CONTROL_ROOT);
    let (claim_0, claim_1) = split_digest(&claim);
    let inputs = [root_0, root_1, claim_0, claim_1, BN254_CONTROL_ID];
    let vk_x = linear_combination(c, IC[0], &IC[1..], &inputs)?;
    let a_y: [u8; 32] = seal[36..68].try_into().unwrap();
    // e(-A, B) e(alpha, beta) e(vk_x, gamma) e(C, delta) == 1, in `verifyProof`'s order.
    let pairing: Vec<u8> = [
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
    pairing_is_one(c, &pairing)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(negate(&Q), Err(ProofError::NotInField));
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
