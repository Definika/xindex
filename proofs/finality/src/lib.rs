//! P1, the proof that an Ethereum checkpoint is finalized (Stage B spec, section 10). The statement is checked here in
//! plain Rust, so it can be tested natively; the SP1 program only reads an [`Input`], calls [`verify`] and commits the
//! [`Output`]. Nothing here trusts the prover: every value that matters is hashed, proven against the anchor, or
//! signed by the anchor's validators.

pub mod beacon;
pub mod bls;
pub mod cycles;
pub mod execution;
pub mod registry;
pub mod ssz;
pub mod statement;
pub mod testkit;

pub use statement::{verify, Aggregate, Anchor, Error, Input, NewKey, Output};

/// A 32-byte hash or root.
pub type Root = [u8; 32];
