#[test_only]
/// P1's and P2's Groth16 checks on each system's own proof: SP1 v6's fixture from sp1-contracts' test, which
/// `SP1VerifierGroth16.sol` accepts on the EVM, and RISC Zero's v3.0 receipt, which `RiscZeroGroth16Verifier` accepts;
/// and the verifying keys rebuilt from the Solidity verifiers' own constants (`fixtures`, read from those files). The
/// Sui twin's `proofs_tests`.
module xindex_vault::proofs_tests {
    use std::hash::sha2_256;
    use aptos_std::bn254_algebra::{FormatG1Uncompr, FormatG2Uncompr, G1, G2};
    use aptos_std::crypto_algebra;
    use xindex_vault::bytes;
    use xindex_vault::fixtures as f;
    use xindex_vault::harness;
    use xindex_vault::proofs;

    const Q: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;
    const R: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    fun neg(y: u256): u256 { if (y == 0) 0 else Q - y }

    fun boot() {
        harness::boot(1_800_000_000);
    }

    /// SP1 v6's verifying key in arkworks' form, from `Groth16Verifier.sol`'s constants: alpha, beta, gamma and delta
    /// negated as the Solidity holds them, and the public inputs' points after the constant.
    fun sp1_key(): vector<vector<u8>> {
        let ic = proofs::g1(f::sp1_constant_x(), f::sp1_constant_y());
        ic.append(proofs::g1(f::sp1_pub_0_x(), f::sp1_pub_0_y()));
        ic.append(proofs::g1(f::sp1_pub_1_x(), f::sp1_pub_1_y()));
        ic.append(proofs::g1(f::sp1_pub_2_x(), f::sp1_pub_2_y()));
        ic.append(proofs::g1(f::sp1_pub_3_x(), f::sp1_pub_3_y()));
        ic.append(proofs::g1(f::sp1_pub_4_x(), f::sp1_pub_4_y()));
        vector[
            proofs::g1(f::sp1_alpha_x(), f::sp1_alpha_y()),
            proofs::g2(f::sp1_beta_neg_x_1(), f::sp1_beta_neg_x_0(), f::sp1_beta_neg_y_1(), f::sp1_beta_neg_y_0()),
            proofs::g2(f::sp1_gamma_neg_x_1(), f::sp1_gamma_neg_x_0(), f::sp1_gamma_neg_y_1(), f::sp1_gamma_neg_y_0()),
            proofs::g2(f::sp1_delta_neg_x_1(), f::sp1_delta_neg_x_0(), f::sp1_delta_neg_y_1(), f::sp1_delta_neg_y_0()),
            ic,
        ]
    }

    /// RISC Zero v3.0's verifying key in arkworks' form, from its `Groth16Verifier.sol`: `x1` the imaginary part, as its
    /// pairing input writes it, and beta, gamma and delta negated here.
    fun risc0_key(): vector<vector<u8>> {
        let ic = proofs::g1(f::risc0_ic0x(), f::risc0_ic0y());
        ic.append(proofs::g1(f::risc0_ic1x(), f::risc0_ic1y()));
        ic.append(proofs::g1(f::risc0_ic2x(), f::risc0_ic2y()));
        ic.append(proofs::g1(f::risc0_ic3x(), f::risc0_ic3y()));
        ic.append(proofs::g1(f::risc0_ic4x(), f::risc0_ic4y()));
        ic.append(proofs::g1(f::risc0_ic5x(), f::risc0_ic5y()));
        vector[
            proofs::g1(f::risc0_alphax(), f::risc0_alphay()),
            proofs::g2(f::risc0_betax1(), f::risc0_betax2(), neg(f::risc0_betay1()), neg(f::risc0_betay2())),
            proofs::g2(f::risc0_gammax1(), f::risc0_gammax2(), neg(f::risc0_gammay1()), neg(f::risc0_gammay2())),
            proofs::g2(f::risc0_deltax1(), f::risc0_deltax2(), neg(f::risc0_deltay1()), neg(f::risc0_deltay2())),
            ic,
        ]
    }

    /// Every point of a key lies on its curve, in its subgroup.
    fun on_the_curve(key: &vector<vector<u8>>) {
        assert!(crypto_algebra::deserialize<G1, FormatG1Uncompr>(&key[0]).is_some());
        let i = 1;
        while (i < 4) {
            assert!(crypto_algebra::deserialize<G2, FormatG2Uncompr>(&key[i]).is_some());
            i += 1;
        };
        let j = 0;
        while (j < 6) {
            assert!(crypto_algebra::deserialize<G1, FormatG1Uncompr>(&bytes::slice(&key[4], 64 * j, 64)).is_some());
            j += 1;
        };
    }

    #[test]
    /// The keys are the Solidity verifiers', converted, and every point is on its curve.
    fun the_keys_are_the_verifiers() {
        boot();
        assert!(sp1_key() == proofs::sp1_key());
        assert!(risc0_key() == proofs::risc0_key());
        on_the_curve(&proofs::sp1_key());
        on_the_curve(&proofs::risc0_key());
    }

    #[test]
    fun verifies_sp1s_own_fixture() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &f::sp1_proof());
    }

    #[test]
    fun verifies_risc_zeros_own_receipt() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &f::risc0_seal());
    }

    fun flip(v: vector<u8>, i: u64): vector<u8> {
        v[i] ^= 1;
        v
    }

    fun put_word(v: vector<u8>, at: u64, w: vector<u8>): vector<u8> {
        let i = 0;
        while (i < 32) {
            v[at + i] = w[i];
            i += 1;
        };
        v
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    fun sp1_refuses_another_public_value() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &flip(f::sp1_public_values(), 31), &f::sp1_proof());
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    fun sp1_refuses_another_program() {
        boot();
        proofs::verify_sp1(&flip(f::sp1_program_key(), 31), &f::sp1_public_values(), &f::sp1_proof());
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    /// Another nonce, which the proof's statement fixes.
    fun sp1_refuses_another_nonce() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 64 + 31));
    }

    #[test, expected_failure(abort_code = proofs::EBadPoint, location = proofs)]
    /// A's x moved off the curve.
    fun sp1_refuses_another_point() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 96 + 10));
    }

    #[test, expected_failure(abort_code = proofs::EWrongLength, location = proofs)]
    fun sp1_refuses_a_short_proof() {
        boot();
        let p = f::sp1_proof();
        p.pop_back();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
    }

    #[test, expected_failure(abort_code = proofs::EWrongSelector, location = proofs)]
    fun sp1_refuses_another_selector() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 0));
    }

    #[test, expected_failure(abort_code = proofs::EBadExitCode, location = proofs)]
    fun sp1_refuses_an_exit_code() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 31));
    }

    #[test, expected_failure(abort_code = proofs::EWrongVkRoot, location = proofs)]
    fun sp1_refuses_another_vk_root() {
        boot();
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &flip(f::sp1_proof(), 4 + 32 + 31));
    }

    #[test, expected_failure(abort_code = proofs::ENotInField, location = proofs)]
    fun sp1_refuses_a_nonce_past_the_field() {
        boot();
        let p = put_word(f::sp1_proof(), 4 + 64, bytes::word(R));
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
    }

    #[test, expected_failure(abort_code = proofs::ENotInField, location = proofs)]
    fun sp1_refuses_a_program_key_past_the_field() {
        boot();
        proofs::verify_sp1(&bytes::word(R), &f::sp1_public_values(), &f::sp1_proof());
    }

    #[test, expected_failure(abort_code = proofs::ENotInField, location = proofs)]
    fun sp1_refuses_a_coordinate_past_the_field() {
        boot();
        let p = put_word(f::sp1_proof(), 4 + 96, bytes::word(Q));
        proofs::verify_sp1(&f::sp1_program_key(), &f::sp1_public_values(), &p);
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    fun risc0_refuses_another_journal() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &flip(f::risc0_journal(), 0), &f::risc0_seal());
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    /// The journal's digest in its place: the check hashes the journal itself.
    fun risc0_refuses_the_journals_digest() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &sha2_256(f::risc0_journal()), &f::risc0_seal());
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    fun risc0_refuses_another_image() {
        boot();
        proofs::verify_risc0(&flip(f::risc0_image_id(), 31), &f::risc0_journal(), &f::risc0_seal());
    }

    #[test, expected_failure(abort_code = proofs::EWrongSelector, location = proofs)]
    fun risc0_refuses_another_selector() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 0));
    }

    #[test, expected_failure(abort_code = proofs::EWrongLength, location = proofs)]
    fun risc0_refuses_a_long_seal() {
        boot();
        let s = f::risc0_seal();
        s.push_back(0);
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
    }

    #[test, expected_failure(abort_code = proofs::EBadPoint, location = proofs)]
    fun risc0_refuses_another_c() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 200));
    }

    #[test, expected_failure(abort_code = proofs::EBadPoint, location = proofs)]
    fun risc0_refuses_another_b() {
        boot();
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &flip(f::risc0_seal(), 100));
    }

    #[test, expected_failure(abort_code = proofs::ENotInField, location = proofs)]
    /// A's y-coordinate past the field, which the EVM would reduce: refused.
    fun risc0_refuses_a_coordinate_past_the_field() {
        boot();
        let s = put_word(f::risc0_seal(), 36, bytes::word(Q));
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
    }

    #[test, expected_failure(abort_code = proofs::EInvalidProof, location = proofs)]
    /// A's y replaced by its negation: the point `-A`, on the curve, which no proof of this statement holds.
    fun risc0_refuses_the_negated_point() {
        boot();
        let s = f::risc0_seal();
        let y = bytes::u256_at(&s, 36);
        let s = put_word(s, 36, bytes::word(Q - y));
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
    }

    #[test, expected_failure(abort_code = proofs::EBadPoint, location = proofs)]
    /// The EVM's point at infinity, `(0, 0)`, as A: refused, as no honest prover writes it.
    fun risc0_refuses_the_point_at_infinity() {
        boot();
        let s = put_word(f::risc0_seal(), 4, bytes::zero32());
        let s = put_word(s, 36, bytes::zero32());
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
    }

    #[test, expected_failure(abort_code = proofs::EBadPoint, location = proofs)]
    /// B's coordinates' halves swapped, as a verifier that confused the EVM's order would read them: no point of G2.
    fun risc0_refuses_b_in_the_other_order() {
        boot();
        let s = f::risc0_seal();
        let x_im = bytes::slice(&s, 68, 32);
        let x_re = bytes::slice(&s, 100, 32);
        let y_im = bytes::slice(&s, 132, 32);
        let y_re = bytes::slice(&s, 164, 32);
        let s = put_word(s, 68, x_re);
        let s = put_word(s, 100, x_im);
        let s = put_word(s, 132, y_re);
        let s = put_word(s, 164, y_im);
        proofs::verify_risc0(&f::risc0_image_id(), &f::risc0_journal(), &s);
    }

    #[test]
    /// Both halves of `splitDigest` and the claim's layout, as `ReceiptClaimLib` writes them: the real receipt verifies
    /// only with them, and here the claim of another journal is another digest.
    fun the_claim_digest_is_risc_zeros() {
        let image = f::risc0_image_id();
        let journal = sha2_256(f::risc0_journal());
        let claim = proofs::claim_digest(&image, &journal);
        assert!(claim.length() == 32);
        assert!(claim != proofs::claim_digest(&image, &sha2_256(b"another journal")));
    }
}
