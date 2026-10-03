//! What the core's tests share: hex, the repository's real fixtures, and the native cryptography.
#![allow(dead_code)]

use serde_json::Value;

pub use xindex_core::native::Native;
pub const C: Native = Native;

pub fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

pub fn bytes(v: &Value) -> Vec<u8> {
    hex(v.as_str().unwrap())
}

pub fn h20(v: &Value) -> [u8; 20] {
    bytes(v).try_into().unwrap()
}

pub fn h32(v: &Value) -> [u8; 32] {
    bytes(v).try_into().unwrap()
}

/// A file of the repository, by its path from the root.
pub fn repo_file(path: &str) -> String {
    std::fs::read_to_string(format!("{}/../../{path}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

pub fn json(path: &str) -> Value {
    serde_json::from_str(&repo_file(path)).unwrap()
}
