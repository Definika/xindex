//! Writes `fixtures/attest.json`: the synthetic attest's public values, slots, values and record, which
//! `test/StellarStateVerifier.t.sol` decodes, so the record's encoding and the public values' layout are pinned on both
//! sides. `tests/vector.rs` fails if the file no longer matches the code.
//!
//! ```text
//! cargo run --example vector
//! ```

fn main() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/attest.json");
    std::fs::write(path, xindex_stellar::testkit::vector()).unwrap();
}
