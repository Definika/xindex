//! The repository's real fixtures, for the unit tests: SP1 v6's own Groth16 proof, RISC Zero's own v3.0 receipt, and
//! mainnet receipts, read where the other chains' tests read them.

pub fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

/// Bytes as lowercase hex, without a prefix: an ed25519 implicit account's id.
pub fn hex_str(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A file of the repository, by its path from the root.
pub fn repo_file(path: &str) -> String {
    std::fs::read_to_string(format!("{}/../../../{path}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

/// SP1 v6's own Groth16 fixture (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`): the program key, the public values
/// and the proof.
pub fn sp1_fixture() -> ([u8; 32], Vec<u8>, Vec<u8>) {
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
pub fn risc0_receipt() -> ([u8; 32], Vec<u8>, Vec<u8>) {
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
