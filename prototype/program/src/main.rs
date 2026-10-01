//! M1 of the proving prototype: the zkVM cost of each primitive a proof of Ethereum finality is made of. The host runs
//! it in execute mode only, which counts cycles without proving. Each mode repeats one primitive `n` times, so the
//! cycles of a mode, less those of the same mode at n = 0, divided by n, is that primitive's cost.
#![no_main]
sp1_zkvm::entrypoint!(main);

use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{
    multi_miller_loop, G1Affine, G1Projective, G2Affine, G2Prepared, G2Projective,
};
use group::{Curve, Group};
use sha2::{Digest, Sha256};

/// Ethereum's BLS signature domain separation tag (proof of possession scheme).
const DST: &[u8] = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

pub fn main() {
    let mode = sp1_zkvm::io::read::<u32>();
    let n = sp1_zkvm::io::read::<u32>();
    match mode {
        // SHA-256 over n 64-byte blocks: n compressions plus one for the padding.
        0 => {
            let data = vec![0x5au8; 64 * n as usize];
            let digest = Sha256::digest(&data);
            sp1_zkvm::io::commit_slice(&digest);
        }
        // Aggregating public keys: n additions of G1 points, as in summing an attestation's signers.
        1 => {
            let g = G1Projective::generator();
            let mut point = g;
            let mut acc = G1Projective::identity();
            for _ in 0..n {
                acc += point;
                point += g;
            }
            sp1_zkvm::io::commit_slice(&acc.to_affine().to_compressed());
        }
        // Reading n compressed public keys with every check, as a key from an unchecked source must be.
        2 => {
            let keys = sp1_zkvm::io::read::<Vec<Vec<u8>>>();
            let mut acc = G1Projective::identity();
            for key in keys.iter() {
                let bytes: [u8; 48] = key.as_slice().try_into().unwrap();
                acc += G1Affine::from_compressed(&bytes).unwrap();
            }
            sp1_zkvm::io::commit_slice(&acc.to_affine().to_compressed());
        }
        // Reading n uncompressed public keys without the subgroup check, as keys from a committed validator set may be.
        3 => {
            let keys = sp1_zkvm::io::read::<Vec<Vec<u8>>>();
            let mut acc = G1Projective::identity();
            for key in keys.iter() {
                let bytes: [u8; 96] = key.as_slice().try_into().unwrap();
                acc += G1Affine::from_uncompressed_unchecked(&bytes).unwrap();
            }
            sp1_zkvm::io::commit_slice(&acc.to_affine().to_compressed());
        }
        // n aggregate signature checks, e(pk, H(m)) == e(g1, sig), each hashing its 32-byte signing root to G2.
        4 => {
            let pk = sp1_zkvm::io::read::<Vec<u8>>();
            let sig = sp1_zkvm::io::read::<Vec<u8>>();
            let msg = sp1_zkvm::io::read::<Vec<u8>>();
            let pk = G1Affine::from_compressed(&pk.as_slice().try_into().unwrap()).unwrap();
            let sig = G2Affine::from_compressed(&sig.as_slice().try_into().unwrap()).unwrap();
            let mut ok = true;
            for _ in 0..n {
                let h = <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&msg[..]], DST).to_affine();
                let neg_g1 = -G1Affine::generator();
                let result = multi_miller_loop(&[(&pk, &G2Prepared::from(h)), (&neg_g1, &G2Prepared::from(sig))])
                    .final_exponentiation();
                ok &= bool::from(result.is_identity());
            }
            assert!(ok, "a signature failed to verify");
            sp1_zkvm::io::commit(&ok);
        }
        // The swap-or-not shuffle of an n-long index list, 90 rounds, as the beacon chain assigns committees
        // (the list algorithm of the consensus clients, n / 2 swaps and about n / 256 hashes per round).
        5 => {
            let mut list: Vec<u32> = (0..n).collect();
            shuffle_list(&mut list, [7u8; 32], 90);
            let mut h = Sha256::new();
            for x in list.iter().take(64) {
                h.update(x.to_le_bytes());
            }
            sp1_zkvm::io::commit_slice(&h.finalize());
        }
        _ => panic!("unknown mode"),
    }
}

fn hash_round(seed: &[u8; 32], round: u8, position: u32) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(seed);
    h.update([round]);
    h.update(position.to_le_bytes());
    h.finalize().into()
}

/// The consensus clients' whole-list swap-or-not shuffle (lighthouse's `shuffle_list`, un-shuffling direction).
fn shuffle_list(input: &mut [u32], seed: [u8; 32], rounds: u8) {
    let n = input.len() as u64;
    if n < 2 {
        return;
    }
    for r in (0..rounds).rev() {
        let mut h = Sha256::new();
        h.update(seed);
        h.update([r]);
        let pivot_hash: [u8; 32] = h.finalize().into();
        let pivot = u64::from_le_bytes(pivot_hash[0..8].try_into().unwrap()) % n;

        let mirror = (pivot + 1) >> 1;
        let mut source = hash_round(&seed, r, (pivot >> 8) as u32);
        let mut byte_v = source[((pivot & 0xff) >> 3) as usize];
        for i in 0..mirror {
            let j = pivot - i;
            if j & 0xff == 0xff {
                source = hash_round(&seed, r, (j >> 8) as u32);
            }
            if j & 0x07 == 0x07 {
                byte_v = source[((j & 0xff) >> 3) as usize];
            }
            if (byte_v >> (j & 0x07)) & 0x01 == 1 {
                input.swap(i as usize, j as usize);
            }
        }

        let mirror = (pivot + n + 1) >> 1;
        let end = n - 1;
        source = hash_round(&seed, r, (end >> 8) as u32);
        byte_v = source[((end & 0xff) >> 3) as usize];
        for (k, i) in ((pivot + 1)..mirror).enumerate() {
            let j = end - k as u64;
            if j & 0xff == 0xff {
                source = hash_round(&seed, r, (j >> 8) as u32);
            }
            if j & 0x07 == 0x07 {
                byte_v = source[((j & 0xff) >> 3) as usize];
            }
            if (byte_v >> (j & 0x07)) & 0x01 == 1 {
                input.swap(i as usize, j as usize);
            }
        }
    }
}
