/// P1's and P2's proof checks, on Aptos's native BN254 (`aptos_std::crypto_algebra` with `bn254_algebra`), from the
/// proofs as the EVM verifiers take them: SP1 v6's Groth16 proof, as `SP1VerifierGroth16.sol` and `Groth16Verifier.sol`
/// make it (sp1-contracts v6.0.0, MIT, at d3629729c3216eb51bd4859d027a8eb729399fa4), and RISC Zero v3.0's seal, as
/// `RiscZeroGroth16Verifier` makes it (risc0-ethereum v3.0.1, Apache-2.0, at 365e7b2db4f620fa256580c27558d2623362b9ae),
/// the twins of `crates/xindex-core/src/sp1.rs` and `risc0.rs` and of `sui/sources/proofs.move`.
///
/// Both check Groth16's equation as SP1's verifier writes it, `e(A, B) e(C, -delta) e(alpha, -beta) e(L, -gamma) = 1`,
/// `L` the verifying key's input points summed under the public inputs: one `multi_pairing` of four pairs, compared
/// with the identity of `Gt`. SP1's key holds beta, gamma and delta negated already; RISC Zero's (snarkjs's form) holds
/// them as they are, so its constants below are negated here, which `tests/proofs_tests.move` rebuilds from both
/// Solidity verifiers' own constants.
///
/// Points are read in arkworks' uncompressed form, which `bn254_algebra::FormatG1Uncompr` and `FormatG2Uncompr` name:
/// a coordinate 32 bytes little-endian, G2's `Fq2` coordinates as `c0 ++ c1` (real part first), the top two bits of the
/// last byte flags. The EVM writes them big-endian, G2's imaginary part first, so each is converted here. Every
/// coordinate is checked to lie below q, which leaves both flag bits clear, and the algebra module then checks the point
/// lies on the curve and in its prime-order subgroup, or refuses it: a proof whose point is not the curve's is refused,
/// where Sui's twin, which compresses, reads the curve's point at that x. The EVM's point at infinity, `(0, 0)`, is
/// refused too: no honest prover writes one.
module xindex_vault::proofs {
    use std::hash::sha2_256;
    use std::option;
    use std::vector;
    use aptos_std::crypto_algebra::{Self, Element};
    use aptos_std::bn254_algebra::{Fr, FormatFrLsb, FormatG1Uncompr, FormatG2Uncompr, G1, G2, Gt};
    use xindex_vault::bytes;

    /// The proof or seal is not its system's length.
    const EWrongLength: u64 = 151;
    /// The proof names another verifier.
    const EWrongSelector: u64 = 152;
    /// SP1's exit code is not zero.
    const EBadExitCode: u64 = 153;
    /// SP1's vk root is not v6's.
    const EWrongVkRoot: u64 = 154;
    /// A public input or a coordinate lies past its field.
    const ENotInField: u64 = 155;
    /// The pairing check failed: no proof of this statement.
    const EInvalidProof: u64 = 156;
    /// A point is not on the curve, or not in its prime-order subgroup.
    const EBadPoint: u64 = 157;

    /// The scalar field's size, r, and the base field's, q.
    const R: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    const Q: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;

    /// SP1: the proof's length (selector, exit code, vk root, nonce, then A, B and C as eight words), the selector, the
    /// first four bytes of `VERIFIER_HASH`, and v6's vk root.
    const SP1_PROOF_LEN: u64 = 356;
    const SP1_SELECTOR: vector<u8> = x"0e78f4db";
    const SP1_VK_ROOT: vector<u8> = x"008cd56e10c2fe24795cff1e1d1f40d3a324528d315674da45d26afb376e8670";

    /// SP1 v6's verifying key, uncompressed: alpha, beta, gamma and delta negated, and the input points (CONSTANT,
    /// PUB_0..PUB_4).
    const SP1_ALPHA: vector<u8> = x"3a6ebe350f4c9b104ed46ee0702375fd9fa438d537281c51ec47ee8abced382822da5a0dc7c23810fd050277bc2e7c468640f3597b1306a7bac77bf05cedbe1c";
    const SP1_BETA_NEG: vector<u8> = x"33f9aa54f72d2d16ba77cc79880527da5809fcaee7f1baf2ac88eb0e6657642f45fdb9159a20525a33e5ca9256da2607571f44cae6336dd73aba4f1284be8c02a87efddf4342e7d24139569000481c2bd15f1213b2071adf6888f66e5cb62a208326f6608db28170cc6d62ab248d3e4575334ce465b33ce04c700779a843bd19";
    const SP1_GAMMA_NEG: vector<u8> = x"edf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e199d7f827115c039ef11f72d5c2883afb3cd17b6f335d4a46d3e32a505cdef9b1dec655a073ab173e6993bbef75d3936dbc724751809acb1cbb3afd188a2c45d27";
    const SP1_DELTA_NEG: vector<u8> = x"b145245b045244dec38e589e22d50edbcf90eda58158e5643a180debe956da08fa7a811fa72220b28153156f4d585888db359ca6f12b48a7f4d7c50527b6212f23da63953030987f2ac1cce77b33aad2e1ec123fc880d9111275215b5f5b05284587f228055d4c5d0939acf0c8a2979fe820049aaf3eb11580596cd6f6f9a016";
    const SP1_IC: vector<u8> = x"64a54f0edbee5d82e072c938cdfa79537497f9ff7c99c61dd8ea621e88d52c2a9adde891e23596db2dd3a7de42738e18d7c0bda5d0623d1ba576f86b9c7b8c20c469c3f19324a6a0a758d0b74498a67423116dcd9380d736aef5c53bd1179e2129e9d19206f19154fdc51ab17f31c488a9704c0b7862e2e4c55bdb2c0a204c25d6b2d2402dda8fefe70acebace5a652e5e6e7915a99b8748a2599330a2718c2591a39039abb225580401b6d2b58c43a38d1df8e4b3938880c690eef53ed73c0b232acd07f3504ba5961a518dd7eef8fa3b66277aab2bb2e0fcace85ef6b04509be6afdbbd28bc55c6bfceb6908d65009c8f9061f000088ebbf9c3e688b70f01e5c23e939b9d5d499a2f412db3459b601e1909c7bb16112177fc9c48eba3c0b29b05ea2e3056ae04dc1cb9b92bd00d760a13a3613d60b5b579e0119f92b4c911416f90ce6895eda27193d7c930e92bf652997e55bc5a06952c3ab640ba34e472234d376f5ff22184b0a021469c3082811c52e70ef9757a78d93755ca94cd62d27";

    /// RISC Zero: the seal's length (selector, then A, B and C as eight words), the selector (`bytes4` of the verifier's
    /// parameters' digest, pinned on the EVM by `DeployVault`'s `RISC_ZERO_SELECTOR`), the control root and the BN254
    /// control id (`ControlID.sol`), and the zero system state's digest (`IRiscZeroVerifier.sol`).
    const RISC0_SEAL_LEN: u64 = 260;
    const RISC0_SELECTOR: vector<u8> = x"73c457ba";
    const RISC0_CONTROL_ROOT: vector<u8> = x"a54dc85ac99f851c92d7c96d7318af41dbe7c0194edfcc37eb4d422a998c1f56";
    const RISC0_BN254_CONTROL_ID: vector<u8> = x"04446e66d300eb7fb45c9726bb53c793dda407a62e9601618bb43c5c14657ac0";
    const RISC0_SYSTEM_STATE_ZERO_DIGEST: vector<u8> = x"a3acc27117418996340b84e5a90f3ef4c49d22c79e44aad822ec9c313e1eb8e2";

    /// RISC Zero v3.0's verifying key, uncompressed: alpha, beta, gamma and delta negated here, and IC0..IC5.
    const RISC0_ALPHA: vector<u8> = x"e2f26dbea299f5223b646cb1fb33eadb059d9407559d7441dfd902e3a79a4d2d26194d00ffca76f0010323190a8389ce45e39f2060ecd861b0ce373c50ddbe14";
    const RISC0_BETA_NEG: vector<u8> = x"abb73dc17fbc13021e2471e0c08bd67d8401f52b73d6d07483794cad4778180e0c06f33bbc4c79a9cadef253a68084d382f17788f885c9afd176f7cb2f0367097f2eac5dc285a166e3c48729cbb2ea9ecac65134e4211f8762f7d93cc18c2a19a0b659c7c9f1799e55bdf7fccc8b83ec20cc41a86e5d5a1edf2fa700a1521700";
    const RISC0_GAMMA_NEG: vector<u8> = x"edf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e199d7f827115c039ef11f72d5c2883afb3cd17b6f335d4a46d3e32a505cdef9b1dec655a073ab173e6993bbef75d3936dbc724751809acb1cbb3afd188a2c45d27";
    const RISC0_DELTA_NEG: vector<u8> = x"33033e7fea1f40604eaacf699d4be9aacc577054a0db22d9129a1728ff85a01a1c3af829b62bf4914c0bcf2c81a4bd577190eff5f194ee9bac95faefd53cb00374363d5bfeacddca70e041cabbf5538c30d568fe9ede678041483a15535b0312e5f579cb82b98edfc2a1ff6c223419efae8e68ac6f3d07c20f9511925f3e581f";
    const RISC0_IC: vector<u8> = x"e43bdc655d0f9d730535554d9caa611ddd152c081a06a932a8e1d5dc259aac12d4ac80e90ec6232bee3e0fd3a2f56f106985891c913117d97abe1e5844a75a023f42a188f683d869873ccc4c119442e57b056e03e2fa92f2028c97bc20b907074266ff870765a482373803c25555d5d2ac8134f67b35bcf7549558b794a0322e47c30f85444697fdf436e348711c011115963f855197243e4b39e6cbe236ca0b8b9bdffcb153c109f4f7b86dfad435842a4e71683dfa29373acf48cf9a7cde2ea7f2042e11f9255afbb6c6e2c3accb88e401f2aac21c097c92b3fbdb99f98a1bd6cc9c674ff09c3e7f15601ad886d550c8812a199f9422576f1b2ea96aa2912b0dcd6c075ada6ed0ddfece1d4a2d005f61a7d5df0b75c18a5b2374d64e495f2b825eadb26516e7c512f9148ff86fa7b863a8b9cb7f81bacbb9aa2020ad20e52f93d4c4b1200394d5253cce2f25a59b862ee8e4cd43686603faa09d5d0d3c1c0f09e8690bbd01aa8782f608362fbbc88b2d4807b3070d8cfef625f474fffc4b21";

    /// Aborts unless `proof` is SP1 v6's Groth16 proof that the program `program_key` committed `public_values`.
    public fun verify_sp1(program_key: &vector<u8>, public_values: &vector<u8>, proof: &vector<u8>) {
        assert!(proof.length() == SP1_PROOF_LEN, EWrongLength);
        let (selector, vk_root) = (SP1_SELECTOR, SP1_VK_ROOT);
        assert!(bytes::slice_eq(proof, 0, 4, &selector), EWrongSelector);
        let exit_code = bytes::slice(proof, 4, 32);
        assert!(bytes::is_zero(&exit_code), EBadExitCode);
        assert!(bytes::slice_eq(proof, 36, 32, &vk_root), EWrongVkRoot);
        // `hashPublicValues`: SHA-256 with its top three bits cleared, so it lies in the scalar field.
        let digest = sha2_256(*public_values);
        digest[0] &= 0x1f;
        let inputs = vector[
            bytes::to_u256(program_key),
            bytes::to_u256(&digest),
            0,
            bytes::u256_at(proof, 36),
            bytes::u256_at(proof, 68),
        ];
        check(SP1_ALPHA, SP1_BETA_NEG, SP1_GAMMA_NEG, SP1_DELTA_NEG, SP1_IC, inputs, proof, 100);
    }

    /// Aborts unless `seal` is RISC Zero v3.0's Groth16 seal of a receipt claiming that the image `image_id` ran and
    /// committed `journal`, as `verify(seal, imageId, sha256(journal))` succeeds on the EVM.
    public fun verify_risc0(image_id: &vector<u8>, journal: &vector<u8>, seal: &vector<u8>) {
        assert!(seal.length() == RISC0_SEAL_LEN, EWrongLength);
        let (selector, root, control_id) = (RISC0_SELECTOR, RISC0_CONTROL_ROOT, RISC0_BN254_CONTROL_ID);
        assert!(bytes::slice_eq(seal, 0, 4, &selector), EWrongSelector);
        let claim = claim_digest(image_id, &sha2_256(*journal));
        let (root0, root1) = split_digest(&root);
        let (claim0, claim1) = split_digest(&claim);
        let inputs = vector[root0, root1, claim0, claim1, bytes::to_u256(&control_id)];
        check(RISC0_ALPHA, RISC0_BETA_NEG, RISC0_GAMMA_NEG, RISC0_DELTA_NEG, RISC0_IC, inputs, seal, 4);
    }

    /// `ReceiptClaimLib.ok(imageId, journalDigest).digest()`: the claim that the image ran, halted with exit code 0,
    /// committed the journal of that digest, and assumed nothing. Each struct's digest is SHA-256 of its tag's digest,
    /// its digest fields, its data, and its count of digest fields as a little-endian `u16`.
    public fun claim_digest(image_id: &vector<u8>, journal_digest: &vector<u8>): vector<u8> {
        let output = sha2_256(b"risc0.Output");
        output.append(*journal_digest);
        output.append(bytes::zero32());
        output.append(vector[2, 0]);
        let output = sha2_256(output);
        let claim = sha2_256(b"risc0.ReceiptClaim");
        claim.append(bytes::zero32());
        claim.append(*image_id);
        claim.append(RISC0_SYSTEM_STATE_ZERO_DIGEST);
        claim.append(output);
        claim.append(vector[0, 0, 0, 0, 0, 0, 0, 0, 4, 0]);
        sha2_256(claim)
    }

    /// `splitDigest`: the digest's bytes reversed, then its low and its high 128 bits, each a public input: the
    /// little-endian numbers of the digest's first sixteen bytes and of its last sixteen.
    fun split_digest(digest: &vector<u8>): (u256, u256) {
        let low = bytes::slice(digest, 0, 16);
        low.append(bytes::repeat(0, 16));
        let high = bytes::slice(digest, 16, 16);
        high.append(bytes::repeat(0, 16));
        (le_u256(&low), le_u256(&high))
    }

    /// A 32-byte little-endian number.
    fun le_u256(v: &vector<u8>): u256 {
        let x: u256 = 0;
        let i = 32;
        while (i > 0) {
            i -= 1;
            x = (x << 8) | (v[i] as u256);
        };
        x
    }

    /// A G1 point `(x, y)` as the EVM writes it, in arkworks' uncompressed form.
    public fun g1(x: u256, y: u256): vector<u8> {
        assert!(x < Q && y < Q, ENotInField);
        let out = bytes::le32(x);
        out.append(bytes::le32(y));
        out
    }

    /// A G2 point as the EVM writes it, `x_im, x_re, y_im, y_re`, in arkworks' uncompressed form: `x_re ++ x_im ++
    /// y_re ++ y_im`.
    public fun g2(x_im: u256, x_re: u256, y_im: u256, y_re: u256): vector<u8> {
        assert!(x_im < Q && x_re < Q && y_im < Q && y_re < Q, ENotInField);
        let out = bytes::le32(x_re);
        out.append(bytes::le32(x_im));
        out.append(bytes::le32(y_re));
        out.append(bytes::le32(y_im));
        out
    }

    fun point1(encoded: &vector<u8>): Element<G1> {
        let p = crypto_algebra::deserialize<G1, FormatG1Uncompr>(encoded);
        assert!(p.is_some(), EBadPoint);
        p.destroy_some()
    }

    fun point2(encoded: &vector<u8>): Element<G2> {
        let p = crypto_algebra::deserialize<G2, FormatG2Uncompr>(encoded);
        assert!(p.is_some(), EBadPoint);
        p.destroy_some()
    }

    /// A public input as a scalar: below r.
    fun scalar(x: u256): Element<Fr> {
        assert!(x < R, ENotInField);
        option::destroy_some(crypto_algebra::deserialize<Fr, FormatFrLsb>(&bytes::le32(x)))
    }

    /// Groth16's check of the proof's A, B and C at `at` against the key and the five public inputs.
    fun check(
        alpha: vector<u8>,
        beta_neg: vector<u8>,
        gamma_neg: vector<u8>,
        delta_neg: vector<u8>,
        ic: vector<u8>,
        inputs: vector<u256>,
        proof: &vector<u8>,
        at: u64,
    ) {
        // The scalars first, so an input past the field is refused before any point is read.
        let scalars = vector[crypto_algebra::one<Fr>()];
        let i = 0;
        while (i < inputs.length()) {
            scalars.push_back(scalar(inputs[i]));
            i += 1;
        };
        let a = g1(bytes::u256_at(proof, at), bytes::u256_at(proof, at + 32));
        let b = g2(
            bytes::u256_at(proof, at + 64),
            bytes::u256_at(proof, at + 96),
            bytes::u256_at(proof, at + 128),
            bytes::u256_at(proof, at + 160),
        );
        let c = g1(bytes::u256_at(proof, at + 192), bytes::u256_at(proof, at + 224));
        let points = vector::empty<Element<G1>>();
        let i = 0;
        while (i < scalars.length()) {
            points.push_back(point1(&bytes::slice(&ic, 64 * i, 64)));
            i += 1;
        };
        let l = crypto_algebra::multi_scalar_mul(&points, &scalars);
        let g1s = vector[point1(&a), point1(&c), point1(&alpha), l];
        let g2s = vector[point2(&b), point2(&delta_neg), point2(&beta_neg), point2(&gamma_neg)];
        let product = crypto_algebra::multi_pairing<G1, G2, Gt>(&g1s, &g2s);
        assert!(crypto_algebra::eq(&product, &crypto_algebra::zero<Gt>()), EInvalidProof);
    }

    #[test_only]
    public fun sp1_key(): vector<vector<u8>> {
        vector[SP1_ALPHA, SP1_BETA_NEG, SP1_GAMMA_NEG, SP1_DELTA_NEG, SP1_IC]
    }

    #[test_only]
    public fun risc0_key(): vector<vector<u8>> {
        vector[RISC0_ALPHA, RISC0_BETA_NEG, RISC0_GAMMA_NEG, RISC0_DELTA_NEG, RISC0_IC]
    }
}
