//! P1 on Stellar (Stage B spec, section 10): a light client of Ethereum that anyone advances with an SP1 proof that a
//! checkpoint is finalized by two thirds of the anchor's validators, and that proves a vault message by its receipt in
//! any execution block those proofs covered. The twin of `EthereumFinalityVerifier.sol` and of Solana's
//! `ethereum-verifier`: `xindex_soroban::light_client` with SP1 v6's Groth16 check (`xindex_core::sp1`).
//!
//! No owner and no upgrade: the constructor sets the program key, the first anchor and the network's genesis time at
//! deployment, and no call replaces the contract's Wasm.

#![no_std]

use soroban_sdk::{contract, contractimpl, Bytes, BytesN, Env};
use xindex_core::groth16::ProofError;
use xindex_soroban::light_client::{self as lc, Range, State};
use xindex_soroban::Soroban;

fn sp1(c: &Soroban, key: &[u8; 32], values: &[u8], proof: &[u8]) -> Result<(), ProofError> {
    xindex_core::sp1::verify(c, key, values, proof)
}

#[contract]
pub struct P1Verifier;

#[contractimpl]
impl P1Verifier {
    /// The program key (`p1 vkey`), the first anchor and its epoch (`p1-input check-state`), and the beacon chain's
    /// genesis time: 1606824023 on mainnet, 1655733600 on Sepolia.
    pub fn __constructor(
        env: Env,
        program_key: BytesN<32>,
        anchor: BytesN<32>,
        epoch: u64,
        genesis_time: u64,
    ) {
        lc::construct(&env, program_key, anchor, epoch, genesis_time);
    }

    /// Anyone, within a day of the anchor's epoch: an SP1 proof of the statement from the stored anchor, whose public
    /// values are `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`.
    pub fn update(env: Env, public_values: Bytes, proof: Bytes) {
        lc::update(&env, &public_values, &proof, sp1);
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

    /// Fails unless `proof` is SP1 v6's Groth16 proof that the program `key` committed `public_values`.
    pub fn check_proof(env: Env, key: BytesN<32>, proof: Bytes, public_values: Bytes) {
        lc::check_proof(&env, &key, &proof, &public_values, sp1);
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
