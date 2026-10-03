//! P1's and P2's Groth16 checks on each system's own proof: SP1 v6's fixture from sp1-contracts' test, which
//! `SP1VerifierGroth16.sol` accepts on the EVM, and RISC Zero's v3.0 receipt, which `RiscZeroGroth16Verifier` accepts on
//! the EVM and on TRON's VM; and every RISC Zero constant read back from the vendored Solidity.

mod common;

use common::*;
use xindex_core::crypto::Crypto;
use xindex_core::groth16::{ProofError, Q, R};
use xindex_core::hex::h;
use xindex_core::{risc0, sp1};

/// SP1 v6's own Groth16 fixture (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`): the program key, the public values
/// and the proof.
fn sp1_fixture() -> ([u8; 32], Vec<u8>, Vec<u8>) {
    let t = repo_file("prototype/evm/test/SP1VerifierGroth16V6.t.sol");
    let grab = |name: &str| -> String {
        let rest = &t[t.find(name).unwrap()..];
        let start = rest.find(['"', '(']).unwrap() + 1;
        let start = if rest[start..].starts_with("0x") {
            start + 2
        } else {
            start
        };
        let end = start + rest[start..].find(['"', ')']).unwrap();
        rest[start..end].to_string()
    };
    (
        hex(&grab("PROGRAM_VKEY =")).try_into().unwrap(),
        hex(&grab("PUBLIC_VALUES =")),
        hex(&grab("PROOF_BYTES =")),
    )
}

/// RISC Zero's own v3.0 receipt (`vendor/risc0-ethereum/test/TestReceiptV3_0.sol`): the image id, the journal and the
/// seal.
fn risc0_receipt() -> ([u8; 32], Vec<u8>, Vec<u8>) {
    let t = repo_file("vendor/risc0-ethereum/test/TestReceiptV3_0.sol");
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
fn verifies_sp1s_own_fixture() {
    let (key, values, proof) = sp1_fixture();
    assert_eq!(sp1::verify(&C, &key, &values, &proof), Ok(()));
}

#[test]
fn sp1_refuses_anything_else() {
    let (key, values, proof) = sp1_fixture();
    let mut v = values.clone();
    v[31] ^= 1;
    assert_eq!(
        sp1::verify(&C, &key, &v, &proof),
        Err(ProofError::Invalid),
        "another public value"
    );
    let mut k = key;
    k[31] ^= 1;
    assert_eq!(
        sp1::verify(&C, &k, &values, &proof),
        Err(ProofError::Invalid),
        "another program"
    );
    let mut p = proof.clone();
    p[4 + 3 * 32 + 10] ^= 1;
    assert!(sp1::verify(&C, &key, &values, &p).is_err(), "another point");
    assert_eq!(
        sp1::verify(&C, &key, &values, &proof[1..]),
        Err(ProofError::WrongLength)
    );
    let mut p = proof.clone();
    p[0] ^= 1;
    assert_eq!(
        sp1::verify(&C, &key, &values, &p),
        Err(ProofError::WrongSelector)
    );
    let mut p = proof.clone();
    p[4 + 31] = 1;
    assert_eq!(
        sp1::verify(&C, &key, &values, &p),
        Err(ProofError::BadExitCode)
    );
    let mut p = proof.clone();
    p[4 + 32 + 31] ^= 1;
    assert_eq!(
        sp1::verify(&C, &key, &values, &p),
        Err(ProofError::WrongVkRoot)
    );
    let mut p = proof.clone();
    p[4 + 64..4 + 96].copy_from_slice(&R);
    assert_eq!(
        sp1::verify(&C, &key, &values, &p),
        Err(ProofError::NotInField),
        "a nonce past the field"
    );
}

#[test]
fn verifies_risc_zeros_own_receipt() {
    let (image_id, journal, seal) = risc0_receipt();
    assert_eq!(seal.len(), risc0::SEAL_LEN);
    assert_eq!(risc0::verify(&C, &image_id, &journal, &seal), Ok(()));
}

#[test]
fn risc0_refuses_anything_else() {
    let (image_id, journal, seal) = risc0_receipt();
    let mut j = journal.clone();
    j[0] ^= 1;
    assert_eq!(
        risc0::verify(&C, &image_id, &j, &seal),
        Err(ProofError::Invalid),
        "another journal"
    );
    let digest = C.sha256(&[&journal]);
    assert_eq!(
        risc0::verify(&C, &image_id, &digest, &seal),
        Err(ProofError::Invalid),
        "the journal's digest in its place: the check hashes the journal itself"
    );
    let mut i = image_id;
    i[31] ^= 1;
    assert_eq!(
        risc0::verify(&C, &i, &journal, &seal),
        Err(ProofError::Invalid),
        "another image"
    );
    let mut s = seal.clone();
    s[0] ^= 1;
    assert_eq!(
        risc0::verify(&C, &image_id, &journal, &s),
        Err(ProofError::WrongSelector)
    );
    assert_eq!(
        risc0::verify(&C, &image_id, &journal, &seal[..risc0::SEAL_LEN - 1]),
        Err(ProofError::WrongLength)
    );
    assert_eq!(
        risc0::verify(&C, &image_id, &journal, &[&seal[..], &[0]].concat()),
        Err(ProofError::WrongLength)
    );
    let mut s = seal.clone();
    s[200] ^= 1;
    assert!(
        risc0::verify(&C, &image_id, &journal, &s).is_err(),
        "another C"
    );
    let mut s = seal.clone();
    s[100] ^= 1;
    assert!(
        risc0::verify(&C, &image_id, &journal, &s).is_err(),
        "another B"
    );
    // A's y-coordinate past the field, which the EVM would reduce: refused.
    let mut s = seal.clone();
    s[36..68].copy_from_slice(&Q);
    assert_eq!(
        risc0::verify(&C, &image_id, &journal, &s),
        Err(ProofError::NotInField)
    );
}

/// A decimal Solidity literal as a 32-byte big-endian word.
fn decimal(s: &str) -> [u8; 32] {
    let mut w = [0u8; 32];
    for c in s.bytes() {
        let mut carry = u32::from(c - b'0');
        for b in w.iter_mut().rev() {
            let v = u32::from(*b) * 10 + carry;
            *b = v as u8;
            carry = v >> 8;
        }
        assert_eq!(carry, 0, "fits 256 bits");
    }
    w
}

fn solidity_uint(source: &str, name: &str) -> [u8; 32] {
    let at = source.find(&format!("uint256 constant {name} = ")).unwrap();
    let rest = &source[at..];
    let start = rest.find("= ").unwrap() + 2;
    let end = start + rest[start..].find(';').unwrap();
    decimal(&rest[start..end])
}

fn solidity_hex(source: &str, name: &str) -> [u8; 32] {
    let rest = &source[source.find(name).unwrap()..];
    let start = rest.find("hex\"").unwrap() + 4;
    hex(&rest[start..start + 64]).try_into().unwrap()
}

/// Every RISC Zero constant is the vendored Solidity's.
#[test]
fn the_risc0_constants_are_risc_zeros() {
    use risc0::*;
    let g = repo_file("vendor/risc0-ethereum/src/groth16/Groth16Verifier.sol");
    let pairs: [(&str, [u8; 32]); 16] = [
        ("r", R),
        ("q", Q),
        ("alphax", ALPHA_X),
        ("alphay", ALPHA_Y),
        ("betax1", BETA_X_1),
        ("betax2", BETA_X_2),
        ("betay1", BETA_Y_1),
        ("betay2", BETA_Y_2),
        ("gammax1", GAMMA_X_1),
        ("gammax2", GAMMA_X_2),
        ("gammay1", GAMMA_Y_1),
        ("gammay2", GAMMA_Y_2),
        ("deltax1", DELTA_X_1),
        ("deltax2", DELTA_X_2),
        ("deltay1", DELTA_Y_1),
        ("deltay2", DELTA_Y_2),
    ];
    for (name, value) in pairs {
        assert_eq!(solidity_uint(&g, name), value, "{name}");
    }
    for (i, (x, y)) in IC.iter().enumerate() {
        assert_eq!(solidity_uint(&g, &format!("IC{i}x")), *x, "IC{i}x");
        assert_eq!(solidity_uint(&g, &format!("IC{i}y")), *y, "IC{i}y");
    }
    let c = repo_file("vendor/risc0-ethereum/src/groth16/ControlID.sol");
    assert_eq!(solidity_hex(&c, "CONTROL_ROOT ="), CONTROL_ROOT);
    assert_eq!(solidity_hex(&c, "BN254_CONTROL_ID ="), BN254_CONTROL_ID);
    let v = repo_file("vendor/risc0-ethereum/src/IRiscZeroVerifier.sol");
    let rest = &v[v.find("SYSTEM_STATE_ZERO_DIGEST = 0x").unwrap()..];
    let start = rest.find("0x").unwrap() + 2;
    assert_eq!(h(&rest[start..start + 64]), SYSTEM_STATE_ZERO_DIGEST);
}

/// The selector is what `RiscZeroGroth16Verifier`'s constructor computes from this key and these control ids: the
/// key's digest (`verifier_key_digest`), with the IC points as a tagged list, then the parameters' digest.
#[test]
fn the_risc0_selector_follows_from_the_key_and_the_control_ids() {
    use risc0::*;
    let sha256 = |parts: &[&[u8]]| C.sha256(parts);
    let tag = |s: &str| sha256(&[s.as_bytes()]);
    let ic_tag = tag("risc0_groth16.VerifyingKey.IC");
    let mut list = [0u8; 32];
    for (x, y) in IC.iter().rev() {
        let head = sha256(&[x, y]);
        list = sha256(&[&ic_tag, &head, &list, &[2, 0]]);
    }
    let key_digest = sha256(&[
        &tag("risc0_groth16.VerifyingKey"),
        &sha256(&[&ALPHA_X, &ALPHA_Y]),
        &sha256(&[&BETA_X_1, &BETA_X_2, &BETA_Y_1, &BETA_Y_2]),
        &sha256(&[&GAMMA_X_1, &GAMMA_X_2, &GAMMA_Y_1, &GAMMA_Y_2]),
        &sha256(&[&DELTA_X_1, &DELTA_X_2, &DELTA_Y_1, &DELTA_Y_2]),
        &list,
        &[5, 0],
    ]);
    let mut control_id = BN254_CONTROL_ID;
    control_id.reverse();
    let parameters = sha256(&[
        &tag("risc0.Groth16ReceiptVerifierParameters"),
        &CONTROL_ROOT,
        &control_id,
        &key_digest,
        &[3, 0],
    ]);
    assert_eq!(parameters[..4], SELECTOR);
}

/// The native cryptography answers the standard vectors: keccak and SHA-256 of "abc", and twice the BN254 generator
/// both by addition and by multiplication.
#[test]
fn the_native_cryptography_is_the_standard() {
    assert_eq!(
        C.keccak256(&[b"a", b"bc"]),
        h("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    );
    assert_eq!(
        C.sha256(&[b"ab", b"c"]),
        h("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    );
    let mut g = [0u8; 64];
    g[31] = 1;
    g[63] = 2;
    let mut add = [0u8; 128];
    add[..64].copy_from_slice(&g);
    add[64..].copy_from_slice(&g);
    let mut mul = [0u8; 96];
    mul[..64].copy_from_slice(&g);
    mul[95] = 2;
    let twice = C.bn254_g1_add(&add).unwrap();
    assert_eq!(C.bn254_g1_mul(&mul).unwrap(), twice);
    assert_eq!(
        twice[..32],
        h("030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3")
    );
    assert_eq!(C.bn254_pairing_check(&[]), Ok(true), "the empty product");
    let mut off = g;
    off[63] = 3;
    let mut bad = [0u8; 128];
    bad[..64].copy_from_slice(&off);
    assert!(C.bn254_g1_add(&bad).is_err(), "a point off the curve");
}
