//! P1's host. Usage, from `proofs/` (see its README for the toolchain):
//!
//! ```text
//! p1 execute --synthetic <validators> <gap> <headers>   run the program on a synthetic chain, in execute mode
//! p1 execute <input.bin>                                 run it on an input file (bincode of `Input`)
//! p1 vkey                                                print the program key a verifier contract is built with
//! p1 prove <input.bin> <out.json>                        Groth16 proof for `update`, on SP1_PROVER=network or cuda
//! ```
//!
//! Execute mode counts instructions and SP1's prover gas without proving, and checks that the program commits exactly
//! what the statement computes natively. Proving refuses this machine's CPU, as the prototype's `slice` does.
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};
use std::time::Instant;
use xindex_finality::{testkit, verify, Input};

const ELF: Elf = include_elf!("xindex-p1-program");

/// The synthetic chain's anchor epoch: Fulu, so the domain is known.
const E0: u64 = 411_400;
/// Synthetic validators hold 2,048 ETH, the most an Electra validator can.
const BALANCE: u64 = 2_048_000_000_000;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("execute") => execute(&args[1..]),
        Some("vkey") => vkey(),
        Some("prove") => prove(&args[1..]),
        _ => {
            eprintln!("usage: p1 execute --synthetic <validators> <gap> <headers> | p1 execute <input.bin> | p1 vkey | p1 prove <input.bin> <out.json>");
            std::process::exit(2);
        }
    }
}

fn synthetic(args: &[String]) -> Input {
    let arg = |i: usize, default: u64| {
        args.get(i)
            .map(|a| a.parse().expect("a number"))
            .unwrap_or(default)
    };
    let (n, gap, headers) = (arg(0, 1_000) as usize, arg(1, 1), arg(2, 64));
    let chain = testkit::chain(n, BALANCE);
    // Everyone signs: the most work the statement can be given for this many validators.
    let signers: Vec<u32> = (0..n as u32).collect();
    testkit::build(&chain, E0, gap, &signers, headers)
}

fn read(path: &str) -> Input {
    bincode::deserialize(&std::fs::read(path).expect("the input file")).expect("an Input")
}

fn stdin(input: &Input) -> SP1Stdin {
    let mut stdin = SP1Stdin::new();
    stdin.write(input);
    stdin
}

fn execute(args: &[String]) {
    let input = match args.first().map(String::as_str) {
        Some("--synthetic") => synthetic(&args[1..]),
        Some(path) => read(path),
        None => synthetic(&[]),
    };
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
    println!(
        "validators {}, signers {} + {}, headers {}: {} instructions, {} prover gas, {seconds:.1} s",
        input.validators.len(),
        input.justification.iter().map(|a| a.signers.len()).sum::<usize>(),
        input.finalization.iter().map(|a| a.signers.len()).sum::<usize>(),
        input.exec_headers.len(),
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
    let (input_path, out_path) = match args {
        [input, out] => (input.as_str(), out.as_str()),
        _ => {
            eprintln!("usage: p1 prove <input.bin> <out.json>");
            std::process::exit(2);
        }
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
