//! Execution-layer headers: the few fields a vault needs, read from a header's RLP, and the keccak tree the proof
//! commits to over them.

use crate::Root;
use tiny_keccak::{Hasher, Keccak};

pub fn keccak(parts: &[&[u8]]) -> Root {
    let mut k = Keccak::v256();
    for p in parts {
        k.update(p);
    }
    let mut out = [0u8; 32];
    k.finalize(&mut out);
    out
}

/// What the proof keeps of an execution header, with the header's own hash.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExecHeader {
    pub hash: Root,
    pub parent_hash: Root,
    pub state_root: Root,
    pub receipts_root: Root,
    pub number: u64,
    pub timestamp: u64,
}

impl ExecHeader {
    /// `keccak256(abi.encode(uint256 number, uint256 timestamp, bytes32 stateRoot, bytes32 receiptsRoot))`, the leaf a
    /// verifier on a vault chain recomputes.
    pub fn leaf(&self) -> Root {
        let mut n = [0u8; 32];
        n[24..].copy_from_slice(&self.number.to_be_bytes());
        let mut t = [0u8; 32];
        t[24..].copy_from_slice(&self.timestamp.to_be_bytes());
        keccak(&[&n, &t, &self.state_root, &self.receipts_root])
    }
}

/// Reads a header from its RLP: a list whose fields are all strings. It keeps the parent hash (0), the state root (3),
/// the receipts root (5), the number (8) and the timestamp (11), and hashes the whole RLP. Any later fields, as each
/// fork adds, are read past, so the header's own hash still binds them.
pub fn parse_header(rlp: &[u8]) -> Option<ExecHeader> {
    let (payload_start, payload_len, is_list) = prefix(rlp, 0)?;
    if !is_list || payload_start + payload_len != rlp.len() {
        return None;
    }
    let mut fields: Vec<&[u8]> = Vec::with_capacity(21);
    let mut at = payload_start;
    while at < rlp.len() {
        let (start, len, is_list) = prefix(rlp, at)?;
        if is_list || start + len > rlp.len() {
            return None;
        }
        fields.push(&rlp[start..start + len]);
        at = start + len;
    }
    if fields.len() < 16 {
        return None;
    }
    Some(ExecHeader {
        hash: keccak(&[rlp]),
        parent_hash: word(fields[0])?,
        state_root: word(fields[3])?,
        receipts_root: word(fields[5])?,
        number: integer(fields[8])?,
        timestamp: integer(fields[11])?,
    })
}

/// The item at `at`: where its payload starts, how long it is, and whether it is a list.
fn prefix(data: &[u8], at: usize) -> Option<(usize, usize, bool)> {
    let b = *data.get(at)? as usize;
    let (start, len, is_list) = match b {
        0x00..=0x7f => (at, 1, false),
        0x80..=0xb7 => (at + 1, b - 0x80, false),
        0xb8..=0xbf => {
            let n = b - 0xb7;
            (at + 1 + n, be(data.get(at + 1..at + 1 + n)?)?, false)
        }
        0xc0..=0xf7 => (at + 1, b - 0xc0, true),
        _ => {
            let n = b - 0xf7;
            (at + 1 + n, be(data.get(at + 1..at + 1 + n)?)?, true)
        }
    };
    if start.checked_add(len)? > data.len() {
        return None;
    }
    Some((start, len, is_list))
}

fn be(bytes: &[u8]) -> Option<usize> {
    if bytes.len() > 8 {
        return None;
    }
    Some(bytes.iter().fold(0usize, |acc, b| (acc << 8) | *b as usize))
}

fn word(bytes: &[u8]) -> Option<Root> {
    bytes.try_into().ok()
}

fn integer(bytes: &[u8]) -> Option<u64> {
    if bytes.len() > 8 {
        return None;
    }
    Some(bytes.iter().fold(0u64, |acc, b| (acc << 8) | *b as u64))
}

/// The keccak Merkle root over `leaves`, layer by layer, a zero node standing in for the missing sibling of an odd
/// layer's last node; a single leaf is its own root. Its depth is `ceil(log2(len))`, and a proof of leaf `i` is its
/// siblings from the bottom up, zeros included.
pub fn keccak_root(leaves: &[Root]) -> Root {
    assert!(!leaves.is_empty(), "no leaves");
    let mut layer = leaves.to_vec();
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            layer.push([0u8; 32]);
        }
        layer = layer.chunks(2).map(|p| keccak(&[&p[0], &p[1]])).collect();
    }
    layer[0]
}
