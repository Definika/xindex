/// P1's and P2's Groth16 checks on each system's own proof: SP1 v6's fixture from sp1-contracts' test, which
/// `SP1VerifierGroth16.sol` accepts on the EVM, and RISC Zero's v3.0 receipt, which `RiscZeroGroth16Verifier` accepts;
/// and the prepared keys rebuilt from the Solidity verifiers' own constants (`fixtures`, read from those files).
#[test_only]
module xindex_vault::proofs_tests;

use std::hash::sha2_256;
use sui::groth16;
use xindex_vault::bytes;
use xindex_vault::fixtures as f;
use xindex_vault::proofs;

const Q: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;
const R: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

fun neg(y: u256): u256 { if (y == 0) 0 else Q - y }

fun count(n: u64): vector<u8> {
    let mut out = bytes::le32((n as u256));
    while (out.length() > 8) { out.pop_back(); };
    out
}

/// SP1 v6's verifying key in arkworks' form, from `Groth16Verifier.sol`'s constants: beta, gamma and delta negated
/// back, and the public inputs' points after the constant.
fun sp1_vk(): vector<u8> {
    let mut vk = proofs::g1(f::sp1_alpha_x(), f::sp1_alpha_y());
    vk.append(proofs::g2(f::sp1_beta_neg_x_1(), f::sp1_beta_neg_x_0(), neg(f::sp1_beta_neg_y_1()), neg(f::sp1_beta_neg_y_0())));
    vk.append(proofs::g2(f::sp1_gamma_neg_x_1(), f::sp1_gamma_neg_x_0(), neg(f::sp1_gamma_neg_y_1()), neg(f::sp1_gamma_neg_y_0())));
    vk.append(proofs::g2(f::sp1_delta_neg_x_1(), f::sp1_delta_neg_x_0(), neg(f::sp1_delta_neg_y_1()), neg(f::sp1_delta_neg_y_0())));
    vk.append(count(6));
    vk.append(proofs::g1(f::sp1_constant_x(), f::sp1_constant_y()));
    vk.append(proofs::g1(f::sp1_pub_0_x(), f::sp1_pub_0_y()));
    vk.append(proofs::g1(f::sp1_pub_1_x(), f::sp1_pub_1_y()));
    vk.append(proofs::g1(f::sp1_pub_2_x(), f::sp1_pub_2_y()));
    vk.append(proofs::g1(f::sp1_pub_3_x(), f::sp1_pub_3_y()));
    vk.append(proofs::g1(f::sp1_pub_4_x(), f::sp1_pub_4_y()));
    vk
}

/// RISC Zero v3.0's verifying key in arkworks' form, from its `Groth16Verifier.sol`: `x1` the imaginary part, as its
/// pairing input writes it.
fun risc0_vk(): vector<u8> {
    let mut vk = proofs::g1(f::risc0_alphax(), f::risc0_alphay());
    vk.append(proofs::g2(f::risc0_betax1(), f::risc0_betax2(), f::risc0_betay1(), f::risc0_betay2()));
    vk.append(proofs::g2(f::risc0_gammax1(), f::risc0_gammax2(), f::risc0_gammay1(), f::risc0_gammay2()));
    vk.append(proofs::g2(f::risc0_deltax1(), f::risc0_deltax2(), f::risc0_deltay1(), f::risc0_deltay2()));
    vk.append(count(6));
    vk.append(proofs::g1(f::risc0_ic0x(), f::risc0_ic0y()));
    vk.append(proofs::g1(f::risc0_ic1x(), f::risc0_ic1y()));
    vk.append(proofs::g1(f::risc0_ic2x(), f::risc0_ic2y()));
    vk.append(proofs::g1(f::risc0_ic3x(), f::risc0_ic3y()));
    vk.append(proofs::g1(f::risc0_ic4x(), f::risc0_ic4y()));
    vk.append(proofs::g1(f::risc0_ic5x(), f::risc0_ic5y()));
    vk
}

fun prepare(vk: vector<u8>): vector<vector<u8>> {
    groth16::pvk_to_bytes(groth16::prepare_verifying_key(&groth16::bn254(), &vk))
}

/// The prepared keys are what Sui makes of the Solidity verifiers' keys.
#[test]
fun the_prepared_keys_are_the_verifiers() {
    assert!(prepare(sp1_vk()) == proofs::sp1_prepared());
    assert!(prepare(risc0_vk()) == proofs::risc0_prepared());
}

#[test]
fun verifies_sp1s_own_fixture() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &f::sp1_proof());
}

#[test]
fun verifies_risc_zeros_own_receipt() {
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &f::risc0_seal());
}

fun flip(v: vector<u8>, i: u64): vector<u8> {
    let mut v = v;
    let b = v[i];
    *&mut v[i] = b ^ 1;
    v
}

fun put_word(v: vector<u8>, at: u64, w: vector<u8>): vector<u8> {
    let mut v = v;
    let mut i = 0;
    while (i < 32) {
        *&mut v[at + i] = w[i];
        i = i + 1;
    };
    v
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun sp1_refuses_another_public_value() {
    proofs::verify_sp1(&f::sp1_program_key(), &flip(f::sp1_public_values(), 31), &f::sp1_proof());
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun sp1_refuses_another_program() {
    proofs::verify_sp1(&flip(f::sp1_program_key(), 31), &f::sp1_public_values(), &f::sp1_proof());
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun sp1_refuses_another_point() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 96 + 10));
}

#[test, expected_failure(abort_code = proofs::EWrongLength)]
fun sp1_refuses_a_short_proof() {
    let mut p = f::sp1_proof();
    p.pop_back();
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
}

#[test, expected_failure(abort_code = proofs::EWrongSelector)]
fun sp1_refuses_another_selector() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 0));
}

#[test, expected_failure(abort_code = proofs::EBadExitCode)]
fun sp1_refuses_an_exit_code() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 31));
}

#[test, expected_failure(abort_code = proofs::EWrongVkRoot)]
fun sp1_refuses_another_vk_root() {
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 32 + 31));
}

#[test, expected_failure(abort_code = proofs::ENotInField)]
fun sp1_refuses_a_nonce_past_the_field() {
    let p = put_word(f::sp1_proof(), 4 + 64, bytes::word(R));
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
}

#[test, expected_failure(abort_code = proofs::ENotInField)]
fun sp1_refuses_a_coordinate_past_the_field() {
    let p = put_word(f::sp1_proof(), 4 + 96, bytes::word(Q));
    proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_another_journal() {
    proofs::verify_risc0(&f::risc0_image_id(), &flip(f::risc0_journal(), 0), &f::risc0_seal());
}

/// The journal's digest in its place: the check hashes the journal itself.
#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_the_journals_digest() {
    proofs::verify_risc0(&f::risc0_image_id(), &sha2_256(f::risc0_journal()), &f::risc0_seal());
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_another_image() {
    proofs::verify_risc0(&flip(f::risc0_image_id(), 31), &f::risc0_journal(), &f::risc0_seal());
}

#[test, expected_failure(abort_code = proofs::EWrongSelector)]
fun risc0_refuses_another_selector() {
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 0));
}

#[test, expected_failure(abort_code = proofs::EWrongLength)]
fun risc0_refuses_a_long_seal() {
    let mut s = f::risc0_seal();
    s.push_back(0);
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_another_c() {
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 200));
}

#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_another_b() {
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 100));
}

/// A's y-coordinate past the field, which the EVM would reduce: refused.
#[test, expected_failure(abort_code = proofs::ENotInField)]
fun risc0_refuses_a_coordinate_past_the_field() {
    let s = put_word(f::risc0_seal(), 36, bytes::word(Q));
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
}

/// A's y replaced by its negation: the point `-A`, which no proof of this statement holds.
#[test, expected_failure(abort_code = proofs::EInvalidProof)]
fun risc0_refuses_the_negated_point() {
    let s = f::risc0_seal();
    let y = bytes::u256_at(&s, 36);
    let s = put_word(s, 36, bytes::word(Q - y));
    proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
}

/// Both halves of `splitDigest` and the claim's layout, as `ReceiptClaimLib` writes them: the real receipt verifies
/// only with them, and here the claim of another exit is another digest.
#[test]
fun the_claim_digest_is_risc_zeros() {
    let image = f::risc0_image_id();
    let journal = sha2_256(f::risc0_journal());
    let claim = proofs::claim_digest(&image, &journal);
    assert!(claim.length() == 32);
    assert!(claim != proofs::claim_digest(&image, &sha2_256(b"another journal")));
}
