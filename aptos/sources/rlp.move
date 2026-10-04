/// RLP read in place, as `RlpReader.sol` and `crates/xindex-core/src/rlp.rs` read it: an item is where its payload lies
/// in the bytes that hold it, and whether it is a list. Every item is checked to lie inside the one that holds it, so a
/// malformed encoding aborts `EBadRlp` rather than being read past its end. The twin of `sui/sources/rlp.move`.
module xindex_vault::rlp {
    use xindex_vault::bytes;

    /// The encoding runs past its end, has bytes after it, or is not what the reader expects.
    const EBadRlp: u64 = 101;

    const SHORT_STRING: u8 = 0x80;
    const LONG_STRING: u8 = 0xb8;
    const SHORT_LIST: u8 = 0xc0;
    const LONG_LIST: u8 = 0xf8;

    /// An item: its payload's place in the buffer, and whether it is a list.
    struct Item has copy, drop {
        start: u64,
        len: u64,
        list: bool,
    }

    public fun start(i: &Item): u64 { i.start }

    public fun len(i: &Item): u64 { i.len }

    public fun is_list(i: &Item): bool { i.list }

    /// The item at `at` in `buf`, which must end by `end`, and where the next one starts.
    fun decode(buf: &vector<u8>, at: u64, end: u64): (Item, u64) {
        assert!(at < end && end <= buf.length(), EBadRlp);
        let prefix = buf[at];
        let (offset, len, list) = if (prefix < SHORT_STRING) {
            (0, 1, false)
        } else if (prefix < LONG_STRING) {
            (1, ((prefix - SHORT_STRING) as u64), false)
        } else if (prefix < SHORT_LIST) {
            let n = ((prefix - LONG_STRING + 1) as u64);
            assert!(n <= end - at - 1, EBadRlp);
            (1 + n, bytes::be_at(buf, at + 1, n), false)
        } else if (prefix < LONG_LIST) {
            (1, ((prefix - SHORT_LIST) as u64), true)
        } else {
            let n = ((prefix - LONG_LIST + 1) as u64);
            assert!(n <= end - at - 1, EBadRlp);
            (1 + n, bytes::be_at(buf, at + 1, n), true)
        };
        let start = at + offset;
        assert!(start <= end && len <= end - start, EBadRlp);
        (Item { start, len, list }, start + len)
    }

    /// The item `buf[start..start + len]` encodes, which must span all of it.
    public fun to_item(buf: &vector<u8>, start: u64, len: u64): Item {
        assert!(start <= buf.length() && len <= buf.length() - start, EBadRlp);
        let (item, next) = decode(buf, start, start + len);
        assert!(next == start + len, EBadRlp);
        item
    }

    /// The number of items in a list, each decoded in place and none kept.
    public fun count(buf: &vector<u8>, list: &Item): u64 {
        assert!(list.list, EBadRlp);
        let end = list.start + list.len;
        let at = list.start;
        let n = 0;
        while (at < end) {
            let (_, next) = decode(buf, at, end);
            at = next;
            n += 1;
        };
        n
    }

    /// The `index`-th item of a list, after skipping the items before it in place.
    public fun at(buf: &vector<u8>, list: &Item, index: u64): Item {
        assert!(list.list, EBadRlp);
        let end = list.start + list.len;
        let at = list.start;
        let i = 0;
        while (i < index) {
            let (_, next) = decode(buf, at, end);
            at = next;
            i += 1;
        };
        let (item, _) = decode(buf, at, end);
        item
    }

    /// A string's bytes, copied.
    public fun bytes(buf: &vector<u8>, item: &Item): vector<u8> {
        assert!(!item.list, EBadRlp);
        bytes::slice(buf, item.start, item.len)
    }

    /// A string that must be exactly 32 bytes.
    public fun bytes32(buf: &vector<u8>, item: &Item): vector<u8> {
        assert!(!item.list && item.len == 32, EBadRlp);
        bytes::slice(buf, item.start, 32)
    }

    /// A string of at most 32 bytes as a big-endian number, which must fit 64 bits.
    public fun uint(buf: &vector<u8>, item: &Item): u64 {
        assert!(!item.list && item.len <= 32, EBadRlp);
        let split = if (item.len > 8) { item.len - 8 } else { 0 };
        let i = 0;
        while (i < split) {
            assert!(buf[item.start + i] == 0, EBadRlp);
            i += 1;
        };
        bytes::be_at(buf, item.start + split, item.len - split)
    }

    /// Whether a string is empty: an empty branch child.
    public fun is_empty_string(item: &Item): bool {
        !item.list && item.len == 0
    }
}
