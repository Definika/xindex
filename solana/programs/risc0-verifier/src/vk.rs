//! RISC Zero v3.0's Groth16 verifying key, its control ids and the receipt claim's constants, each as a 32-byte
//! big-endian word. Taken from risc0-ethereum v3.0.1 (vendored in `vendor/risc0-ethereum`, at commit
//! 365e7b2db4f620fa256580c27558d2623362b9ae): the verifying key and the fields from `src/groth16/Groth16Verifier.sol`,
//! where they are decimal; the control ids from `src/groth16/ControlID.sol`; the zero system state's digest from
//! `src/IRiscZeroVerifier.sol`. The tests below read every one back from those files.

use ethereum_verifier::vk::h;

/// The scalar field's size, `r`, and the base field's, `q`.
pub const R: [u8; 32] = h("30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001");
pub const Q: [u8; 32] = h("30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47");

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

#[cfg(test)]
mod tests {
    use super::*;

    fn sha256(parts: &[&[u8]]) -> [u8; 32] {
        solana_sha256_hasher::hashv(parts).to_bytes()
    }

    fn read(path: &str) -> String {
        std::fs::read_to_string(format!(
            "{}/../../../vendor/risc0-ethereum/{path}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
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
        h(&rest[start..start + 64])
    }

    /// Every constant is the vendored Solidity's.
    #[test]
    fn the_constants_are_risc_zeros() {
        let g = read("src/groth16/Groth16Verifier.sol");
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
        let c = read("src/groth16/ControlID.sol");
        assert_eq!(solidity_hex(&c, "CONTROL_ROOT ="), CONTROL_ROOT);
        assert_eq!(solidity_hex(&c, "BN254_CONTROL_ID ="), BN254_CONTROL_ID);
        let v = read("src/IRiscZeroVerifier.sol");
        let rest = &v[v.find("SYSTEM_STATE_ZERO_DIGEST = 0x").unwrap()..];
        let start = rest.find("0x").unwrap() + 2;
        assert_eq!(h(&rest[start..start + 64]), SYSTEM_STATE_ZERO_DIGEST);
    }

    /// The selector is what `RiscZeroGroth16Verifier`'s constructor computes from this key and these control ids: the
    /// key's digest (`verifier_key_digest`), with the IC points as a tagged list, then the parameters' digest.
    #[test]
    fn the_selector_follows_from_the_key_and_the_control_ids() {
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
}
