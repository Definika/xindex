//! P2 on Solana (Stage B spec, section 11): the twin of `RiscZeroFinalityVerifier.sol`. The same light client as P1,
//! `ethereum_verifier`'s core, advanced by RISC Zero proofs of the same statement with the same public values. Only
//! the check of a proof differs: RISC Zero v3.0's Groth16 seal over the receipt claim of the image `key`, whose journal
//! is the public values, passed by their SHA-256 as `RiscZeroFinalityVerifier._verifyProof` passes them
//! (`xindex_core::risc0`, over Solana's syscalls).
//!
//! Every instruction is P1's, with these differences: the key in the state is P2's image id, and a proof is a seal of
//! 260 bytes, RISC Zero's selector then the Groth16 points, as `p2 prove` writes it. So `update` takes
//! `publicValues (192) ++ seal (260)` and `check_proof` takes `imageId ++ seal (260) ++ journal`. Deployed and frozen
//! as P1 is, under a program id of its own: the vault requires P1 and P2 to be two different programs.

use anchor_lang::solana_program::account_info::AccountInfo;
use anchor_lang::solana_program::entrypoint::ProgramResult;
use anchor_lang::solana_program::pubkey::Pubkey;
use ethereum_verifier::{process_with, ProofSystem, Solana};
use xindex_core::risc0;

/// P2's: RISC Zero v3.0's Groth16 seal (`xindex_core::risc0`).
pub const RISC0: ProofSystem = ProofSystem {
    proof_len: risc0::SEAL_LEN,
    verify: |image_id, journal, seal| risc0::verify(&Solana, image_id, journal, seal).is_ok(),
};

#[cfg(not(feature = "no-entrypoint"))]
anchor_lang::solana_program::entrypoint!(process);

/// P2's entrypoint: P1's core with RISC Zero's check.
pub fn process(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    process_with(program_id, accounts, data, &RISC0)
}
