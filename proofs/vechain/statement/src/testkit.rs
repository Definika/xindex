//! Synthetic chains signed with test keys, for the tests and the host: headers written and signed through the
//! statement's own encoding (which the real-data tests pin to thor's), transactions tries built here, and claims
//! assembled around them. Never in the program; never a real key.

use alloc::boxed::Box;
use alloc::vec;
use alloc::vec::Vec;
use k256::ecdsa::SigningKey;

use crate::encode::{self, blake2b, keccak};
use crate::{
    Address, Attested, Call, Common, Fees, Header, Input, Receipt, Table, Transaction, Word, EPOCH,
};

pub struct Validator {
    pub key: SigningKey,
    pub address: Address,
    /// In whole VET.
    pub weight: u64,
}

/// Validators with test keys derived from `salt`, weighing `weights` VET each.
pub fn validators(salt: &[u8], weights: &[u64]) -> Vec<Validator> {
    weights
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let seed = keccak(&[b"xindex vechain testkit", salt, &(i as u64).to_be_bytes()]);
            let key = SigningKey::from_slice(&seed).expect("a test key");
            let point = key.verifying_key().to_encoded_point(false);
            let mut address = [0u8; 20];
            address.copy_from_slice(&keccak(&[&point.as_bytes()[1..]])[12..]);
            Validator {
                key,
                address,
                weight: *w,
            }
        })
        .collect()
}

fn wei(vet: u64) -> Word {
    let mut w = [0u8; 32];
    w[16..].copy_from_slice(&(u128::from(vet) * 1_000_000_000_000_000_000).to_be_bytes());
    w
}

/// The table of `vals`, its total their sum.
pub fn table(vals: &[Validator]) -> Table {
    Table {
        total_weight: wei(vals.iter().map(|v| v.weight).sum()),
        validators: vals.iter().map(|v| (v.address, wei(v.weight))).collect(),
    }
}

/// Signs `h` with `key`: secp256k1's 65 bytes, then 81 bytes standing in for the VRF proof, which nothing checks here.
pub fn sign(h: &mut Header, key: &SigningKey) {
    let hash = encode::signing_hash(h);
    let (sig, recid) = key.sign_prehash_recoverable(&hash).expect("signs");
    let mut out = sig.to_bytes().to_vec();
    out.push(recid.to_byte());
    out.extend_from_slice(&[0u8; 81]);
    h.signature = out;
}

// ---------------------------------------------------------------------------
// tries
// ---------------------------------------------------------------------------

enum Node {
    Leaf(Vec<u8>, Vec<u8>),
    Ext(Vec<u8>, Box<Node>),
    Branch(Vec<Option<Node>>),
}

fn nibbles(b: &[u8]) -> Vec<u8> {
    b.iter().flat_map(|x| [x >> 4, x & 15]).collect()
}

fn compact(n: &[u8], leaf: bool) -> Vec<u8> {
    let flag = if leaf { 2 } else { 0 };
    let mut out = Vec::new();
    let rest = if n.len() % 2 == 1 {
        out.push(((flag + 1) << 4) | n[0]);
        &n[1..]
    } else {
        out.push(flag << 4);
        n
    };
    out.extend(rest.chunks(2).map(|c| (c[0] << 4) | c[1]));
    out
}

fn build_node(items: Vec<(Vec<u8>, Vec<u8>)>) -> Option<Node> {
    if items.is_empty() {
        return None;
    }
    if items.len() == 1 {
        let (k, v) = items.into_iter().next().unwrap();
        return Some(Node::Leaf(k, v));
    }
    let first = items[0].0.clone();
    let mut common = 0;
    while items
        .iter()
        .all(|(k, _)| k.len() > common && k[common] == first[common])
    {
        common += 1;
    }
    if common > 0 {
        let rest = items
            .into_iter()
            .map(|(k, v)| (k[common..].to_vec(), v))
            .collect();
        return Some(Node::Ext(
            first[..common].to_vec(),
            Box::new(build_node(rest).unwrap()),
        ));
    }
    let mut children = Vec::with_capacity(16);
    for n in 0..16u8 {
        let sub: Vec<_> = items
            .iter()
            .filter(|(k, _)| k[0] == n)
            .map(|(k, v)| (k[1..].to_vec(), v.clone()))
            .collect();
        children.push(build_node(sub));
    }
    Some(Node::Branch(children))
}

fn node_rlp(n: &Node) -> Vec<u8> {
    let mut body = Vec::new();
    match n {
        Node::Leaf(k, v) => {
            encode::bytes(&mut body, &compact(k, true));
            encode::bytes(&mut body, v);
        }
        Node::Ext(k, c) => {
            encode::bytes(&mut body, &compact(k, false));
            reference(&mut body, c);
        }
        Node::Branch(children) => {
            for c in children {
                match c {
                    Some(c) => reference(&mut body, c),
                    None => encode::bytes(&mut body, &[]),
                }
            }
            encode::bytes(&mut body, &[]);
        }
    }
    let mut out = Vec::new();
    encode::list(&mut out, &body);
    out
}

fn reference(out: &mut Vec<u8>, n: &Node) {
    let e = node_rlp(n);
    if e.len() < 32 {
        out.extend_from_slice(&e);
    } else {
        encode::bytes(out, &blake2b(&[&e]));
    }
}

/// `trie.DeriveRoot` over `values`, and the proof of index `index` (the hashed nodes from the root to its leaf).
pub fn trie(values: &[Vec<u8>], index: Option<u32>) -> (Word, Vec<Vec<u8>>) {
    if values.is_empty() {
        return (blake2b(&[&[0x80]]), vec![]);
    }
    let items = values
        .iter()
        .enumerate()
        .map(|(i, v)| (nibbles(&encode::index_key(i as u32)), v.clone()))
        .collect();
    let root = build_node(items).unwrap();
    let root_hash = blake2b(&[&node_rlp(&root)]);
    let mut proof = Vec::new();
    if let Some(i) = index {
        let mut key = nibbles(&encode::index_key(i));
        let mut node = &root;
        let mut hashed = true;
        loop {
            let e = node_rlp(node);
            if hashed {
                proof.push(e);
            }
            node = match node {
                Node::Leaf(..) => break,
                Node::Ext(k, c) => {
                    key = key[k.len()..].to_vec();
                    c
                }
                Node::Branch(children) => {
                    let c = children[key[0] as usize].as_ref().unwrap();
                    key = key[1..].to_vec();
                    c
                }
            };
            hashed = node_rlp(node).len() >= 32;
        }
    }
    (root_hash, proof)
}

// ---------------------------------------------------------------------------
// chains and claims
// ---------------------------------------------------------------------------

/// A transaction calling `to` with `data`, and its receipt, as a test chain's block holds them.
pub fn transaction(chain_tag: u8, nonce: u64, dynamic: bool) -> (Transaction, Receipt) {
    let fees = if dynamic {
        Fees::Dynamic {
            max_priority_fee_per_gas: wei(0),
            max_fee_per_gas: {
                let mut w = [0u8; 32];
                w[24..].copy_from_slice(&20_000_000_000_000u64.to_be_bytes());
                w
            },
        }
    } else {
        Fees::Legacy { gas_price_coef: 0 }
    };
    let t = Transaction {
        chain_tag,
        block_ref: 0x018c_f3a8_0000_0000 + nonce,
        expiration: 720,
        fees,
        gas: 1_000_000,
        depends_on: None,
        nonce,
        features: 0,
        signature: keccak(&[b"testkit tx", &nonce.to_be_bytes()]).repeat(2),
    };
    let r = Receipt {
        gas_used: 700_000,
        gas_payer: [0x11; 20],
        paid: wei(7),
        reward: wei(2),
    };
    (t, r)
}

/// One block of a test chain: who signs it, its vote, and its calls (to, data, outputs).
pub struct Block {
    pub signer: usize,
    pub com: bool,
    pub calls: Vec<(Address, Vec<u8>, Vec<u8>)>,
}

/// A call as a block holds it: its transaction's and receipt's fields, and the leaves the statement writes for them.
pub type Written = (Transaction, Receipt, Vec<u8>, Vec<u8>);

/// A test chain: its headers, and each block's transactions and receipts as the statement writes them.
pub struct Chain {
    pub headers: Vec<Header>,
    pub calls: Vec<Vec<Written>>,
}

/// Builds blocks `first..` from `blocks`, signed by `vals`, on mainnet's chain tag.
pub fn chain(first: u32, vals: &[Validator], blocks: &[Block]) -> Chain {
    let mut parent = [0u8; 32];
    parent[..4].copy_from_slice(&(first - 1).to_be_bytes());
    parent[4..].copy_from_slice(&keccak(&[b"testkit parent"])[4..]);
    let mut headers = Vec::new();
    let mut all = Vec::new();
    for (i, b) in blocks.iter().enumerate() {
        let mut txs = Vec::new();
        for (j, (to, data, outputs)) in b.calls.iter().enumerate() {
            let (t, r) = transaction(0x4a, (i * 16 + j) as u64, j % 2 == 1);
            let tb = encode::transaction(&t, to, data);
            let rb = encode::receipt(t.fees.is_dynamic(), &r, outputs);
            txs.push((t, r, tb, rb));
        }
        let (txs_root, _) = trie(&txs.iter().map(|x| x.2.clone()).collect::<Vec<_>>(), None);
        let (receipts_root, _) = trie(&txs.iter().map(|x| x.3.clone()).collect::<Vec<_>>(), None);
        let mut base_fee = [0u8; 32];
        base_fee[24..].copy_from_slice(&10_000_000_000_000u64.to_be_bytes());
        let mut h = Header {
            parent_id: parent,
            timestamp: 1_791_000_000 + 10 * i as u64,
            gas_limit: 40_000_000,
            beneficiary: vals[b.signer].address,
            gas_used: 0,
            total_score: 1_000 + i as u64,
            txs_root,
            txs_features: 1,
            state_root: keccak(&[b"testkit state", &parent]),
            receipts_root,
            alpha: blake2b(&[b"testkit beta", &parent]).to_vec(),
            com: b.com,
            base_fee,
            signature: Vec::new(),
        };
        sign(&mut h, &vals[b.signer].key);
        parent = encode::block_id(
            first + i as u32,
            &encode::signing_hash(&h),
            &vals[b.signer].address,
        );
        headers.push(h);
        all.push(txs);
    }
    Chain {
        headers,
        calls: all,
    }
}

impl Chain {
    /// The proof of block `block`'s call `index`.
    pub fn call(&self, block: usize, index: usize) -> Call {
        let txs = &self.calls[block];
        let (_, transaction_proof) = trie(
            &txs.iter().map(|x| x.2.clone()).collect::<Vec<_>>(),
            Some(index as u32),
        );
        let (_, receipt_proof) = trie(
            &txs.iter().map(|x| x.3.clone()).collect::<Vec<_>>(),
            Some(index as u32),
        );
        Call {
            block: block as u32,
            index: index as u32,
            transaction: txs[index].0.clone(),
            receipt: txs[index].1.clone(),
            transaction_proof,
            receipt_proof,
        }
    }
}

/// Mainnet's genesis id, whose last byte is the chain tag the test transactions carry.
pub const CHAIN: Word = [
    0x00, 0x00, 0x00, 0x00, 0x85, 0x1c, 0xaf, 0x3c, 0xfd, 0xb6, 0xe8, 0x99, 0xcf, 0x59, 0x58, 0xbf,
    0xb1, 0xac, 0x34, 0x13, 0xd3, 0x46, 0xd4, 0x35, 0x39, 0x62, 0x7e, 0x6b, 0xe7, 0xec, 0x1b, 0x4a,
];
pub const ATTESTER: Address = [0xa7; 20];
pub const VAULT: Address = [0x5a; 20];

/// A slots claim on a test chain: the vault's call in block `y`, the tables of rounds `k` and `r` attested in blocks
/// `xk` and `xr`, all block numbers, the chain from `first` to `last`, each block signed by `signer(number)` with
/// vote `com(number)`, and the trusted table `trusted` at a block before `first`.
pub struct Plan<'a> {
    pub vals: &'a [Validator],
    pub trusted: Table,
    pub table_k: Table,
    pub table_r: Table,
    pub first: u32,
    pub last: u32,
    pub y: u32,
    pub xk: u32,
    pub xr: u32,
    pub signer: &'a dyn Fn(u32) -> usize,
    pub com: &'a dyn Fn(u32) -> bool,
}

pub fn slots_of(p: &Plan) -> Input {
    let slots = vec![[0x01; 32], {
        let mut w = [0u8; 32];
        w[31] = 25;
        w
    }];
    let values = vec![[0x02; 32], [0u8; 32]];
    let hk = crate::weights(&p.table_k).unwrap().hash;
    let hr = crate::weights(&p.table_r).unwrap().hash;
    let blocks: Vec<Block> = (p.first..=p.last)
        .map(|n| {
            let mut calls = Vec::new();
            if n == p.y {
                calls.push((
                    VAULT,
                    encode::vault_attest(&slots, &values),
                    encode::NO_OUTPUTS.to_vec(),
                ));
            }
            if n == p.xk {
                calls.push((
                    ATTESTER,
                    encode::staker_attest(&hk),
                    encode::NO_OUTPUTS.to_vec(),
                ));
            }
            if n == p.xr {
                calls.push((
                    ATTESTER,
                    encode::staker_attest(&hr),
                    encode::NO_OUTPUTS.to_vec(),
                ));
            }
            Block {
                signer: (p.signer)(n),
                com: (p.com)(n),
                calls,
            }
        })
        .collect();
    let c = chain(p.first, p.vals, &blocks);
    let at = |n: u32| (n - p.first) as usize;
    // The calls sit in their blocks in the order pushed above: the vault's, round k's table, round r's.
    let idx = |which: usize| -> usize {
        let ns = [p.y, p.xk, p.xr];
        ns[..which].iter().filter(|m| **m == ns[which]).count()
    };
    let mut trusted_id = [0x77u8; 32];
    trusted_id[..4].copy_from_slice(&(p.first - 10).to_be_bytes());
    Input::Slots {
        common: Common {
            chain: CHAIN,
            attester: ATTESTER,
            trusted_id,
            trusted: p.trusted.clone(),
            headers: c.headers.clone(),
        },
        vault: VAULT,
        slots,
        values,
        call: c.call(at(p.y), idx(0)),
        justified: Attested {
            table: p.table_k.clone(),
            call: c.call(at(p.xk), idx(1)),
        },
        committed: Attested {
            table: p.table_r.clone(),
            call: c.call(at(p.xr), idx(2)),
        },
    }
}

/// The plan most tests vary: `vals` all signing in turn from the last block of round `EPOCH * 100 - 1`, the vault's
/// call there, the tables attested in the second block of rounds 100 and 101, every vote COM, and the chain ending
/// with round 101.
pub fn default_plan<'a>(
    vals: &'a [Validator],
    signer: &'a dyn Fn(u32) -> usize,
    com: &'a dyn Fn(u32) -> bool,
) -> Plan<'a> {
    let k = 100 * EPOCH;
    Plan {
        vals,
        trusted: table(vals),
        table_k: table(vals),
        table_r: table(vals),
        first: k - 1,
        last: k + 2 * EPOCH - 1,
        y: k - 1,
        xk: k + 1,
        xr: k + EPOCH + 1,
        signer,
        com,
    }
}
