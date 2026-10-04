/// Byte strings as Ethereum writes them: big-endian 32-byte words, as `abi.encode` writes a number, and slices of a
/// longer string. Move has no slice type, so a slice is copied; every reader here checks its bounds first and aborts
/// `EOutOfBounds` rather than reading past the end. The twin of `sui/sources/bytes.move`.
module xindex_vault::bytes {
    use std::bcs;
    use std::vector;

    /// A read past the end of a byte string.
    const EOutOfBounds: u64 = 1;
    /// More than eight bytes asked of a little- or big-endian integer.
    const ETooLarge: u64 = 2;

    /// A slice is copied natively from this many bytes, and when it is at least this share (one part in so many) of
    /// the string it is cut from (`copied_natively`).
    const NATIVE_MIN: u64 = 64;
    const NATIVE_SHARE: u64 = 256;

    /// `n` copies of the byte `b`.
    public fun repeat(b: u8, n: u64): vector<u8> {
        let out = vector::empty<u8>();
        let i = 0;
        while (i < n) {
            out.push_back(b);
            i += 1;
        };
        out
    }

    /// The 32 zero bytes.
    public fun zero32(): vector<u8> {
        repeat(0, 32)
    }

    /// Whether every byte is zero (the empty string included).
    public fun is_zero(v: &vector<u8>): bool {
        let i = 0;
        let n = v.length();
        while (i < n) {
            if (v[i] != 0) return false;
            i += 1;
        };
        true
    }

    /// Whether a slice of `len` bytes of `v` is cheaper copied natively: copying all of `v` and moving the slice out
    /// with `vector::move_range` costs a few hundred internal units a byte of `v`, a loop some tens of thousands a byte
    /// of the slice. A receipt's leaf and the log's data are walked this way, so a receipt bloated by other logs costs
    /// little more than its size (LG-1).
    fun copied_natively(v: &vector<u8>, len: u64): bool {
        len >= NATIVE_MIN && len * NATIVE_SHARE >= v.length()
    }

    /// `len` bytes of `v` from `start`.
    public fun slice(v: &vector<u8>, start: u64, len: u64): vector<u8> {
        assert!(start <= v.length() && len <= v.length() - start, EOutOfBounds);
        if (copied_natively(v, len)) {
            let all = *v;
            let out = vector::empty<u8>();
            vector::move_range(&mut all, start, len, &mut out, 0);
            out
        } else {
            v.slice(start, start + len)
        }
    }

    /// Whether `v[start..start + len]` is `other`.
    public fun slice_eq(v: &vector<u8>, start: u64, len: u64, other: &vector<u8>): bool {
        assert!(start <= v.length() && len <= v.length() - start, EOutOfBounds);
        if (other.length() != len) return false;
        if (copied_natively(v, len)) return slice(v, start, len) == *other;
        let i = 0;
        while (i < len) {
            if (v[start + i] != other[i]) return false;
            i += 1;
        };
        true
    }

    /// The 32-byte big-endian word at `start` as a number.
    public fun u256_at(v: &vector<u8>, start: u64): u256 {
        assert!(start <= v.length() && 32 <= v.length() - start, EOutOfBounds);
        let x: u256 = 0;
        let i = 0;
        while (i < 32) {
            x = (x << 8) | (v[start + i] as u256);
            i += 1;
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
        let out = bcs::to_bytes(&x);
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
        let x: u64 = 0;
        let i = 0;
        while (i < n) {
            x = (x << 8) | (v[start + i] as u64);
            i += 1;
        };
        x
    }

    /// `n` little-endian bytes at `start` as a number: a proof's u64, u32 or u8.
    public fun le_at(v: &vector<u8>, start: u64, n: u64): u64 {
        assert!(n <= 8, ETooLarge);
        assert!(start <= v.length() && n <= v.length() - start, EOutOfBounds);
        let x: u64 = 0;
        let i = n;
        while (i > 0) {
            i -= 1;
            x = (x << 8) | (v[start + i] as u64);
        };
        x
    }

    /// An address as a word: 20 bytes left-padded with zeros, as `abi.encode(address)` writes it.
    public fun address_word(a: &vector<u8>): vector<u8> {
        assert!(a.length() == 20, EOutOfBounds);
        let out = repeat(0, 12);
        out.append(*a);
        out
    }
}
