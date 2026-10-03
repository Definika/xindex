//! What a Groth16 check over BN254 needs of the chain, shared by SP1's (`sp1`) and RISC Zero's (`risc0`): the public
//! inputs' combination on G1 and the pairing product, in Ethereum's encodings (EIP-196 and EIP-197).

use crate::crypto::Crypto;
use crate::hex::h;

/// The scalar field's size, `r`, and the base field's, `q`.
pub const R: [u8; 32] = h("30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001");
pub const Q: [u8; 32] = h("30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProofError {
    WrongLength,
    WrongSelector,
    BadExitCode,
    WrongVkRoot,
    NotInField,
    Invalid,
}

/// The public inputs' combination on G1, `base + sum of inputs[i] * points[i]`, as a Groth16 verifier computes it, in
/// Ethereum's encoding. Every input must lie in the scalar field: multiplication does not reduce its scalar, so an
/// input past the field would pass as its remainder.
pub fn linear_combination<C: Crypto>(
    c: &C,
    base: ([u8; 32], [u8; 32]),
    points: &[([u8; 32], [u8; 32])],
    inputs: &[[u8; 32]],
) -> Result<[u8; 64], ProofError> {
    if points.len() != inputs.len() {
        return Err(ProofError::WrongLength);
    }
    if inputs.iter().any(|s| *s >= R) {
        return Err(ProofError::NotInField);
    }
    let mut l = [0u8; 64];
    l[..32].copy_from_slice(&base.0);
    l[32..].copy_from_slice(&base.1);
    for (s, (x, y)) in inputs.iter().zip(points) {
        let mut mul = [0u8; 96];
        mul[..32].copy_from_slice(x);
        mul[32..64].copy_from_slice(y);
        mul[64..].copy_from_slice(s);
        let term = c.bn254_g1_mul(&mul).map_err(|_| ProofError::Invalid)?;
        let mut add = [0u8; 128];
        add[..64].copy_from_slice(&l);
        add[64..].copy_from_slice(&term);
        l = c.bn254_g1_add(&add).map_err(|_| ProofError::Invalid)?;
    }
    Ok(l)
}

/// Succeeds only if the product of the pairings `input` lists, each a G1 point then a G2 point in Ethereum's encoding
/// (EIP-197), is one.
pub fn pairing_is_one<C: Crypto>(c: &C, input: &[u8]) -> Result<(), ProofError> {
    match c.bn254_pairing_check(input) {
        Ok(true) => Ok(()),
        _ => Err(ProofError::Invalid),
    }
}
