//! P2's host. Usage, from `proofs/p2/` (see proofs/README.md, "P2", for the toolchain):
//!
//! ```text
//! p2 execute --synthetic <validators> <gap> <headers> [exited]   run the guest on a synthetic chain, in execute mode
//! p2 execute <input.bin>                                 run it on an input file (bincode of `Input`, as for P1)
//! p2 image-id                                            print the image id a verifier contract is built with
//! p2 prove <input.bin> <out.json>                        Groth16 proof for `update`, with Bonsai or on a CUDA GPU
//! ```
//!
//! Execute mode counts cycles without proving, and checks that the guest commits exactly what the statement computes
//! natively, which is also exactly what P1's program commits. Proving refuses this machine's CPU, as P1's host does.
use risc0_zkvm::{default_executor, default_prover, Digest, ExecutorEnv, ProverOpts};
use std::time::Instant;
use xindex_finality::{beacon::NETWORK, testkit, verify, Input};
use xindex_p2_methods::{XINDEX_P2_GUEST_ELF, XINDEX_P2_GUEST_ID};

/// The synthetic chain's anchor epoch: Fulu, so the domain is known.
const E0: u64 = 411_400;
/// Synthetic validators hold 2,048 ETH, the most an Electra validator can.
const BALANCE: u64 = 2_048_000_000_000;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Each network's guest is its own image id, so every run says which one this host embeds.
    eprintln!("P2 for {NETWORK}");
    match args.first().map(String::as_str) {
        Some("execute") => execute(&args[1..]),
        Some("image-id") => println!("0x{}", hex::encode(image_id())),
        Some("prove") => prove(&args[1..]),
        _ => {
            eprintln!("usage: p2 execute --synthetic <validators> <gap> <headers> [exited] | p2 execute <input.bin> | p2 image-id | p2 prove <input.bin> <out.json>");
            std::process::exit(2);
        }
    }
}

/// The image id as the verifier contract takes it, a bytes32.
fn image_id() -> [u8; 32] {
    let digest = Digest::from(XINDEX_P2_GUEST_ID);
    digest.as_bytes().try_into().expect("32 bytes")
}

fn synthetic(args: &[String]) -> Input {
    let arg = |i: usize, default: u64| {
        args.get(i)
            .map(|a| a.parse().expect("a number"))
            .unwrap_or(default)
    };
    let (n, gap, headers, exited) = (
        arg(0, 1_000) as usize,
        arg(1, 1),
        arg(2, 64),
        arg(3, 0) as usize,
    );
    let mut chain = testkit::chain(n, BALANCE);
    // The last `exited` validators left before the anchor, as most of mainnet's registry has.
    for v in chain.validators[n - exited..].iter_mut() {
        v.exit_epoch = E0 - 1;
    }
    // Everyone else signs: the most work the statement can be given for this many validators.
    let signers: Vec<u32> = (0..(n - exited) as u32).collect();
    testkit::build(&chain, E0, gap, &signers, headers)
}

fn read(path: &str) -> Vec<u8> {
    std::fs::read(path).expect("the input file")
}

/// The guest reads the input as P1's program does: the bincode of `Input`, here as raw bytes on its stdin.
fn env(bytes: &[u8]) -> ExecutorEnv<'_> {
    ExecutorEnv::builder()
        .write_slice(bytes)
        .build()
        .expect("an executor environment")
}

fn execute(args: &[String]) {
    let bytes = match args.first().map(String::as_str) {
        Some("--synthetic") => bincode::serialize(&synthetic(&args[1..])).expect("bincode"),
        Some(path) => read(path),
        None => bincode::serialize(&synthetic(&[])).expect("bincode"),
    };
    let input: Input = bincode::deserialize(&bytes).expect("an Input");
    let expected = verify(&input)
        .expect("the statement must hold natively first")
        .abi_encode();
    let started = Instant::now();
    let session = default_executor()
        .execute(env(&bytes), XINDEX_P2_GUEST_ELF)
        .expect("execution failed");
    let seconds = started.elapsed().as_secs_f64();
    assert_eq!(
        session.journal.bytes, expected,
        "the guest must commit what the statement computes"
    );
    let padded: u64 = session.segments.iter().map(|s| 1u64 << s.po2).sum();
    println!(
        "registry {} bytes, signers {} + {}, headers {}: {} cycles, {} segments, {} proving cycles, {seconds:.1} s",
        input.registry.len(),
        input.justification.iter().map(|a| a.signers.len()).sum::<usize>(),
        input.finalization.iter().map(|a| a.signers.len()).sum::<usize>(),
        input.exec_headers.len(),
        session.cycles(),
        session.segments.len(),
        padded,
    );
    println!("journal 0x{}", hex::encode(&session.journal.bytes));
}

fn prove(args: &[String]) {
    let bonsai = std::env::var("RISC0_PROVER").as_deref() == Ok("bonsai");
    if !bonsai && !cfg!(feature = "cuda") {
        eprintln!("refusing to prove on this CPU: set RISC0_PROVER=bonsai (with BONSAI_API_KEY and BONSAI_API_URL), or build with --features cuda");
        std::process::exit(2);
    }
    let (input_path, out_path) = match args {
        [input, out] => (input.as_str(), out.as_str()),
        _ => {
            eprintln!("usage: p2 prove <input.bin> <out.json>");
            std::process::exit(2);
        }
    };
    let bytes = read(input_path);
    let input: Input = bincode::deserialize(&bytes).expect("an Input");
    let expected = verify(&input)
        .expect("the statement must hold natively first")
        .abi_encode();
    let started = Instant::now();
    let receipt = default_prover()
        .prove_with_opts(env(&bytes), XINDEX_P2_GUEST_ELF, &ProverOpts::groth16())
        .expect("proving failed")
        .receipt;
    receipt
        .verify(XINDEX_P2_GUEST_ID)
        .expect("the receipt verifies");
    assert_eq!(
        receipt.journal.bytes, expected,
        "the journal is the statement's"
    );
    let groth16 = receipt.inner.groth16().expect("a Groth16 receipt");
    // What RISC Zero's Solidity verifier takes: the selector of its parameters, then the seal.
    let mut seal = groth16.verifier_parameters.as_bytes()[..4].to_vec();
    seal.extend_from_slice(&groth16.seal);
    let out = format!(
        "{{\"journal\":\"0x{}\",\"seal\":\"0x{}\",\"imageId\":\"0x{}\",\"seconds\":{:.1}}}\n",
        hex::encode(&receipt.journal.bytes),
        hex::encode(&seal),
        hex::encode(image_id()),
        started.elapsed().as_secs_f64()
    );
    std::fs::write(out_path, out).expect("the proof file");
    println!("wrote {out_path}");
}
