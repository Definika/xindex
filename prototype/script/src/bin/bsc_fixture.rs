//! M6 input: checks the recorded BNB Chain finality vote natively, with the reference BLS12-381 library, and writes
//! the EIP-2537 encodings a Solidity verifier on Ethereum takes: every voter's key uncompressed (128 bytes, each
//! coordinate left-padded to 64) and the aggregate signature uncompressed (256 bytes).
use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{pairing, G1Affine, G1Projective, G2Affine, G2Projective};
use group::Curve;
use sha2::Sha256;

const DST: &[u8] = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

fn unhex(s: &str) -> Vec<u8> {
    hex::decode(s.trim_start_matches("0x")).expect("hex")
}

fn pad(b: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; 16];
    out.extend_from_slice(b);
    out
}

fn main() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let fx: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("fixtures-bsc-vote.json")).unwrap()).unwrap();
    let validators = fx["validators"].as_array().unwrap();
    let voters: Vec<usize> = fx["voters"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as usize).collect();

    let mut keys = Vec::new();
    let mut agg = G1Projective::identity();
    for v in validators {
        let c: [u8; 48] = unhex(v["bls"].as_str().unwrap()).try_into().unwrap();
        let p = G1Affine::from_compressed(&c).unwrap();
        keys.push(p);
    }
    for &i in &voters {
        agg += keys[i];
    }
    let sig_bytes: [u8; 96] = unhex(fx["aggSig"].as_str().unwrap()).try_into().unwrap();
    let sig = G2Affine::from_compressed(&sig_bytes).unwrap();
    let msg = unhex(fx["voteHash"].as_str().unwrap());
    let h = <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&msg[..]], DST).to_affine();
    let ok = pairing(&agg.to_affine(), &h) == pairing(&G1Affine::generator(), &sig);
    println!("native check of the recorded vote ({} of {} voters): {}", voters.len(), keys.len(), ok);
    assert!(ok, "the vote does not verify with this message and tag");

    // EIP-2537 encodings: G1 = x || y, G2 = x.c0 || x.c1 || y.c0 || y.c1, each 48-byte element left-padded to 64.
    let g1 = |p: &G1Affine| -> String {
        let u = p.to_uncompressed();
        format!("0x{}{}", hex::encode(pad(&u[0..48])), hex::encode(pad(&u[48..96])))
    };
    let su = sig.to_uncompressed(); // zkcrypto order: x.c1, x.c0, y.c1, y.c0
    let sig_enc = format!(
        "0x{}{}{}{}",
        hex::encode(pad(&su[48..96])),
        hex::encode(pad(&su[0..48])),
        hex::encode(pad(&su[144..192])),
        hex::encode(pad(&su[96..144]))
    );
    let out = serde_json::json!({
        "voteHash": fx["voteHash"],
        "voteRlp": fx["voteRlp"],
        "bitset": fx["bitset"],
        "keys": keys.iter().map(g1).collect::<Vec<_>>(),
        "keysCompressed": validators.iter().map(|v| v["bls"].clone()).collect::<Vec<_>>(),
        "signature": sig_enc,
        "signatureCompressed": fx["aggSig"],
    });
    let path = dir.join("evm/test/fixture.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, serde_json::to_string_pretty(&out).unwrap()).unwrap();
    println!("wrote {}", path.display());
}
