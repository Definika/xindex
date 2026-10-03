//! Finds which of devnet's BLS keys signed its Alpenglow genesis certificate, and writes them to
//! `fixtures/genesis_signers.json`, which `tests/cert.rs` verifies the certificate against.
//!
//! The certificate (slot 504,148,999, epoch 1167) was checked against epoch 1167's ranked set, whose stakes public RPC
//! no longer serves; today's vote accounts carry the same keys but other stakes, so the ranks may differ. The bitmap
//! says how many signed, and the aggregate must equal the sum of exactly those keys: this pairs each key with the
//! payload's hash once, then searches the key sets of that size for the one whose product in GT is the signature's
//! pairing, which only the true set can be.
//!
//! cargo run --release --example find_genesis_signers

use bls12_381::{G1Affine, Gt};
use serde_json::Value;
use std::fs;
use xindex_solana_state::cert::{
    block_payload, decode_base2, per_key_pairings, signature, signature_pairing, GENESIS,
};

fn bytes(v: &Value) -> Vec<u8> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|b| b.as_u64().unwrap() as u8)
        .collect()
}

fn main() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures");
    let d: Value =
        serde_json::from_str(&fs::read_to_string(format!("{dir}/devnet.json")).unwrap()).unwrap();
    let cert = &d["genesisCert"];
    let slot = cert["block"]["slot"].as_u64().unwrap();
    let block_id: [u8; 32] = bytes(&cert["block"]["blockId"]).try_into().unwrap();
    let shred_version = d["shredVersions"][0].as_u64().unwrap() as u16;
    let sig = signature(&bytes(&cert["signature"]["signature"])).unwrap();
    let bitmap = bytes(&cert["signature"]["bitmap"]);
    let ranks = decode_base2(&bitmap, usize::from(u16::MAX)).unwrap();

    let candidates: Vec<(String, G1Affine)> = d["voteAccounts"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| {
            let hex = v["blsPubkeyCompressed"].as_str()?;
            let raw: [u8; 48] = (0..48)
                .map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap())
                .collect::<Vec<_>>()
                .try_into()
                .unwrap();
            let key = Option::<G1Affine>::from(G1Affine::from_compressed(&raw))?;
            Some((v["votePubkey"].as_str().unwrap().to_string(), key))
        })
        .collect();
    let payload = block_payload(GENESIS, slot, &block_id, shred_version);
    let keys: Vec<G1Affine> = candidates.iter().map(|c| c.1).collect();
    let pairs = per_key_pairings(&keys, &payload);
    let target = signature_pairing(&sig);
    let k = ranks.len();
    println!(
        "{} of {} ranks signed; {} candidate keys; searching sets of {k}",
        k,
        bitmap[1],
        candidates.len()
    );

    let n = pairs.len();
    let mut found = Vec::new();
    let mut idx: Vec<usize> = (0..k).collect();
    loop {
        let product = idx.iter().fold(Gt::identity(), |acc, &i| acc + pairs[i]);
        if product == target {
            found.push(idx.clone());
        }
        // Next combination of k out of n, in lexicographic order.
        let mut i = k;
        while i > 0 && idx[i - 1] == n - k + i - 1 {
            i -= 1;
        }
        if i == 0 {
            break;
        }
        idx[i - 1] += 1;
        for j in i..k {
            idx[j] = idx[j - 1] + 1;
        }
    }
    assert_eq!(found.len(), 1, "exactly one key set signs: {found:?}");
    let signers: Vec<&str> = found[0].iter().map(|&i| candidates[i].0.as_str()).collect();
    println!("signers: {signers:?}");
    let out = serde_json::json!({
        "slot": slot,
        "shredVersion": shred_version,
        "signerVotePubkeys": signers,
    });
    fs::write(
        format!("{dir}/genesis_signers.json"),
        serde_json::to_string_pretty(&out).unwrap() + "\n",
    )
    .unwrap();
}
