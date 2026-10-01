//! A Merkle-Patricia walk, as `MerklePatricia.sol` walks a block's receipts trie: every node is authenticated by its
//! hash from the root down, or embedded in an authenticated parent, so the value found is the one the root commits
//! to; a proof that the key is absent returns nothing.

use crate::keccak;
use crate::rlp::{to_item, Item};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BadProof;

impl From<crate::rlp::BadRlp> for BadProof {
    fn from(_: crate::rlp::BadRlp) -> Self {
        BadProof
    }
}

const BRANCH_ITEMS: usize = 17;
const SHORT_NODE_ITEMS: usize = 2;
const LEAF_EVEN: u8 = 2;
const LEAF_ODD: u8 = 3;

/// The leaf value stored under the key whose first `key_nibbles` nibbles are `key`'s, if the proof shows one. In a
/// receipts trie no key is a prefix of another, so a value is only ever a leaf's.
pub fn get<'a>(
    root: &[u8; 32],
    key: &[u8],
    key_nibbles: usize,
    proof: &[&'a [u8]],
) -> Result<Option<Item<'a>>, BadProof> {
    if key_nibbles > 2 * key.len() {
        return Err(BadProof);
    }
    let mut expected = *root;
    let mut embedded: Option<Item<'a>> = None;
    let mut next = 0;
    let mut nibble = 0;
    loop {
        let node = match embedded.take() {
            Some(node) => node,
            None => {
                let raw = *proof.get(next).ok_or(BadProof)?;
                if keccak(&[raw]) != expected {
                    return Err(BadProof);
                }
                next += 1;
                to_item(raw)?
            }
        };
        let items = node.items()?;
        let child = match items.len() {
            BRANCH_ITEMS => {
                if nibble >= key_nibbles {
                    return Err(BadProof);
                }
                let child = items[nibble_at(key, nibble) as usize];
                nibble += 1;
                if !child.is_list && child.payload.is_empty() {
                    return Ok(None);
                }
                child
            }
            SHORT_NODE_ITEMS => {
                let (length, is_leaf, matches) = match_path(&items[0], key, nibble, key_nibbles)?;
                if !matches {
                    return Ok(None);
                }
                nibble += length;
                if is_leaf {
                    if nibble != key_nibbles {
                        return Err(BadProof);
                    }
                    return Ok(Some(items[1]));
                }
                items[1]
            }
            _ => return Err(BadProof),
        };
        // A child is embedded when it is a list, else named by its 32-byte hash.
        if child.is_list {
            embedded = Some(child);
        } else {
            expected = child.bytes32()?;
        }
    }
}

/// Decodes a hex-prefix path and compares it with `key` from nibble `offset`. The first nibble of the encoding is a
/// flag: 0 or 1 an extension, 2 or 3 a leaf, odd when the path has an odd number of nibbles, whose first then shares
/// the flag's byte; an even path pads that byte's second nibble with zero.
fn match_path(
    path: &Item,
    key: &[u8],
    offset: usize,
    key_nibbles: usize,
) -> Result<(usize, bool, bool), BadProof> {
    let encoded = path.bytes()?;
    let first = *encoded.first().ok_or(BadProof)?;
    let flag = first >> 4;
    if flag > LEAF_ODD {
        return Err(BadProof);
    }
    let is_leaf = flag >= LEAF_EVEN;
    let odd = flag & 1 == 1;
    if !odd && first & 0x0f != 0 {
        return Err(BadProof);
    }
    let rest = &encoded[1..];
    let length = 2 * rest.len() + usize::from(odd);
    if offset + length > key_nibbles {
        return Ok((length, is_leaf, false));
    }
    let path_nibble = |i: usize| -> u8 {
        if odd {
            if i == 0 {
                first & 0x0f
            } else {
                nibble_at(rest, i - 1)
            }
        } else {
            nibble_at(rest, i)
        }
    };
    let matches = (0..length).all(|i| path_nibble(i) == nibble_at(key, offset + i));
    Ok((length, is_leaf, matches))
}

fn nibble_at(bytes: &[u8], i: usize) -> u8 {
    let b = bytes[i / 2];
    if i & 1 == 0 {
        b >> 4
    } else {
        b & 0x0f
    }
}

/// A receipt's key in its block's trie, `rlp(txIndex)`, and its length in nibbles.
pub fn receipt_key(tx_index: u32) -> Option<(Vec<u8>, usize)> {
    match tx_index {
        0 => Some((vec![0x80], 2)),
        1..=0x7f => Some((vec![tx_index as u8], 2)),
        0x80..=0xff => Some((vec![0x81, tx_index as u8], 4)),
        0x100..=0xffff => Some((vec![0x82, (tx_index >> 8) as u8, tx_index as u8], 6)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipt_keys_are_rlp_of_the_index() {
        assert_eq!(receipt_key(0), Some((vec![0x80], 2)));
        assert_eq!(receipt_key(0x7f), Some((vec![0x7f], 2)));
        assert_eq!(receipt_key(130), Some((vec![0x81, 130], 4)));
        assert_eq!(receipt_key(0x1234), Some((vec![0x82, 0x12, 0x34], 6)));
        assert_eq!(receipt_key(0x10000), None);
    }

    #[test]
    fn hex_prefix_paths() {
        let key = [0x12, 0x34];
        let leaf = |b: &'static [u8]| Item {
            payload: b,
            is_list: false,
        };
        assert_eq!(
            match_path(&leaf(&[0x20, 0x12, 0x34]), &key, 0, 4),
            Ok((4, true, true))
        );
        assert_eq!(
            match_path(&leaf(&[0x31, 0x23]), &key, 0, 3),
            Ok((3, true, true))
        );
        assert_eq!(
            match_path(&leaf(&[0x13, 0x4f]), &key, 1, 4),
            Ok((3, false, false)),
            "another path"
        );
        assert_eq!(
            match_path(&leaf(&[0x00, 0x12]), &key, 0, 4),
            Ok((2, false, true))
        );
        assert_eq!(
            match_path(&leaf(&[0x00, 0x13]), &key, 0, 4),
            Ok((2, false, false))
        );
        assert_eq!(
            match_path(&leaf(&[0x40]), &key, 0, 4),
            Err(BadProof),
            "no such flag"
        );
        assert_eq!(
            match_path(&leaf(&[0x21]), &key, 0, 4),
            Err(BadProof),
            "an even path's pad is zero"
        );
        assert_eq!(match_path(&leaf(&[]), &key, 0, 4), Err(BadProof));
        assert_eq!(
            match_path(&leaf(&[0x20]), &key, 4, 4),
            Ok((0, true, true)),
            "an empty path matches"
        );
    }
}
