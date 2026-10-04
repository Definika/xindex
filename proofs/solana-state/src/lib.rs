//! Prototype of the Solana state proof (`design/2026-10-03-solana-state-proof.md`): the pieces a zkVM statement would
//! chain to prove on Ethereum what the Solana vault holds, in plain Rust and tested natively first, as
//! `proofs/finality` was.
//!
//! 1. [`cert`]: a block `(slot, block_id)` is final, by Alpenglow's BLS certificates over the epoch's ranked set.
//! 2. [`block_id`]: the block id commits to the block's shreds, and so to its footer, which carries its bank hash.
//! 3. [`bank`]: the bank hash opens to the slot's lattice hash and its parent's bank hash, which opens to the parent's
//!    lattice hash; the parent's with the slot's writes must make the slot's.
//! 4. [`lthash`]: each written account's lattice hash, so the vault's account written in that slot is proven.
//!
//! Not here yet: the shreds' framing (which bytes of the last FEC set are the footer), the registry program that
//! carries each epoch's set from Solana to Ethereum, and the zkVM program.

pub mod bank;
pub mod block_id;
pub mod cert;
pub mod lthash;
