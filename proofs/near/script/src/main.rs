//! The NEAR state verifier's host. Usage, from `proofs/near/` (toolchain as `proofs/README.md`):
//!
//! ```text
//! near execute [fixtures/mainnet.json]   run the program on mainnet's chain, in execute mode
//! near vkey                              print the program key `NearStateVerifier` is built with
//! near prove <input.json> <out.json>     Groth16 proof for `update`, on SP1_PROVER=network or cuda
//! ```
//!
//! Execute mode counts instructions and SP1's prover gas without proving, and checks that the program commits exactly
//! what the statement computes natively. Proving refuses this machine's CPU, as P1's host does.
use serde_json::Value;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};
use std::time::Instant;
use xindex_near_finality::*;

const ELF: Elf = include_elf!("xindex-near-program");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("execute") => execute(args.get(1).map_or("fixtures/mainnet.json", String::as_str)),
        Some("vkey") => vkey(),
        Some("prove") => prove(&args[1..]),
        _ => {
            eprintln!(
                "usage: near execute [input.json] | near vkey | near prove <input.json> <out.json>"
            );
            std::process::exit(2);
        }
    }
}

fn hex32(v: &Value) -> Hash {
    hex::decode(v.as_str().unwrap().trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap()
}

fn producers(v: &Value) -> Vec<Producer> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| Producer {
            account_id: p["account_id"].as_str().unwrap().to_string(),
            public_key: hex32(&p["public_key"]),
            stake: p["stake"].as_str().unwrap().parse().unwrap(),
        })
        .collect()
}

fn block(v: &Value) -> LightClientBlock {
    let l = &v["inner_lite"];
    LightClientBlock {
        prev_block_hash: hex32(&v["prev_block_hash"]),
        next_block_inner_hash: hex32(&v["next_block_inner_hash"]),
        inner_lite: InnerLite {
            height: l["height"].as_u64().unwrap(),
            epoch_id: hex32(&l["epoch_id"]),
            next_epoch_id: hex32(&l["next_epoch_id"]),
            prev_state_root: hex32(&l["prev_state_root"]),
            outcome_root: hex32(&l["outcome_root"]),
            timestamp: l["timestamp"].as_u64().unwrap(),
            next_bp_hash: hex32(&l["next_bp_hash"]),
            block_merkle_root: hex32(&l["block_merkle_root"]),
        },
        inner_rest_hash: hex32(&v["inner_rest_hash"]),
        next_bps: v["next_bps"].as_array().map(|_| producers(&v["next_bps"])),
        approvals_after_next: v["approvals_after_next"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| {
                a.as_str().map(|s| {
                    Sig(hex::decode(s.trim_start_matches("0x"))
                        .unwrap()
                        .try_into()
                        .unwrap())
                })
            })
            .collect(),
    }
}

/// The statement's input from a fixture in `fixtures/mainnet.json`'s form: the anchor and the blocks after it.
fn read(path: &str) -> Input {
    let f: Value = serde_json::from_str(&std::fs::read_to_string(path).expect("the input file"))
        .expect("JSON");
    Input {
        epoch_id: hex32(&f["anchor"]["epoch_id"]),
        producers: producers(&f["anchor"]["producers"]),
        blocks: f["blocks"].as_array().unwrap().iter().map(block).collect(),
    }
}

fn stdin(input: &Input) -> SP1Stdin {
    let mut stdin = SP1Stdin::new();
    stdin.write(input);
    stdin
}

fn execute(path: &str) {
    let input = read(path);
    let expected = verify(&input)
        .expect("the statement must hold natively first")
        .abi_encode();
    let client = ProverClient::from_env();
    let started = Instant::now();
    let (public_values, report) = client
        .execute(ELF, stdin(&input))
        .run()
        .expect("execution failed");
    let seconds = started.elapsed().as_secs_f64();
    assert_eq!(
        public_values.to_vec(),
        expected,
        "the program must commit what the statement computes"
    );
    let signatures: usize = input
        .blocks
        .iter()
        .map(|b| {
            b.approvals_after_next
                .iter()
                .take(64 * 1024)
                .filter(|a| a.is_some())
                .count()
        })
        .sum();
    println!(
        "{} blocks, {signatures} approvals: {} instructions, {} prover gas, {seconds:.1} s",
        input.blocks.len(),
        report.total_instruction_count(),
        report.gas().unwrap_or(0),
    );
    println!("public values 0x{}", hex::encode(public_values.to_vec()));
}

fn vkey() {
    let client = ProverClient::from_env();
    let pk = client.setup(ELF).expect("setup");
    println!("{}", pk.verifying_key().bytes32());
}

fn prove(args: &[String]) {
    let mode = std::env::var("SP1_PROVER").unwrap_or_default();
    if mode != "network" && mode != "cuda" {
        eprintln!("refusing to prove with SP1_PROVER={mode:?}: set network or cuda");
        std::process::exit(2);
    }
    let [input_path, out_path] = args else {
        eprintln!("usage: near prove <input.json> <out.json>");
        std::process::exit(2);
    };
    let input = read(input_path);
    verify(&input).expect("the statement must hold natively first");
    let client = ProverClient::from_env();
    let pk = client.setup(ELF).expect("setup");
    let started = Instant::now();
    let proof = client
        .prove(&pk, stdin(&input))
        .groth16()
        .run()
        .expect("proving failed");
    let out = format!(
        "{{\"publicValues\":\"0x{}\",\"proof\":\"0x{}\",\"vkey\":\"{}\",\"seconds\":{:.1}}}\n",
        hex::encode(proof.public_values.to_vec()),
        hex::encode(proof.bytes()),
        pk.verifying_key().bytes32(),
        started.elapsed().as_secs_f64()
    );
    std::fs::write(out_path, out).expect("the output file");
    println!("wrote {out_path}");
}
