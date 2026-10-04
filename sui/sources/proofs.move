/// P1's and P2's proof checks, on Sui's native BN254 Groth16 (`sui::groth16`), from the proofs as the EVM verifiers take
/// them: SP1 v6's Groth16 proof, as `SP1VerifierGroth16.sol` and `Groth16Verifier.sol` make it (sp1-contracts v6.0.0,
/// MIT, at d3629729c3216eb51bd4859d027a8eb729399fa4), and RISC Zero v3.0's seal, as `RiscZeroGroth16Verifier` makes it
/// (risc0-ethereum v3.0.1, Apache-2.0, at 365e7b2db4f620fa256580c27558d2623362b9ae), the twins of
/// `crates/xindex-core/src/sp1.rs` and `risc0.rs`.
///
/// Sui checks `e(A, B) = e(alpha, beta) e(L, gamma) e(C, delta)` with arkworks' encodings: a G1 point compressed to its
/// x-coordinate, 32 bytes little-endian, with the top bit of its last byte set when `y > (q - 1) / 2`; a G2 point to
/// `x.c0 ++ x.c1`, the flag on `x.c1`'s last byte, set when `y.c1 > (q - 1) / 2`, or `y.c1 = 0` and `y.c0 > (q - 1) / 2`
/// (`Fq2` ordered by `c1` first); a scalar 32 bytes little-endian. The EVM writes points uncompressed and big-endian, G2
/// with the imaginary part first, so each point is converted here. SP1's verifier writes beta, gamma and delta negated
/// and checks a product of four pairings against one: the same equation. The prepared keys below are what
/// `groth16::prepare_verifying_key` makes of each verifier's key, written from its Solidity constants; the tests
/// rebuild both from those constants and compare.
///
/// A point is checked to be canonical (each coordinate below q) but not to lie on the curve: compression keeps x and
/// y's sign only, and Sui decompresses to the curve's point there or refuses. A proof whose y is not the curve's is so
/// read as the proof with the curve's y: the same statement, which that proof proves, so nothing is accepted that a
/// valid proof does not show. Groth16 proofs are malleable anyway, and nothing here keys on a proof's bytes.
module xindex_vault::proofs;

use std::hash::sha2_256;
use sui::groth16;
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

/// The scalar field's size, r, and the base field's, q, and (q - 1) / 2.
const R: u256 = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
const Q: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;
const HALF_Q: u256 = 0x183227397098d014dc2822db40c0ac2ecbc0b548b438e5469e10460b6c3e7ea3;

/// SP1: the proof's length (selector, exit code, vk root, nonce, then A, B and C as eight words), the selector, the
/// first four bytes of `VERIFIER_HASH`, and v6's vk root.
const SP1_PROOF_LEN: u64 = 356;
const SP1_SELECTOR: vector<u8> = x"0e78f4db";
const SP1_VK_ROOT: vector<u8> = x"008cd56e10c2fe24795cff1e1d1f40d3a324528d315674da45d26afb376e8670";

/// SP1 v6's verifying key, prepared: `IC` (CONSTANT, PUB_0..PUB_4) compressed, `e(alpha, beta)`, and gamma and delta
/// negated and compressed.
const SP1_VK_GAMMA_ABC: vector<u8> = x"64a54f0edbee5d82e072c938cdfa79537497f9ff7c99c61dd8ea621e88d52caac469c3f19324a6a0a758d0b74498a67423116dcd9380d736aef5c53bd1179ea1d6b2d2402dda8fefe70acebace5a652e5e6e7915a99b8748a2599330a2718c25232acd07f3504ba5961a518dd7eef8fa3b66277aab2bb2e0fcace85ef6b045895c23e939b9d5d499a2f412db3459b601e1909c7bb16112177fc9c48eba3c0b2916f90ce6895eda27193d7c930e92bf652997e55bc5a06952c3ab640ba34e47a2";
const SP1_ALPHA_BETA: vector<u8> = x"fb5cec747ce95fd7b6d853286422f51039b473dbb008bcce6bc37f0b8749110e329d50b18a4a60d1d626e473c29e117542a7dc9e5368132da650b23b76727a00727a36dda928f53c7e3ab00b02f7c4b2b12119978e0b6511aec780dd7d62c114cfa231ea24f477d6de4401fe5c9db539765ffc93ad208eb3da5cdfb8f75e9d1f6812324201400bfeaff963fce13c5eb3f8c27f700942bd0d04e264e0022f7a28761127bcb595188962c6fcdca33cf7b537b9dc55c6d80ca4038d169ddf21880d4cf3ac8c50424864f9c6effde05416bbece0cda6439baba27f3dcc0c7a1e911e7b0a566ccd69bf28a613fc4c4d18378148e9a19960907ac9f2919148fceff4127a7e0899f1b1f54298b2e42f36545a984df2fff7dde85fd2f42f6efd0cf45429d21cdcf6639ba188eecea3b8dfbe3e4292f08e6ba6ef3b55341b146fd6d0952083ee7935e5cae9924f4373f77e6e7ee3f16ecbe0a2cc8656f24265e514f472144a9882bd916e5784d7c53c2d4dea32b8a53cd126163d661587be441e8560fe00";
const SP1_GAMMA_NEG: vector<u8> = x"edf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e99";
const SP1_DELTA_NEG: vector<u8> = x"b145245b045244dec38e589e22d50edbcf90eda58158e5643a180debe956da08fa7a811fa72220b28153156f4d585888db359ca6f12b48a7f4d7c50527b6212f";

/// RISC Zero: the seal's length (selector, then A, B and C as eight words), the selector (`bytes4` of the verifier's
/// parameters' digest, pinned on the EVM by `DeployVault`'s `RISC_ZERO_SELECTOR`), the control root and the BN254
/// control id (`ControlID.sol`), and the zero system state's digest (`IRiscZeroVerifier.sol`).
const RISC0_SEAL_LEN: u64 = 260;
const RISC0_SELECTOR: vector<u8> = x"73c457ba";
const RISC0_CONTROL_ROOT: vector<u8> = x"a54dc85ac99f851c92d7c96d7318af41dbe7c0194edfcc37eb4d422a998c1f56";
const RISC0_BN254_CONTROL_ID: vector<u8> = x"04446e66d300eb7fb45c9726bb53c793dda407a62e9601618bb43c5c14657ac0";
const RISC0_SYSTEM_STATE_ZERO_DIGEST: vector<u8> = x"a3acc27117418996340b84e5a90f3ef4c49d22c79e44aad822ec9c313e1eb8e2";

/// RISC Zero v3.0's verifying key, prepared as SP1's is.
const RISC0_VK_GAMMA_ABC: vector<u8> = x"e43bdc655d0f9d730535554d9caa611ddd152c081a06a932a8e1d5dc259aac123f42a188f683d869873ccc4c119442e57b056e03e2fa92f2028c97bc20b9078747c30f85444697fdf436e348711c011115963f855197243e4b39e6cbe236ca8ba7f2042e11f9255afbb6c6e2c3accb88e401f2aac21c097c92b3fbdb99f98a9b0dcd6c075ada6ed0ddfece1d4a2d005f61a7d5df0b75c18a5b2374d64e495fab93d4c4b1200394d5253cce2f25a59b862ee8e4cd43686603faa09d5d0d3c1c8f";
const RISC0_ALPHA_BETA: vector<u8> = x"0d14dc30b678357d988b3eb0e8ada11bc7b2b5d2cf0c1fe27522cb2a819b7c044a601bd9302a94a80677a9f72ebeaada131e9bfba30621c8f038b547beb9962e182089742c1d388436771390c6af9937729c39e6414746ee5636c4741d1f220df45c80a7cded5ad653bc4f8b201c94054918dee160e1dc90cea027d4ec69e01a6df0f8d739d7911aa63b6b6923f10cdce763de1046fe0f91d590f5f510397611c57ac6daac2f9222d8cc3130e57f99dcd2edecb3e1d11b860c0d9d64a5dda30f42b8a8e513c9d5983486332c3ecd1236192b988666c15818838559bc27b6a50f49fee88fd43ac88dc3e75419bfd451374e25b8c4845b4bfcbd460ad48bb55016e4e1edf293696a43b76c8a5feffe6cfddb59cd7bc0246c1784061ed3eff2280a74e56fcabc5b93d84d72e10a0ad78079b02d06cc8c3ae435936ce2e85722d82b9480a46f039988a80cf4ca669c026100f8ce3fbc5298180dec08d2055d7a621ad3cc4fdd99242a86d7c80528d3b438c4669288c56b77abb8367528a31f01c511";
const RISC0_GAMMA_NEG: vector<u8> = x"edf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e99";
const RISC0_DELTA_NEG: vector<u8> = x"33033e7fea1f40604eaacf699d4be9aacc577054a0db22d9129a1728ff85a01a1c3af829b62bf4914c0bcf2c81a4bd577190eff5f194ee9bac95faefd53cb083";

/// Aborts unless `proof` is SP1 v6's Groth16 proof that the program `program_key` committed `public_values`.
public fun verify_sp1(program_key: &vector<u8>, public_values: &vector<u8>, proof: &vector<u8>) {
    assert!(proof.length() == SP1_PROOF_LEN, EWrongLength);
    let (selector, vk_root) = (SP1_SELECTOR, SP1_VK_ROOT);
    assert!(bytes::slice_eq(proof, 0, 4, &selector), EWrongSelector);
    let exit_code = bytes::slice(proof, 4, 32);
    assert!(bytes::is_zero(&exit_code), EBadExitCode);
    assert!(bytes::slice_eq(proof, 36, 32, &vk_root), EWrongVkRoot);
    // `hashPublicValues`: SHA-256 with its top three bits cleared, so it lies in the scalar field.
    let mut digest = sha2_256(*public_values);
    let top = digest[0];
    *&mut digest[0] = top & 0x1f;
    let mut inputs = scalar(bytes::to_u256(program_key));
    inputs.append(scalar(bytes::to_u256(&digest)));
    inputs.append(scalar(0));
    inputs.append(scalar(bytes::u256_at(proof, 36)));
    inputs.append(scalar(bytes::u256_at(proof, 68)));
    let points = points(proof, 100);
    check(SP1_VK_GAMMA_ABC, SP1_ALPHA_BETA, SP1_GAMMA_NEG, SP1_DELTA_NEG, inputs, points);
}

/// Aborts unless `seal` is RISC Zero v3.0's Groth16 seal of a receipt claiming that the image `image_id` ran and
/// committed `journal`, as `verify(seal, imageId, sha256(journal))` succeeds on the EVM.
public fun verify_risc0(image_id: &vector<u8>, journal: &vector<u8>, seal: &vector<u8>) {
    assert!(seal.length() == RISC0_SEAL_LEN, EWrongLength);
    let (selector, root, control_id) = (RISC0_SELECTOR, RISC0_CONTROL_ROOT, RISC0_BN254_CONTROL_ID);
    assert!(bytes::slice_eq(seal, 0, 4, &selector), EWrongSelector);
    let claim = claim_digest(image_id, &sha2_256(*journal));
    let mut inputs = split_digest(&root);
    inputs.append(split_digest(&claim));
    inputs.append(scalar(bytes::to_u256(&control_id)));
    let points = points(seal, 4);
    check(RISC0_VK_GAMMA_ABC, RISC0_ALPHA_BETA, RISC0_GAMMA_NEG, RISC0_DELTA_NEG, inputs, points);
}

/// `ReceiptClaimLib.ok(imageId, journalDigest).digest()`: the claim that the image ran, halted with exit code 0,
/// committed the journal of that digest, and assumed nothing. Each struct's digest is SHA-256 of its tag's digest, its
/// digest fields, its data, and its count of digest fields as a little-endian `u16`.
public fun claim_digest(image_id: &vector<u8>, journal_digest: &vector<u8>): vector<u8> {
    let mut output = sha2_256(b"risc0.Output");
    output.append(*journal_digest);
    output.append(bytes::zero32());
    output.append(vector[2, 0]);
    let output = sha2_256(output);
    let mut claim = sha2_256(b"risc0.ReceiptClaim");
    claim.append(bytes::zero32());
    claim.append(*image_id);
    claim.append(RISC0_SYSTEM_STATE_ZERO_DIGEST);
    claim.append(output);
    claim.append(vector[0, 0, 0, 0, 0, 0, 0, 0, 4, 0]);
    sha2_256(claim)
}

/// `splitDigest`: the digest's bytes reversed, then its low and its high 128 bits, each a public input; as scalars,
/// little-endian, the digest's first sixteen bytes and its last sixteen, each padded with zeros.
fun split_digest(digest: &vector<u8>): vector<u8> {
    let mut out = bytes::slice(digest, 0, 16);
    out.append(vector::tabulate!(16, |_| 0u8));
    out.append(bytes::slice(digest, 16, 16));
    out.append(vector::tabulate!(16, |_| 0u8));
    out
}

/// A public input as Sui takes it: below r, 32 bytes little-endian.
fun scalar(x: u256): vector<u8> {
    assert!(x < R, ENotInField);
    bytes::le32(x)
}

/// The proof's A, B and C at `at`, as the EVM writes them, compressed as arkworks writes them.
fun points(proof: &vector<u8>, at: u64): vector<u8> {
    let mut out = g1(bytes::u256_at(proof, at), bytes::u256_at(proof, at + 32));
    out.append(g2(
        bytes::u256_at(proof, at + 64),
        bytes::u256_at(proof, at + 96),
        bytes::u256_at(proof, at + 128),
        bytes::u256_at(proof, at + 160),
    ));
    out.append(g1(bytes::u256_at(proof, at + 192), bytes::u256_at(proof, at + 224)));
    out
}

/// A G1 point `(x, y)`, compressed.
public fun g1(x: u256, y: u256): vector<u8> {
    assert!(x < Q && y < Q, ENotInField);
    let mut out = bytes::le32(x);
    if (y > HALF_Q) {
        let top = out[31];
        *&mut out[31] = top | 0x80;
    };
    out
}

/// A G2 point as the EVM writes it, `x_im, x_re, y_im, y_re`, compressed.
public fun g2(x_im: u256, x_re: u256, y_im: u256, y_re: u256): vector<u8> {
    assert!(x_im < Q && x_re < Q && y_im < Q && y_re < Q, ENotInField);
    let mut out = bytes::le32(x_re);
    out.append(bytes::le32(x_im));
    let negative = if (y_im != 0) { y_im > HALF_Q } else { y_re > HALF_Q };
    if (negative) {
        let top = out[63];
        *&mut out[63] = top | 0x80;
    };
    out
}

fun check(
    gamma_abc: vector<u8>,
    alpha_beta: vector<u8>,
    gamma_neg: vector<u8>,
    delta_neg: vector<u8>,
    inputs: vector<u8>,
    points: vector<u8>,
) {
    let curve = groth16::bn254();
    let pvk = groth16::pvk_from_bytes(gamma_abc, alpha_beta, gamma_neg, delta_neg);
    let ok = groth16::verify_groth16_proof(
        &curve,
        &pvk,
        &groth16::public_proof_inputs_from_bytes(inputs),
        &groth16::proof_points_from_bytes(points),
    );
    assert!(ok, EInvalidProof);
}

#[test_only]
public fun sp1_prepared(): vector<vector<u8>> {
    vector[SP1_VK_GAMMA_ABC, SP1_ALPHA_BETA, SP1_GAMMA_NEG, SP1_DELTA_NEG]
}

#[test_only]
public fun risc0_prepared(): vector<vector<u8>> {
    vector[RISC0_VK_GAMMA_ABC, RISC0_ALPHA_BETA, RISC0_GAMMA_NEG, RISC0_DELTA_NEG]
}
