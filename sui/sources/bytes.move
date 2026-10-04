/// Byte strings as Ethereum writes them: big-endian 32-byte words, as `abi.encode` writes a number, and slices of a
/// longer string. Move has no slice type, so a slice is copied; every reader here checks its bounds first and aborts
/// `EOutOfBounds` rather than reading past the end.
module xindex_vault::bytes;

use sui::bcs;

/// A read past the end of a byte string.
const EOutOfBounds: u64 = 1;
/// More than eight bytes asked of a little- or big-endian integer.
const ETooLarge: u64 = 2;

/// The 32 zero bytes.
public fun zero32(): vector<u8> {
    vector::tabulate!(32, |_| 0u8)
}

/// Whether every byte is zero (the empty string included).
public fun is_zero(v: &vector<u8>): bool {
    v.all!(|b| *b == 0)
}

/// `len` bytes of `v` from `start`.
public fun slice(v: &vector<u8>, start: u64, len: u64): vector<u8> {
    assert!(start <= v.length() && len <= v.length() - start, EOutOfBounds);
    let mut out = vector[];
    let mut i = start;
    let end = start + len;
    while (i < end) {
        out.push_back(v[i]);
        i = i + 1;
    };
    out
}

/// Whether `v[start..start + len]` is `other`, without copying.
public fun slice_eq(v: &vector<u8>, start: u64, len: u64, other: &vector<u8>): bool {
    assert!(start <= v.length() && len <= v.length() - start, EOutOfBounds);
    if (other.length() != len) return false;
    let mut i = 0;
    while (i < len) {
        if (v[start + i] != other[i]) return false;
        i = i + 1;
    };
    true
}

/// The 32-byte big-endian word at `start` as a number.
public fun u256_at(v: &vector<u8>, start: u64): u256 {
    assert!(start <= v.length() && 32 <= v.length() - start, EOutOfBounds);
    let mut x: u256 = 0;
    let mut i = 0;
    while (i < 32) {
        x = (x << 8) | (v[start + i] as u256);
        i = i + 1;
    };
    x
}

/// A 32-byte big-endian word as a number.
public fun to_u256(w: &vector<u8>): u256 {
    assert!(w.length() == 32, EOutOfBounds);
    u256_at(w, 0)
}

/// A number as a 32-byte big-endian word, as `abi.encode(uint256)` writes it.
public fun word(x: u256): vector<u8> {
    let mut out = bcs::to_bytes(&x);
    out.reverse();
    out
}

/// A `u64` as a word.
public fun word64(x: u64): vector<u8> {
    word(x as u256)
}

/// A number as 32 bytes little-endian, as arkworks writes a field element.
public fun le32(x: u256): vector<u8> {
    bcs::to_bytes(&x)
}

/// `n` big-endian bytes at `start` as a number: a long RLP item's length, at most eight bytes.
public fun be_at(v: &vector<u8>, start: u64, n: u64): u64 {
    assert!(n <= 8, ETooLarge);
    assert!(start <= v.length() && n <= v.length() - start, EOutOfBounds);
    let mut x: u64 = 0;
    let mut i = 0;
    while (i < n) {
        x = (x << 8) | (v[start + i] as u64);
        i = i + 1;
    };
    x
}

/// `n` little-endian bytes at `start` as a number: a proof's u64, u32 or u8.
public fun le_at(v: &vector<u8>, start: u64, n: u64): u64 {
    assert!(n <= 8, ETooLarge);
    assert!(start <= v.length() && n <= v.length() - start, EOutOfBounds);
    let mut x: u64 = 0;
    let mut i = n;
    while (i > 0) {
        i = i - 1;
        x = (x << 8) | (v[start + i] as u64);
    };
    x
}

/// An address as a word: 20 bytes left-padded with zeros, as `abi.encode(address)` writes it.
public fun address_word(a: &vector<u8>): vector<u8> {
    assert!(a.length() == 20, EOutOfBounds);
    let mut out = vector::tabulate!(12, |_| 0u8);
    out.append(*a);
    out
}
