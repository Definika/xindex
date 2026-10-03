//! Hex literals as byte arrays, at compile time: how every Solidity constant here is written down.

/// A 64-digit lowercase hex string as 32 bytes.
pub const fn h(s: &str) -> [u8; 32] {
    let b = s.as_bytes();
    assert!(b.len() == 64, "64 hex digits");
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = (nibble(b[2 * i]) << 4) | nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}

/// A 40-digit lowercase hex string as 20 bytes.
pub const fn h20(s: &str) -> [u8; 20] {
    let b = s.as_bytes();
    assert!(b.len() == 40, "40 hex digits");
    let mut out = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        out[i] = (nibble(b[2 * i]) << 4) | nibble(b[2 * i + 1]);
        i += 1;
    }
    out
}

const fn nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("not a hex digit"),
    }
}
