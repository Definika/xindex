//! An Alpenglow block id: the "double Merkle root" over a block's FEC sets (`Blockstore::build_double_merkle_tree`,
//! `ledger/src/blockstore.rs`, Agave v4.4.0-beta.0).
//!
//! - **Leaves:** each FEC set's Merkle root, in order, then `sha256(parent_slot (u64 LE) ++ parent_block_id ++
//!   fec_set_count (u32 LE))`, which binds the count so an odd tail cannot be faked.
//! - **Nodes** (`ledger/src/shred/merkle_tree.rs`): `sha256(b"\x01SOLANA_MERKLE_SHREDS_NODE" ++ left[..20] ++
//!   right[..20])`, an odd layer's last node joined with itself; the leaves enter as they are, and the root is a whole
//!   32-byte hash. An FEC set's own root is the same tree over its shreds, each leaf `sha256(b"\x00SOLANA_MERKLE_SHREDS_LEAF"
//!   ++ the shred's signed bytes)`.
//!
//! The footer, which carries the block's bank hash, is the block's last component, so it lies in the last FEC set:
//! a proof of it is its data shreds' paths to that set's root, and that root's path here, beside the parent leaf.

use sha2::{Digest, Sha256};

pub const NODE_PREFIX: &[u8] = b"\x01SOLANA_MERKLE_SHREDS_NODE";
pub const LEAF_PREFIX: &[u8] = b"\x00SOLANA_MERKLE_SHREDS_LEAF";
/// A proof entry: the first 20 bytes of a sibling.
pub const ENTRY: usize = 20;

pub fn join(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
    Sha256::new()
        .chain_update(NODE_PREFIX)
        .chain_update(&left[..ENTRY])
        .chain_update(&right[..ENTRY])
        .finalize()
        .into()
}

/// The last leaf: the parent block and the number of FEC sets.
pub fn parent_leaf(parent_slot: u64, parent_block_id: &[u8; 32], fec_set_count: u32) -> [u8; 32] {
    Sha256::new()
        .chain_update(parent_slot.to_le_bytes())
        .chain_update(parent_block_id)
        .chain_update(fec_set_count.to_le_bytes())
        .finalize()
        .into()
}

/// The root over `leaves`, as `MerkleTree::try_new_with_len` builds it.
pub fn root(leaves: &[[u8; 32]]) -> Option<[u8; 32]> {
    let mut layer = leaves.to_vec();
    if layer.is_empty() {
        return None;
    }
    while layer.len() > 1 {
        layer = layer
            .chunks(2)
            .map(|p| join(&p[0], p.get(1).unwrap_or(&p[0])))
            .collect();
    }
    Some(layer[0])
}

/// The root a leaf at `index` reaches through `proof`, as `get_merkle_root` walks it: each entry is a sibling's first
/// 20 bytes, and the index must run out exactly at the root.
pub fn root_from_proof(index: usize, leaf: [u8; 32], proof: &[[u8; ENTRY]]) -> Option<[u8; 32]> {
    let mut node = leaf;
    let mut index = index;
    for sibling in proof {
        let mut other = [0u8; 32];
        other[..ENTRY].copy_from_slice(sibling);
        node = if index.is_multiple_of(2) {
            join(&node, &other)
        } else {
            join(&other, &node)
        };
        index >>= 1;
    }
    (index == 0).then_some(node)
}

/// A block id from its FEC sets' roots and its parent.
pub fn block_id(
    fec_roots: &[[u8; 32]],
    parent_slot: u64,
    parent_block_id: &[u8; 32],
) -> Option<[u8; 32]> {
    let count = u32::try_from(fec_roots.len()).ok()?;
    let mut leaves = fec_roots.to_vec();
    leaves.push(parent_leaf(parent_slot, parent_block_id, count));
    root(&leaves)
}

/// An FEC set's root from one shred's signed bytes, its index in the set, and its proof.
pub fn fec_root(
    shred_signed_bytes: &[u8],
    index: usize,
    proof: &[[u8; ENTRY]],
) -> Option<[u8; 32]> {
    let leaf: [u8; 32] = Sha256::new()
        .chain_update(LEAF_PREFIX)
        .chain_update(shred_signed_bytes)
        .finalize()
        .into();
    root_from_proof(index, leaf, proof)
}
