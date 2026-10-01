//! Runs M1 in execute mode: cycles per primitive, no proving. Usage:
//!   CARGO_BUILD_JOBS=2 nice -n 19 cargo run --release --bin bench
use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{G1Affine, G2Affine, G2Projective, Scalar};
use ff::Field;
use group::Curve;
use sha2::Sha256;
use sp1_sdk::{
    blocking::{Prover, ProverClient},
    include_elf, Elf, SP1Stdin,
};

const ELF: Elf = include_elf!("xindex-bench-program");
const DST: &[u8] = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

/// Instructions and SP1's normalized prover gas, which the prover network prices, for one execution.
fn cycles(client: &impl Prover, mode: u32, n: u32, extra: impl Fn(&mut SP1Stdin)) -> (u64, u64) {
    let mut stdin = SP1Stdin::new();
    stdin.write(&mode);
    stdin.write(&n);
    extra(&mut stdin);
    let (_, report) = client.execute(ELF, stdin).run().expect("execution failed");
    (report.total_instruction_count(), report.gas().unwrap_or(0))
}

fn per(client: &impl Prover, name: &str, mode: u32, n: u32, extra: impl Fn(&mut SP1Stdin, u32)) {
    let (base, base_gas) = cycles(client, mode, 0, |s| extra(s, 0));
    let (full, full_gas) = cycles(client, mode, n, |s| extra(s, n));
    let each = (full - base) as f64 / n as f64;
    let each_gas = (full_gas - base_gas) as f64 / n as f64;
    println!("{name:<52} n={n:<5} instructions/item {each:>11.0}  prover gas/item {each_gas:>11.0}");
}

fn keys(n: u32, compressed: bool) -> Vec<Vec<u8>> {
    let mut rng = rand::thread_rng();
    (0..n)
        .map(|_| {
            let p = (G1Affine::generator() * Scalar::random(&mut rng)).to_affine();
            if compressed { p.to_compressed().to_vec() } else { p.to_uncompressed().to_vec() }
        })
        .collect()
}

fn main() {
    let client = ProverClient::from_env();
    println!("SP1 execute mode, cycles (RISC-V instructions)");
    per(&client, "SHA-256 compression", 0, 4096, |_, _| {});
    per(&client, "G1 addition (aggregating a key)", 1, 4096, |_, _| {});
    per(&client, "G1 key read, compressed, fully checked", 2, 256, |s, n| s.write(&keys(n, true)));
    per(&client, "G1 key read, uncompressed, no subgroup check", 3, 1024, |s, n| s.write(&keys(n, false)));

    let mut rng = rand::thread_rng();
    let sk = Scalar::random(&mut rng);
    let pk = (G1Affine::generator() * sk).to_affine().to_compressed().to_vec();
    let msg = vec![0x42u8; 32];
    let h = <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&msg[..]], DST);
    let sig = G2Affine::from(h * sk).to_compressed().to_vec();
    per(&client, "swap-or-not shuffle, per index (90 rounds)", 5, 65536, |_, _| {});
    per(&client, "aggregate signature check (hash to G2 + 2 pairings)", 4, 8, |s, _| {
        s.write(&pk);
        s.write(&sig);
        s.write(&msg);
    });
}
