//! The execution header parser under random and hostile input: a header written by the test kit's encoder parses back
//! to its fields, garbage and mutants never panic, and each malformed shape is refused. Only the hash binds a header,
//! so a non-canonical length prefix is accepted on purpose: a forged one still has to chain by keccak.

use xindex_finality::execution::{keccak, parse_header};
use xindex_finality::testkit::{exec_header, rlp_bytes, rlp_int, rlp_list};

/// xorshift64*, so every run is the same run.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn bytes(&mut self, n: usize) -> Vec<u8> {
        (0..n).map(|_| self.next() as u8).collect()
    }

    /// A u64 of a random magnitude, so numbers take every length from no bytes to eight.
    fn int(&mut self) -> u64 {
        match self.below(5) {
            0 => 0,
            1 => self.below(256),
            2 => self.below(1 << 32),
            3 => self.next(),
            _ => u64::MAX,
        }
    }
}

fn word(bytes: &[u8]) -> [u8; 32] {
    bytes.try_into().unwrap()
}

#[test]
fn random_headers_parse_to_their_fields() {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    for _ in 0..2_000 {
        let count = 16 + rng.below(6) as usize;
        let parent = rng.bytes(32);
        let state = rng.bytes(32);
        let receipts = rng.bytes(32);
        let number = rng.int();
        let timestamp = rng.int();
        let fields: Vec<Vec<u8>> = (0..count)
            .map(|i| match i {
                0 => rlp_bytes(&parent),
                3 => rlp_bytes(&state),
                5 => rlp_bytes(&receipts),
                8 => rlp_int(number),
                11 => rlp_int(timestamp),
                _ => {
                    let len = rng.below(300) as usize;
                    rlp_bytes(&rng.bytes(len))
                }
            })
            .collect();
        let rlp = rlp_list(&fields);
        let h = parse_header(&rlp).expect("a well-formed header parses");
        assert_eq!(h.hash, keccak(&[&rlp]));
        assert_eq!(h.parent_hash, word(&parent));
        assert_eq!(h.state_root, word(&state));
        assert_eq!(h.receipts_root, word(&receipts));
        assert_eq!(h.number, number);
        assert_eq!(h.timestamp, timestamp);
    }
}

#[test]
fn garbage_and_mutants_never_panic() {
    let mut rng = Rng(0xd1b5_4a32_d192_ed03);
    for _ in 0..20_000 {
        let len = rng.below(600) as usize;
        let bytes = rng.bytes(len);
        if let Some(h) = parse_header(&bytes) {
            assert_eq!(h.hash, keccak(&[&bytes]));
        }
    }
    // Structured garbage: every RLP prefix class at the front of random payloads.
    for _ in 0..5_000 {
        let len = rng.below(100) as usize;
        let mut bytes = rng.bytes(len);
        if !bytes.is_empty() {
            bytes[0] = match rng.below(4) {
                0 => 0xc0 + rng.below(56) as u8,
                1 => 0xf8 + rng.below(8) as u8,
                2 => 0xb8 + rng.below(8) as u8,
                _ => rng.next() as u8,
            };
        }
        let _ = parse_header(&bytes);
    }
    // Mutants of real headers: a flipped byte, a truncation, an insertion, a deletion, an extension.
    for i in 0..500u64 {
        let base = exec_header([i as u8; 32], i);
        for _ in 0..20 {
            let mut m = base.clone();
            match rng.below(5) {
                0 => {
                    let at = rng.below(m.len() as u64) as usize;
                    m[at] ^= 1 << rng.below(8);
                }
                1 => {
                    let at = rng.below(m.len() as u64) as usize;
                    m.truncate(at);
                }
                2 => {
                    let at = rng.below(m.len() as u64 + 1) as usize;
                    m.insert(at, rng.next() as u8);
                }
                3 => {
                    let at = rng.below(m.len() as u64) as usize;
                    m.remove(at);
                }
                _ => m.push(rng.next() as u8),
            }
            if let Some(h) = parse_header(&m) {
                assert_eq!(h.hash, keccak(&[&m]));
            }
        }
    }
}

#[test]
fn malformed_headers_are_refused() {
    let base = exec_header([0x11; 32], 5);
    assert!(parse_header(&base).is_some());

    let fields = |n: usize| -> Vec<Vec<u8>> {
        (0..n)
            .map(|i| match i {
                0 | 3 | 5 => rlp_bytes(&[i as u8; 32]),
                8 => rlp_int(5),
                11 => rlp_int(1_750_000_060),
                _ => rlp_bytes(b"x"),
            })
            .collect()
    };
    assert!(
        parse_header(&rlp_list(&fields(16))).is_some(),
        "sixteen fields"
    );
    assert!(
        parse_header(&rlp_list(&fields(15))).is_none(),
        "fifteen fields"
    );

    let mut f = fields(16);
    f[0] = rlp_bytes(&[0x11; 31]);
    assert!(
        parse_header(&rlp_list(&f)).is_none(),
        "a parent hash of 31 bytes"
    );
    let mut f = fields(16);
    f[8] = rlp_bytes(&[1; 9]);
    assert!(
        parse_header(&rlp_list(&f)).is_none(),
        "a number of nine bytes"
    );
    let mut f = fields(16);
    f[11] = rlp_bytes(&[1; 9]);
    assert!(
        parse_header(&rlp_list(&f)).is_none(),
        "a timestamp of nine bytes"
    );
    let mut f = fields(16);
    f[2] = rlp_list(&[rlp_bytes(b"a")]);
    assert!(
        parse_header(&rlp_list(&f)).is_none(),
        "a list where a field goes"
    );

    let mut trailing = base.clone();
    trailing.push(0);
    assert!(parse_header(&trailing).is_none(), "a trailing byte");
    assert!(
        parse_header(&base[..base.len() - 1]).is_none(),
        "a byte short"
    );
    assert!(parse_header(&[]).is_none(), "nothing");
    assert!(
        parse_header(&rlp_bytes(&base)).is_none(),
        "a string, not a list"
    );

    // Non-canonical lengths are read as given: only the hash binds a header, and a header with a padded length never
    // chains to a real one.
    let mut f = fields(16);
    f[2] = [vec![0xb8, 1], b"x".to_vec()].concat();
    assert!(
        parse_header(&rlp_list(&f)).is_some(),
        "a long-form one-byte string"
    );
    let payload: Vec<u8> = fields(16).concat();
    let padded = [vec![0xf9, 0, payload.len() as u8], payload].concat();
    assert!(
        parse_header(&padded).is_some(),
        "a list length with a leading zero"
    );
}
