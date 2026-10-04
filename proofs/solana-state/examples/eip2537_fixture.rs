//! Writes devnet's real Alpenglow genesis certificate in the encodings Ethereum's BLS12-381 precompiles take (EIP-2537),
//! for `test/SolanaCertificate.t.sol`: the 43-byte payload its signers signed, their keys in signing order, each
//! uncompressed and compressed, and the aggregate signature.
//!
//! EIP-2537 pads each base-field element to 64 bytes and writes an Fp2 element `c0` first. The zcash encoding
//! `bls12_381` and `getAgGenesisCert` use writes 48 bytes and `c1` first, so G2 coordinates swap halves here.
//!
//! cargo run --release --example eip2537_fixture -- ../../test/fixtures/solana/genesis-cert.json

use bls12_381::{G1Affine, G2Affine};
use serde_json::{json, Value};
use std::fs;
use xindex_solana_state::cert::{block_payload, decode_base2, signature, GENESIS};

fn fixture(name: &str) -> Value {
    let path = format!("{}/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn bytes(v: &Value) -> Vec<u8> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|b| b.as_u64().unwrap() as u8)
        .collect()
}

fn hex(b: &[u8]) -> String {
    format!(
        "0x{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    )
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

/// One base-field element, 48 bytes big-endian, padded to EIP-2537's 64.
fn fp(b: &[u8]) -> Vec<u8> {
    assert_eq!(b.len(), 48);
    [&[0u8; 16][..], b].concat()
}

fn g1(p: &G1Affine) -> Vec<u8> {
    let u = p.to_uncompressed();
    [fp(&u[..48]), fp(&u[48..])].concat()
}

/// zcash order is x.c1, x.c0, y.c1, y.c0; EIP-2537's is x.c0, x.c1, y.c0, y.c1.
fn g2(p: &G2Affine) -> Vec<u8> {
    let u = p.to_uncompressed();
    [fp(&u[48..96]), fp(&u[..48]), fp(&u[144..]), fp(&u[96..144])].concat()
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: eip2537_fixture <out.json>");
    let d = fixture("devnet.json");
    let s = fixture("genesis_signers.json");
    let cert = &d["genesisCert"];
    let slot = cert["block"]["slot"].as_u64().unwrap();
    let block_id: [u8; 32] = bytes(&cert["block"]["blockId"]).try_into().unwrap();
    let shred_version = s["shredVersion"].as_u64().unwrap() as u16;
    let bitmap = bytes(&cert["signature"]["bitmap"]);
    let ranks = decode_base2(&bitmap, 17).unwrap();
    let sig = signature(&bytes(&cert["signature"]["signature"])).unwrap();

    let mut keys = vec![];
    let mut compressed = vec![];
    for p in s["signerVotePubkeys"].as_array().unwrap() {
        let v = d["voteAccounts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["votePubkey"] == *p)
            .unwrap();
        let c = unhex(v["blsPubkeyCompressed"].as_str().unwrap());
        let k = Option::<G1Affine>::from(G1Affine::from_compressed(&c.clone().try_into().unwrap()))
            .unwrap();
        keys.push(hex(&g1(&k)));
        compressed.push(hex(&c));
    }
    assert_eq!(
        keys.len(),
        ranks.len(),
        "one key for each rank the bitmap sets"
    );

    let doc = json!({
        "note": "Solana devnet's Alpenglow genesis certificate (getAgGenesisCert, 3 October 2026), re-encoded for EIP-2537 by proofs/solana-state/examples/eip2537_fixture.rs. The signers are the 11 of epoch 1167's 17 ranks that examples/find_genesis_signers.rs found, in rank order.",
        "slot": slot,
        "blockId": hex(&block_id),
        "shredVersion": shred_version,
        "bitmap": hex(&bitmap),
        "ranks": ranks,
        "payload": hex(&block_payload(GENESIS, slot, &block_id, shred_version)),
        "signerVotePubkeys": s["signerVotePubkeys"],
        "keys": keys,
        "keysCompressed": compressed,
        "signature": hex(&g2(&sig)),
    });
    fs::write(&out, serde_json::to_string_pretty(&doc).unwrap() + "\n").unwrap();
    println!("wrote {out}");
}
