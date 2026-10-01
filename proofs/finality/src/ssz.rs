//! The part of SSZ merkleization the statement needs: SHA-256 pairs, trees padded with zero subtrees, and branches.

use crate::Root;
use sha2::digest::generic_array::GenericArray;

/// SHA-256's initial state.
const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// The second block of every 64-byte message: the padding bit, then the length, 512 bits, big-endian.
const PAD_64: [u8; 64] = {
    let mut p = [0u8; 64];
    p[0] = 0x80;
    p[62] = 0x02;
    p
};

/// SHA-256 of `a ‖ b`. It runs the two compressions itself, which in the zkVM are SP1's precompile, and skips the
/// buffering of the streaming API, which cost more than the compressions it fed.
pub fn hash_pair(a: &Root, b: &Root) -> Root {
    let mut block = [0u8; 64];
    block[..32].copy_from_slice(a);
    block[32..].copy_from_slice(b);
    let mut state = H0;
    sha2::compress256(
        &mut state,
        &[GenericArray::from(block), GenericArray::from(PAD_64)],
    );
    let mut out = [0u8; 32];
    for (o, word) in out.as_chunks_mut::<4>().0.iter_mut().zip(state) {
        *o = word.to_be_bytes();
    }
    out
}

/// A `uint64` as its SSZ chunk: little-endian, zero-padded.
pub fn u64_chunk(x: u64) -> Root {
    let mut c = [0u8; 32];
    c[..8].copy_from_slice(&x.to_le_bytes());
    c
}

/// The root of `chunks` padded with zero chunks to `2^depth` leaves.
pub fn merkleize(chunks: &[Root], depth: usize) -> Root {
    let mut m = Merkleizer::new(depth);
    for chunk in chunks {
        m.push(chunk);
    }
    m.root()
}

/// Merkleizes chunks as they come, holding one node per level rather than the tree: the root of the chunks pushed,
/// padded with zero chunks to `2^depth` leaves. It hashes each pair once, and a zero subtree only where the padding
/// needs one.
pub struct Merkleizer {
    depth: usize,
    count: u64,
    /// `left[l]` is the root of the last whole subtree of `2^l` chunks still waiting for its right sibling, wherever
    /// bit `l` of `count` is set.
    left: Vec<Root>,
}

impl Merkleizer {
    pub fn new(depth: usize) -> Self {
        assert!(depth < 64, "too deep");
        Merkleizer {
            depth,
            count: 0,
            left: vec![[0u8; 32]; depth + 1],
        }
    }

    pub fn count(&self) -> u64 {
        self.count
    }

    pub fn push(&mut self, chunk: &Root) {
        assert!(
            self.count < 1u64 << self.depth,
            "too many chunks for the depth"
        );
        let mut node = *chunk;
        let mut level = 0;
        let mut pending = self.count;
        while pending & 1 == 1 {
            node = hash_pair(&self.left[level], &node);
            pending >>= 1;
            level += 1;
        }
        self.left[level] = node;
        self.count += 1;
    }

    pub fn root(&self) -> Root {
        if self.count == 1u64 << self.depth {
            return self.left[self.depth];
        }
        // Climb from the first empty leaf: at each level the node so far is a right child where a whole subtree waits
        // on its left, and a left child of a zero subtree otherwise.
        let mut node = [0u8; 32];
        let mut zero = [0u8; 32];
        for level in 0..self.depth {
            node = if (self.count >> level) & 1 == 1 {
                hash_pair(&self.left[level], &node)
            } else {
                hash_pair(&node, &zero)
            };
            if level + 1 < self.depth {
                zero = hash_pair(&zero, &zero);
            }
        }
        node
    }
}

pub fn mix_in_length(root: &Root, length: u64) -> Root {
    hash_pair(root, &u64_chunk(length))
}

/// The root of eight chunks, a container of five to eight fields.
pub fn root_of_eight(c: &[Root; 8]) -> Root {
    hash_pair(
        &hash_pair(&hash_pair(&c[0], &c[1]), &hash_pair(&c[2], &c[3])),
        &hash_pair(&hash_pair(&c[4], &c[5]), &hash_pair(&c[6], &c[7])),
    )
}

/// The consensus specs' `is_valid_merkle_branch`: `leaf` at `index` of a depth-`depth` tree whose root is `root`, with
/// `branch` its siblings from the bottom up.
pub fn is_valid_branch(
    leaf: &Root,
    branch: &[Root],
    depth: usize,
    index: u64,
    root: &Root,
) -> bool {
    if branch.len() != depth || (depth < 64 && index >> depth != 0) {
        return false;
    }
    let mut node = *leaf;
    for (i, sibling) in branch.iter().enumerate() {
        node = if (index >> i) & 1 == 1 {
            hash_pair(sibling, &node)
        } else {
            hash_pair(&node, sibling)
        };
    }
    node == *root
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tree as the consensus specs define it: every layer whole, padded with zero subtrees.
    fn layered(chunks: &[Root], depth: usize) -> Root {
        let mut zero = [0u8; 32];
        let mut layer = if chunks.is_empty() {
            vec![zero]
        } else {
            chunks.to_vec()
        };
        for _ in 0..depth {
            if layer.len() % 2 == 1 {
                layer.push(zero);
            }
            layer = layer.chunks(2).map(|p| hash_pair(&p[0], &p[1])).collect();
            zero = hash_pair(&zero, &zero);
        }
        layer[0]
    }

    fn chunks(n: usize) -> Vec<Root> {
        (0..n).map(|i| u64_chunk(i as u64 * 7 + 1)).collect()
    }

    #[test]
    fn the_merkleizer_builds_the_specs_tree() {
        for depth in 0..7 {
            for n in 0..=(1usize << depth) {
                assert_eq!(
                    merkleize(&chunks(n), depth),
                    layered(&chunks(n), depth),
                    "{n} chunks at depth {depth}"
                );
            }
        }
        for n in [0, 1, 2, 3, 1000, 1025] {
            assert_eq!(
                merkleize(&chunks(n), 40),
                layered(&chunks(n), 40),
                "{n} chunks at depth 40"
            );
        }
        let eight: [Root; 8] = chunks(8).try_into().unwrap();
        assert_eq!(root_of_eight(&eight), layered(&eight, 3));
    }

    #[test]
    fn a_pair_hashes_as_sha256_does() {
        use sha2::{Digest, Sha256};
        for i in 0..64u8 {
            let a = [i; 32];
            let mut b = [i.wrapping_mul(37); 32];
            b[31 - (i as usize % 32)] ^= 0xa5;
            let expected: Root = Sha256::new()
                .chain_update(a)
                .chain_update(b)
                .finalize()
                .into();
            assert_eq!(hash_pair(&a, &b), expected);
        }
    }

    #[test]
    #[should_panic(expected = "too many chunks for the depth")]
    fn a_full_tree_takes_no_more() {
        merkleize(&chunks(9), 3);
    }
}
