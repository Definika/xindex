//! M4 of the proving prototype: proves one representative slice of the finality proof, the key-aggregation step, and
//! reports its prover gas and the wall time, so the price and time per billion prover gas can be read off and scaled
//! to the whole proof. It refuses to prove on this machine's CPU: run it with SP1_PROVER=network (the Succinct prover
//! network, NETWORK_PRIVATE_KEY set) or SP1_PROVER=cuda on a rented GPU.
//!
//!   SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... cargo run --release --bin slice -- 900000
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, SP1Stdin,
};
use std::time::Instant;

const ELF: Elf = include_elf!("xindex-bench-program");

fn main() {
    let mode = std::env::var("SP1_PROVER").unwrap_or_default();
    if mode != "network" && mode != "cuda" && mode != "mock" {
        eprintln!("refusing to prove with SP1_PROVER={mode:?}: set network or cuda (mock only checks the flow)");
        std::process::exit(2);
    }
    let n: u32 = std::env::args().nth(1).map(|a| a.parse().expect("n")).unwrap_or(900_000);
    let client = ProverClient::from_env();

    let mut stdin = SP1Stdin::new();
    stdin.write(&1u32); // the key-aggregation mode
    stdin.write(&n);
    let (_, report) = client.execute(ELF, stdin.clone()).run().expect("execution failed");
    let gas = report.gas().unwrap_or(0);
    println!("slice: {n} key additions, {} instructions, {gas} prover gas", report.total_instruction_count());

    let pk = client.setup(ELF).expect("setup");
    let start = Instant::now();
    let proof = client.prove(&pk, stdin).compressed().run().expect("proving failed");
    let secs = start.elapsed().as_secs_f64();
    println!("proved (compressed) in {secs:.1} s: {:.2} s per billion prover gas", secs / (gas as f64 / 1e9));
    let _ = proof;
    println!("scale: about 11B prover gas for a two-epoch finality proof, about 6.7B for one epoch");
}
