//! A Merkle-Patricia walk down a block's transactions or receipts trie, as `crates/xindex-core`'s `mpt::get` walks an
//! Ethereum receipts trie, with blake2b in place of Keccak (`trie.DeriveRoot`, `trie/node.go`'s `encodeConsensus`):
//! every node is authenticated by its hash from the root down, the root always hashed, or embedded in an authenticated
//! parent when its encoding is shorter than 32 bytes. Trie nodes are the one thing the statement reads rather than
//! writes, as every receipt proof does; the leaf it finds is then compared with what the statement wrote.

use crate::encode::blake2b;
use crate::Word;

/// An RLP item read in place: its payload and whether it is a list.
#[derive(Clone, Copy)]
struct Item<'a> {
    payload: &'a [u8],
    is_list: bool,
}

/// The item at the start of `data`, and the bytes after it. Every length is checked against what holds it.
fn decode(data: &[u8]) -> Option<(Item<'_>, &[u8])> {
    let prefix = *data.first()?;
    let (start, len, is_list) = match prefix {
        0x00..=0x7f => (0, 1, false),
        0x80..=0xb7 => (1, usize::from(prefix - 0x80), false),
        0xb8..=0xbf => {
            let n = usize::from(prefix - 0xb7);
            (1 + n, long(data.get(1..1 + n)?)?, false)
        }
        0xc0..=0xf7 => (1, usize::from(prefix - 0xc0), true),
        0xf8..=0xff => {
            let n = usize::from(prefix - 0xf7);
            (1 + n, long(data.get(1..1 + n)?)?, true)
        }
    };
    let end = start.checked_add(len)?;
    let payload = data.get(start..end)?;
    Some((Item { payload, is_list }, &data[end..]))
}

fn long(bytes: &[u8]) -> Option<usize> {
    let mut v: u64 = 0;
    for b in bytes {
        v = v.checked_mul(256)? | u64::from(*b);
    }
    usize::try_from(v).ok()
}

/// The items of a list, which must span its payload exactly.
fn items<'a>(list: &Item<'a>, out: &mut [Option<Item<'a>>; 17]) -> Option<usize> {
    if !list.is_list {
        return None;
    }
    let mut rest = list.payload;
    let mut n = 0;
    while !rest.is_empty() {
        let (item, after) = decode(rest)?;
        *out.get_mut(n)? = Some(item);
        n += 1;
        rest = after;
    }
    Some(n)
}

fn nibble(bytes: &[u8], i: usize) -> u8 {
    let b = bytes[i / 2];
    if i.is_multiple_of(2) {
        b >> 4
    } else {
        b & 0x0f
    }
}

/// The value stored under `key`, if the proof shows one under `root`; `None` for any proof that does not lead to the
/// key's leaf, whether malformed, inauthentic or showing the key absent. In these tries every key is `rlp(index)`,
/// and no key is a prefix of another, so a value is only ever a leaf's.
pub fn get<'a>(root: &Word, key: &[u8], proof: &'a [alloc::vec::Vec<u8>]) -> Option<&'a [u8]> {
    let key_nibbles = 2 * key.len();
    let mut expected = *root;
    let mut embedded: Option<Item<'a>> = None;
    let mut next = 0;
    let mut at = 0;
    loop {
        let node = match embedded.take() {
            Some(node) => node,
            None => {
                let raw = proof.get(next)?;
                if blake2b(&[raw]) != expected {
                    return None;
                }
                next += 1;
                let (node, rest) = decode(raw)?;
                if !rest.is_empty() {
                    return None;
                }
                node
            }
        };
        let mut slots = [None; 17];
        let child = match items(&node, &mut slots)? {
            17 => {
                if at >= key_nibbles {
                    return None;
                }
                let child = slots[usize::from(nibble(key, at))]?;
                at += 1;
                if !child.is_list && child.payload.is_empty() {
                    return None;
                }
                child
            }
            2 => {
                let path = slots[0]?;
                if path.is_list {
                    return None;
                }
                let encoded = path.payload;
                let first = *encoded.first()?;
                let flag = first >> 4;
                if flag > 3 {
                    return None;
                }
                let is_leaf = flag >= 2;
                let odd = flag & 1 == 1;
                if !odd && first & 0x0f != 0 {
                    return None;
                }
                let rest = &encoded[1..];
                let length = 2 * rest.len() + usize::from(odd);
                if at + length > key_nibbles {
                    return None;
                }
                for i in 0..length {
                    let p = if odd {
                        if i == 0 {
                            first & 0x0f
                        } else {
                            nibble(rest, i - 1)
                        }
                    } else {
                        nibble(rest, i)
                    };
                    if p != nibble(key, at + i) {
                        return None;
                    }
                }
                at += length;
                let child = slots[1]?;
                if is_leaf {
                    if at != key_nibbles || child.is_list {
                        return None;
                    }
                    // The whole proof must have been used: nothing is left unauthenticated or unread.
                    if next != proof.len() {
                        return None;
                    }
                    return Some(child.payload);
                }
                child
            }
            _ => return None,
        };
        // A child is embedded when it is a list, else named by its 32-byte hash.
        if child.is_list {
            embedded = Some(child);
        } else {
            expected = child.payload.try_into().ok()?;
        }
    }
}
