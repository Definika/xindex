//! The part of SSZ merkleization the statement needs: SHA-256 pairs, trees padded with zero subtrees, and branches.

use crate::Root;
use sha2::{Digest, Sha256};

pub fn hash_pair(a: &Root, b: &Root) -> Root {
    let mut h = Sha256::new();
    h.update(a);
    h.update(b);
    h.finalize().into()
}

/// A `uint64` as its SSZ chunk: little-endian, zero-padded.
pub fn u64_chunk(x: u64) -> Root {
    let mut c = [0u8; 32];
    c[..8].copy_from_slice(&x.to_le_bytes());
    c
}

/// `zeros[i]` is the root of a tree of `2^i` zero chunks.
pub fn zero_hashes(depth: usize) -> Vec<Root> {
    let mut zeros = vec![[0u8; 32]; depth + 1];
    for i in 0..depth {
        zeros[i + 1] = hash_pair(&zeros[i], &zeros[i]);
    }
    zeros
}

/// The root of `chunks` padded with zero chunks to `2^depth` leaves.
pub fn merkleize(chunks: &[Root], depth: usize) -> Root {
    assert!(
        depth < 64 && (chunks.len() as u128) <= (1u128 << depth),
        "too many chunks for the depth"
    );
    let zeros = zero_hashes(depth);
    if chunks.is_empty() {
        return zeros[depth];
    }
    let mut layer = chunks.to_vec();
    for zero in zeros.iter().take(depth) {
        if layer.len() % 2 == 1 {
            layer.push(*zero);
        }
        layer = layer.chunks(2).map(|p| hash_pair(&p[0], &p[1])).collect();
    }
    layer[0]
}

pub fn mix_in_length(root: &Root, length: u64) -> Root {
    hash_pair(root, &u64_chunk(length))
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
