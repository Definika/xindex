//! P2 on Stellar (Stage B spec, section 11): the same light client as P1, advanced by RISC Zero proofs of the same
//! statement with the same public values. The twin of `RiscZeroFinalityVerifier.sol` and of Solana's
//! `risc0-verifier`: `xindex_soroban::light_client` with RISC Zero v3.0's Groth16 check (`xindex_core::risc0`), the
//! journal passed by its SHA-256 as `verify(seal, imageId, sha256(journal))` passes it.
//!
//! No owner and no upgrade: the constructor sets the image id, the first anchor and the network's genesis time at
//! deployment, and no call replaces the contract's Wasm.

#![no_std]

use soroban_sdk::{contract, contractimpl, Bytes, BytesN, Env};
use xindex_core::groth16::ProofError;
use xindex_soroban::light_client::{self as lc, Range, State};
use xindex_soroban::Soroban;

fn risc0(c: &Soroban, image_id: &[u8; 32], journal: &[u8], seal: &[u8]) -> Result<(), ProofError> {
    xindex_core::risc0::verify(c, image_id, journal, seal)
}

#[contract]
pub struct P2Verifier;

#[contractimpl]
impl P2Verifier {
    /// P2's image id (`p2 image-id`), the first anchor and its epoch (the same as P1's), and the beacon chain's genesis
    /// time: 1606824023 on mainnet, 1655733600 on Sepolia.
    pub fn __constructor(
        env: Env,
        image_id: BytesN<32>,
        anchor: BytesN<32>,
        epoch: u64,
        genesis_time: u64,
    ) {
        lc::construct(&env, image_id, anchor, epoch, genesis_time);
    }

    /// Anyone, within a day of the anchor's epoch: a RISC Zero seal of the statement from the stored anchor, its journal
    /// the public values `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`.
    pub fn update(env: Env, public_values: Bytes, seal: Bytes) {
        lc::update(&env, &public_values, &seal, risc0);
    }

    /// The vault's call: fails unless the proof shows that log in a final Ethereum block.
    pub fn verify_event(
        env: Env,
        block: u64,
        emitter: BytesN<20>,
        topic0: BytesN<32>,
        topic1: BytesN<32>,
        data_hash: BytesN<32>,
        proof: Bytes,
    ) {
        lc::verify_event(&env, block, &emitter, &topic0, &topic1, &data_hash, &proof);
    }

    /// The vault's call: fails unless the proof shows that final Ethereum block, with that timestamp and state root.
    pub fn verify_checkpoint(
        env: Env,
        block: u64,
        timestamp: u64,
        state_root: BytesN<32>,
        proof: Bytes,
    ) {
        lc::verify_checkpoint(&env, block, timestamp, &state_root, &proof);
    }

    /// Fails unless `seal` is RISC Zero v3.0's Groth16 seal of the image `image_id` committing `journal`.
    pub fn check_proof(env: Env, image_id: BytesN<32>, seal: Bytes, journal: Bytes) {
        lc::check_proof(&env, &image_id, &seal, &journal, risc0);
    }

    pub fn state(env: Env) -> State {
        lc::state(&env)
    }

    pub fn lag_ends(env: Env) -> u64 {
        lc::lag_ends(&env)
    }

    pub fn range(env: Env, headers_root: BytesN<32>) -> Option<Range> {
        lc::range(&env, &headers_root)
    }
}
