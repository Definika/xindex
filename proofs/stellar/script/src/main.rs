//! The Stellar state proof's host. Usage, from `proofs/stellar/`:
//!
//! ```text
//! stellar-proof execute --synthetic [orgs] [gap]            the program on a synthetic Tier 1's attest, in execute mode
//! stellar-proof execute --mainnet <fixture.json> [--all]    the measurement build on a real mainnet ledger: the
//!                                                           fewest signatures that satisfy Tier 1, or all of them
//! stellar-proof vkey                                        the program key `StellarStateVerifier` is built with
//! stellar-proof prove <input.json> <out.json>               a Groth16 proof, on SP1_PROVER=network or cuda only
//! ```
//!
//! Execute mode counts instructions and SP1's prover gas without proving, and checks that the program commits exactly
//! what the statement computes natively. No vault exists on mainnet yet, so a real ledger runs through the measurement
//! build, which takes the real call's own event in place of the vault's `attest` (`program/src/measure.rs`); the
//! program itself runs on the synthetic attest, with the same number of signatures.
use serde_json::Value;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1Stdin,
};
use std::time::Instant;
use xindex_stellar::{
    keccak256, stellar_xdr::ContractEvent, testkit, verify, verify_event, xdr, Input, Output,
};

const ELF: Elf = include_elf!("xindex-stellar-program");
const MEASURE: Elf = include_elf!("xindex-stellar-measure");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("execute") => execute(&args[1..]),
        Some("vkey") => vkey(),
        Some("prove") => prove(&args[1..]),
        _ => {
            eprintln!(
                "usage: stellar-proof execute --synthetic [orgs] [gap] | execute --mainnet <fixture.json> [--all] \
                 | vkey | prove <input.json> <out.json>"
            );
            std::process::exit(2);
        }
    }
}

fn bytes(v: &Value) -> Vec<u8> {
    hex::decode(v.as_str().expect("hex")).expect("hex")
}

/// The fewest envelopes that satisfy a two-level quorum set like Tier 1's: each inner set's threshold of its signers,
/// inner set by inner set, until the top threshold is met.
fn minimal(quorum_set: &[u8], envelopes: Vec<Vec<u8>>) -> Vec<Vec<u8>> {
    use xindex_stellar::stellar_xdr::{NodeId, PublicKey, ScpEnvelope, ScpQuorumSet};
    let q: ScpQuorumSet = xdr::decode(quorum_set, "quorum set").unwrap();
    let signer = |raw: &Vec<u8>| {
        let e: ScpEnvelope = xdr::decode(raw, "envelope").unwrap();
        let NodeId(PublicKey::PublicKeyTypeEd25519(k)) = e.statement.node_id;
        k.0
    };
    let mut out = Vec::new();
    for inner in q.inner_sets.iter().take(q.threshold as usize) {
        let members = xindex_stellar::quorum::validators(inner);
        out.extend(
            envelopes
                .iter()
                .filter(|e| members.contains(&signer(e)))
                .take(inner.threshold as usize)
                .cloned(),
        );
    }
    out
}

/// The real ledger of `fixtures/mainnet.json`, with its call's own event as the expected one: every envelope, or with
/// `minimal`, the fewest that satisfy the quorum set.
fn mainnet(path: &str, all: bool) -> (Input, Vec<u8>) {
    let f: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture")).expect("JSON");
    let events: Vec<Vec<u8>> = f["events"].as_array().unwrap().iter().map(bytes).collect();
    let event_index = f["eventIndex"].as_u64().unwrap() as u32;
    let expected = events[event_index as usize].clone();
    let quorum_set = bytes(&f["quorumSet"]);
    let mut envelopes: Vec<Vec<u8>> = f["envelopes"]
        .as_array()
        .unwrap()
        .iter()
        .map(bytes)
        .collect();
    if !all {
        envelopes = minimal(&quorum_set, envelopes);
    }
    let input = Input {
        network_id: bytes(&f["networkId"]).try_into().unwrap(),
        quorum_set,
        envelopes,
        tx_set: bytes(&f["txSet"]),
        headers: f["headers"].as_array().unwrap().iter().map(bytes).collect(),
        result_set: bytes(&f["resultSet"]),
        result_index: f["resultIndex"].as_u64().unwrap() as u32,
        return_value: bytes(&f["returnValue"]),
        events,
        event_index,
        vault_id: [0; 32],
        record: Vec::new(),
    };
    (input, expected)
}

fn report(label: &str, public_values: &[u8], report: &sp1_sdk::ExecutionReport, seconds: f64) {
    println!(
        "{label}: {} instructions, {} prover gas, {seconds:.1} s",
        report.total_instruction_count(),
        report.gas().unwrap_or(0),
    );
    let mut sections: Vec<_> = report.cycle_tracker.iter().collect();
    sections.sort_by(|a, b| b.1.cmp(a.1));
    for (section, instructions) in sections {
        println!("  {section}: {instructions} instructions");
    }
    println!("public values 0x{}", hex::encode(public_values));
}

fn execute(args: &[String]) {
    let client = ProverClient::from_env();
    match args.first().map(String::as_str) {
        Some("--mainnet") => {
            let path = args.get(1).expect("the fixture's path");
            let all = args.get(2).map(String::as_str) == Some("--all");
            let (input, expected_bytes) = mainnet(path, all);
            let expected: ContractEvent = xdr::decode(&expected_bytes, "expected").unwrap();
            let proven =
                verify_event(&input, &expected).expect("the statement must hold natively first");
            let native = Output {
                proven,
                vault_id: expected
                    .contract_id
                    .as_ref()
                    .map(|c| c.0 .0)
                    .unwrap_or([0; 32]),
                record_hash: keccak256(&expected_bytes),
            }
            .abi_encode();
            let mut stdin = SP1Stdin::new();
            stdin.write(&input);
            stdin.write(&expected_bytes);
            let started = Instant::now();
            let (public_values, r) = client
                .execute(MEASURE, stdin)
                .run()
                .expect("execution failed");
            assert_eq!(
                public_values.to_vec(),
                native,
                "the build must commit what the statement computes"
            );
            let label = format!(
                "mainnet ledger, {} signatures, {} bytes of transaction set, {} of results",
                input.envelopes.len(),
                input.tx_set.len(),
                input.result_set.len()
            );
            report(
                &label,
                public_values.as_slice(),
                &r,
                started.elapsed().as_secs_f64(),
            );
        }
        _ => {
            let arg = |i: usize, d: u64| {
                args.get(i)
                    .map(|a| a.parse().expect("a number"))
                    .unwrap_or(d)
            };
            let (orgs, gap) = (arg(1, 7) as usize, arg(2, 1) as u32);
            let input = testkit::build(orgs, gap);
            let native = verify(&input)
                .expect("the statement must hold natively first")
                .abi_encode();
            let mut stdin = SP1Stdin::new();
            stdin.write(&input);
            let started = Instant::now();
            let (public_values, r) = client.execute(ELF, stdin).run().expect("execution failed");
            assert_eq!(
                public_values.to_vec(),
                native,
                "the program must commit what the statement computes"
            );
            let label = format!(
                "synthetic attest, {} signatures, {gap} header(s)",
                input.envelopes.len()
            );
            report(
                &label,
                public_values.as_slice(),
                &r,
                started.elapsed().as_secs_f64(),
            );
        }
    }
}

fn vkey() {
    let client = ProverClient::from_env();
    let pk = client.setup(ELF).expect("setup");
    println!("{}", pk.verifying_key().bytes32());
}

/// A Groth16 proof of an input given as JSON in the fixture's layout, with the vault's id and record set. Proving
/// refuses this machine's CPU, as P1's host does.
fn prove(args: &[String]) {
    let mode = std::env::var("SP1_PROVER").unwrap_or_default();
    if mode != "network" && mode != "cuda" {
        eprintln!("refusing to prove with SP1_PROVER={mode:?}: set network or cuda");
        std::process::exit(2);
    }
    let (Some(input_path), Some(out)) = (args.first(), args.get(1)) else {
        eprintln!("usage: stellar-proof prove <input.json> <out.json>");
        std::process::exit(2);
    };
    let f: Value = serde_json::from_str(&std::fs::read_to_string(input_path).expect("the input"))
        .expect("JSON");
    let (mut input, _) = mainnet(input_path, false);
    input.vault_id = bytes(&f["vaultId"]).try_into().expect("a 32-byte vault id");
    input.record = bytes(&f["record"]);
    let expected = verify(&input)
        .expect("the statement must hold natively first")
        .abi_encode();
    let client = ProverClient::from_env();
    let pk = client.setup(ELF).expect("setup");
    let mut stdin = SP1Stdin::new();
    stdin.write(&input);
    let started = Instant::now();
    let proof = client
        .prove(&pk, stdin)
        .groth16()
        .run()
        .expect("proving failed");
    assert_eq!(proof.public_values.to_vec(), expected);
    std::fs::write(
        out,
        format!(
            "{{\"publicValues\":\"0x{}\",\"proof\":\"0x{}\",\"vkey\":\"{}\",\"seconds\":{:.1}}}\n",
            hex::encode(proof.public_values.as_slice()),
            hex::encode(proof.bytes()),
            pk.verifying_key().bytes32(),
            started.elapsed().as_secs_f64()
        ),
    )
    .expect("writing the proof");
}
