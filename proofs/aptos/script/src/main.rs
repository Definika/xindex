//! Aptos's state verifier's host. Usage, from `proofs/aptos/` (toolchain as `proofs/README.md`):
//!
//! ```text
//! aptos execute [fixtures/synthetic.json]            run the fixture's claims in execute mode
//! aptos vkey                                         print the program key `AptosStateVerifier` is built with
//! aptos prove <update|slots> <input.json> <out.json> Groth16 proof, on SP1_PROVER=network or cuda
//! ```
//!
//! An input file has `fixtures/synthetic.json`'s form, which `fixtures/generate.py` writes; `fixtures/mainnet.json`
//! holds a real update and runs too. Execute mode counts instructions and SP1's prover gas without proving, and checks
//! that the program commits exactly what the statement computes natively, and what the fixture's separate
//! implementation computed. Proving refuses this machine's CPU, as P1's host does.
use serde_json::Value;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};
use std::time::Instant;
use xindex_aptos::{json, verify, Input};

const ELF: Elf = include_elf!("xindex-aptos-program");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("execute") => execute(
            args.get(1)
                .map_or("fixtures/synthetic.json", String::as_str),
        ),
        Some("vkey") => vkey(),
        Some("prove") => prove(&args[1..]),
        _ => {
            eprintln!(
                "usage: aptos execute [input.json] | aptos vkey | aptos prove <update|slots> <input.json> <out.json>"
            );
            std::process::exit(2);
        }
    }
}

fn read(path: &str) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).expect("the input file")).expect("JSON")
}

fn input(kind: &str, f: &Value) -> Input {
    match kind {
        "update" => json::update(f),
        "slots" => json::slots(f),
        _ => {
            eprintln!("the claim is `update` or `slots`");
            std::process::exit(2);
        }
    }
}

fn stdin(input: &Input) -> SP1Stdin {
    let mut stdin = SP1Stdin::new();
    stdin.write(input);
    stdin
}

fn execute(path: &str) {
    let f = read(path);
    let client = ProverClient::from_env();
    for kind in ["update", "slots"] {
        if f.get(kind).is_none() {
            continue;
        }
        let input = input(kind, &f);
        let expected = verify(&input)
            .expect("the statement must hold natively first")
            .abi_encode();
        assert_eq!(
            expected,
            json::hex(f["public_values"][kind].as_str().unwrap()),
            "the statement must compute what the fixture's separate implementation did"
        );
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
        let (hops, validators) = match &input {
            Input::Update { trusted, hops } | Input::Slots { trusted, hops, .. } => {
                (hops.len(), trusted.validators.len())
            }
        };
        println!(
            "{kind}: {hops} hops, {validators} validators: {} instructions, {} prover gas, {seconds:.1} s",
            report.total_instruction_count(),
            report.gas().unwrap_or(0),
        );
        println!("  public values 0x{}", hex::encode(public_values.to_vec()));
    }
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
    let [kind, input_path, out_path] = args else {
        eprintln!("usage: aptos prove <update|slots> <input.json> <out.json>");
        std::process::exit(2);
    };
    let input = input(kind, &read(input_path));
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
