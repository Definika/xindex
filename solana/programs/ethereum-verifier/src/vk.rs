//! SP1 v6's Groth16 verifying key and the verifier's checks, as constants. Generated from sp1-contracts v6.0.0's
//! `Groth16Verifier.sol` and `SP1VerifierGroth16.sol` (vendored in `prototype/evm/src/sp1`, MIT, at commit
//! d3629729c3216eb51bd4859d027a8eb729399fa4): each is the Solidity constant as a 32-byte big-endian word.

/// A 64-digit hex string as 32 bytes, at compile time.
const fn h(s: &str) -> [u8; 32] {
    let b = s.as_bytes();
    assert!(b.len() == 64, "64 hex digits");
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = (nibble(b[2 * i]) << 4) | nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}

const fn nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("not a hex digit"),
    }
}

pub const VERIFIER_HASH: [u8; 32] =
    h("0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896");
pub const VK_ROOT: [u8; 32] = h("008cd56e10c2fe24795cff1e1d1f40d3a324528d315674da45d26afb376e8670");
pub const ALPHA_X: [u8; 32] = h("2838edbc8aee47ec511c2837d538a49ffd752370e06ed44e109b4c0f35be6e3a");
pub const ALPHA_Y: [u8; 32] = h("1cbeed5cf07bc7baa706137b59f34086467c2ebc770205fd1038c2c70d5ada22");
pub const BETA_NEG_X_0: [u8; 32] =
    h("2f6457660eeb88acf2baf1e7aefc0958da27058879cc77ba162d2df754aaf933");
pub const BETA_NEG_X_1: [u8; 32] =
    h("028cbe84124fba3ad76d33e6ca441f570726da5692cae5335a52209a15b9fd45");
pub const BETA_NEG_Y_0: [u8; 32] =
    h("202ab65c6ef68868df1a07b213125fd12b1c480090563941d2e74243dffd7ea8");
pub const BETA_NEG_Y_1: [u8; 32] =
    h("19bd43a87907704ce03cb365e44c3375453e8d24ab626dcc7081b28d60f62683");
pub const GAMMA_NEG_X_0: [u8; 32] =
    h("1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed");
pub const GAMMA_NEG_X_1: [u8; 32] =
    h("198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2");
pub const GAMMA_NEG_Y_0: [u8; 32] =
    h("1d9befcd05a5323e6da4d435f3b617cdb3af83285c2df711ef39c01571827f9d");
pub const GAMMA_NEG_Y_1: [u8; 32] =
    h("275dc4a288d1afb3cbb1ac09187524c7db36395df7be3b99e673b13a075a65ec");
pub const DELTA_NEG_X_0: [u8; 32] =
    h("08da56e9eb0d183a64e55881a5ed90cfdb0ed5229e588ec3de4452045b2445b1");
pub const DELTA_NEG_X_1: [u8; 32] =
    h("2f21b62705c5d7f4a7482bf1a69c35db8858584d6f155381b22022a71f817afa");
pub const DELTA_NEG_Y_0: [u8; 32] =
    h("28055b5f5b21751211d980c83f12ece1d2aa337be7ccc12a7f9830309563da23");
pub const DELTA_NEG_Y_1: [u8; 32] =
    h("16a0f9f6d66c598015b13eaf9a0420e89f97a2c8f0ac39095d4c5d0528f28745");
pub const CONSTANT_X: [u8; 32] =
    h("2a2cd5881e62ead81dc6997cfff997745379facd38c972e0825deedb0e4fa564");
pub const CONSTANT_Y: [u8; 32] =
    h("208c7b9c6bf876a51b3d62d0a5bdc0d7188e7342dea7d32ddb9635e291e8dd9a");
pub const PUB_0_X: [u8; 32] = h("219e17d13bc5f5ae36d78093cd6d112374a69844b7d058a7a0a62493f1c369c4");
pub const PUB_0_Y: [u8; 32] = h("254c200a2cdb5bc5e4e262780b4c70a988c4317fb11ac5fd5491f10692d1e929");
pub const PUB_1_X: [u8; 32] = h("258c71a2309359a248879ba915796e5e2e655acebace0ae7ef8fda2d40d2b2d6");
pub const PUB_1_Y: [u8; 32] = h("0b3cd73ef5ee90c6808893b3e4f81d8da3438cb5d2b601045825b2ab3990a391");
pub const PUB_2_X: [u8; 32] = h("0945b0f65ee8acfce0b22bab7a27663bfaf8eed78d511a96a54b50f307cd2a23");
pub const PUB_2_Y: [u8; 32] = h("1ef0708b683e9cbfeb8800001f06f9c80950d60869ebfc6b5cc58bd2bbfd6abe");
pub const PUB_3_X: [u8; 32] = h("290b3cba8ec4c97f171261b17b9c90e101b65934db12f4a299d4d5b939e9235c");
pub const PUB_3_Y: [u8; 32] = h("14914c2bf919019e575b0bd613363aa160d700bd929bcbc14de06a05e3a25eb0");
pub const PUB_4_X: [u8; 32] = h("22474ea30b64abc35269a0c55be5972965bf920e937c3d1927da5e89e60cf916");
pub const PUB_4_Y: [u8; 32] = h("272dd64ca95c75938da75797ef702ec5112808c36914020a4b1822fff576d334");
pub const R: [u8; 32] = h("30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001");
