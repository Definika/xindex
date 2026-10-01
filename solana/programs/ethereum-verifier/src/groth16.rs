//! SP1 v6's Groth16 check, as `SP1VerifierGroth16.sol` and `Groth16Verifier.sol` make it, on Solana's alt_bn128
//! syscalls, which take Ethereum's big-endian encodings (EIP-196 and EIP-197). Natively the same functions run on
//! arkworks, so the host tests check the very code the program runs.

use crate::vk::*;
use solana_bn254::prelude::{
    alt_bn128_g1_addition_be, alt_bn128_g1_multiplication_be, alt_bn128_pairing_be,
};

/// The proof SP1 hands a verifier: the verifier's selector, the exit code, the vk root, the nonce, then the Groth16
/// points A, B and C as eight words.
pub const PROOF_LEN: usize = 4 + 3 * 32 + 8 * 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProofError {
    WrongLength,
    WrongSelector,
    BadExitCode,
    WrongVkRoot,
    NotInField,
    Invalid,
}

/// `sha256(publicValues)` with its top three bits cleared, so it lies in the scalar field: `hashPublicValues`.
pub fn public_values_digest(public_values: &[u8]) -> [u8; 32] {
    let mut d = solana_sha256_hasher::hashv(&[public_values]).to_bytes();
    d[0] &= 0x1f;
    d
}

/// Succeeds only if `proof` is SP1 v6's Groth16 proof that the program `program_key` committed `public_values`.
pub fn verify(
    program_key: &[u8; 32],
    public_values: &[u8],
    proof: &[u8],
) -> Result<(), ProofError> {
    if proof.len() != PROOF_LEN {
        return Err(ProofError::WrongLength);
    }
    if proof[..4] != VERIFIER_HASH[..4] {
        return Err(ProofError::WrongSelector);
    }
    let word = |i: usize| -> [u8; 32] { proof[4 + 32 * i..4 + 32 * (i + 1)].try_into().unwrap() };
    let (exit_code, vk_root, nonce) = (word(0), word(1), word(2));
    if exit_code != [0u8; 32] {
        return Err(ProofError::BadExitCode);
    }
    if vk_root != VK_ROOT {
        return Err(ProofError::WrongVkRoot);
    }
    let inputs = [
        *program_key,
        public_values_digest(public_values),
        exit_code,
        vk_root,
        nonce,
    ];
    // Multiplication does not reduce its scalar, so an input past the field would pass as its remainder.
    if inputs.iter().any(|s| *s >= R) {
        return Err(ProofError::NotInField);
    }
    let points = [
        (PUB_0_X, PUB_0_Y),
        (PUB_1_X, PUB_1_Y),
        (PUB_2_X, PUB_2_Y),
        (PUB_3_X, PUB_3_Y),
        (PUB_4_X, PUB_4_Y),
    ];
    // The public inputs' combination: CONSTANT + sum of input_i * PUB_i.
    let mut l = [CONSTANT_X, CONSTANT_Y].concat();
    for (s, (x, y)) in inputs.iter().zip(points) {
        let term = alt_bn128_g1_multiplication_be(&[x, y, *s].concat())
            .map_err(|_| ProofError::Invalid)?;
        l = alt_bn128_g1_addition_be(&[l, term].concat()).map_err(|_| ProofError::Invalid)?;
    }
    // e(A, B) e(C, -delta) e(alpha, -beta) e(L, -gamma) == 1, with A, B and C as the proof encodes them.
    let pairing = [
        &proof[4 + 3 * 32..],
        &DELTA_NEG_X_1,
        &DELTA_NEG_X_0,
        &DELTA_NEG_Y_1,
        &DELTA_NEG_Y_0,
        &ALPHA_X,
        &ALPHA_Y,
        &BETA_NEG_X_1,
        &BETA_NEG_X_0,
        &BETA_NEG_Y_1,
        &BETA_NEG_Y_0,
        &l,
        &GAMMA_NEG_X_1,
        &GAMMA_NEG_X_0,
        &GAMMA_NEG_Y_1,
        &GAMMA_NEG_Y_0,
    ]
    .concat();
    let result = alt_bn128_pairing_be(&pairing).map_err(|_| ProofError::Invalid)?;
    let mut one = [0u8; 32];
    one[31] = 1;
    if result[..] != one {
        return Err(ProofError::Invalid);
    }
    Ok(())
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

    /// SP1 v6's own Groth16 fixture, from sp1-contracts' test (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`), which
    /// `SP1VerifierGroth16.sol` accepts on the EVM.
    pub fn fixture() -> ([u8; 32], Vec<u8>, Vec<u8>) {
        let t = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../prototype/evm/test/SP1VerifierGroth16V6.t.sol"
        ))
        .unwrap();
        let grab = |name: &str| -> String {
            let at = t.find(name).unwrap();
            let rest = &t[at..];
            let start = rest.find(['"', '(']).unwrap() + 1;
            let start = if rest[start..].starts_with("0x") {
                start + 2
            } else {
                start
            };
            let end = start + rest[start..].find(['"', ')']).unwrap();
            rest[start..end].to_string()
        };
        let key: [u8; 32] = hex(&grab("PROGRAM_VKEY =")).try_into().unwrap();
        (
            key,
            hex(&grab("PUBLIC_VALUES =")),
            hex(&grab("PROOF_BYTES =")),
        )
    }

    #[test]
    fn verifies_sp1s_own_fixture() {
        let (key, values, proof) = fixture();
        assert_eq!(verify(&key, &values, &proof), Ok(()));
    }

    #[test]
    fn refuses_anything_else() {
        let (key, values, proof) = fixture();
        let mut v = values.clone();
        v[31] ^= 1;
        assert_eq!(
            verify(&key, &v, &proof),
            Err(ProofError::Invalid),
            "another public value"
        );
        let mut k = key;
        k[31] ^= 1;
        assert_eq!(
            verify(&k, &values, &proof),
            Err(ProofError::Invalid),
            "another program"
        );
        let mut p = proof.clone();
        p[4 + 3 * 32 + 10] ^= 1;
        assert!(verify(&key, &values, &p).is_err(), "another point");
        assert_eq!(
            verify(&key, &values, &proof[1..]),
            Err(ProofError::WrongLength)
        );
        let mut p = proof.clone();
        p[0] ^= 1;
        assert_eq!(verify(&key, &values, &p), Err(ProofError::WrongSelector));
        let mut p = proof.clone();
        p[4 + 31] = 1;
        assert_eq!(verify(&key, &values, &p), Err(ProofError::BadExitCode));
        let mut p = proof.clone();
        p[4 + 32 + 31] ^= 1;
        assert_eq!(verify(&key, &values, &p), Err(ProofError::WrongVkRoot));
        let mut p = proof.clone();
        p[4 + 64..4 + 96].copy_from_slice(&R);
        assert_eq!(
            verify(&key, &values, &p),
            Err(ProofError::NotInField),
            "a nonce past the field"
        );
    }
}
