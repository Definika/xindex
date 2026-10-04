//! What the statement writes and hashes, from typed fields, never parsed from bytes a prover gives (as
//! `TronStateVerifier` writes Tron's): RLP as go-ethereum's `rlp` writes it, VeChain's headers, transactions and
//! receipts as vechain/thor writes them, and the ABI words the public values and the calls' data are made of.
//!
//! Anything a prover leaves out or adds makes a hash differ, so it fails closed: a header without a base fee, a
//! transaction with a second clause or a value, a receipt that reverted or logged anything.

use alloc::vec::Vec;
use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use tiny_keccak::{Hasher, Keccak};

use crate::{Address, Fees, Header, Receipt, Transaction, Word};

/// `thor.Blake2b`: blake2b with a 32-byte output.
pub fn blake2b(parts: &[&[u8]]) -> Word {
    let mut h = Blake2b::<U32>::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

pub fn keccak(parts: &[&[u8]]) -> Word {
    let mut k = Keccak::v256();
    for p in parts {
        k.update(p);
    }
    let mut out = [0u8; 32];
    k.finalize(&mut out);
    out
}

// ---------------------------------------------------------------------------
// RLP
// ---------------------------------------------------------------------------

fn length(out: &mut Vec<u8>, len: usize, offset: u8) {
    if len < 56 {
        out.push(offset + len as u8);
    } else {
        let be = (len as u64).to_be_bytes();
        let skip = be.iter().take_while(|b| **b == 0).count();
        out.push(offset + 55 + (8 - skip) as u8);
        out.extend_from_slice(&be[skip..]);
    }
}

/// A byte string.
pub fn bytes(out: &mut Vec<u8>, b: &[u8]) {
    if b.len() == 1 && b[0] < 0x80 {
        out.push(b[0]);
    } else {
        length(out, b.len(), 0x80);
        out.extend_from_slice(b);
    }
}

/// An integer: its big-endian bytes without leading zeros, zero the empty string.
pub fn uint(out: &mut Vec<u8>, v: u64) {
    let be = v.to_be_bytes();
    let skip = be.iter().take_while(|b| **b == 0).count();
    bytes(out, &be[skip..]);
}

/// A 256-bit integer given big-endian, as `*big.Int` encodes.
pub fn uint256(out: &mut Vec<u8>, v: &Word) {
    let skip = v.iter().take_while(|b| **b == 0).count();
    bytes(out, &v[skip..]);
}

/// `true` is `0x01`, `false` the empty string.
pub fn boolean(out: &mut Vec<u8>, v: bool) {
    out.push(if v { 0x01 } else { 0x80 });
}

/// A list of the items already written in `body`.
pub fn list(out: &mut Vec<u8>, body: &[u8]) {
    length(out, body.len(), 0xc0);
    out.extend_from_slice(body);
}

fn listed(body: Vec<u8>) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 9);
    list(&mut out, &body);
    out
}

// ---------------------------------------------------------------------------
// headers
// ---------------------------------------------------------------------------

/// The signed fields, `block/header.go`'s `signingFields`: since Galactica the extension `[alpha, COM, baseFee]` is
/// among them, so the signer signs its COM vote. The statement writes it always: a header without a base fee hashes
/// differently and is refused.
pub fn signing_rlp(h: &Header) -> Vec<u8> {
    let mut body = Vec::with_capacity(320);
    bytes(&mut body, &h.parent_id);
    uint(&mut body, h.timestamp);
    uint(&mut body, h.gas_limit);
    bytes(&mut body, &h.beneficiary);
    uint(&mut body, h.gas_used);
    uint(&mut body, h.total_score);
    // `txsRootFeatures`: the bare root while no feature is on, else `[root, features]`.
    if h.txs_features == 0 {
        bytes(&mut body, &h.txs_root);
    } else {
        let mut trf = Vec::with_capacity(40);
        bytes(&mut trf, &h.txs_root);
        uint(&mut trf, u64::from(h.txs_features));
        list(&mut body, &trf);
    }
    bytes(&mut body, &h.state_root);
    bytes(&mut body, &h.receipts_root);
    let mut ext = Vec::with_capacity(48);
    bytes(&mut ext, &h.alpha);
    boolean(&mut ext, h.com);
    uint256(&mut ext, &h.base_fee);
    list(&mut body, &ext);
    listed(body)
}

pub fn signing_hash(h: &Header) -> Word {
    blake2b(&[&signing_rlp(h)])
}

/// A block's number: its parent's, in the first 4 bytes of the parent's id, plus one.
pub fn number(h: &Header) -> Option<u32> {
    u32::from_be_bytes([
        h.parent_id[0],
        h.parent_id[1],
        h.parent_id[2],
        h.parent_id[3],
    ])
    .checked_add(1)
}

/// `Header.ID`: the number, then the last 28 bytes of `blake2b(signingHash ++ signer)`.
pub fn block_id(number: u32, signing_hash: &Word, signer: &Address) -> Word {
    let mut id = blake2b(&[signing_hash, signer]);
    id[..4].copy_from_slice(&number.to_be_bytes());
    id
}

// ---------------------------------------------------------------------------
// transactions and receipts
// ---------------------------------------------------------------------------

/// `tx.TypeDynamicFee`; a legacy transaction has no type byte.
pub const DYNAMIC_FEE: u8 = 0x51;

/// A transaction's leaf in its block's transactions trie (`Transaction.MarshalBinary`), with one clause: `to`, no
/// value, `data`. Its other fields come typed; `reserved` is the features word alone, trimmed, as consensus requires
/// (`TestFeatures` refuses any unused reserved slot).
pub fn transaction(t: &Transaction, to: &Address, data: &[u8]) -> Vec<u8> {
    let mut clause = Vec::with_capacity(data.len() + 32);
    bytes(&mut clause, to);
    uint(&mut clause, 0);
    bytes(&mut clause, data);
    let mut clauses = Vec::with_capacity(clause.len() + 4);
    list(&mut clauses, &listed(clause));

    let mut body = Vec::with_capacity(clauses.len() + 160);
    uint(&mut body, u64::from(t.chain_tag));
    uint(&mut body, t.block_ref);
    uint(&mut body, u64::from(t.expiration));
    body.extend_from_slice(&clauses);
    match &t.fees {
        Fees::Legacy { gas_price_coef } => uint(&mut body, u64::from(*gas_price_coef)),
        Fees::Dynamic {
            max_priority_fee_per_gas,
            max_fee_per_gas,
        } => {
            uint256(&mut body, max_priority_fee_per_gas);
            uint256(&mut body, max_fee_per_gas);
        }
    }
    uint(&mut body, t.gas);
    match &t.depends_on {
        Some(id) => bytes(&mut body, id),
        None => bytes(&mut body, &[]),
    }
    uint(&mut body, t.nonce);
    let mut reserved = Vec::with_capacity(6);
    if t.features != 0 {
        uint(&mut reserved, u64::from(t.features));
    }
    list(&mut body, &reserved);
    bytes(&mut body, &t.signature);
    typed(t.fees.is_dynamic(), listed(body))
}

/// One clause's outputs with no event and no transfer, `[[[], []]]`: what a call to a view leaves.
pub const NO_OUTPUTS: [u8; 4] = [0xc3, 0xc2, 0xc0, 0xc0];

/// A receipt's leaf in its block's receipts trie (`Receipt.MarshalBinary`), typed as its transaction is, with
/// `reverted` written false and the outputs as given, already encoded. The fields before `reverted` are typed and each
/// encoding delimits itself, so whatever follows, a leaf equal to this one says the transaction did not revert.
pub fn receipt(dynamic: bool, r: &Receipt, outputs: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(96 + outputs.len());
    uint(&mut body, r.gas_used);
    bytes(&mut body, &r.gas_payer);
    uint256(&mut body, &r.paid);
    uint256(&mut body, &r.reward);
    boolean(&mut body, false);
    body.extend_from_slice(outputs);
    typed(dynamic, listed(body))
}

fn typed(dynamic: bool, rlp: Vec<u8>) -> Vec<u8> {
    if !dynamic {
        return rlp;
    }
    let mut out = Vec::with_capacity(rlp.len() + 1);
    out.push(DYNAMIC_FEE);
    out.extend_from_slice(&rlp);
    out
}

/// A transaction's or receipt's key in its block's trie: `rlp(index)`.
pub fn index_key(index: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(5);
    uint(&mut out, u64::from(index));
    out
}

// ---------------------------------------------------------------------------
// ABI
// ---------------------------------------------------------------------------

pub fn word_u64(v: u64) -> Word {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&v.to_be_bytes());
    w
}

pub fn word_address(a: &Address) -> Word {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

/// `abi.encode(bytes32[] slots, bytes32[] values)`.
pub fn abi_slots_values(slots: &[Word], values: &[Word]) -> Vec<u8> {
    let n = slots.len();
    let mut out = Vec::with_capacity(32 * (4 + slots.len() + values.len()));
    out.extend_from_slice(&word_u64(64));
    out.extend_from_slice(&word_u64(64 + 32 + 32 * n as u64));
    out.extend_from_slice(&word_u64(n as u64));
    for s in slots {
        out.extend_from_slice(s);
    }
    out.extend_from_slice(&word_u64(values.len() as u64));
    for v in values {
        out.extend_from_slice(v);
    }
    out
}

/// `IXindexVault.attest(bytes32[],bytes32[])`'s selector.
pub const VAULT_ATTEST: [u8; 4] = [0xe9, 0x1e, 0x56, 0xd4];
/// `VeChainStakerAttester.attest(bytes32)`'s selector.
pub const STAKER_ATTEST: [u8; 4] = [0x23, 0xc3, 0x61, 0x7f];

/// The vault's call: `abi.encodeCall(IXindexVault.attest, (slots, values))`.
pub fn vault_attest(slots: &[Word], values: &[Word]) -> Vec<u8> {
    let mut out = VAULT_ATTEST.to_vec();
    out.extend_from_slice(&abi_slots_values(slots, values));
    out
}

/// The attester's call: `abi.encodeCall(VeChainStakerAttester.attest, (table))`.
pub fn staker_attest(table: &Word) -> Vec<u8> {
    let mut out = STAKER_ATTEST.to_vec();
    out.extend_from_slice(table);
    out
}
